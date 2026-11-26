# frozen_string_literal: true

require "json"

module Agentic
  # Speaks the same `chat(parameters:)` contract LlmClient uses with
  # ruby-openai, but sends the request through RubyLLM. Takes OpenAI-shaped
  # parameters and returns an OpenAI-shaped response hash, so LlmClient's
  # refusal, parse, and LlmResponse handling stay unchanged when the
  # transport swaps.
  #
  # RubyLLM and Faraday exceptions come back out as agentic's typed errors
  # (via RubyLlmErrorMap), which RetryHandler and the intervention pause
  # already branch on.
  class RubyLlmAdapter
    # Parameters with a dedicated RubyLLM setter. Everything else non-nil
    # rides through `with_provider_options`.
    HANDLED = %i[model messages temperature max_tokens response_format stream].freeze

    # @param context [RubyLLM::Context, #chat] where chats are built; a
    #   context keeps per-client keys and base URLs off the global config
    # @param provider [Symbol, nil] force a provider (e.g. :ollama, :openai)
    # @param assume_model_exists [Boolean] skip RubyLLM's model registry
    #   lookup, needed for local and custom model names
    def initialize(context:, provider: nil, assume_model_exists: false)
      @context = context
      @provider = provider
      @assume_model_exists = assume_model_exists
    end

    # @param parameters [Hash] OpenAI chat-completions parameters
    # @return [Hash] OpenAI chat-completions response shape
    # @raise [Errors::LlmError] typed error for any RubyLLM/Faraday failure
    def chat(parameters:)
      params = parameters.transform_keys(&:to_sym)
      chat = build_chat(params)
      stream = params[:stream]

      message = if stream.respond_to?(:call)
        chat.complete { |chunk| forward_chunk(chunk, stream) }
      else
        chat.complete
      end

      to_openai_response(message)
    rescue Errors::LlmError
      raise
    rescue => e
      typed = RubyLlmErrorMap.translate(e)
      raise(typed || e)
    end

    private

    def build_chat(params)
      chat = @context.chat(
        model: params[:model],
        provider: @provider,
        assume_model_exists: @assume_model_exists
      )

      Array(params[:messages]).each do |msg|
        msg = msg.transform_keys(&:to_sym)
        chat.add_message(role: msg[:role].to_sym, content: msg[:content])
      end

      chat.with_temperature(params[:temperature]) unless params[:temperature].nil?
      chat.with_max_output_tokens(params[:max_tokens]) if params[:max_tokens]

      schema = json_schema(params[:response_format])
      chat.with_schema(schema) if schema

      extra = params.except(*HANDLED).compact
      chat.with_provider_options(extra) unless extra.empty?

      chat
    end

    def json_schema(response_format)
      return nil unless response_format.is_a?(Hash)

      format = response_format.transform_keys(&:to_sym)
      (format[:type].to_s == "json_schema") ? format[:json_schema] : nil
    end

    # ruby-openai's stream proc receives (chunk_hash, bytesize)
    def forward_chunk(chunk, stream)
      content = chunk.respond_to?(:content) ? chunk.content : nil
      return if content.nil? || content == ""

      stream.call({"choices" => [{"delta" => {"content" => content}}]}, nil)
    end

    def to_openai_response(message)
      {
        "model" => message.model,
        "choices" => [{
          "index" => 0,
          "message" => {"role" => "assistant", "content" => serialize(message.content)},
          "finish_reason" => message.finish_reason&.to_s
        }],
        "usage" => usage(message.tokens)
      }
    end

    # ruby_llm 2.2.3 keeps Message#content a String (structured data lives on
    # #parsed); guard anyway, since LlmClient JSON-parses the content itself.
    def serialize(content)
      (content.is_a?(Hash) || content.is_a?(Array)) ? JSON.generate(content) : content
    end

    def usage(tokens)
      return nil unless tokens

      input = tokens.input
      output = tokens.output
      return nil if input.nil? && output.nil?

      {
        "prompt_tokens" => input,
        "completion_tokens" => output,
        "total_tokens" => input.to_i + output.to_i
      }.compact
    end
  end
end
