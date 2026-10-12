# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Agentic::ExecutionJournal do
  let(:dir) { Dir.mktmpdir("agentic_journal_test") }
  let(:path) { File.join(dir, "plan.journal.jsonl") }
  let(:journal) { described_class.new(path: path) }

  after { FileUtils.remove_entry(dir) }

  describe "#record" do
    it "appends one JSON line per event" do
      journal.record(:task_started, task_id: "t-1")
      journal.record(:task_succeeded, task_id: "t-1", output: {answer: 42})

      lines = File.readlines(path).map { |line| JSON.parse(line) }
      expect(lines.size).to eq(2)
      expect(lines.first["event"]).to eq("task_started")
      expect(lines.last.dig("output", "answer")).to eq(42)
      expect(lines).to all(have_key("at"))
    end

    it "is safe under concurrent writers" do
      threads = 8.times.map do |i|
        Thread.new do
          10.times { |j| journal.record(:task_started, task_id: "t-#{i}-#{j}") }
        end
      end
      threads.each(&:join)

      lines = File.readlines(path)
      expect(lines.size).to eq(80)
      expect { lines.each { |line| JSON.parse(line) } }.not_to raise_error
    end
  end

  describe "integration with PlanOrchestrator" do
    let(:agent) { double("Agent", execute: {"result" => "done"}) }
    let(:provider) { double("AgentProvider", get_agent_for_task: agent) }

    it "journals task and plan lifecycle events" do
      orchestrator = Agentic::PlanOrchestrator.new(lifecycle_hooks: journal.lifecycle_hooks)
      task = Agentic::Task.new(
        description: "Journaled task",
        agent_spec: {"instructions" => "test"},
        input: {}
      )
      orchestrator.add_task(task)

      orchestrator.execute_plan(provider)

      events = File.readlines(path).map { |line| JSON.parse(line).fetch("event") }
      expect(events).to eq(%w[task_started task_succeeded plan_completed])
    end

    it "records the task's token usage on task_succeeded and replays it" do
      stats = Agentic::GenerationStats.new(id: "gen-1", prompt_tokens: 100, completion_tokens: 50, total_tokens: 150)
      allow(agent).to receive(:last_stats).and_return(stats)
      orchestrator = Agentic::PlanOrchestrator.new(lifecycle_hooks: journal.lifecycle_hooks)
      task = Agentic::Task.new(description: "Costed", agent_spec: {"instructions" => "test"}, input: {})
      orchestrator.add_task(task)

      orchestrator.execute_plan(provider)

      line = File.readlines(path).map { |l| JSON.parse(l) }.find { |e| e["event"] == "task_succeeded" }
      expect(line).to include("prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150)
      state = described_class.replay(path: path)
      expect(state.tokens[task.id]).to eq(prompt_tokens: 100, completion_tokens: 50, total_tokens: 150)
      expect(state.total_tokens).to eq(150)
    end

    it "omits token fields when the result carries no stats" do
      orchestrator = Agentic::PlanOrchestrator.new(lifecycle_hooks: journal.lifecycle_hooks)
      orchestrator.add_task(Agentic::Task.new(description: "Free", agent_spec: {"instructions" => "test"}, input: {}))

      orchestrator.execute_plan(provider)

      line = File.readlines(path).map { |l| JSON.parse(l) }.find { |e| e["event"] == "task_succeeded" }
      expect(line.keys).not_to include("total_tokens")
      state = described_class.replay(path: path)
      expect(state.tokens).to be_empty
      expect(state.total_tokens).to be_nil
    end

    it "chains through existing hooks instead of replacing them" do
      observed = []
      hooks = journal.lifecycle_hooks(
        after_task_success: ->(task_id:, task:, result:, duration:) { observed << task_id }
      )
      orchestrator = Agentic::PlanOrchestrator.new(lifecycle_hooks: hooks)
      task = Agentic::Task.new(description: "Chained", agent_spec: {"instructions" => "test"}, input: {})
      orchestrator.add_task(task)

      orchestrator.execute_plan(provider)

      expect(observed).to eq([task.id])
    end
  end

  describe ".replay" do
    it "returns empty state for a journal that does not exist yet" do
      state = described_class.replay(path: File.join(dir, "missing.jsonl"))

      expect(state.completed_task_ids).to be_empty
      expect(state.status).to be_nil
    end

    it "reconstructs completed work and its outputs" do
      journal.record(:task_started, task_id: "t-1")
      journal.record(:task_succeeded, task_id: "t-1", output: {"answer" => 42})
      journal.record(:task_started, task_id: "t-2")
      journal.record(:task_failed, task_id: "t-2", error: "boom", error_type: "StandardError")
      journal.record(:plan_completed, plan_id: "p-1", status: "partial")

      state = described_class.replay(path: path)

      expect(state.plan_id).to eq("p-1")
      expect(state.status).to eq(:partial)
      expect(state.completed?("t-1")).to be true
      expect(state.outputs["t-1"]).to eq(answer: 42)
      expect(state.failed_task_ids).to eq(["t-2"])
      expect(state.failures["t-2"][:message]).to eq("boom")
    end

    it "treats a retry success after failure as completed" do
      journal.record(:task_failed, task_id: "t-1", error: "flaky", error_type: "TimeoutError")
      journal.record(:task_succeeded, task_id: "t-1", output: {"ok" => true})

      state = described_class.replay(path: path)

      expect(state.completed?("t-1")).to be true
      expect(state.failed_task_ids).to be_empty
      expect(state.failures).to be_empty
    end

    it "answers completed? by description, the cross-run idempotency key" do
      journal.record(:task_succeeded, task_id: "run1-uuid", description: "invoice-3", output: nil)

      state = described_class.replay(path: path)

      expect(state.completed?("invoice-3")).to be true
      expect(state.completed_descriptions).to eq(["invoice-3"])
    end
  end

  describe "descriptions on lifecycle events" do
    let(:agent) { double("Agent", execute: {"ok" => true}) }
    let(:provider) { double("AgentProvider", get_agent_for_task: agent) }

    it "records the task description on success events so reruns can resume by name" do
      orchestrator = Agentic::PlanOrchestrator.new(lifecycle_hooks: journal.lifecycle_hooks)
      task = Agentic::Task.new(description: "monthly-report", agent_spec: {"instructions" => "x"}, input: {})
      orchestrator.add_task(task)
      orchestrator.execute_plan(provider)

      state = described_class.replay(path: path)

      expect(state.completed?("monthly-report")).to be true
    end
  end
end
