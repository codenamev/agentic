# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::LlmAssistedCompositionStrategy do
  let(:registry) { Agentic::AgentCapabilityRegistry.instance }
  let(:llm_client) { instance_double(Agentic::LlmClient) }
  let(:llm_response) { instance_double(Agentic::LlmResponse) }
  let(:strategy) { described_class.new }

  # Sample capabilities for testing
  let(:text_gen_capability) do
    Agentic::CapabilitySpecification.new(
      name: "text_generation",
      description: "Generates text based on a prompt",
      version: "1.0.0",
      inputs: {prompt: {type: "string", required: true}},
      outputs: {response: {type: "string"}}
    )
  end

  let(:text_gen_provider) do
    Agentic::CapabilityProvider.new(
      capability: text_gen_capability,
      implementation: ->(inputs) { {response: "Generated text"} }
    )
  end

  let(:data_analysis_capability) do
    Agentic::CapabilitySpecification.new(
      name: "data_analysis",
      description: "Analyzes data",
      version: "1.0.0",
      inputs: {data: {type: "object", required: true}},
      outputs: {insights: {type: "array"}},
      dependencies: [{name: "text_generation", version: "1.0.0"}]
    )
  end

  let(:data_analysis_provider) do
    Agentic::CapabilityProvider.new(
      capability: data_analysis_capability,
      implementation: ->(inputs) { {insights: ["Insight 1"]} }
    )
  end

  before do
    # Reset the registry
    registry.clear

    # Register test capabilities
    registry.register(text_gen_capability, text_gen_provider)
    registry.register(data_analysis_capability, data_analysis_provider)

    # Mock the LLM client
    allow(Agentic).to receive(:client).and_return(llm_client)
  end

  describe "#select_capabilities" do
    let(:requirements) do
      {
        "data_analysis" => {importance: 0.8, version_constraint: nil}
      }
    end

    context "when LLM suggests valid capabilities" do
      before do
        # Mock the LLM response to return valid capabilities
        json_response = {
          selected_capabilities: [
            {name: "data_analysis", version: "1.0.0", reason: "Required for analyzing data"}
          ],
          rationale: "Selected capabilities that match the requirements"
        }.to_json

        allow(llm_client).to receive(:complete).and_return(llm_response)
        allow(llm_response).to receive(:content).and_return(json_response)
      end

      it "returns the suggested capabilities with dependencies" do
        capabilities = strategy.select_capabilities(requirements, registry)

        expect(capabilities.size).to eq(2)
        expect(capabilities.map { |c| c[:name] }).to include("data_analysis", "text_generation")
      end

      it "sends the prompt as a user message (complete takes positional messages)" do
        strategy.select_capabilities(requirements, registry)

        expect(llm_client).to have_received(:complete)
          .with([{role: "user", content: a_string_including("select the most appropriate capabilities")}])
      end
    end

    context "when LLM suggests invalid capabilities" do
      before do
        # Mock the LLM response to return an invalid capability
        json_response = {
          selected_capabilities: [
            {name: "non_existent", version: "1.0.0", reason: "This capability doesn't exist"}
          ],
          rationale: "Selected non-existent capability"
        }.to_json

        allow(llm_client).to receive(:complete).and_return(llm_response)
        allow(llm_response).to receive(:content).and_return(json_response)
      end

      it "filters out invalid capabilities and falls back to the default strategy" do
        default_strategy = instance_double(Agentic::DefaultCompositionStrategy)
        allow(Agentic::DefaultCompositionStrategy).to receive(:new).and_return(default_strategy)
        allow(default_strategy).to receive(:select_capabilities).and_return([])

        capabilities = strategy.select_capabilities(requirements, registry)

        expect(capabilities).to be_empty
        expect(default_strategy).to have_received(:select_capabilities).with(requirements, registry)
      end
    end

    context "when LLM response is malformed" do
      before do
        # Mock the LLM response to return malformed JSON
        allow(llm_client).to receive(:complete).and_return(llm_response)
        allow(llm_response).to receive(:content).and_return("This is not JSON")
      end

      it "falls back to the default strategy" do
        # Mock the DefaultCompositionStrategy
        default_strategy = instance_double(Agentic::DefaultCompositionStrategy)
        allow(Agentic::DefaultCompositionStrategy).to receive(:new).and_return(default_strategy)
        allow(default_strategy).to receive(:select_capabilities).and_return([
          {name: "data_analysis", version: "1.0.0"}
        ])

        capabilities = strategy.select_capabilities(requirements, registry)

        expect(capabilities).to eq([{name: "data_analysis", version: "1.0.0"}])
        expect(default_strategy).to have_received(:select_capabilities).with(requirements, registry)
      end
    end
  end

  describe "integration with Agentic module" do
    it "provides a convenience method for creating the strategy" do
      strategy = Agentic.llm_assisted_strategy
      expect(strategy).to be_a(described_class)
    end

    it "supports use_llm parameter in assemble_agent" do
      task = instance_double(Agentic::Task)
      agent = instance_double(Agentic::Agent)

      # Swap in a doubled assembly engine so we can observe the strategy it receives
      engine = instance_double(Agentic::AgentAssemblyEngine, assemble_agent: agent)
      original_engine = Agentic.instance_variable_get(:@agent_assembly_engine)
      allow(Agentic).to receive(:initialize_agent_assembly)
      Agentic.instance_variable_set(:@agent_assembly_engine, engine)

      begin
        result = Agentic.assemble_agent(task, use_llm: true)

        expect(result).to eq(agent)
        expect(engine).to have_received(:assemble_agent).with(
          task,
          strategy: instance_of(described_class),
          store: true
        )
      ensure
        Agentic.instance_variable_set(:@agent_assembly_engine, original_engine)
      end
    end
  end
end
