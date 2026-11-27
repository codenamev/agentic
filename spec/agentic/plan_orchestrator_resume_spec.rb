# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Agentic::PlanOrchestrator, "resume_from:" do
  let(:dir) { Dir.mktmpdir }
  let(:journal_path) { File.join(dir, "plan.journal.jsonl") }
  let(:calls) { Hash.new(0) }

  after { FileUtils.remove_entry(dir) }

  # A fresh process rebuilds the plan: same descriptions, new task ids
  def build_chain(journal, fail_on: nil)
    tasks = (1..5).map do |n|
      Agentic::Task.new(description: "step #{n}", agent_spec: {"name" => "w", "instructions" => "w"}, input: {})
    end
    orchestrator = described_class.new(concurrency_limit: 1, lifecycle_hooks: journal.lifecycle_hooks)
    agent = lambda do |task|
      calls[task.description] += 1
      raise "boom" if task.description == fail_on
      upstream = task.dependency_outputs.values.first
      upstream ? "#{upstream}>#{task.description}" : task.description
    end
    tasks.each_with_index do |task, i|
      orchestrator.add_task(task, i.zero? ? [] : [tasks[i - 1].id], agent: agent)
    end
    [orchestrator, tasks]
  end

  def journal
    Agentic::ExecutionJournal.new(path: journal_path)
  end

  it "skips tasks the journal proves completed and finishes the rest" do
    first, = build_chain(journal, fail_on: "step 4")
    expect(first.execute_plan.status).not_to eq(:completed)
    expect(calls.values_at("step 1", "step 2", "step 3")).to eq([1, 1, 1])

    state = Agentic::ExecutionJournal.replay(path: journal_path)
    second, tasks = build_chain(journal)
    result = second.execute_plan(resume_from: state)

    expect(result.status).to eq(:completed)
    expect(calls.values_at("step 1", "step 2", "step 3")).to eq([1, 1, 1])
    expect(calls.values_at("step 4", "step 5")).to eq([2, 1])
    expect(result.results[tasks[4].id].output).to eq("step 1>step 2>step 3>step 4>step 5")
    expect(tasks[0].status).to eq(:completed)
  end

  it "resumes over a torn journal in tolerant mode" do
    first, = build_chain(journal, fail_on: "step 4")
    first.execute_plan
    File.open(journal_path, "a") { |f| f.write("{\"event\":\"task_succ") }

    state = Agentic::ExecutionJournal.replay(path: journal_path, mode: :tolerant)
    expect(state).to be_damaged
    second, = build_chain(journal)

    expect(second.execute_plan(resume_from: state).status).to eq(:completed)
    expect(calls["step 1"]).to eq(1)
  end

  it "runs everything when the journal records nothing for this plan" do
    File.write(journal_path, "")
    state = Agentic::ExecutionJournal.replay(path: journal_path)
    orchestrator, = build_chain(journal)

    expect(orchestrator.execute_plan(resume_from: state).status).to eq(:completed)
    expect(calls.values).to all(eq(1))
  end
end
