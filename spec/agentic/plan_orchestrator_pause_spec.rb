# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Agentic::PlanOrchestrator, "pausing for a human" do
  let(:dir) { Dir.mktmpdir }
  let(:journal_path) { File.join(dir, "plan.journal.jsonl") }
  let(:calls) { Hash.new(0) }

  after { FileUtils.remove_entry(dir) }

  # Stands in for a provider auth failure; TaskFailure types it by class name
  before { stub_const("AuthenticationError", Class.new(StandardError)) }

  # fetch -> report, plus an unrelated sidecar task
  def build(fail_with:)
    journal = Agentic::ExecutionJournal.new(path: journal_path)
    orchestrator = described_class.new(concurrency_limit: 1, lifecycle_hooks: journal.lifecycle_hooks)
    spec = {"name" => "w", "instructions" => "w"}
    fetch, report, sidecar = ["fetch", "report", "sidecar"].map do |d|
      Agentic::Task.new(description: d, agent_spec: spec, input: {})
    end
    agent = lambda do |task|
      calls[task.description] += 1
      raise fail_with, "401 from provider" if fail_with && task.description == "fetch"
      task.description
    end
    orchestrator.add_task(fetch, [], agent: agent)
    orchestrator.add_task(report, [fetch.id], agent: agent)
    orchestrator.add_task(sidecar, [], agent: agent)
    orchestrator
  end

  it "ends with :awaiting_human, holds dependents, and finishes independent work" do
    result = build(fail_with: AuthenticationError).execute_plan

    expect(result.status).to eq(:awaiting_human)
    expect(calls.values_at("fetch", "report", "sidecar")).to eq([1, 0, 1])
  end

  it "journals the pause so another process can find the open question" do
    build(fail_with: AuthenticationError).execute_plan

    state = Agentic::ExecutionJournal.replay(path: journal_path)
    expect(state.awaiting_human.size).to eq(1)
    expect(state.awaiting_human.values.first).to include(error_type: "AuthenticationError", message: "401 from provider")
    expect(state.status).to eq(:awaiting_human)
  end

  it "keeps :partial_failure for ordinary failures" do
    result = build(fail_with: RuntimeError).execute_plan

    expect(result.status).to eq(:partial_failure)
    expect(Agentic::ExecutionJournal.replay(path: journal_path).awaiting_human).to be_empty
  end
end
