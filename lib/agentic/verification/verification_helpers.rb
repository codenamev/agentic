# frozen_string_literal: true

module Agentic
  module Verification
    # Helper methods for setting up verification using standardized patterns
    module VerificationHelpers
      # Creates a verification hub with common configuration
      # @param config [Hash] Configuration for verification setup
      # @option config [Array<Hash>] :strategies Array of strategy configurations
      # @option config [Hash] :hub_config Configuration for the verification hub
      # @option config [Object] :llm_client LLM client for LLM verification strategy
      # @return [VerificationHub] Configured verification hub
      def self.create_verification_hub(config = {})
        strategies_config = config[:strategies] || default_strategies_config
        hub_config = config[:hub_config] || {}
        global_dependencies = extract_global_dependencies(config)

        StrategyFactory.create_hub(
          strategies_config: strategies_config,
          hub_config: hub_config,
          **global_dependencies
        )
      end

      # Creates a basic verification hub with schema validation only
      # @param config [Hash] Configuration options
      # @return [VerificationHub] Hub with schema verification
      def self.create_schema_verification_hub(config = {})
        strategies_config = [
          {
            type: :schema,
            config: config[:schema_config] || {}
          }
        ]

        StrategyFactory.create_hub(
          strategies_config: strategies_config,
          hub_config: config[:hub_config] || {}
        )
      end

      # Creates a verification hub with LLM verification
      # @param llm_client [LlmClient] LLM client for verification
      # @param config [Hash] Configuration options
      # @return [VerificationHub] Hub with LLM verification
      def self.create_llm_verification_hub(llm_client, config = {})
        strategies_config = [
          {
            type: :llm,
            config: config[:llm_config] || {}
          }
        ]

        StrategyFactory.create_hub(
          strategies_config: strategies_config,
          hub_config: config[:hub_config] || {},
          llm_client: llm_client
        )
      end

      # Creates a comprehensive verification hub with multiple strategies
      # @param llm_client [LlmClient] LLM client for verification
      # @param config [Hash] Configuration options
      # @return [VerificationHub] Hub with multiple verification strategies
      def self.create_comprehensive_verification_hub(llm_client, config = {})
        strategies_config = [
          {
            type: :schema,
            config: config[:schema_config] || {}
          },
          {
            type: :llm,
            config: config[:llm_config] || {}
          }
        ]

        StrategyFactory.create_hub(
          strategies_config: strategies_config,
          hub_config: config[:hub_config] || {min_confidence: 0.7},
          llm_client: llm_client
        )
      end

      def self.default_strategies_config
        [
          {
            type: :schema,
            config: {strict_mode: false}
          }
        ]
      end

      def self.extract_global_dependencies(config)
        dependencies = {}
        dependencies[:llm_client] = config[:llm_client] if config[:llm_client]
        dependencies
      end

      private_class_method :default_strategies_config, :extract_global_dependencies
    end

    # Convenience methods for common verification patterns
    module ConvenienceMethods
      # Quick setup for task verification
      # @param task [Task] Task to verify
      # @param result [TaskResult] Result to verify
      # @param verification_type [Symbol] Type of verification (:schema, :llm, :comprehensive)
      # @param llm_client [LlmClient, nil] LLM client if needed
      # @return [VerificationResult] Verification result
      def self.verify_task_result(task, result, verification_type: :schema, llm_client: nil)
        hub = case verification_type
        when :schema
          VerificationHelpers.create_schema_verification_hub
        when :llm
          raise ArgumentError, "LLM client required for LLM verification" unless llm_client
          VerificationHelpers.create_llm_verification_hub(llm_client)
        when :comprehensive
          raise ArgumentError, "LLM client required for comprehensive verification" unless llm_client
          VerificationHelpers.create_comprehensive_verification_hub(llm_client)
        else
          raise ArgumentError, "Unknown verification type: #{verification_type}"
        end

        hub.verify(task, result)
      end

      # Batch verify multiple task results
      # @param task_results [Array<Array>] Array of [task, result] pairs
      # @param verification_type [Symbol] Type of verification
      # @param llm_client [LlmClient, nil] LLM client if needed
      # @return [Array<VerificationResult>] Array of verification results
      def self.batch_verify(task_results, verification_type: :schema, llm_client: nil)
        hub = case verification_type
        when :schema
          VerificationHelpers.create_schema_verification_hub
        when :llm
          raise ArgumentError, "LLM client required for LLM verification" unless llm_client
          VerificationHelpers.create_llm_verification_hub(llm_client)
        when :comprehensive
          raise ArgumentError, "LLM client required for comprehensive verification" unless llm_client
          VerificationHelpers.create_comprehensive_verification_hub(llm_client)
        else
          raise ArgumentError, "Unknown verification type: #{verification_type}"
        end

        task_results.map do |task, result|
          hub.verify(task, result)
        end
      end
    end
  end
end
