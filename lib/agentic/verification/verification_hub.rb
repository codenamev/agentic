# frozen_string_literal: true

module Agentic
  module Verification
    # Coordinates verification strategies and manages the verification process
    class VerificationHub
      # Default configuration for verification hub
      DEFAULT_CONFIG = {
        fail_fast: false,
        min_confidence: 0.0,
        require_all_strategies: true
      }.freeze

      # @return [Array<VerificationStrategy>] The registered verification strategies
      attr_reader :strategies

      # @return [Hash] Configuration options for the verification hub
      attr_reader :config

      # Initializes a new VerificationHub
      # @param strategies [Array<VerificationStrategy>] The verification strategies to use
      # @param config [Hash] Configuration options for the verification hub
      def initialize(strategies: [], config: {})
        @strategies = strategies
        @config = DEFAULT_CONFIG.merge(config)
      end

      # Adds a verification strategy
      # @param strategy [VerificationStrategy] The strategy to add
      # @return [void]
      # @raise [ArgumentError] If strategy is not a VerificationStrategy
      def add_strategy(strategy)
        unless strategy.is_a?(VerificationStrategy)
          raise ArgumentError, "Strategy must be a VerificationStrategy instance"
        end
        @strategies << strategy
      end

      # Creates and adds a strategy using the factory
      # @param type [Symbol] The strategy type
      # @param config [Hash] Strategy configuration
      # @param dependencies [Hash] Strategy dependencies
      # @return [void]
      def add_strategy_from_factory(type, config: {}, **dependencies)
        strategy = StrategyFactory.create(type, config: config, **dependencies)
        add_strategy(strategy)
      end

      # Verifies a task result using the registered strategies
      # @param task [Task] The task to verify
      # @param result [TaskResult] The result to verify
      # @return [VerificationResult] The verification result
      def verify(task, result)
        return failed_task_result(task) if result.failed?
        return no_strategies_result(task) if @strategies.empty?

        begin
          apply_verification_strategies(task, result)
        rescue => e
          Agentic.logger.error("Verification hub error: #{e.message}")
          error_result(task, e)
        end
      end

      # Returns the number of registered strategies
      # @return [Integer] Number of strategies
      def strategy_count
        @strategies.size
      end

      # Clears all registered strategies
      # @return [void]
      def clear_strategies
        @strategies.clear
      end

      private

      def failed_task_result(task)
        VerificationResult.new(
          task_id: task.id,
          verified: false,
          confidence: 0.0,
          messages: ["Task failed, skipping verification"]
        )
      end

      def no_strategies_result(task)
        VerificationResult.new(
          task_id: task.id,
          verified: true,
          confidence: 1.0,
          messages: ["No verification strategies configured, passing by default"]
        )
      end

      def error_result(task, error)
        VerificationResult.new(
          task_id: task.id,
          verified: false,
          confidence: 0.0,
          messages: ["Verification hub error: #{error.message}"]
        )
      end

      def apply_verification_strategies(task, result)
        strategy_results = []
        failed_strategies = []

        @strategies.each do |strategy|
          strategy_result = strategy.verify(task, result)
          strategy_results << strategy_result

          # Fail fast if configured and strategy failed
          if config[:fail_fast] && !strategy_result.verified
            break
          end
        rescue => e
          Agentic.logger.warn("Strategy #{strategy.class.name} failed: #{e.message}")
          failed_strategies << strategy.class.name

          # Continue with other strategies unless require_all_strategies is true
          if config[:require_all_strategies]
            raise e
          end
        end

        combine_strategy_results(task, strategy_results, failed_strategies)
      end

      def combine_strategy_results(task, strategy_results, failed_strategies)
        return no_successful_strategies_result(task, failed_strategies) if strategy_results.empty?

        # Combine results
        verified = strategy_results.all?(&:verified)
        confidence = strategy_results.map(&:confidence).sum / strategy_results.size.to_f
        messages = strategy_results.flat_map(&:messages)

        # Add failed strategy messages if any
        unless failed_strategies.empty?
          messages << "Failed strategies: #{failed_strategies.join(", ")}"
        end

        # Check minimum confidence requirement
        if confidence < config[:min_confidence]
          verified = false
          messages << "Combined confidence below minimum threshold (#{confidence.round(2)} < #{config[:min_confidence]})"
        end

        VerificationResult.new(
          task_id: task.id,
          verified: verified,
          confidence: confidence,
          messages: messages
        )
      end

      def no_successful_strategies_result(task, failed_strategies)
        VerificationResult.new(
          task_id: task.id,
          verified: false,
          confidence: 0.0,
          messages: ["All verification strategies failed: #{failed_strategies.join(", ")}"]
        )
      end
    end
  end
end
