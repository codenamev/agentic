# frozen_string_literal: true

module Agentic
  # All Agentic error classes live in this one file so that referencing
  # Agentic::Errors (or any constant beneath it) loads every error class.
  # Zeitwerk autoloads a file when its namesake constant is referenced;
  # sibling constants scattered across files would only load alongside
  # their namesakes, making `rescue Errors::LlmTimeoutError` a NameError
  # lottery dependent on load order.
  module Errors
    # Raised when the library is asked to talk to an LLM without usable
    # credentials or endpoint configuration. Raised at client construction
    # time so misconfiguration fails at boot, not at request time.
    class ConfigurationError < StandardError; end

    # Raised by strict-mode journal replay when a line is torn,
    # mis-encoded, or (for task events) missing its identifying keys.
    # Tolerant replay - the recovery default - reports damage on the
    # replayed state instead of raising.
    class JournalDamagedError < StandardError
      # @return [Integer] 1-based line number of the damaged line
      attr_reader :line_number

      # @param message [String] What was wrong
      # @param line_number [Integer] Where it was wrong
      def initialize(message, line_number:)
        @line_number = line_number
        super("#{message} (line #{line_number})")
      end
    end

    # Raised when a capability's inputs or outputs violate its declared
    # specification. Collects every violation instead of failing on the
    # first, so callers can fix a bad payload in one round trip.
    class ValidationError < StandardError
      # @return [String] The capability whose contract was violated
      attr_reader :capability

      # @return [Symbol] Which side of the contract failed (:inputs or :outputs)
      attr_reader :kind

      # @return [Hash{Symbol=>Array<String>}] Violation messages keyed by attribute
      attr_reader :violations

      # The declared contract for each violated key - type, enum, min/max,
      # required - so callers can render what WOULD have been legal without
      # side-channel knowledge of the contract
      # @return [Hash{Symbol=>Hash}] Declarations keyed by violated attribute
      attr_reader :expectations

      # Structured cross-field rule violations: each carries the rule's
      # identifier, its human message, and the fields it reads - so UIs
      # can highlight the offending inputs, not just print prose
      # @return [Array<Hash>] [{rule:, message:, fields:}, ...]
      attr_reader :rule_violations

      # Typo diagnoses: when a sent key is close to a missing declared
      # key, the error says so - "you sent :weight_kilo - did you mean
      # :weight_kg?". Missing-plus-similar-extra is a typo's signature,
      # and the correction costs one Levenshtein pass at raise time.
      # @return [Array<String>] Human hint sentences (possibly empty)
      attr_reader :hints

      # @param capability [String] The capability name
      # @param kind [Symbol] :inputs or :outputs
      # @param violations [Hash{Symbol=>Array<String>}] Messages keyed by attribute
      # @param expectations [Hash{Symbol=>Hash}] Declarations for violated keys
      # @param rule_violations [Array<Hash>] Structured broken-rule records
      # @param hints [Array<String>] Typo diagnoses to append to the message
      def initialize(capability:, kind:, violations:, expectations: {}, rule_violations: [], hints: [])
        @capability = capability
        @kind = kind
        @violations = violations
        @expectations = expectations
        @rule_violations = rule_violations
        @hints = hints

        details = violations.map { |key, messages| "#{key} #{Array(messages).join(", ")}" }.join("; ")
        details += ". #{hints.join(" ")}" unless hints.empty?
        super("Invalid #{kind} for capability '#{capability}': #{details}")
      end
    end

    # Base class for agent configuration and capability errors
    class AgentError < StandardError; end

    # Raised when a capability is requested that the registry or agent
    # does not know about
    class CapabilityNotFoundError < AgentError
      # @return [String] The capability that could not be found
      attr_reader :capability_name

      # @param capability_name [String] The capability that could not be found
      # @param context [String, nil] Where the lookup failed
      def initialize(capability_name, context: nil)
        @capability_name = capability_name
        message = "Capability not found: #{capability_name}"
        message += " (#{context})" if context
        super(message)
      end
    end

    # Raised when a structured-output schema is requested from an agent
    # whose execution path cannot honor it
    class SchemaNotSupportedError < AgentError; end

    # Raised when an agent is asked to execute but has neither a
    # text_generation capability nor an LLM client configured
    class AgentNotConfiguredError < AgentError
      def initialize(message = nil)
        super(message || "Agent not configured with LLM capabilities. " \
          "Use DefaultAgentProvider or configure llm_client directly.")
      end
    end

    # Raised when the planner cannot break a goal into tasks because the
    # LLM call failed (bad key, network, refusal). An empty plan would
    # otherwise look like success to the caller.
    class PlanningFailedError < StandardError
      # @return [StandardError, nil] The underlying LLM error, if any
      attr_reader :llm_error

      def initialize(message, llm_error: nil)
        super(message)
        @llm_error = llm_error
      end
    end

    # Base class for all LLM-related errors
    class LlmError < StandardError
      include Security::SecureErrorMixin

      # @return [Hash, nil] The raw response from the LLM API, if available
      attr_reader :response

      # @return [Hash, nil] Additional context about the error
      attr_reader :context

      # @param message [String] The error message
      # @param response [Hash, nil] The raw response from the LLM API
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, response: nil, context: nil)
        super(message)
        @response = response
        @context = context || {}
      end
    end

    # Error raised when the LLM refuses to respond
    class LlmRefusalError < LlmError
      # @return [String] The refusal message from the LLM
      attr_reader :refusal_message

      # @return [Symbol] The category of refusal
      attr_reader :refusal_category

      # @param refusal_message [String] The refusal message from the LLM
      # @param refusal_category [Symbol, nil] The category of refusal
      # @param response [Hash, nil] The raw response from the LLM API
      # @param context [Hash, nil] Additional context about the error
      def initialize(refusal_message, refusal_category: nil, response: nil, context: nil)
        super("LLM refused to respond: #{refusal_message}", response: response, context: context)
        @refusal_message = refusal_message
        @refusal_category = refusal_category || determine_refusal_category(refusal_message)
      end

      # Determines whether this refusal is retryable with modifications
      # @return [Boolean] True if the refusal can be retried with modifications
      def retryable_with_modifications?
        [:unclear_instructions, :needs_clarification, :ambiguous_request, :format_error].include?(@refusal_category)
      end

      private

      # Determines the category of refusal from the message
      # @param message [String] The refusal message
      # @return [Symbol] The category of refusal
      def determine_refusal_category(message)
        message = message.to_s.downcase

        if message.include?("harmful") || message.include?("offensive") || message.include?("illegal")
          :harmful_content
        elsif message.include?("clarif") || message.include?("ambiguous")
          :needs_clarification
        elsif message.include?("format") || message.include?("structure")
          :format_error
        elsif message.include?("unclear") || message.include?("specific")
          :unclear_instructions
        elsif message.include?("capability") || message.include?("unable")
          :capability_limitation
        else
          :general_refusal
        end
      end
    end

    # Error raised when the LLM response cannot be parsed
    class LlmParseError < LlmError
      # @return [Exception] The original parsing exception
      attr_reader :parse_exception

      # @param message [String] The error message
      # @param parse_exception [Exception] The original parsing exception
      # @param response [Hash, nil] The raw response from the LLM API
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, parse_exception: nil, response: nil, context: nil)
        super(message, response: response, context: context)
        @parse_exception = parse_exception
      end
    end

    # Error raised when there's a connection or network issue
    class LlmNetworkError < LlmError
      # @return [Exception] The original network exception
      attr_reader :network_exception

      # @param message [String] The error message
      # @param network_exception [Exception] The original network exception
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, network_exception: nil, context: nil)
        super(message, context: context)
        @network_exception = network_exception
      end

      # @return [Boolean] Whether this error is retryable
      def retryable?
        true
      end
    end

    # Error raised when the API returns a rate limit error
    class LlmRateLimitError < LlmError
      # @return [Integer, nil] The number of seconds to wait before retrying
      attr_reader :retry_after

      # @param message [String] The error message
      # @param retry_after [Integer, nil] The number of seconds to wait before retrying
      # @param response [Hash, nil] The raw response from the LLM API
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, retry_after: nil, response: nil, context: nil)
        super(message, response: response, context: context)
        @retry_after = retry_after
      end

      # @return [Boolean] Whether this error is retryable
      def retryable?
        true
      end
    end

    # Error raised when the API returns an authentication error
    class LlmAuthenticationError < LlmError
      # @param message [String] The error message
      # @param response [Hash, nil] The raw response from the LLM API
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, response: nil, context: nil)
        super
      end

      # @return [Boolean] Whether this error is retryable
      def retryable?
        false
      end
    end

    # Error raised when the API returns a server error
    class LlmServerError < LlmError
      # @param message [String] The error message
      # @param response [Hash, nil] The raw response from the LLM API
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, response: nil, context: nil)
        super
      end

      # @return [Boolean] Whether this error is retryable
      def retryable?
        true
      end
    end

    # Error raised when the request to the LLM times out
    class LlmTimeoutError < LlmError
      # @param message [String] The error message
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, context: nil)
        super
      end

      # @return [Boolean] Whether this error is retryable
      def retryable?
        true
      end
    end

    # Error raised when an invalid request is made to the LLM API
    class LlmInvalidRequestError < LlmError
      # @param message [String] The error message
      # @param response [Hash, nil] The raw response from the LLM API
      # @param context [Hash, nil] Additional context about the error
      def initialize(message, response: nil, context: nil)
        super
      end

      # @return [Boolean] Whether this error is retryable
      def retryable?
        false
      end
    end
  end
end
