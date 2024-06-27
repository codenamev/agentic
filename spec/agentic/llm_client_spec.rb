# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::LlmClient do
  let(:llm_config) { Agentic::LlmConfig.new(model: "test-model") }
  let(:client) { described_class.new(llm_config) }
  let(:mock_openai_client) { instance_double(OpenAI::Client) }

  describe "#initialize" do
    it "creates an OpenAI::Client instance" do
      expect(client.client).to be_an_instance_of(OpenAI::Client)
    end
  end

  describe "#complete" do
    let(:messages) { [{role: "user", content: "Hello"}] }
    let(:response) { {"choices" => [{"message" => {"content" => "Hi there!"}}]} }

    before do
      allow(client).to receive(:client).and_return(mock_openai_client)
    end

    it "sends a completion request with correct parameters" do
      expect(mock_openai_client).to receive(:chat).with(
        parameters: {
          model: llm_config.model,
          messages: messages
        }
      ).and_return(response)
      client.complete(messages)
    end

    it "returns the response from the client" do
      allow(mock_openai_client).to receive(:chat).and_return(response)
      expect(client.complete(messages)).to eq(response.dig("choices", 0, "message", "content"))
    end
  end

  describe "#models", :vcr do
    it "returns the models from the client" do
      VCR.use_cassette("models") do
        expect(client.models).to be_an(Array)
      end
    end
  end

  describe "#query_generation_stats" do
    let(:generation_id) { "gen123" }
    let(:stats) { {"id" => generation_id, "usage" => {"total_tokens" => 100}} }

    before do
      allow(client.client).to receive(:query_generation_stats).and_return(stats)
    end

    it "queries generation stats with the given ID" do
      expect(client.client).to receive(:query_generation_stats).with(generation_id)
      client.query_generation_stats(generation_id)
    end

    it "returns the stats from the client" do
      expect(client.query_generation_stats(generation_id)).to eq(stats)
    end
  end

  describe "live API request", :vcr do
    let(:llm_config) { Agentic::LlmConfig.new(model: "gpt-4o-mini") }
    let(:client) { described_class.new(llm_config) }
    let(:messages) { [{role: "user", content: "What is the capital of France?"}] }

    it "successfully makes a request to the OpenAI GPT-4o-mini model" do
      VCR.use_cassette("gpt4o_mini_completion") do
        response = client.complete(messages)

        expect(response).to include("Paris")
      end
    end
  end
end
