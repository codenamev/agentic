# frozen_string_literal: true

module Agentic
  # Security module providing comprehensive PII sanitization and secure error handling
  #
  # This module centralizes security-aware functionality including:
  # - PII detection and sanitization
  # - Security configuration management
  # - Secure error handling and logging
  # - Context-aware data filtering
  #
  # @example Basic usage
  #   # Configure security level
  #   Agentic::Security::Config.configure(sanitization_level: :strict)
  #
  #   # Use sanitizer directly
  #   sanitizer = Agentic::Security::Config.sanitizer
  #   safe_text = sanitizer.sanitize("user@example.com has key sk-123456")
  #
  # @example Error handling
  #   begin
  #     # Some operation that might fail
  #   rescue => error
  #     # Log securely if error supports it
  #     if error.respond_to?(:log_securely)
  #       error.log_securely
  #     else
  #       safe_message = Agentic::Security::Config.sanitizer.sanitize_error(error.message)
  #       logger.error(safe_message)
  #     end
  #   end
  module Security
    class << self
      # Quick access to current sanitizer
      # @return [Sanitizer] The currently configured sanitizer
      def sanitizer
        Config.sanitizer
      end

      # Quick sanitization method
      # @param content [String, Hash, Array] Content to sanitize
      # @param context [Symbol] Context type for sanitization
      # @return [String, Hash, Array] Sanitized content
      def sanitize(content, context: :default)
        sanitizer.sanitize(content, context: context)
      end

      # Quick error sanitization
      # @param error [Exception, String] Error to sanitize
      # @return [String] Sanitized error message
      def sanitize_error(error)
        sanitizer.sanitize_error(error)
      end

      # Quick check for sensitive content
      # @param content [String] Content to check
      # @return [Boolean] True if content appears sensitive
      def sensitive?(content)
        sanitizer.potentially_sensitive?(content)
      end

      # Initialize security with environment-appropriate settings
      # @param env [String] Environment name (development, staging, production)
      def initialize_for_environment(env = nil)
        Config.configure_for_environment(env)
      end

      # Get security status summary
      # @return [Hash] Current security configuration status
      def status
        Config.status
      end
    end
  end
end
