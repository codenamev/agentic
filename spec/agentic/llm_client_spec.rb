# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::LlmClient, :vcr do
  let(:config) { double("LlmConfig") }
  let(:access_token) { "test-token" }
  let(:messages) { [{role: "user", content: "Test message"}] }
  let(:api_parameters) { {model: "gpt-4", messages: messages, temperature: 0.7} }

  before do
    allow(Agentic.configuration).to receive(:access_token).and_return(access_token)
    allow(Agentic.configuration).to receive(:llm_backend).and_return(:openai) # legacy transport; goes with ruby-openai
    allow(Agentic.configuration).to receive(:api_base_url).and_return(nil)
    allow(config).to receive(:to_api_parameters).and_return(api_parameters)
    allow(Agentic.logger).to receive(:error)
    allow(Agentic.logger).to receive(:warn)
    # Exercise retry logic without real backoff waits
    allow_any_instance_of(Agentic::RetryHandler).to receive(:sleep)
  end

  describe ".new" do
    it "routes the deprecated :openai backend through RubyLlmAdapter" do
      expect(OpenAI::Client).not_to receive(:new)

      client = described_class.new(config)

      expect(client.client).to be_a(Agentic::RubyLlmAdapter)
      expect(client.client.instance_variable_get(:@context).config.openai_api_key).to eq(access_token)
    end

    context "with custom API base URL on the :openai backend" do
      before do
        allow(Agentic.configuration).to receive(:api_base_url).and_return("http://localhost:11434")
      end

      it "points the RubyLLM context at the base URL" do
        adapter = described_class.new(config).client

        expect(adapter.instance_variable_get(:@context).config.openai_api_base).to eq("http://localhost:11434")
        expect(adapter.instance_variable_get(:@assume_model_exists)).to be(true)
      end
    end

    context "with llm_backend :ruby_llm" do
      before do
        require "ruby_llm"
        allow(Agentic.configuration).to receive(:llm_backend).and_return(:ruby_llm)
      end

      it "uses a RubyLlmAdapter on a private context instead of ruby-openai" do
        expect(OpenAI::Client).not_to receive(:new)

        client = described_class.new(config)

        expect(client.client).to be_a(Agentic::RubyLlmAdapter)
        context = client.client.instance_variable_get(:@context)
        expect(context.config.openai_api_key).to eq(access_token)
        expect(RubyLLM.config.openai_api_key).not_to eq(access_token)
        expect(client.client.instance_variable_get(:@assume_model_exists)).to be(false)
      end

      it "points the context at a custom base URL and skips the model registry" do
        allow(Agentic.configuration).to receive(:api_base_url).and_return("http://localhost:11434/v1")

        adapter = described_class.new(config).client

        expect(adapter.instance_variable_get(:@context).config.openai_api_base).to eq("http://localhost:11434/v1")
        expect(adapter.instance_variable_get(:@assume_model_exists)).to be(true)
      end

      it "sends complete() through RubyLLM and keeps the LlmResponse contract" do
        chat = double("RubyLLM::Chat")
        allow_any_instance_of(RubyLLM::Context).to receive(:chat).and_return(chat)
        allow(chat).to receive(:with_temperature).and_return(chat)
        allow(chat).to receive(:add_message)
        message = double("RubyLLM::Message", content: "hi back", tokens: nil, model: "gpt-4", finish_reason: :stop)
        allow(chat).to receive(:complete).and_return(message)

        response = described_class.new(config).complete(messages)

        expect(response).to be_successful
        expect(response.content).to eq("hi back")
      end

      it "keeps the adapter's typed error instead of rewrapping it as a generic LlmError" do
        chat = double("RubyLLM::Chat")
        allow_any_instance_of(RubyLLM::Context).to receive(:chat).and_return(chat)
        allow(chat).to receive(:with_temperature).and_return(chat)
        allow(chat).to receive(:add_message)
        allow(chat).to receive(:complete).and_raise(RubyLLM::UnauthorizedError.new("Invalid API key"))

        expect {
          described_class.new(config).complete(messages, fail_on_error: true, use_retries: false)
        }.to raise_error(Agentic::Errors::LlmAuthenticationError)
      end
    end

    context "with retry configuration" do
      let(:retry_config) { {max_retries: 5, backoff_factor: 2.0} }

      it "initializes retry handler with configuration" do
        expect(Agentic::RetryHandler).to receive(:new).with(retry_config)

        described_class.new(config, retry_config)
      end
    end

    context "with RetryConfig object" do
      let(:retry_config) { instance_double(Agentic::RetryConfig) }
      let(:retry_handler) { instance_double(Agentic::RetryHandler) }

      before do
        allow(retry_config).to receive(:to_handler).and_return(retry_handler)
      end

      it "converts RetryConfig to handler" do
        client = described_class.new(config, retry_config)
        expect(client.retry_handler).to eq(retry_handler)
      end
    end
  end

  describe "#complete" do
    let(:openai_client) { instance_double(Agentic::RubyLlmAdapter) }
    let(:success_response) do
      {
        "choices" => [
          {
            "message" => {
              "content" => "Test response"
            }
          }
        ]
      }
    end

    subject { described_class.new(config) }

    before do
      allow(Agentic::RubyLlmAdapter).to receive(:from_configuration).and_return(openai_client)
      allow(openai_client).to receive(:chat).and_return(success_response)
    end

    context "with successful response" do
      it "returns successful LlmResponse" do
        result = subject.complete(messages)

        expect(result).to be_a(Agentic::LlmResponse)
        expect(result.success?).to be true
        expect(result.content).to eq("Test response")
      end

      it "calls OpenAI client with correct parameters" do
        expect(openai_client).to receive(:chat).with(parameters: api_parameters)

        subject.complete(messages)
      end

      it "stores last response" do
        subject.complete(messages)
        expect(subject.last_response).to eq(success_response)
      end
    end

    context "with structured output schema" do
      let(:schema) { double("Schema") }
      let(:schema_hash) { {"type" => "object", "properties" => {}} }
      let(:json_response) do
        {
          "choices" => [
            {
              "message" => {
                "content" => '{"result": "success"}'
              }
            }
          ]
        }
      end

      before do
        allow(schema).to receive(:to_hash).and_return(schema_hash)
        allow(openai_client).to receive(:chat).and_return(json_response)
      end

      it "adds response format to parameters" do
        expected_params = api_parameters.merge(
          response_format: {
            type: "json_schema",
            json_schema: schema_hash
          }
        )

        expect(openai_client).to receive(:chat).with(parameters: expected_params)

        subject.complete(messages, output_schema: schema)
      end

      it "parses JSON content" do
        result = subject.complete(messages, output_schema: schema)

        expect(result.success?).to be true
        expect(result.content).to eq({"result" => "success"})
      end

      context "with invalid JSON" do
        let(:invalid_json_response) do
          {
            "choices" => [
              {
                "message" => {
                  "content" => "invalid json"
                }
              }
            ]
          }
        end

        before do
          allow(openai_client).to receive(:chat).and_return(invalid_json_response)
        end

        it "handles JSON parse error gracefully" do
          result = subject.complete(messages, output_schema: schema)

          expect(result.success?).to be false
          expect(result.error).to be_a(Agentic::Errors::LlmParseError)
        end

        context "with fail_on_error true" do
          it "raises parse error" do
            expect do
              subject.complete(messages, output_schema: schema, fail_on_error: true)
            end.to raise_error(Agentic::Errors::LlmParseError)
          end
        end
      end

      context "with empty content" do
        let(:empty_response) do
          {
            "choices" => [
              {
                "message" => {
                  "content" => nil
                }
              }
            ]
          }
        end

        before do
          allow(openai_client).to receive(:chat).and_return(empty_response)
        end

        it "handles empty content error" do
          result = subject.complete(messages, output_schema: schema)

          expect(result.success?).to be false
          expect(result.error).to be_a(Agentic::Errors::LlmParseError)
          expect(result.error.message).to include("Empty content returned from LLM")
        end
      end
    end

    context "with LLM refusal" do
      let(:refusal_response) do
        {
          "choices" => [
            {
              "message" => {
                "refusal" => "I cannot help with that request"
              }
            }
          ]
        }
      end

      before do
        allow(openai_client).to receive(:chat).and_return(refusal_response)
      end

      it "handles refusal gracefully" do
        result = subject.complete(messages)

        expect(result.success?).to be false
        expect(result.refusal?).to be true
        expect(result.refusal_reason).to eq("I cannot help with that request")
      end

      context "with fail_on_error true" do
        it "raises refusal error" do
          expect do
            subject.complete(messages, fail_on_error: true)
          end.to raise_error(Agentic::Errors::LlmRefusalError)
        end
      end
    end

    context "with options override" do
      let(:override_options) { {temperature: 1.0, max_tokens: 100} }

      it "merges options with config parameters" do
        expected_params = api_parameters.merge(override_options)
        expect(openai_client).to receive(:chat).with(parameters: expected_params)

        subject.complete(messages, options: override_options)
      end
    end

    context "with HTTP errors" do
      let(:timeout_error) { Faraday::TimeoutError.new("Request timeout") }
      let(:rate_limit_error) { Faraday::TooManyRequestsError.new("Rate limit exceeded", {status: 429, headers: {}}) }
      let(:auth_error) { Faraday::UnauthorizedError.new("Invalid API key", {status: 401, headers: {}}) }

      context "when timeout error occurs" do
        before do
          allow(openai_client).to receive(:chat).and_raise(timeout_error)
        end

        it "maps to LlmTimeoutError" do
          result = subject.complete(messages)

          expect(result.success?).to be false
          expect(result.error).to be_a(Agentic::Errors::LlmTimeoutError)
        end

        context "with fail_on_error true" do
          it "raises timeout error" do
            expect do
              subject.complete(messages, fail_on_error: true)
            end.to raise_error(Agentic::Errors::LlmTimeoutError)
          end
        end
      end

      context "when the HTTP layer raises Faraday::TooManyRequestsError" do
        let(:faraday_429) do
          Faraday::TooManyRequestsError.new(nil, {status: 429, headers: {"retry-after" => "1"}, body: "rate limited"})
        end

        it "maps to LlmRateLimitError rather than a generic LlmError" do
          allow(openai_client).to receive(:chat).and_raise(faraday_429)

          result = subject.complete(messages, use_retries: false)

          expect(result.success?).to be false
          expect(result.error).to be_a(Agentic::Errors::LlmRateLimitError)
          expect(result.error.retry_after).to eq(1)
        end

        it "is retried by RetryHandler and succeeds on the next attempt" do
          calls = 0
          allow(openai_client).to receive(:chat) do
            calls += 1
            raise faraday_429 if calls == 1
            success_response
          end

          result = subject.complete(messages, fail_on_error: true)

          expect(result.success?).to be true
          expect(calls).to eq(2)
        end
      end

      context "when rate limit error occurs" do
        before do
          allow(openai_client).to receive(:chat).and_raise(rate_limit_error)
        end

        it "maps to LlmRateLimitError" do
          result = subject.complete(messages)

          expect(result.success?).to be false
          expect(result.error).to be_a(Agentic::Errors::LlmRateLimitError)
        end
      end

      context "when authentication error occurs" do
        before do
          allow(openai_client).to receive(:chat).and_raise(auth_error)
        end

        it "maps to LlmAuthenticationError" do
          result = subject.complete(messages)

          expect(result.success?).to be false
          expect(result.error).to be_a(Agentic::Errors::LlmAuthenticationError)
        end
      end
    end

    context "when the provider error carries a secret" do
      let(:leaky_error) { Faraday::UnauthorizedError.new("Incorrect API key provided: sk-abcdefghijklmnop1234", {status: 401, headers: {}}) }

      before do
        Agentic::Security::Config.configure(enable_pii_detection: true)
        allow(openai_client).to receive(:chat).and_raise(leaky_error)
      end

      after { Agentic::Security::Config.reset! }

      it "logs the sanitized message, not the raw one" do
        subject.complete(messages)

        expect(Agentic.logger).to have_received(:error).with(a_string_including("[REDACTED_API_KEY]"))
        expect(Agentic.logger).not_to have_received(:error).with(a_string_including("sk-abcdefghijklmnop1234"))
      end

      it "keeps the raw message on the returned error" do
        result = subject.complete(messages)

        expect(result.error.message).to include("sk-abcdefghijklmnop1234")
      end
    end

    context "when the provider error body has invalid bytes" do
      let(:garbled) { (+"Incorrect API key provided: sk-abcdefghijklmnop1234 \xFF\xFE").force_encoding("UTF-8") }
      let(:leaky_error) { Faraday::UnauthorizedError.new(garbled, {status: 401, headers: {}}) }

      before do
        Agentic::Security::Config.configure(enable_pii_detection: true)
        allow(openai_client).to receive(:chat).and_raise(leaky_error)
      end

      after { Agentic::Security::Config.reset! }

      it "still returns an error result instead of raising out of the rescue" do
        result = nil
        expect { result = subject.complete(messages) }.not_to raise_error

        expect(result.success?).to be false
        expect(result.error).to be_a(Agentic::Errors::LlmAuthenticationError)
        expect(Agentic.logger).not_to have_received(:error).with(a_string_including("sk-abcdefghijklmnop1234"))
      end
    end

    context "with network errors" do
      let(:timeout_error) { Net::ReadTimeout.new("Read timeout") }

      before do
        allow(openai_client).to receive(:chat).and_raise(timeout_error)
      end

      it "maps to LlmTimeoutError" do
        result = subject.complete(messages)

        expect(result.success?).to be false
        expect(result.error).to be_a(Agentic::Errors::LlmTimeoutError)
      end
    end

    context "with unexpected errors" do
      let(:unexpected_error) { StandardError.new("Unexpected error") }

      before do
        allow(openai_client).to receive(:chat).and_raise(unexpected_error)
      end

      it "maps to generic LlmError" do
        result = subject.complete(messages)

        expect(result.success?).to be false
        expect(result.error).to be_a(Agentic::Errors::LlmError)
      end
    end

    context "with retries disabled" do
      let(:retry_handler) { instance_double(Agentic::RetryHandler) }

      before do
        allow(subject).to receive(:retry_handler).and_return(retry_handler)
      end

      it "does not use retry handler" do
        expect(retry_handler).not_to receive(:with_retry)

        subject.complete(messages, use_retries: false)
      end
    end

    context "with retries enabled" do
      let(:retry_handler) { instance_double(Agentic::RetryHandler) }

      before do
        allow(subject).to receive(:retry_handler).and_return(retry_handler)
        allow(retry_handler).to receive(:with_retry).and_yield
      end

      it "uses retry handler" do
        expect(retry_handler).to receive(:with_retry)

        subject.complete(messages, use_retries: true)
      end

      context "when retries are exhausted" do
        let(:llm_error) { Agentic::Errors::LlmError.new("Persistent error") }

        before do
          allow(retry_handler).to receive(:with_retry).and_raise(llm_error)
        end

        it "handles exhausted retries" do
          result = subject.complete(messages)

          expect(result.success?).to be false
          expect(result.error).to eq(llm_error)
        end
      end
    end
  end

  describe "provider metadata endpoints (plain HTTP, any backend)", vcr: false do
    include WebMock::API

    subject { described_class.new(config) }

    after { WebMock.reset! }

    [:openai, :ruby_llm].each do |backend|
      context "with llm_backend #{backend.inspect}" do
        before { allow(Agentic.configuration).to receive(:llm_backend).and_return(backend) }

        describe "#models" do
          it "GETs /v1/models with the bearer token and returns data" do
            stub_request(:get, "https://api.openai.com/v1/models")
              .with(headers: {"Authorization" => "Bearer test-token"})
              .to_return(status: 200, body: {data: [{id: "gpt-4"}, {id: "gpt-3.5-turbo"}]}.to_json)

            expect(subject.models).to eq([{"id" => "gpt-4"}, {"id" => "gpt-3.5-turbo"}])
          end

          it "returns nil on a 500" do
            stub_request(:get, "https://api.openai.com/v1/models").to_return(status: 500, body: "{}")

            expect(subject.models).to be_nil
          end

          it "raises a typed server error on a 500 with fail_on_error" do
            stub_request(:get, "https://api.openai.com/v1/models").to_return(status: 500, body: "{}")

            expect { subject.models(fail_on_error: true) }.to raise_error(Agentic::Errors::LlmServerError)
          end

          it "raises a typed auth error on a 401 with fail_on_error" do
            stub_request(:get, "https://api.openai.com/v1/models").to_return(status: 401, body: "{}")

            expect { subject.models(fail_on_error: true) }.to raise_error(Agentic::Errors::LlmAuthenticationError)
          end
        end

        describe "#query_generation_stats" do
          let(:stats) { {"data" => {"id" => "gen_123", "total_cost" => 0.001}} }

          it "GETs /generation?id= and returns the parsed body" do
            stub_request(:get, "https://api.openai.com/v1/generation")
              .with(query: {id: "gen_123"})
              .to_return(status: 200, body: stats.to_json)

            expect(subject.query_generation_stats("gen_123")).to eq(stats)
          end

          it "returns nil on a 404" do
            stub_request(:get, "https://api.openai.com/v1/generation").with(query: {id: "nope"}).to_return(status: 404, body: "{}")

            expect(subject.query_generation_stats("nope")).to be_nil
          end

          it "raises a typed invalid-request error on a 404 with fail_on_error" do
            stub_request(:get, "https://api.openai.com/v1/generation").with(query: {id: "nope"}).to_return(status: 404, body: "{}")

            expect { subject.query_generation_stats("nope", fail_on_error: true) }
              .to raise_error(Agentic::Errors::LlmInvalidRequestError)
          end
        end
      end
    end

    describe "base URL handling" do
      before { allow(Agentic.configuration).to receive(:llm_backend).and_return(:ruby_llm) }

      {
        "https://openrouter.ai/api/v1" => "https://openrouter.ai/api/v1/models",
        "https://openrouter.ai/api/v1/" => "https://openrouter.ai/api/v1/models",
        "http://localhost:11434" => "http://localhost:11434/v1/models"
      }.each do |base, expected|
        it "resolves #{base} to #{expected}" do
          allow(Agentic.configuration).to receive(:api_base_url).and_return(base)
          stub_request(:get, expected).to_return(status: 200, body: {data: []}.to_json)

          expect(subject.models).to eq([])
        end
      end

      it "sends no Authorization header when there is no token" do
        allow(Agentic.configuration).to receive(:api_base_url).and_return("http://localhost:11434/v1")
        allow(Agentic.configuration).to receive(:access_token).and_return(nil)
        stub_request(:get, "http://localhost:11434/v1/models")
          .with { |req| !req.headers.key?("Authorization") }
          .to_return(status: 200, body: {data: []}.to_json)

        expect(subject.models).to eq([])
      end
    end
  end

  describe "private methods" do
    subject { described_class.new(config) }

    describe "#extract_message_content" do
      let(:messages) do
        [
          {role: "user", content: "Short message"},
          {"role" => "assistant", "content" => "This is a long response that needs to be truncated. " * 5},
          {role: "system", content: nil}
        ]
      end

      it "extracts and truncates message content" do
        result = subject.send(:extract_message_content, messages)

        expect(result[0]).to eq("user: Short message")
        expect(result[1]).to start_with("assistant: This is a long response")
        expect(result[1]).to end_with("...")
        expect(result[1].length).to be <= 115  # role + ": " + 100 chars + "..."
        expect(result[2]).to eq("system: [no content]")
      end
    end

    describe "#map_http_error" do
      context "with Faraday errors" do
        def faraday_error(klass, status, headers: {}, body: nil)
          klass.new(nil, {status: status, headers: headers, body: body})
        end

        it "maps 429 to LlmRateLimitError with retry-after" do
          error = faraday_error(Faraday::TooManyRequestsError, 429, headers: {"retry-after" => "7"}, body: "slow down")
          mapped = subject.send(:map_http_error, error)
          expect(mapped).to be_a(Agentic::Errors::LlmRateLimitError)
          expect(mapped.retry_after).to eq(7)
        end

        it "maps 401 and 403 to LlmAuthenticationError" do
          expect(subject.send(:map_http_error, faraday_error(Faraday::UnauthorizedError, 401)))
            .to be_a(Agentic::Errors::LlmAuthenticationError)
          expect(subject.send(:map_http_error, faraday_error(Faraday::ForbiddenError, 403)))
            .to be_a(Agentic::Errors::LlmAuthenticationError)
        end

        it "maps 400, 404 and 422 to LlmInvalidRequestError" do
          [[Faraday::BadRequestError, 400], [Faraday::ResourceNotFound, 404], [Faraday::UnprocessableEntityError, 422]].each do |klass, status|
            expect(subject.send(:map_http_error, faraday_error(klass, status)))
              .to be_a(Agentic::Errors::LlmInvalidRequestError)
          end
        end

        it "maps 5xx to LlmServerError" do
          mapped = subject.send(:map_http_error, faraday_error(Faraday::ServerError, 503, body: "upstream down"))
          expect(mapped).to be_a(Agentic::Errors::LlmServerError)
        end

        it "maps a Faraday::Error with no HTTP status to LlmNetworkError" do
          mapped = subject.send(:map_http_error, Faraday::Error.new("socket reset"))
          expect(mapped).to be_a(Agentic::Errors::LlmNetworkError)
        end

        it "still maps Faraday::TimeoutError to LlmTimeoutError" do
          mapped = subject.send(:map_http_error, Faraday::TimeoutError.new("execution expired"))
          expect(mapped).to be_a(Agentic::Errors::LlmTimeoutError)
        end

        it "maps Faraday::ConnectionFailed to LlmNetworkError" do
          mapped = subject.send(:map_http_error, Faraday::ConnectionFailed.new("connection refused"))
          expect(mapped).to be_a(Agentic::Errors::LlmNetworkError)
        end
      end
    end

    describe "#handle_error" do
      let(:error) { Agentic::Errors::LlmError.new("Test error") }

      context "with fail_on_error true" do
        it "raises the error" do
          expect do
            subject.send(:handle_error, error, true)
          end.to raise_error(error)
        end
      end

      context "with fail_on_error false" do
        it "returns error response" do
          result = subject.send(:handle_error, error, false)

          expect(result).to be_a(Agentic::LlmResponse)
          expect(result.success?).to be false
          expect(result.error).to eq(error)
        end
      end
    end
  end
end
