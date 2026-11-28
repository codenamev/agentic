# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-023 phase 1: a paused task is journal state, so any process can see
# the open question and the answer that closed it.
RSpec.describe Agentic::ExecutionJournal, "human intervention replay" do
  let(:dir) { Dir.mktmpdir("agentic_journal_intervention") }
  let(:path) { File.join(dir, "plan.journal.jsonl") }
  let(:journal) { described_class.new(path: path) }

  after { FileUtils.remove_entry(dir) }

  def pause(task_id, question: nil, message: "401 from provider")
    journal.record(:task_awaiting_human, task_id: task_id, description: "fetch orders",
      error_type: "AuthenticationError", message: message, question: question)
  end

  it "records an open question with its context" do
    pause("t-1", question: "Which API key should I use?")

    state = described_class.replay(path: path)
    expect(state.awaiting_human?("t-1")).to be(true)
    expect(state.awaiting_human["t-1"]).to include(
      question: "Which API key should I use?", error_type: "AuthenticationError", message: "401 from provider"
    )
    expect(state.awaiting_human["t-1"][:at]).to be_a(String)
    expect(state.failed_task_ids).to be_empty
    expect(state.completed?("t-1")).to be(false)
    expect(state.descriptions["t-1"]).to eq("fetch orders")
  end

  it "falls back to the failure message when no question was supplied" do
    pause("t-1")

    expect(described_class.replay(path: path).awaiting_human["t-1"][:question]).to eq("401 from provider")
  end

  it "clears the pause and records the claim when a human answers" do
    pause("t-1")
    journal.record(:task_human_answered, task_id: "t-1", answer: "use the staging key", answered_by: "val")

    state = described_class.replay(path: path)
    expect(state.awaiting_human?("t-1")).to be(false)
    expect(state.answered?("t-1")).to be(true)
    expect(state.human_answers["t-1"]).to include(answer: "use the staging key", answered_by: "val")
  end

  it "clears the pause when the task later succeeds" do
    pause("t-1")
    journal.record(:task_succeeded, task_id: "t-1", description: "fetch orders", output: {rows: 3})

    state = described_class.replay(path: path)
    expect(state.awaiting_human).to be_empty
    expect(state.completed?("t-1")).to be(true)
  end

  it "ignores a pause for a task the journal already proves completed" do
    journal.record(:task_succeeded, task_id: "t-1", description: "fetch orders", output: {})
    pause("t-1")

    expect(described_class.replay(path: path).awaiting_human).to be_empty
  end

  it "reopens the question when an answered task pauses again" do
    pause("t-1")
    journal.record(:task_human_answered, task_id: "t-1", answer: "wrong key")
    pause("t-1", message: "still 401")

    state = described_class.replay(path: path)
    expect(state.awaiting_human["t-1"][:message]).to eq("still 401")
    expect(state.answered?("t-1")).to be(false)
  end

  it "replays journals written before intervention existed" do
    journal.record(:task_succeeded, task_id: "t-1", description: "a", output: {})
    journal.record(:plan_completed, plan_id: "p", status: "completed", execution_time: 0.1)

    state = described_class.replay(path: path)
    expect(state.awaiting_human).to eq({})
    expect(state.human_answers).to eq({})
  end

  it "reads an awaiting_human plan status" do
    pause("t-1")
    journal.record(:plan_completed, plan_id: "p", status: "awaiting_human", execution_time: 0.1)

    expect(described_class.replay(path: path).status).to eq(:awaiting_human)
  end

  it "treats intervention lines without a task_id as damage" do
    journal.record(:task_awaiting_human, message: "no id")
    journal.record(:task_human_answered, answer: "no id")

    state = described_class.replay(path: path)
    expect(state.damage.map { |d| d[:reason] }).to eq(["missing task_id", "missing task_id"])
    expect { described_class.replay(path: path, mode: :strict) }.to raise_error(Agentic::Errors::JournalDamagedError)
  end
end
