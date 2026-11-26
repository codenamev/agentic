# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::RubyLlmErrorMap do
  # Stand-ins mirroring ruby_llm 2.2.3's hierarchy, so the map is exercised
  # without the gem loaded.
  before do
    base = Class.new(StandardError) do
      attr_reader :response

      def initialize(response = nil, message = nil)
        @response = response
        super(message || "llm error")
      end
    end
    stub_const("RubyLLM::Error", base)
    stub_const("RubyLLM::UnauthorizedError", Class.new(base))
    stub_const("RubyLLM::ForbiddenError", Class.new(base))
    stub_const("RubyLLM::PaymentRequiredError", Class.new(base))
    stub_const("RubyLLM::RateLimitError", Class.new(base))
    stub_const("RubyLLM::BadRequestError", Class.new(base))
    stub_const("RubyLLM::UnsupportedParameterError", Class.new(RubyLLM::BadRequestError))
    stub_const("RubyLLM::ContextLengthExceededError", Class.new(base))
    stub_const("RubyLLM::ContentFilterError", Class.new(base))
    stub_const("RubyLLM::OverloadedError", Class.new(base))
    stub_const("RubyLLM::ServerError", Class.new(base))
    stub_const("RubyLLM::ServiceUnavailableError", Class.new(base))
    stub_const("RubyLLM::ModelNotFoundError", Class.new(StandardError))
    stub_const("RubyLLM::ConfigurationError", Class.new(StandardError))
  end

  {
    "RubyLLM::UnauthorizedError" => Agentic::Errors::LlmAuthenticationError,
    "RubyLLM::ForbiddenError" => Agentic::Errors::LlmAuthenticationError,
    "RubyLLM::PaymentRequiredError" => Agentic::Errors::LlmAuthenticationError,
    "RubyLLM::RateLimitError" => Agentic::Errors::LlmRateLimitError,
    "RubyLLM::BadRequestError" => Agentic::Errors::LlmInvalidRequestError,
    "RubyLLM::UnsupportedParameterError" => Agentic::Errors::LlmInvalidRequestError,
    "RubyLLM::ContextLengthExceededError" => Agentic::Errors::LlmInvalidRequestError,
    "RubyLLM::ContentFilterError" => Agentic::Errors::LlmRefusalError,
    "RubyLLM::OverloadedError" => Agentic::Errors::LlmServerError,
    "RubyLLM::ServerError" => Agentic::Errors::LlmServerError,
    "RubyLLM::ServiceUnavailableError" => Agentic::Errors::LlmServerError,
    "RubyLLM::Error" => Agentic::Errors::LlmServerError
  }.each do |source, target|
    it "maps #{source} to #{target.name.split("::").last}" do
      translated = described_class.translate(Object.const_get(source).new(nil, "boom"))

      expect(translated).to be_a(target)
      expect(translated.context[:source]).to eq(source)
    end
  end

  it "keeps auth failures non-retryable so intervention can pause on them" do
    translated = described_class.translate(RubyLLM::UnauthorizedError.new(nil, "bad key"))

    expect(translated.retryable?).to be(false)
    expect(translated.message).to eq("bad key")
  end

  it "maps the plain-StandardError ruby_llm classes" do
    expect(described_class.translate(RubyLLM::ModelNotFoundError.new("no model")))
      .to be_a(Agentic::Errors::LlmInvalidRequestError)
    expect(described_class.translate(RubyLLM::ConfigurationError.new("no key")))
      .to be_a(Agentic::Errors::LlmAuthenticationError)
  end

  it "carries retry-after and the response body for rate limits" do
    response = Struct.new(:body, :headers).new({"error" => {"message" => "slow down"}}, {"retry-after" => "7"})
    translated = described_class.translate(RubyLLM::RateLimitError.new(response, "429"))

    expect(translated.retry_after).to eq(7)
    expect(translated.response).to eq({"error" => {"message" => "slow down"}})
  end

  it "maps Faraday transport failures to timeout and network errors" do
    stub_const("Faraday::TimeoutError", Class.new(StandardError))
    stub_const("Faraday::ConnectionFailed", Class.new(StandardError))

    expect(described_class.translate(Faraday::TimeoutError.new("slow"))).to be_a(Agentic::Errors::LlmTimeoutError)
    network = described_class.translate(Faraday::ConnectionFailed.new("refused"))
    expect(network).to be_a(Agentic::Errors::LlmNetworkError)
    expect(network.retryable?).to be(true)
  end

  it "passes agentic errors through untouched" do
    original = Agentic::Errors::LlmServerError.new("already typed")

    expect(described_class.translate(original)).to be(original)
  end

  it "returns nil for exceptions it doesn't know" do
    expect(described_class.translate(ArgumentError.new("nope"))).to be_nil
  end
end
