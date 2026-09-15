# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::TaskDefinition do
  let(:agent) do
    Agentic::AgentSpecification.new(
      name: "ResearchAgent",
      description: "An agent that performs research",
      instructions: "Research the given topic thoroughly"
    )
  end

  let(:task_definition) do
    described_class.new(
      description: "Research AI trends",
      agent: agent
    )
  end

  describe "#initialize" do
    it "sets the description and agent" do
      expect(task_definition.description).to eq("Research AI trends")
      expect(task_definition.agent).to eq(agent)
    end
  end

  describe "#to_h" do
    it "returns a hash representation of the task definition" do
      expect(task_definition.to_h).to eq({
        "description" => "Research AI trends",
        "agent" => {
          "name" => "ResearchAgent",
          "description" => "An agent that performs research",
          "instructions" => "Research the given topic thoroughly"
        }
      })
    end
  end

  describe ".from_hash" do
    let(:hash) do
      {
        "description" => "Research AI trends",
        "agent" => {
          "name" => "ResearchAgent",
          "description" => "An agent that performs research",
          "instructions" => "Research the given topic thoroughly"
        }
      }
    end

    it "creates a TaskDefinition from a hash" do
      task = described_class.from_hash(hash)
      expect(task).to be_a(described_class)
      expect(task.description).to eq("Research AI trends")
      expect(task.agent).to be_a(Agentic::AgentSpecification)
      expect(task.agent.name).to eq("ResearchAgent")
      expect(task.agent.description).to eq("An agent that performs research")
      expect(task.agent.instructions).to eq("Research the given topic thoroughly")
    end
  end
end

RSpec.describe Agentic::TaskDefinition, "dependency graph fields" do
  let(:agent) do
    Agentic::AgentSpecification.new(name: "Writer", description: "Writes", instructions: "Write it")
  end

  it "defaults to a flat task with no graph fields" do
    task = described_class.new(description: "Write", agent: agent)
    expect(task.id).to be_nil
    expect(task.depends_on).to eq([])
    expect(task.needs).to eq({})
    expect(task.dependencies).to eq([])
  end

  it "normalizes ids, depends_on and needs to strings" do
    task = described_class.new(description: "Write", agent: agent, id: :write, depends_on: [:research], needs: {findings: :research})
    expect(task.id).to eq("write")
    expect(task.depends_on).to eq(["research"])
    expect(task.needs).to eq({"findings" => "research"})
  end

  it "unions depends_on and needs into dependencies" do
    task = described_class.new(description: "Write", agent: agent, depends_on: ["research", "outline"], needs: {"findings" => "research"})
    expect(task.dependencies).to eq(["research", "outline"])
  end

  describe "#to_h" do
    it "omits graph fields when unset so flat plans keep their shape" do
      hash = described_class.new(description: "Write", agent: agent).to_h
      expect(hash.keys).to eq(["description", "agent"])
    end

    it "includes graph fields when set" do
      hash = described_class.new(description: "Write", agent: agent, id: "write", depends_on: ["research"], needs: {"findings" => "research"}).to_h
      expect(hash).to include("id" => "write", "depends_on" => ["research"], "needs" => {"findings" => "research"})
    end
  end

  describe ".from_hash" do
    it "round-trips graph fields" do
      original = described_class.new(description: "Write", agent: agent, id: "write", depends_on: ["research"], needs: {"findings" => "research"})
      restored = described_class.from_hash(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end

    it "reads a hash without graph fields as a flat task" do
      task = described_class.from_hash("description" => "Write", "agent" => agent.to_h)
      expect(task.dependencies).to eq([])
    end
  end
end

RSpec.describe Agentic::TaskDefinition, "on_failure policy" do
  let(:agent) do
    Agentic::AgentSpecification.new(name: "Writer", description: "Writes", instructions: "Write it")
  end

  it "defaults to skip_dependents" do
    task = described_class.new(description: "Write", agent: agent)
    expect(task.on_failure).to eq("skip_dependents")
    expect(task.continue_on_failure?).to be(false)
  end

  it "accepts continue as a string or symbol" do
    expect(described_class.new(description: "Write", agent: agent, on_failure: "continue").continue_on_failure?).to be(true)
    expect(described_class.new(description: "Write", agent: agent, on_failure: :continue).on_failure).to eq("continue")
  end

  it "rejects an unknown policy" do
    expect {
      described_class.new(description: "Write", agent: agent, on_failure: "shrug")
    }.to raise_error(ArgumentError, /skip_dependents, continue/)
  end

  it "serializes on_failure only when it is not the default" do
    expect(described_class.new(description: "Write", agent: agent).to_h).not_to have_key("on_failure")
    expect(described_class.new(description: "Write", agent: agent, on_failure: "continue").to_h["on_failure"]).to eq("continue")
  end

  it "round-trips through from_hash" do
    original = described_class.new(description: "Write", agent: agent, id: "write", on_failure: "continue")
    restored = described_class.from_hash(original.to_h)
    expect(restored.on_failure).to eq("continue")
    expect(described_class.from_hash("description" => "Write", "agent" => agent.to_h).on_failure).to eq("skip_dependents")
  end
end
