# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::Capabilities::Examples do
  describe "text_generation provider" do
    let(:registry) { Agentic::AgentCapabilityRegistry.instance }
    let(:llm_client) { instance_double(Agentic::LlmClient) }
    let(:llm_response) { instance_double(Agentic::LlmResponse, content: "generated text") }

    before do
      registry.clear if registry.respond_to?(:clear)
      allow(Agentic).to receive(:client).and_return(llm_client)
      allow(llm_client).to receive(:complete).and_return(llm_response)
      described_class.register_text_generation
    end

    it "calls complete with a messages array and returns the content" do
      provider = registry.get_provider("text_generation")
      result = provider.execute(prompt: "Say hi")

      expect(llm_client).to have_received(:complete).with([{role: "user", content: "Say hi"}])
      expect(result[:response]).to eq("generated text")
    end
  end
end
