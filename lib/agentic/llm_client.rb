# frozen_string_literal: true

require "openai"
require "net/http"

module Agentic
  # Generic wrapper for LLM API clients
  class LlmClient
    # @return [OpenAI::Client] The underlying LLM client instance
    attr_reader :client, :last_response

    # @return [RetryHandler] The retry handler for transient errors
    attr_reader :retry_handler

    # Initializes a new LlmClient
    # @param config [LlmConfig] The configuration for the LLM
    # @param retry_config [RetryConfig, Hash] Configuration for the retry handler
    # @param limiter [RateLimit, nil] A credential-scoped concurrency ceiling;
    #   share one limiter across every client using the same API key
    def initialize(config, retry_config = {}, limiter: nil)
      configuration = Agentic.configuration
      configuration.validate!
      @limiter = limiter

      # Local endpoints (Ollama, etc.) ignore the token but the client
      # requires one, so send an explicit placeholder rather than nil
      client_options = {access_token: configuration.access_token || "local"}

      # Add custom base URL if configured (for Ollama, etc.)
      if configuration.api_base_url
        client_options[:uri_base] = configuration.api_base_url
      end

      @client = OpenAI::Client.new(**client_options)
      @config = config
      @last_response = nil

      # Convert retry_config to RetryHandler
      @retry_handler = if retry_config.respond_to?(:to_handler)
        retry_config.to_handler
      elsif retry_config.is_a?(Hash)
        RetryHandler.new(**retry_config)
      else
        retry_config
      end
    end

    # Sends a completion request to the LLM
    # @param messages [Array<Hash>] The messages to send
    # @param output_schema [Agentic::StructuredOutputs::Schema, nil] Optional schema for structured output
    # @param fail_on_error [Boolean] Whether to raise errors or return them as part of the response
    # @param use_retries [Boolean] Whether to retry on transient errors
    # @param stream_callback [Proc] Optional callback for streaming tokens/progress
    # @param options [Hash] Additional options to override the config
    # @return [LlmResponse] The structured response from the LLM
    def complete(messages, output_schema: nil, fail_on_error: false, use_retries: true, stream_callback: nil, options: {})
      # Start with base parameters from the config
      parameters = @config.to_api_parameters({messages: messages})

      # Add response format if schema is provided
      if output_schema
        parameters[:response_format] = {
          type: "json_schema",
          json_schema: output_schema.to_hash
        }
      end

      # Override with any additional options
      parameters.merge!(options)

      execution_method = use_retries ? method(:with_retry) : method(:without_retry)

      if @limiter
        @limiter.acquire { execution_method.call(messages, parameters, output_schema, fail_on_error, stream_callback) }
      else
        execution_method.call(messages, parameters, output_schema, fail_on_error, stream_callback)
      end
    end

    # Executes the API call with retries for transient errors
    # @param messages [Array<Hash>] The messages being sent
    # @param parameters [Hash] The request parameters
    # @param output_schema [Agentic::StructuredOutputs::Schema, nil] Optional schema for structured output
    # @param fail_on_error [Boolean] Whether to raise errors or return them as part of the response
    # @param stream_callback [Proc] Optional callback for streaming tokens/progress
    # @return [LlmResponse] The structured response from the LLM
    def with_retry(messages, parameters, output_schema, fail_on_error, stream_callback)
      retry_handler.with_retry do
        without_retry(messages, parameters, output_schema, fail_on_error, stream_callback)
      end
    rescue Errors::LlmError => e
      # If we get here, we've exhausted retries or hit a non-retryable error
      if e.respond_to?(:log_securely)
        e.log_securely(Agentic.logger)
      else
        safe_message = Security::Config.sanitizer.sanitize_error("Failed after retries: #{e.message}")
        Agentic.logger.error(safe_message)
      end
      handle_error(e, fail_on_error)
    end

    # Executes the API call without retries
    # @param messages [Array<Hash>] The messages being sent
    # @param parameters [Hash] The request parameters
    # @param output_schema [Agentic::StructuredOutputs::Schema, nil] Optional schema for structured output
    # @param fail_on_error [Boolean] Whether to raise errors or return them as part of the response
    # @param stream_callback [Proc] Optional callback for streaming tokens/progress
    # @return [LlmResponse] The structured response from the LLM
    def without_retry(messages, parameters, output_schema, fail_on_error, stream_callback)
      @last_response = if stream_callback && output_schema
        stream_structured_response(parameters, output_schema, stream_callback)
      else
        client.chat(parameters: parameters)
      end

      # Check for API-level refusal
      if (refusal = @last_response.dig("choices", 0, "message", "refusal"))
        refusal_error = Errors::LlmRefusalError.new(
          refusal,
          response: @last_response,
          context: {input_messages: extract_message_content(messages)}
        )

        # Use secure logging for refusal messages
        if refusal_error.respond_to?(:log_securely)
          refusal_error.log_securely(Agentic.logger)
        else
          safe_refusal = Security::Config.sanitizer.sanitize_error(refusal)
          Agentic.logger.warn("LLM refused the request: #{safe_refusal} (Category: #{refusal_error.refusal_category})")
        end

        if fail_on_error
          raise refusal_error
        else
          return LlmResponse.refusal(@last_response, refusal, refusal_error)
        end
      end

      # Process the response based on whether we expect structured output
      if output_schema
        begin
          content_text = @last_response.dig("choices", 0, "message", "content")
          if content_text.nil? || content_text.empty?
            error = Errors::LlmParseError.new("Empty content returned from LLM", response: @last_response)
            error.log_securely(Agentic.logger) if error.respond_to?(:log_securely)
            return handle_error(error, fail_on_error)
          end

          content = JSON.parse(content_text)
          LlmResponse.success(@last_response, content)
        rescue JSON::ParserError => e
          error = Errors::LlmParseError.new(
            "Failed to parse JSON response: #{e.message}",
            parse_exception: e,
            response: @last_response
          )
          error.log_securely(Agentic.logger) if error.respond_to?(:log_securely)
          handle_error(error, fail_on_error)
        end
      else
        content = @last_response.dig("choices", 0, "message", "content")
        LlmResponse.success(@last_response, content)
      end
    rescue OpenAI::Error => e
      error = map_openai_error(e)
      Agentic.logger.error("OpenAI API error: #{error.safe_message}")
      handle_error(error, fail_on_error)
    rescue Net::ReadTimeout, Net::OpenTimeout => e
      error = Errors::LlmTimeoutError.new("Request to LLM timed out: #{e.message}", context: {timeout_type: e.class.name})
      Agentic.logger.error(error.safe_message)
      handle_error(error, fail_on_error)
    rescue JSON::ParserError => e
      error = Errors::LlmParseError.new("Failed to parse JSON response: #{e.message}", parse_exception: e)
      Agentic.logger.error(error.safe_message)
      handle_error(error, fail_on_error)
    rescue Errors::LlmRefusalError, Errors::LlmParseError => e
      # Re-raise our custom errors that are already properly formatted
      handle_error(e, fail_on_error)
    rescue => e
      error = Errors::LlmError.new("Unexpected error in LLM request: #{e.message}", context: {error_class: e.class.name})
      Agentic.logger.error("#{error.safe_message}\n#{e.backtrace.join("\n")}")
      handle_error(error, fail_on_error)
    end

    # Fetches available models from the LLM provider
    # @param fail_on_error [Boolean] Whether to raise errors or return nil on error
    # @return [Array<Hash>, nil] The list of available models, or nil if an error occurred and fail_on_error is false
    # @raise [Agentic::Errors::LlmError] If an error occurred and fail_on_error is true
    def models(fail_on_error: false)
      client.models.list&.dig("data")
    rescue OpenAI::Error => e
      error = map_openai_error(e)
      Agentic.logger.error("OpenAI API error when listing models: #{error.safe_message}")
      handle_error(error, fail_on_error)
      nil
    rescue => e
      error = Errors::LlmError.new("Unexpected error listing models: #{e.message}")
      Agentic.logger.error("#{error.safe_message}\n#{e.backtrace.join("\n")}")
      handle_error(error, fail_on_error)
      nil
    end

    # Queries generation stats for a given generation ID
    # @param generation_id [String] The ID of the generation
    # @param fail_on_error [Boolean] Whether to raise errors or return nil on error
    # @return [Hash, nil] The generation stats, or nil if an error occurred and fail_on_error is false
    # @raise [Agentic::Errors::LlmError] If an error occurred and fail_on_error is true
    def query_generation_stats(generation_id, fail_on_error: false)
      client.query_generation_stats(generation_id)
    rescue OpenAI::Error => e
      error = map_openai_error(e)
      Agentic.logger.error("OpenAI API error when querying generation stats: #{error.safe_message}")
      handle_error(error, fail_on_error)
      nil
    rescue => e
      error = Errors::LlmError.new("Unexpected error querying generation stats: #{e.message}")
      Agentic.logger.error("#{error.safe_message}\n#{e.backtrace.join("\n")}")
      handle_error(error, fail_on_error)
      nil
    end

    private

    # Extracts content from messages for logging purposes with security sanitization
    # @param messages [Array<Hash>] The messages
    # @return [Array<String>] The extracted content, sanitized for logging
    def extract_message_content(messages)
      return [] if messages.nil?

      messages.map do |msg|
        content = msg[:content] || msg["content"]
        role = msg[:role] || msg["role"]

        if content
          # Sanitize content for LLM logging context
          sanitized_content = Security::Config.sanitizer.sanitize_llm_content(content)
          # Truncate after sanitization
          truncated = sanitized_content.to_s[0..100]
          truncated += "..." if sanitized_content.to_s.length > 100
          "#{role}: #{truncated}"
        else
          "#{role}: [no content]"
        end
      end
    end

    # Maps OpenAI error types to our custom error classes
    # @param error [OpenAI::Error] The original error from the OpenAI gem
    # @return [Agentic::Errors::LlmError] A mapped error
    def map_openai_error(error)
      # ruby-openai 8.x simplified error classes to just Error, ConfigurationError, and AuthenticationError
      # We check for specific error classes first (including test shims), then parse message

      case error
      when defined?(OpenAI::RateLimitError) && OpenAI::RateLimitError
        retry_after = error.respond_to?(:response) ? error.response&.headers&.[]("retry-after")&.to_i : nil
        Errors::LlmRateLimitError.new(
          "OpenAI API rate limit exceeded: #{error.message}",
          retry_after: retry_after,
          response: error.respond_to?(:response) ? error.response&.to_h : nil
        )
      when defined?(OpenAI::AuthenticationError) && OpenAI::AuthenticationError
        Errors::LlmAuthenticationError.new(
          "OpenAI API authentication error: #{error.message}",
          response: error.respond_to?(:response) ? error.response&.to_h : nil
        )
      when defined?(OpenAI::APIConnectionError) && OpenAI::APIConnectionError
        Errors::LlmNetworkError.new(
          "OpenAI API connection error: #{error.message}",
          network_exception: error
        )
      when defined?(OpenAI::InvalidRequestError) && OpenAI::InvalidRequestError
        Errors::LlmInvalidRequestError.new(
          "Invalid request to OpenAI API: #{error.message}",
          response: error.respond_to?(:response) ? error.response&.to_h : nil
        )
      when defined?(OpenAI::APIError) && OpenAI::APIError
        Errors::LlmServerError.new(
          "OpenAI API server error: #{error.message}",
          response: error.respond_to?(:response) ? error.response&.to_h : nil
        )
      when defined?(OpenAI::Timeout) && OpenAI::Timeout
        Errors::LlmTimeoutError.new("OpenAI API request timed out: #{error.message}")
      when defined?(Faraday::TimeoutError) && Faraday::TimeoutError
        Errors::LlmTimeoutError.new("OpenAI API request timed out: #{error.message}")
      when defined?(Faraday::ConnectionFailed) && Faraday::ConnectionFailed
        Errors::LlmNetworkError.new(
          "OpenAI API connection error: #{error.message}",
          network_exception: error
        )
      when OpenAI::Error
        # Parse error message to determine specific error type
        message = error.message.to_s.downcase

        if message.include?("rate limit") || message.include?("429")
          retry_after = error.respond_to?(:response) ? error.response&.headers&.[]("retry-after")&.to_i : nil
          Errors::LlmRateLimitError.new(
            "OpenAI API rate limit exceeded: #{error.message}",
            retry_after: retry_after,
            response: error.respond_to?(:response) ? error.response&.to_h : nil
          )
        elsif message.include?("timeout") || message.include?("timed out")
          Errors::LlmTimeoutError.new("OpenAI API request timed out: #{error.message}")
        elsif message.include?("connection") || message.include?("network")
          Errors::LlmNetworkError.new(
            "OpenAI API connection error: #{error.message}",
            network_exception: error
          )
        elsif message.include?("invalid") || message.include?("400")
          Errors::LlmInvalidRequestError.new(
            "Invalid request to OpenAI API: #{error.message}",
            response: error.respond_to?(:response) ? error.response&.to_h : nil
          )
        elsif message.include?("server") || message.match?(/5\d\d/)
          Errors::LlmServerError.new(
            "OpenAI API server error: #{error.message}",
            response: error.respond_to?(:response) ? error.response&.to_h : nil
          )
        else
          Errors::LlmError.new(
            "OpenAI API error: #{error.message}",
            response: error.respond_to?(:response) ? error.response&.to_h : nil
          )
        end
      else
        Errors::LlmError.new(
          "Unexpected error: #{error.message}",
          context: {error_class: error.class.name}
        )
      end
    end

    # Handles an error based on whether to fail or return it in the response
    # @param error [Agentic::Errors::LlmError] The error to handle
    # @param fail_on_error [Boolean] Whether to raise the error
    # @return [LlmResponse] An error response if fail_on_error is false
    # @raise [Agentic::Errors::LlmError] If fail_on_error is true
    def handle_error(error, fail_on_error)
      raise error if fail_on_error
      LlmResponse.error(error, @last_response)
    end

    # Streams a structured response using Oj for JSON streaming
    # @param parameters [Hash] The request parameters
    # @param output_schema [Agentic::StructuredOutputs::Schema] The expected output schema
    # @param stream_callback [Proc] Callback for streaming progress updates
    # @return [Hash] The complete response from the LLM
    def stream_structured_response(parameters, output_schema, stream_callback)
      accumulated_content = ""

      # Stream the response using ruby-openai
      response = client.chat(
        parameters: parameters.merge(
          stream: proc do |chunk, _bytesize|
            # Extract content delta from chunk
            content_delta = chunk.dig("choices", 0, "delta", "content")
            next unless content_delta

            accumulated_content += content_delta

            # Notify callback with streaming token
            stream_callback.call(:token_received, content_delta)
          end
        )
      )

      # Fall back to the complete response body when no stream chunks arrived
      # (e.g. a provider or test stub that returns a full JSON response
      # despite the stream parameter)
      if accumulated_content.empty? && response.is_a?(Hash)
        fallback_content = response.dig("choices", 0, "message", "content")
        accumulated_content = fallback_content if fallback_content
      end

      # If streaming delivered nothing at all, degrade gracefully to a
      # non-streaming request rather than failing on empty content
      if accumulated_content.empty?
        fallback_response = client.chat(parameters: parameters)
        if fallback_response.is_a?(Hash)
          content = fallback_response.dig("choices", 0, "message", "content").to_s
          stream_callback.call(:stream_complete, content)
          return fallback_response
        end
      end

      # Notify callback of completion
      stream_callback.call(:stream_complete, accumulated_content)

      # Return response in expected format with accumulated content
      {
        "choices" => [
          {
            "message" => {
              "content" => accumulated_content,
              "role" => "assistant"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => response.is_a?(Hash) ? response["usage"] : nil
      }
    end
  end
end
