# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::LlmClient, :vcr do
  let(:config) { double("LlmConfig") }
  let(:access_token) { "test-token" }
  let(:messages) { [{role: "user", content: "Test message"}] }
  let(:api_parameters) { {model: "gpt-4", messages: messages, temperature: 0.7} }

  before do
    allow(Agentic.configuration).to receive(:access_token).and_return(access_token)
    allow(Agentic.configuration).to receive(:api_base_url).and_return(nil)
    allow(config).to receive(:to_api_parameters).and_return(api_parameters)
    allow(Agentic.logger).to receive(:error)
    allow(Agentic.logger).to receive(:warn)
    # Exercise retry logic without real backoff waits
    allow_any_instance_of(Agentic::RetryHandler).to receive(:sleep)
  end

  describe ".new" do
    it "initializes with OpenAI client" do
      expect(OpenAI::Client).to receive(:new).with(access_token: access_token)

      client = described_class.new(config)
      expect(client).to be_a(described_class)
    end

    context "with custom API base URL" do
      before do
        allow(Agentic.configuration).to receive(:api_base_url).and_return("http://localhost:11434")
      end

      it "configures client with custom base URL" do
        expect(OpenAI::Client).to receive(:new).with(
          access_token: access_token,
          uri_base: "http://localhost:11434"
        )

        described_class.new(config)
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
    let(:openai_client) { instance_double(OpenAI::Client) }
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
      allow(OpenAI::Client).to receive(:new).and_return(openai_client)
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

    context "with OpenAI errors" do
      let(:timeout_error) { OpenAI::Timeout.new("Request timeout") }
      let(:rate_limit_error) { OpenAI::RateLimitError.new("Rate limit exceeded") }
      let(:auth_error) { OpenAI::AuthenticationError.new("Invalid API key") }

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

      context "when the HTTP layer raises Faraday::TooManyRequestsError (ruby-openai 8.x)" do
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

  describe "#models" do
    let(:openai_client) { instance_double(OpenAI::Client) }
    let(:models_response) { {"data" => [{"id" => "gpt-4"}, {"id" => "gpt-3.5-turbo"}]} }
    let(:models_client) { double("OpenAI::Models") }

    subject { described_class.new(config) }

    before do
      allow(OpenAI::Client).to receive(:new).and_return(openai_client)
      allow(openai_client).to receive(:models).and_return(models_client)
      allow(models_client).to receive(:list).and_return(models_response)
    end

    it "returns available models" do
      result = subject.models

      expect(result).to eq([{"id" => "gpt-4"}, {"id" => "gpt-3.5-turbo"}])
    end

    context "when API error occurs" do
      let(:api_error) { OpenAI::APIError.new("Server error") }

      before do
        allow(models_client).to receive(:list).and_raise(api_error)
      end

      it "returns nil on error" do
        result = subject.models

        expect(result).to be_nil
      end

      context "with fail_on_error true" do
        it "raises mapped error" do
          expect do
            subject.models(fail_on_error: true)
          end.to raise_error(Agentic::Errors::LlmServerError)
        end
      end
    end
  end

  describe "#query_generation_stats" do
    let(:openai_client) { double("OpenAI::Client") }
    let(:generation_id) { "gen_123" }
    let(:stats_response) { {"usage" => {"total_tokens" => 100}} }

    subject { described_class.new(config) }

    before do
      allow(OpenAI::Client).to receive(:new).and_return(openai_client)
      allow(openai_client).to receive(:query_generation_stats).and_return(stats_response)
    end

    it "returns generation stats" do
      result = subject.query_generation_stats(generation_id)

      expect(result).to eq(stats_response)
    end

    context "when API error occurs" do
      let(:api_error) { OpenAI::InvalidRequestError.new("Invalid generation ID") }

      before do
        allow(openai_client).to receive(:query_generation_stats).and_raise(api_error)
      end

      it "returns nil on error" do
        result = subject.query_generation_stats(generation_id)

        expect(result).to be_nil
      end

      context "with fail_on_error true" do
        it "raises mapped error" do
          expect do
            subject.query_generation_stats(generation_id, fail_on_error: true)
          end.to raise_error(Agentic::Errors::LlmInvalidRequestError)
        end
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

    describe "#map_openai_error" do
      context "with Faraday errors re-raised by ruby-openai 8.x" do
        def faraday_error(klass, status, headers: {}, body: nil)
          klass.new(nil, {status: status, headers: headers, body: body})
        end

        it "maps 429 to LlmRateLimitError with retry-after" do
          error = faraday_error(Faraday::TooManyRequestsError, 429, headers: {"retry-after" => "7"}, body: "slow down")
          mapped = subject.send(:map_openai_error, error)
          expect(mapped).to be_a(Agentic::Errors::LlmRateLimitError)
          expect(mapped.retry_after).to eq(7)
        end

        it "maps 401 and 403 to LlmAuthenticationError" do
          expect(subject.send(:map_openai_error, faraday_error(Faraday::UnauthorizedError, 401)))
            .to be_a(Agentic::Errors::LlmAuthenticationError)
          expect(subject.send(:map_openai_error, faraday_error(Faraday::ForbiddenError, 403)))
            .to be_a(Agentic::Errors::LlmAuthenticationError)
        end

        it "maps 400, 404 and 422 to LlmInvalidRequestError" do
          [[Faraday::BadRequestError, 400], [Faraday::ResourceNotFound, 404], [Faraday::UnprocessableEntityError, 422]].each do |klass, status|
            expect(subject.send(:map_openai_error, faraday_error(klass, status)))
              .to be_a(Agentic::Errors::LlmInvalidRequestError)
          end
        end

        it "maps 5xx to LlmServerError" do
          mapped = subject.send(:map_openai_error, faraday_error(Faraday::ServerError, 503, body: "upstream down"))
          expect(mapped).to be_a(Agentic::Errors::LlmServerError)
        end

        it "maps a Faraday::Error with no HTTP status to LlmNetworkError" do
          mapped = subject.send(:map_openai_error, Faraday::Error.new("socket reset"))
          expect(mapped).to be_a(Agentic::Errors::LlmNetworkError)
        end

        it "still maps Faraday::TimeoutError to LlmTimeoutError" do
          mapped = subject.send(:map_openai_error, Faraday::TimeoutError.new("execution expired"))
          expect(mapped).to be_a(Agentic::Errors::LlmTimeoutError)
        end
      end
      context "with different OpenAI error types" do
        let(:timeout_error) { OpenAI::Timeout.new("Request timeout") }
        let(:rate_limit_error) { OpenAI::RateLimitError.new("Rate limit") }
        let(:auth_error) { OpenAI::AuthenticationError.new("Auth failed") }
        let(:connection_error) { OpenAI::APIConnectionError.new("Connection failed") }
        let(:invalid_request_error) { OpenAI::InvalidRequestError.new("Invalid request") }
        let(:api_error) { OpenAI::APIError.new("Server error") }
        let(:generic_error) { OpenAI::Error.new("Generic error") }

        it "maps timeout error correctly" do
          mapped = subject.send(:map_openai_error, timeout_error)
          expect(mapped).to be_a(Agentic::Errors::LlmTimeoutError)
        end

        it "maps rate limit error correctly" do
          mapped = subject.send(:map_openai_error, rate_limit_error)
          expect(mapped).to be_a(Agentic::Errors::LlmRateLimitError)
        end

        it "maps authentication error correctly" do
          mapped = subject.send(:map_openai_error, auth_error)
          expect(mapped).to be_a(Agentic::Errors::LlmAuthenticationError)
        end

        it "maps connection error correctly" do
          mapped = subject.send(:map_openai_error, connection_error)
          expect(mapped).to be_a(Agentic::Errors::LlmNetworkError)
        end

        it "maps invalid request error correctly" do
          mapped = subject.send(:map_openai_error, invalid_request_error)
          expect(mapped).to be_a(Agentic::Errors::LlmInvalidRequestError)
        end

        it "maps API error correctly" do
          mapped = subject.send(:map_openai_error, api_error)
          expect(mapped).to be_a(Agentic::Errors::LlmServerError)
        end

        it "maps generic error correctly" do
          mapped = subject.send(:map_openai_error, generic_error)
          expect(mapped).to be_a(Agentic::Errors::LlmError)
        end
      end

      context "with response metadata" do
        let(:response_double) { double("Response", headers: {"retry-after" => "60"}, to_h: {"error" => "details"}) }
        let(:rate_limit_error) do
          error = OpenAI::RateLimitError.new("Rate limit")
          allow(error).to receive(:response).and_return(response_double)
          error
        end

        it "includes retry-after header in rate limit error" do
          mapped = subject.send(:map_openai_error, rate_limit_error)
          expect(mapped).to be_a(Agentic::Errors::LlmRateLimitError)
          expect(mapped.retry_after).to eq(60)
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
