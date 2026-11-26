# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::LegacyConfiguration do
  around do |example|
    original = Agentic.instance_variable_get(:@configuration)
    example.run
  ensure
    Agentic.instance_variable_set(:@configuration, original)
  end

  def fresh_configuration(token: nil, base_url: nil)
    config = nil
    without_env("OPENAI_ACCESS_TOKEN", "AGENTIC_API_TOKEN", "AGENTIC_API_BASE_URL", "OPENAI_BASE_URL") do
      config = described_class.new
    end
    config.access_token = token
    config.api_base_url = base_url
    config
  end

  def without_env(*keys)
    saved = keys.to_h { |key| [key, ENV.delete(key)] }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value if value }
  end

  describe "#validate!" do
    it "raises ConfigurationError when neither token nor base URL is set" do
      config = fresh_configuration

      expect { config.validate! }.to raise_error(
        Agentic::Errors::ConfigurationError, /No LLM credentials configured/
      )
    end

    it "passes with an access token" do
      config = fresh_configuration(token: "sk-real")
      expect(config.validate!).to eq(config)
    end

    it "passes with only a base URL (local endpoints)" do
      config = fresh_configuration(base_url: "http://localhost:11434/v1")
      expect(config.validate!).to eq(config)
    end
  end

  describe "defaults" do
    it "does not invent a placeholder token" do
      config = fresh_configuration
      expect(config.access_token).to be_nil
    end
  end

  describe "#llm_backend" do
    it "defaults to :openai" do
      config = nil
      without_env("AGENTIC_LLM_BACKEND") { config = described_class.new }
      expect(config.llm_backend).to eq(:openai)
    end

    it "accepts :ruby_llm as a string or symbol" do
      config = fresh_configuration
      config.llm_backend = " Ruby_LLM "
      expect(config.llm_backend).to eq(:ruby_llm)
    end

    it "rejects unknown backends" do
      config = fresh_configuration
      expect { config.llm_backend = "anthropic" }
        .to raise_error(Agentic::Errors::ConfigurationError, /Unknown llm_backend/)
    end
  end

  describe "LlmClient fail-fast" do
    it "raises at construction when unconfigured, not at request time" do
      Agentic.instance_variable_set(:@configuration, fresh_configuration)

      expect { Agentic::LlmClient.new(Agentic::LlmConfig.new) }.to raise_error(
        Agentic::Errors::ConfigurationError
      )
    end

    it "constructs with a placeholder token for base-URL-only setups" do
      Agentic.instance_variable_set(
        :@configuration,
        fresh_configuration(base_url: "http://localhost:11434/v1")
      )

      client = Agentic::LlmClient.new(Agentic::LlmConfig.new)
      expect(client.client).to be_a(OpenAI::Client)
    end
  end
end
