# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::Agent do
  describe ".build" do
    it "configures and builds an agent with default values" do
      agent = Agentic::Agent.build

      expect(agent.role).to be_nil
      expect(agent.purpose).to be_nil
      expect(agent.backstory).to be_nil
      expect(agent.tools).to eq(Set.new)
    end

    it "configures and builds an agent with custom values" do
      agent = Agentic::Agent.build do |builder|
        builder.role = "Custom Role"
        builder.purpose = "Custom Purpose"
        builder.backstory = "Custom Backstory"
        builder.tools = ["Custom Tool"]
      end

      expect(agent.role).to eq("Custom Role")
      expect(agent.purpose).to eq("Custom Purpose")
      expect(agent.backstory).to eq("Custom Backstory")
      expect(agent.tools).to eq(["Custom Tool"])
    end
  end

  describe ".from_h" do
    it "builds an agent whose configuration block is actually applied" do
      agent = Agentic::Agent.from_h(role: "Restored", purpose: "Round-trip")

      expect(agent).to be_a(Agentic::Agent)
      expect(agent.role).to eq("Restored")
      expect(agent.purpose).to eq("Round-trip")
    end
  end

  describe "#execute_with_schema" do
    let(:schema) { instance_double(Agentic::StructuredOutputs::Schema) }

    it "honors the schema through the LLM client" do
      response = instance_double(Agentic::LlmResponse, successful?: true, content: {"answer" => 42}, stats: nil)
      llm_client = instance_double(Agentic::LlmClient)
      allow(llm_client).to receive(:complete).with(anything, output_schema: schema).and_return(response)

      agent = Agentic::Agent.build { |a| a.llm_client = llm_client }

      expect(agent.execute_with_schema("What is the answer?", schema)).to eq({"answer" => 42})
    end

    it "remembers the response's token usage as last_stats" do
      stats = Agentic::GenerationStats.new(id: "gen-1", prompt_tokens: 12, completion_tokens: 30, total_tokens: 42)
      response = instance_double(Agentic::LlmResponse, successful?: true, content: {"answer" => 42}, stats: stats)
      llm_client = instance_double(Agentic::LlmClient)
      allow(llm_client).to receive(:complete).and_return(response)

      agent = Agentic::Agent.build { |a| a.llm_client = llm_client }
      agent.execute_with_schema("What is the answer?", schema)

      expect(agent.last_stats).to be(stats)
    end

    it "clears last_stats when an execution does not reach the LLM" do
      stats = Agentic::GenerationStats.new(id: "gen-1", prompt_tokens: 1, completion_tokens: 1, total_tokens: 2)
      response = instance_double(Agentic::LlmResponse, successful?: true, content: "ok", stats: stats)
      llm_client = instance_double(Agentic::LlmClient)
      allow(llm_client).to receive(:complete).and_return(response)
      agent = Agentic::Agent.build { |a| a.llm_client = llm_client }
      agent.execute("first")
      expect(agent.last_stats).to be(stats)

      agent.instance_variable_get(:@capabilities)["text_generation"] = {specification: nil, provider: nil}
      allow(agent).to receive(:execute_capability).and_return({response: "from capability"})
      agent.execute("second")

      expect(agent.last_stats).to be_nil
    end

    it "refuses to silently drop the schema when only text_generation is available" do
      agent = Agentic::Agent.build
      agent.instance_variable_get(:@capabilities)["text_generation"] = {specification: nil, provider: nil}

      expect {
        agent.execute_with_schema("prompt", schema)
      }.to raise_error(Agentic::Errors::SchemaNotSupportedError, /cannot enforce schemas/)
    end

    it "raises a named error when the agent has no execution path" do
      agent = Agentic::Agent.build

      expect {
        agent.execute_with_schema("prompt", schema)
      }.to raise_error(Agentic::Errors::AgentNotConfiguredError)
    end
  end

  describe "capability errors" do
    it "raises CapabilityNotFoundError for unregistered capabilities" do
      agent = Agentic::Agent.build

      expect {
        agent.add_capability("does_not_exist")
      }.to raise_error(Agentic::Errors::CapabilityNotFoundError) { |error|
        expect(error.capability_name).to eq("does_not_exist")
      }
    end

    it "raises CapabilityNotFoundError when executing a capability the agent lacks" do
      agent = Agentic::Agent.build

      expect {
        agent.execute_capability("not_added")
      }.to raise_error(Agentic::Errors::CapabilityNotFoundError, /not added to this agent/)
    end
  end
end
