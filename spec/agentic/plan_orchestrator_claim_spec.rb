# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Agentic::PlanOrchestrator, "resume claim (C16)" do
  let(:dir) { Dir.mktmpdir }
  let(:journal_path) { File.join(dir, "plan.journal.jsonl") }
  let(:calls) { Hash.new(0) }

  after { FileUtils.remove_entry(dir) }

  def journal
    Agentic::ExecutionJournal.new(path: journal_path)
  end

  def build_chain(fail_on: nil, on_run: nil)
    tasks = (1..3).map do |n|
      Agentic::Task.new(description: "step #{n}", agent_spec: {"name" => "w", "instructions" => "w"}, input: {})
    end
    orchestrator = described_class.new(concurrency_limit: 1, lifecycle_hooks: journal.lifecycle_hooks)
    agent = lambda do |task|
      calls[task.description] += 1
      on_run&.call(task)
      raise "boom" if task.description == fail_on
      task.description
    end
    tasks.each_with_index do |task, i|
      orchestrator.add_task(task, i.zero? ? [] : [tasks[i - 1].id], agent: agent)
    end
    orchestrator
  end

  def failed_once_state
    expect(build_chain(fail_on: "step 2").execute_plan.status).not_to eq(:completed)
    calls.clear
    Agentic::ExecutionJournal.replay(path: journal_path)
  end

  it "refuses to resume a journal another resumer holds, running nothing" do
    state = failed_once_state
    held = Agentic::ExecutionJournal.claim(journal_path)

    expect { build_chain.execute_plan(resume_from: state) }
      .to raise_error(Agentic::Errors::JournalBusyError, /already being resumed/) { |e| expect(e.path).to eq(File.expand_path(journal_path)) }
    expect(calls).to be_empty
  ensure
    held&.close
  end

  it "holds the claim for the whole run and releases it afterwards" do
    state = failed_once_state
    busy_during_run = nil
    probe = lambda do |_task|
      Agentic::ExecutionJournal.claim(journal_path).close
      busy_during_run = false
    rescue Agentic::Errors::JournalBusyError
      busy_during_run = true
    end

    expect(build_chain(on_run: probe).execute_plan(resume_from: state).status).to eq(:completed)
    expect(busy_during_run).to be(true)
    expect { Agentic::ExecutionJournal.claim(journal_path).close }.not_to raise_error
  end

  it "releases the claim when the resumed run raises" do
    state = failed_once_state
    orchestrator = build_chain
    allow(orchestrator).to receive(:ensure_agents_resolvable!).and_raise(ArgumentError, "no agent")

    expect { orchestrator.execute_plan(resume_from: state) }.to raise_error(ArgumentError, "no agent")
    expect { Agentic::ExecutionJournal.claim(journal_path).close }.not_to raise_error
  end

  it "takes no claim on a fresh run" do
    held = Agentic::ExecutionJournal.claim(journal_path)
    expect(build_chain.execute_plan.status).to eq(:completed)
  ensure
    held&.close
  end
end
