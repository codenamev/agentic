# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::ExecutionPlan do
  let(:agent_spec) do
    Agentic::AgentSpecification.new(
      name: "Researcher",
      description: "Research expert",
      instructions: "Search latest AI trends"
    )
  end

  let(:task_definition) do
    Agentic::TaskDefinition.new(
      description: "Research AI trends",
      agent: agent_spec
    )
  end

  let(:tasks) do
    [task_definition]
  end

  let(:expected_answer) do
    Agentic::ExpectedAnswerFormat.new(
      format: "PDF",
      sections: ["Summary", "Trends"],
      length: "10 pages"
    )
  end

  let(:execution_plan) { described_class.new(tasks, expected_answer) }

  describe "#initialize" do
    it "sets the tasks and expected_answer" do
      expect(execution_plan.tasks).to eq(tasks)
      expect(execution_plan.expected_answer).to eq(expected_answer)
    end
  end

  describe "#to_h" do
    it "returns a hash representation of the execution plan" do
      hash = execution_plan.to_h
      expect(hash).to be_a(Hash)
      expect(hash[:tasks]).to be_an(Array)
      expect(hash[:tasks].first).to eq(task_definition.to_h)
      expect(hash[:expected_answer]).to eq(expected_answer.to_h)
    end
  end

  describe "#to_s" do
    it "returns a formatted string representation of the execution plan" do
      string = execution_plan.to_s
      expect(string).to include("Research AI trends")
      expect(string).to include("Format: PDF")
      expect(string).to include("Sections: Summary, Trends")
      expect(string).to include("Length: 10 pages")
    end
  end
end

RSpec.describe Agentic::ExecutionPlan, "dependency graph" do
  let(:agent) do
    Agentic::AgentSpecification.new(name: "Agent", description: "Does things", instructions: "Do it")
  end
  let(:expected_answer) { Agentic::ExpectedAnswerFormat.new(format: "text", sections: [], length: "short") }

  def task(description, id: nil, depends_on: [], needs: {})
    Agentic::TaskDefinition.new(description: description, agent: agent, id: id, depends_on: depends_on, needs: needs)
  end

  def plan(*tasks)
    described_class.new(tasks, expected_answer)
  end

  describe "#validate!" do
    it "passes a flat plan" do
      expect(plan(task("a"), task("b")).validate!).to be_a(described_class)
    end

    it "passes a well-formed graph" do
      graph = plan(task("research", id: "research"), task("write", id: "write", needs: {"findings" => "research"}))
      expect(graph.validate!).to eq(graph)
      expect(graph).to be_valid
    end

    it "rejects duplicate ids" do
      expect { plan(task("a", id: "x"), task("b", id: "x")).validate! }
        .to raise_error(described_class::InvalidPlanError, /duplicate task id\(s\): x/)
    end

    it "rejects references to ids no task carries, naming the task" do
      expect { plan(task("research", id: "research"), task("write", id: "write", depends_on: ["reserch"])).validate! }
        .to raise_error(described_class::InvalidPlanError, /write depends on unknown task\(s\) reserch/)
    end

    it "labels tasks without ids by description" do
      expect { plan(task("write the report", depends_on: ["research"])).validate! }
        .to raise_error(described_class::InvalidPlanError, /write the report depends on unknown task\(s\) research/)
    end

    it "checks needs values as well as depends_on" do
      expect { plan(task("write", id: "write", needs: {"findings" => "nope"})).validate! }
        .to raise_error(described_class::InvalidPlanError, /unknown task\(s\) nope/)
    end

    it "rejects a task that depends on itself" do
      expect { plan(task("a", id: "a", depends_on: ["a"])).validate! }
        .to raise_error(described_class::InvalidPlanError, /a depends on itself/)
    end

    it "rejects cycles and names every task stuck on them" do
      cyclic = plan(task("a", id: "a", depends_on: ["b"]), task("b", id: "b", depends_on: ["a"]), task("c", id: "c", depends_on: ["a"]), task("d", id: "d"))
      expect { cyclic.validate! }.to raise_error(described_class::InvalidPlanError, /dependency cycle leaves task\(s\) unrunnable: a, b, c/)
      expect(cyclic).not_to be_valid
    end

    it "reports every problem at once" do
      broken = plan(task("a", id: "x", depends_on: ["missing"]), task("b", id: "x"))
      expect { broken.validate! }.to raise_error(described_class::InvalidPlanError, /duplicate task id.*; x depends on unknown task/)
    end
  end

  describe ".from_hash" do
    it "round-trips a graph plan through to_h" do
      original = plan(task("research", id: "research"), task("write", id: "write", needs: {"findings" => "research"}))
      restored = described_class.from_hash(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
      expect(restored.tasks.last.needs).to eq({"findings" => "research"})
    end

    it "loads a plan parsed from JSON with string keys" do
      json = JSON.parse(JSON.generate(plan(task("a", id: "a"), task("b", id: "b", depends_on: ["a"])).to_h))
      restored = described_class.from_hash(json)
      expect(restored.tasks.map(&:id)).to eq(["a", "b"])
      expect(restored.tasks.last.depends_on).to eq(["a"])
      expect(restored.expected_answer.format).to eq("text")
    end

    it "loads a flat plan written before graph fields existed" do
      flat = {"tasks" => [{"description" => "a", "agent" => agent.to_h}], "expected_answer" => expected_answer.to_h}
      restored = described_class.from_hash(flat)
      expect(restored.tasks.first.dependencies).to eq([])
      expect(restored).to be_valid
    end
  end

  describe "#to_s" do
    it "shows ids and upstream tasks" do
      text = plan(task("research", id: "research"), task("write", id: "write", needs: {"findings" => "research"})).to_s
      expect(text).to include("1. research (Agent: Agent) [research]")
      expect(text).to include("2. write (Agent: Agent) [write] (after: research)")
    end
  end
end
