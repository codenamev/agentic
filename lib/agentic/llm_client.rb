# frozen_string_literal: true

require "openai"

module Agentic
  # Generic wrapper for LLM API clients
  class LlmClient
    # @return [OpenAI::Client] The underlying LLM client instance
    attr_reader :client, :last_response

    # Initializes a new LlmClient
    # @param config [LlmConfig] The configuration for the LLM
    def initialize(config)
      @client = OpenAI::Client.new(access_token: Agentic.configuration.access_token)
      @config = config
      @last_response = nil
    end

    # Sends a completion request to the LLM
    # @param messages [Array<Hash>] The messages to send
    # @return [Hash] The response from the LLM
    def complete(messages, output_schema: nil)
      parameters = {model: @config.model, messages: messages}
      if output_schema
        parameters[:response_format] = {
          type: "json_schema",
          json_schema: output_schema.to_hash
        }
      end

      @last_response = client.chat(parameters: parameters)

      if output_schema
        content = JSON.parse(@last_response.dig("choices", 0, "message", "content"))

        if (refusal = @last_response.dig("choices", 0, "message", "refusal"))
          {refusal: refusal, content: nil}
        else
          {content: content}
        end
      else
        @last_response.dig("choices", 0, "message", "content")
      end
    end

    # Fetches available models from the LLM provider
    # @return [Array<Hash>] The list of available models
    def models
      client.models.list&.dig("data")
    end

    # Queries generation stats for a given generation ID
    # @param generation_id [String] The ID of the generation
    # @return [Hash] The generation stats
    def query_generation_stats(generation_id)
      client.query_generation_stats(generation_id)
    end
  end
end
