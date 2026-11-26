# frozen_string_literal: true

module Agentic
  # Translates RubyLLM (and Faraday transport) exceptions into agentic's typed
  # LLM errors, so callers that branch on Errors::LlmAuthenticationError,
  # Errors::LlmRateLimitError, etc. keep working once LlmClient talks to
  # RubyLLM instead of ruby-openai.
  #
  # Classes are looked up by name at call time so this file loads (and its
  # specs run) whether or not ruby_llm has been required yet.
  module RubyLlmErrorMap
    # Ordered: more specific RubyLLM classes first. UnsupportedParameterError
    # subclasses BadRequestError, so it must precede it.
    MAPPING = [
      ["RubyLLM::UnauthorizedError", :authentication],
      ["RubyLLM::ForbiddenError", :authentication],
      ["RubyLLM::PaymentRequiredError", :authentication],
      ["RubyLLM::RateLimitError", :rate_limit],
      ["RubyLLM::UnsupportedParameterError", :invalid_request],
      ["RubyLLM::ContextLengthExceededError", :invalid_request],
      ["RubyLLM::BadRequestError", :invalid_request],
      ["RubyLLM::ContentFilterError", :refusal],
      ["RubyLLM::OverloadedError", :server],
      ["RubyLLM::ServiceUnavailableError", :server],
      ["RubyLLM::ServerError", :server],
      # Plain StandardError subclasses in ruby_llm 2.x, not RubyLLM::Error
      ["RubyLLM::ModelNotFoundError", :invalid_request],
      ["RubyLLM::ConfigurationError", :authentication],
      ["Faraday::TimeoutError", :timeout],
      ["Faraday::ConnectionFailed", :network],
      ["RubyLLM::Error", :server]
    ].freeze

    module_function

    # @param error [Exception] the exception raised by RubyLLM or Faraday
    # @return [Errors::LlmError, nil] the typed agentic error, or nil when the
    #   exception isn't one this map knows (let it propagate unchanged)
    def translate(error)
      return error if error.is_a?(Errors::LlmError)

      kind = kind_for(error)
      return nil unless kind

      build(kind, error)
    end

    # @param error [Exception]
    # @return [Symbol, nil]
    def kind_for(error)
      MAPPING.each do |class_name, kind|
        klass = constant(class_name)
        return kind if klass && error.is_a?(klass)
      end
      nil
    end

    def build(kind, error)
      message = error.message.to_s
      context = {source: error.class.name}
      response = response_body(error)

      case kind
      when :authentication
        Errors::LlmAuthenticationError.new(message, response: response, context: context)
      when :rate_limit
        Errors::LlmRateLimitError.new(message, retry_after: retry_after(error), response: response, context: context)
      when :invalid_request
        Errors::LlmInvalidRequestError.new(message, response: response, context: context)
      when :refusal
        Errors::LlmRefusalError.new(message, refusal_category: :harmful_content, response: response, context: context)
      when :server
        Errors::LlmServerError.new(message, response: response, context: context)
      when :timeout
        Errors::LlmTimeoutError.new(message, context: context)
      when :network
        Errors::LlmNetworkError.new(message, network_exception: error, context: context)
      end
    end

    def constant(name)
      Object.const_get(name) if Object.const_defined?(name)
    rescue NameError
      nil
    end

    def response_body(error)
      return nil unless error.respond_to?(:response) && error.response

      body = error.response.respond_to?(:body) ? error.response.body : nil
      body.is_a?(Hash) ? body : nil
    end

    def retry_after(error)
      return nil unless error.respond_to?(:response) && error.response.respond_to?(:headers)

      value = error.response.headers&.[]("retry-after")
      Integer(value, exception: false) if value
    end
  end
end
