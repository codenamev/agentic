# frozen_string_literal: true

module Agentic
  module Verification
    # Result of artifact verification
    #
    # @attr_reader [Boolean] passed Whether verification passed
    # @attr_reader [String] message Verification message (success or failure details)
    # @attr_reader [Hash] details Additional verification details
    class ArtifactVerificationResult
      attr_reader :passed, :message, :details

      def initialize(passed:, message:, details: {})
        @passed = passed
        @message = message
        @details = details
      end

      # Check if verification passed
      # @return [Boolean] True if verification passed
      def passed?
        @passed
      end

      # Check if verification failed
      # @return [Boolean] True if verification failed
      def failed?
        !@passed
      end
    end

    # Base strategy for artifact verification
    #
    # Provides foundation for quality assurance of generated artifacts.
    # Subclasses implement language-specific verification logic.
    #
    # @example Verifying an artifact
    #   strategy = ArtifactVerificationStrategy.for_type(:ruby_class)
    #   result = strategy.verify(artifact)
    #   if result.passed?
    #     puts "Artifact verified successfully"
    #   else
    #     puts "Verification failed: #{result.message}"
    #   end
    class ArtifactVerificationStrategy
      # File extensions that select a language-specific strategy. Anything
      # else falls through to BasicArtifactVerificationStrategy.
      EXTENSION_TYPES = {
        ".rb" => :ruby_class,
        ".js" => :javascript_module,
        ".py" => :python_module
      }.freeze

      # Pick the verification strategy for an artifact from its file extension.
      #
      # `artifact.type` is declared by the model that produced the artifact, so
      # trusting it lets a generated `.rb` file labelled `:markdown` skip the Ruby
      # checks. The extension is what the workspace actually writes to disk, so it
      # is what verification keys off. A mismatch between the two is logged.
      #
      # @param artifact [Artifact] The artifact to verify
      # @return [ArtifactVerificationStrategy] Strategy for the artifact's extension
      #
      # @example
      #   strategy = ArtifactVerificationStrategy.for_artifact(artifact)
      #   result = strategy.verify(artifact)
      def self.for_artifact(artifact)
        ext = File.extname(artifact.name.to_s).downcase
        derived_type = EXTENSION_TYPES[ext]

        if derived_type != artifact.type && (derived_type || EXTENSION_TYPES.value?(artifact.type))
          Agentic.logger.warn(
            "Artifact #{artifact.name} declares type #{artifact.type.inspect} but extension " \
            "#{ext.inspect} maps to #{derived_type.inspect}; verifying by extension"
          )
        end

        for_type(derived_type)
      end

      # Factory method to get verification strategy for a declared artifact type.
      # Prefer {.for_artifact} when you have the artifact: it keys off the file
      # extension rather than the model-declared type.
      def self.for_type(artifact_type)
        case artifact_type
        when :ruby_class
          RubyArtifactVerificationStrategy.new
        when :javascript_module
          JavaScriptArtifactVerificationStrategy.new
        when :python_module
          PythonArtifactVerificationStrategy.new
        else
          BasicArtifactVerificationStrategy.new
        end
      end

      # Verify an artifact
      #
      # @param artifact [Artifact] The artifact to verify
      # @return [ArtifactVerificationResult] The verification result
      def verify(artifact)
        ArtifactVerificationResult.new(
          passed: true,
          message: "No verification implemented for base strategy",
          details: {}
        )
      end
    end

    # Basic verification strategy for unknown artifact types
    #
    # Performs minimal checks:
    # - Content is not empty
    # - Content has valid encoding (UTF-8)
    class BasicArtifactVerificationStrategy < ArtifactVerificationStrategy
      def verify(artifact)
        # Check content is not empty
        if artifact.content.nil? || artifact.content.empty?
          return ArtifactVerificationResult.new(
            passed: false,
            message: "Artifact content is empty",
            details: {artifact_name: artifact.name}
          )
        end

        # Check valid encoding
        unless artifact.content.valid_encoding?
          return ArtifactVerificationResult.new(
            passed: false,
            message: "Artifact content has invalid encoding",
            details: {
              artifact_name: artifact.name,
              encoding: artifact.content.encoding.name
            }
          )
        end

        ArtifactVerificationResult.new(
          passed: true,
          message: "Basic verification passed",
          details: {
            artifact_name: artifact.name,
            size: artifact.content.bytesize
          }
        )
      end
    end

    # Ruby-specific verification strategy
    #
    # Extension point for Ruby-specific validation. Currently performs basic checks
    # (content + encoding). Users can subclass to add custom verification:
    # - Syntax checking (ruby -c)
    # - Linting (RuboCop)
    # - Dependency checking
    class RubyArtifactVerificationStrategy < BasicArtifactVerificationStrategy
      def verify(artifact)
        # Run basic verification first
        basic_result = super
        return basic_result unless basic_result.passed?

        # Override this method to add Ruby-specific checks
        ArtifactVerificationResult.new(
          passed: true,
          message: "Ruby artifact verification passed (basic checks only)",
          details: basic_result.details.merge(
            type: :ruby_class,
            verification_level: :basic
          )
        )
      end
    end

    # JavaScript-specific verification strategy
    #
    # Extension point for JavaScript-specific validation. Currently performs basic checks
    # (content + encoding). Users can subclass to add custom verification:
    # - Syntax checking (ESLint)
    # - Module resolution
    # - TypeScript type checking
    class JavaScriptArtifactVerificationStrategy < BasicArtifactVerificationStrategy
      def verify(artifact)
        # Run basic verification first
        basic_result = super
        return basic_result unless basic_result.passed?

        # Override this method to add JavaScript-specific checks
        ArtifactVerificationResult.new(
          passed: true,
          message: "JavaScript artifact verification passed (basic checks only)",
          details: basic_result.details.merge(
            type: :javascript_module,
            verification_level: :basic
          )
        )
      end
    end

    # Python-specific verification strategy
    #
    # Extension point for Python-specific validation. Currently performs basic checks
    # (content + encoding). Users can subclass to add custom verification:
    # - Syntax checking (python -m py_compile)
    # - Linting (pylint, flake8)
    # - Type checking (mypy)
    class PythonArtifactVerificationStrategy < BasicArtifactVerificationStrategy
      def verify(artifact)
        # Run basic verification first
        basic_result = super
        return basic_result unless basic_result.passed?

        # Override this method to add Python-specific checks
        ArtifactVerificationResult.new(
          passed: true,
          message: "Python artifact verification passed (basic checks only)",
          details: basic_result.details.merge(
            type: :python_module,
            verification_level: :basic
          )
        )
      end
    end

    # Error raised when artifact verification fails
    class ArtifactVerificationError < StandardError
      attr_reader :verification_result

      def initialize(message, verification_result = nil)
        super(message)
        @verification_result = verification_result
      end
    end
  end
end
