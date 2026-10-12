# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::TaskPlanner do
  let(:goal) { "Generate a market research report on the latest trends in AI technology." }
  let(:llm_config) { Agentic::LlmConfig.new }
  let(:planner) { described_class.new(goal, llm_config) }

  describe "#initialize" do
    it "sets the goal and llm_config" do
      expect(planner.goal).to eq(goal)
      expect(planner.llm_config).to eq(llm_config)
    end

    it "initializes tasks and expected_answer as empty" do
      expect(planner.tasks).to be_empty
      expect(planner.expected_answer).to be_a(Agentic::ExpectedAnswerFormat)
      expect(planner.expected_answer.format).to eq("Undetermined")
      expect(planner.expected_answer.sections).to be_empty
      expect(planner.expected_answer.length).to eq("Undetermined")
    end
  end

  describe "#analyze_goal" do
    let(:client) { instance_double(Agentic::LlmClient) }
    let(:response) { Agentic::LlmResponse.success({}, {"tasks" => tasks_payload}) }

    def task_payload(id, description, depends_on: [], needs: [], on_failure: "skip_dependents")
      {
        "id" => id,
        "description" => description,
        "agent" => {"name" => "#{id}_agent", "description" => "Does #{id}", "instructions" => "Do #{id}"},
        "depends_on" => depends_on,
        "needs" => needs,
        "on_failure" => on_failure
      }
    end

    before do
      allow(Agentic).to receive(:client).and_return(client)
      allow(client).to receive(:complete).and_return(response)
    end

    context "when the LLM emits dependency edges" do
      let(:tasks_payload) do
        [
          task_payload("research", "Research the topic"),
          task_payload("write", "Write the report", depends_on: ["research"], needs: [{"name" => "findings", "task" => "research"}])
        ]
      end

      it "asks for ids, ordering and wiring in the schema" do
        planner.analyze_goal

        expect(client).to have_received(:complete) do |_messages, output_schema:, **|
          items = output_schema.to_hash[:schema][:properties][:tasks][:items]
          expect(items[:required]).to include("id", "depends_on", "needs", "on_failure")
          expect(items[:properties][:on_failure][:enum]).to eq(%w[skip_dependents continue])
          expect(items[:properties][:needs][:items][:required]).to eq(%w[name task])
        end
      end

      it "carries the ids and edges into the task definitions" do
        planner.analyze_goal

        research, write = planner.tasks
        expect(research.id).to eq("research")
        expect(research.dependencies).to be_empty
        expect(write.id).to eq("write")
        expect(write.depends_on).to eq(["research"])
        expect(write.needs).to eq({"findings" => "research"})
      end

      it "produces a plan that validates" do
        planner.analyze_goal

        expect(planner.execution_plan).to be_valid
      end
    end

    context "when the LLM sets on_failure" do
      let(:tasks_payload) do
        [
          task_payload("research", "Research the topic", on_failure: "continue"),
          task_payload("write", "Write the report", depends_on: ["research"], on_failure: "nonsense")
        ]
      end

      it "carries a known policy and falls back to the default for an unknown one" do
        allow(Agentic.logger).to receive(:warn)
        planner.analyze_goal

        research, write = planner.tasks
        expect(research.on_failure).to eq("continue")
        expect(write.on_failure).to eq("skip_dependents")
        expect(Agentic.logger).to have_received(:warn).with(/Ignoring on_failure in task at index 1/)
      end
    end

    context "when the LLM omits the graph fields" do
      let(:tasks_payload) do
        [{"description" => "Research the topic", "agent" => {"name" => "researcher", "description" => "Researches", "instructions" => "Research"}}]
      end

      it "builds a flat task" do
        planner.analyze_goal

        task = planner.tasks.first
        expect(task.id).to be_nil
        expect(task.depends_on).to eq([])
        expect(task.needs).to eq({})
        expect(task.to_h.keys).to eq(%w[description agent])
      end
    end

    context "when the graph fields are malformed" do
      let(:tasks_payload) do
        [
          task_payload("research", "Research the topic"),
          task_payload("write", "Write the report", depends_on: "research", needs: [{"name" => "findings"}, "junk", {"name" => "brief", "task" => "research"}])
        ]
      end

      it "keeps the well-formed edges and logs the rest" do
        allow(Agentic.logger).to receive(:warn)

        planner.analyze_goal

        write = planner.tasks.last
        expect(write.depends_on).to eq([])
        expect(write.needs).to eq({"brief" => "research"})
        expect(Agentic.logger).to have_received(:warn).with(/Ignoring depends_on in task at index 1/)
        expect(Agentic.logger).to have_received(:warn).with(/Ignoring malformed needs entry in task at index 1/).twice
      end
    end

    context "when the LLM references a task that does not exist" do
      let(:tasks_payload) do
        [task_payload("write", "Write the report", depends_on: ["reserch"])]
      end

      it "keeps the edge for inspection and warns" do
        allow(Agentic.logger).to receive(:warn)

        planner.analyze_goal

        expect(planner.tasks.first.depends_on).to eq(["reserch"])
        expect(planner.execution_plan).not_to be_valid
        expect(Agentic.logger).to have_received(:warn).with(/invalid dependency graph.*reserch/)
      end
    end

    context "when the LLM emits a cycle" do
      let(:tasks_payload) do
        [
          task_payload("a", "First", depends_on: ["b"]),
          task_payload("b", "Second", depends_on: ["a"])
        ]
      end

      it "warns without dropping the tasks" do
        allow(Agentic.logger).to receive(:warn)

        planner.analyze_goal

        expect(planner.tasks.map(&:id)).to eq(%w[a b])
        expect(Agentic.logger).to have_received(:warn).with(/dependency cycle/)
      end
    end
  end
end
