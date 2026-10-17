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

    it "still lands a line when the payload cannot be serialized" do
      binary = (+"caf\xE9").force_encoding(Encoding::BINARY)
      journal.record(:task_succeeded, task_id: "t-bin", description: "Fetch page", output: {body: binary})

      lines = File.readlines(path)
      expect(lines.size).to eq(1)
      entry = JSON.parse(lines.first)
      expect(entry).to include("event" => "task_succeeded", "task_id" => "t-bin", "description" => "Fetch page")
      expect(entry).to have_key("at")
      expect(entry["payload_error"]).to eq("JSON::GeneratorError")
      expect(entry["payload_inspect"]).to include("t-bin")

      state = described_class.replay(path: path, mode: :strict)
      expect(state.completed_task_ids).to eq(["t-bin"])
    end

    it "survives a payload with a symbol and a string spelling of the same key" do
      journal.record(:task_succeeded, task_id: "t-dup", output: {:k => 1, "k" => 2})

      expect(File.readlines(path).size).to eq(1)
      state = described_class.replay(path: path)
      expect(state.completed_task_ids).to eq(["t-dup"])
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
