# frozen_string_literal: true

module Agentic
  module Security
    # Mixin to add security-aware error handling to existing error classes
    #
    # Provides sanitization capabilities for error messages, contexts, and responses
    # without breaking existing error class hierarchies.
    #
    # Design Goals:
    # 1. Non-intrusive enhancement of existing error classes
    # 2. Automatic sanitization of sensitive data in error messages
    # 3. Configurable sanitization levels
    # 4. Backward compatibility with existing error handling
    module SecureErrorMixin
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Wrap existing error class methods to add sanitization
        def secure_error_class!
          # Override initialize if it exists
          if instance_method(:initialize)
            alias_method :original_initialize, :initialize

            define_method(:initialize) do |*args, **kwargs|
              # Call original initialize first
              original_initialize(*args, **kwargs)

              # Apply sanitization to instance variables
              apply_security_sanitization
            end
          end

          # Override message method for sanitized output
          alias_method :original_message, :message if instance_method(:message)

          define_method(:message) do
            if Agentic::Security::Config.pii_detection_enabled?
              @sanitized_message ||= Agentic::Security::Config.sanitizer.sanitize_error(original_message)
            else
              original_message
            end
          end

          # Override to_s for sanitized output
          alias_method :original_to_s, :to_s if instance_method(:to_s)

          define_method(:to_s) do
            message # Use sanitized message method
          end

          # Add inspect method for debugging
          define_method(:inspect) do
            sanitized_attrs = {}

            instance_variables.each do |var|
              value = instance_variable_get(var)

              sanitized_attrs[var] = case var.to_s
              when "@response", "@context", "@network_exception"
                # Sanitize complex objects
                Agentic::Security::Config.sanitizer.sanitize(value, context: :error)
              else
                # Basic sanitization for simple values
                Agentic::Security::Config.sanitizer.sanitize_error(value.to_s)
              end
            end

            "#<#{self.class.name}:#{object_id} #{sanitized_attrs}>"
          end
        end
      end

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

      private

      # Apply sanitization to instance variables after initialization
      def apply_security_sanitization
        return unless Agentic::Security::Config.pii_detection_enabled?

        # Sanitize message if it's directly stored
        if instance_variable_defined?(:@message)
          original_message = instance_variable_get(:@message)
          sanitized_message = Agentic::Security::Config.sanitizer.sanitize_error(original_message)
          instance_variable_set(:@message, sanitized_message)
        end

        # Sanitize context if present
        if instance_variable_defined?(:@context) && @context
          @context = Agentic::Security::Config.sanitizer.sanitize(@context, context: :error)
        end

        # Sanitize response if present
        if instance_variable_defined?(:@response) && @response
          @response = Agentic::Security::Config.sanitizer.sanitize_api_response(@response)
        end

        # Clear cached sanitized values to force recomputation
        @sanitized_message = nil
        @safe_message = nil
        @safe_context = nil
        @safe_response = nil
        @safe_backtrace = nil
      end
    end
  end
end
