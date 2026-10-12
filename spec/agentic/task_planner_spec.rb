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

    def task_payload(id, description, depends_on: [], needs: [])
      {
        "id" => id,
        "description" => description,
        "agent" => {"name" => "#{id}_agent", "description" => "Does #{id}", "instructions" => "Do #{id}"},
        "depends_on" => depends_on,
        "needs" => needs
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
          expect(items[:required]).to include("id", "depends_on", "needs")
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

  describe "#analyze_goal with a registry" do
    let(:client) { instance_double(Agentic::LlmClient) }
    let(:registry) { Agentic::AgentCapabilityRegistry.instance }
    let(:planner) { described_class.new(goal, llm_config, registry: registry) }
    let(:response) { Agentic::LlmResponse.success({}, {"tasks" => tasks_payload}) }
    let(:tasks_payload) do
      [{
        "id" => "summarize",
        "description" => "Summarize the report",
        "agent" => {"name" => "summarizer", "description" => "Summarizes", "instructions" => "Summarize"},
        "depends_on" => [],
        "needs" => [],
        "capabilities" => ["summarization", "summarization", "mind_reading", 7, ""]
      }]
    end

    def register(name, description)
      capability = Agentic::CapabilitySpecification.new(name: name, description: description, version: "1.0.0")
      registry.register(capability, Agentic::CapabilityProvider.new(capability: capability, implementation: ->(_inputs) { {} }))
    end

    before do
      registry.clear
      register("summarization", "Condense a document into its key points")
      register("web_search", "Search the web for current information")
      allow(Agentic).to receive(:client).and_return(client)
      allow(client).to receive(:complete).and_return(response)
    end

    after { registry.clear }

    it "shows the catalog in the prompt and asks for capabilities in the schema" do
      planner.analyze_goal

      expect(client).to have_received(:complete) do |messages, output_schema:, **|
        prompt = messages.last[:content]
        expect(prompt).to include("Capabilities available:")
        expect(prompt).to include("- summarization: Condense a document into its key points")
        expect(prompt).to include("- web_search: Search the web for current information")

        items = output_schema.to_hash[:schema][:properties][:tasks][:items]
        expect(items[:properties][:capabilities]).to eq({type: "array", items: {type: "string"}})
        expect(items[:required]).to include("capabilities")
      end
    end

    it "keeps catalog names in the definition and drops the rest with a warning" do
      allow(Agentic.logger).to receive(:warn)

      planner.analyze_goal

      expect(planner.tasks.first.capabilities).to eq(["summarization"])
      expect(Agentic.logger).to have_received(:warn).with(/Ignoring unknown capability "mind_reading" in task at index 0/)
    end

    it "round-trips the choice through the plan document" do
      planner.analyze_goal

      hash = planner.tasks.first.to_h
      expect(hash["capabilities"]).to eq(["summarization"])
      expect(Agentic::TaskDefinition.from_hash(hash).capabilities).to eq(["summarization"])
    end

    context "without a registry" do
      it "sends the same prompt and schema as before capabilities existed" do
        captured = []
        allow(client).to receive(:complete) do |messages, output_schema:, **|
          captured << [messages, output_schema.to_hash]
          response
        end

        described_class.new(goal, llm_config).analyze_goal
        registry.clear
        described_class.new(goal, llm_config, registry: registry).analyze_goal

        expect(captured.length).to eq(2)
        expect(captured[0]).to eq(captured[1])
        expect(captured[0][0].last[:content]).not_to include("Capabilities available")
        expect(captured[0][1][:schema][:properties][:tasks][:items][:properties]).not_to have_key(:capabilities)
      end
    end
  end
end
