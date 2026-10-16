# frozen_string_literal: true

require_relative "config"

module Agentic
  module Security
    # Mixin that gives an error class sanitized accessors for logging.
    #
    # Sanitization is opt-in and explicit: an error that includes this mixin
    # keeps its ordinary #message, #to_s, and #inspect untouched, and exposes
    # #safe_message, #safe_context, #safe_response, #safe_backtrace,
    # #to_secure_hash, and #log_securely for any code path that writes the
    # error somewhere it could be read (loggers, journals, plan records).
    # Callers that log an error are responsible for picking the safe_* form;
    # nothing here rewrites the error behind their back.
    #
    # Design Goals:
    # 1. Non-intrusive enhancement of existing error classes
    # 2. Sanitized views of message, context, response, and backtrace
    # 3. Configurable sanitization levels via Security::Config
    # 4. Backward compatibility with existing error handling
    module SecureErrorMixin
      # Instance methods available to all classes that include this mixin

      # Get sanitized error message
      def safe_message
        @safe_message ||= if Agentic::Security::Config.pii_detection_enabled?
          Agentic::Security::Config.sanitizer.sanitize_error(message)
        else
          message
        end
      end

      # Get sanitized context (for errors that have context)
      def safe_context
        return nil unless respond_to?(:context)

        @safe_context ||= if Agentic::Security::Config.pii_detection_enabled? && context
          Agentic::Security::Config.sanitizer.sanitize(context, context: :error)
        else
          context
        end
      end

      # Get sanitized response (for errors that have response)
      def safe_response
        return nil unless respond_to?(:response)

        @safe_response ||= if Agentic::Security::Config.pii_detection_enabled? && response
          Agentic::Security::Config.sanitizer.sanitize_api_response(response)
        else
          response
        end
      end

      # Get sanitized backtrace
      def safe_backtrace
        return backtrace unless Agentic::Security::Config.backtrace_sanitization_enabled?

        @safe_backtrace ||= if backtrace
          Agentic::Security::Config.sanitizer.sanitize(backtrace, context: :backtrace)
        else
          backtrace
        end
      end

      # Convert to hash with sanitized data for logging
      def to_secure_hash
        hash = {
          class: self.class.name,
          message: safe_message,
          timestamp: Time.now.iso8601
        }

        # Add context if available
        if respond_to?(:context) && context
          hash[:context] = safe_context
        end

        # Add response if available
        if respond_to?(:response) && response
          hash[:response] = safe_response
        end

        # Add specific error attributes
        if respond_to?(:retry_after) && retry_after
          hash[:retry_after] = retry_after
        end

        if respond_to?(:retryable?)
          hash[:retryable] = retryable?
        end

        # Add sanitized backtrace if enabled
        if Agentic::Security::Config.backtrace_sanitization_enabled? && backtrace
          hash[:backtrace] = safe_backtrace&.first(10) # Limit backtrace length
        end

        hash
      end

      # Log error securely with appropriate sanitization
      def log_securely(logger = nil)
        logger ||= Agentic.logger
        return unless logger

        if Agentic::Security::Config.log_security_events?
          log_data = to_secure_hash

          logger.error("Secure Error Report: #{log_data[:class]}")
          logger.error("Message: #{log_data[:message]}")

          if log_data[:context]
            logger.debug("Context: #{log_data[:context]}")
          end

          if log_data[:backtrace]
            logger.debug("Backtrace: #{log_data[:backtrace].join('\n')}")
          end
        else
          # Minimal logging for production
          logger.error("#{self.class.name}: #{safe_message}")
        end
      end
    end
  end
end
