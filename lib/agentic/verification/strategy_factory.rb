# frozen_string_literal: true

module Agentic
  module Verification
    # Factory for creating verification strategies with consistent configuration
    # Provides a standardized interface for strategy instantiation across the codebase
    class StrategyFactory
      # Registry of available verification strategies
      STRATEGIES = {
        llm: LlmVerificationStrategy,
        schema: SchemaVerificationStrategy
      }.freeze

      class << self
        # Creates a verification strategy instance
        # @param type [Symbol, String] The type of strategy to create (:llm, :schema)
        # @param config [Hash] Configuration options for the strategy
        # @param dependencies [Hash] Required dependencies (e.g., llm_client for LLM strategy)
        # @return [VerificationStrategy] The created strategy instance
        # @raise [ArgumentError] If strategy type is unknown or required dependencies are missing
        def create(type, config: {}, **dependencies)
          strategy_type = type.to_sym
          strategy_class = STRATEGIES[strategy_type]

          unless strategy_class
            available = STRATEGIES.keys.join(", ")
            raise ArgumentError, "Unknown verification strategy type: #{type}. Available: #{available}"
          end

          # Validate and inject dependencies based on strategy type
          case strategy_type
          when :llm
            llm_client = dependencies[:llm_client]
            unless llm_client
              raise ArgumentError, "LLM verification strategy requires :llm_client dependency"
            end
            strategy_class.new(llm_client, config)
          when :schema
            strategy_class.new(config)
          else
            # Generic instantiation for future strategies
            strategy_class.new(config)
          end
        end

        # Creates multiple verification strategies from configuration
        # @param strategies_config [Array<Hash>] Array of strategy configurations
        # @param global_dependencies [Hash] Dependencies available to all strategies
        # @return [Array<VerificationStrategy>] Array of created strategy instances
        def create_multiple(strategies_config, global_dependencies = {})
          strategies_config.map do |strategy_config|
            type = strategy_config[:type] || strategy_config["type"]
            config = strategy_config[:config] || strategy_config["config"] || {}
            dependencies = strategy_config[:dependencies] || strategy_config["dependencies"] || {}

            # Merge global dependencies with strategy-specific dependencies
            merged_dependencies = global_dependencies.merge(dependencies)

            create(type, config: config, **merged_dependencies)
          end
        end

        # Returns available strategy types
        # @return [Array<Symbol>] Available strategy types
        def available_types
          STRATEGIES.keys
        end

        # Registers a new verification strategy type
        # @param type [Symbol] The strategy type identifier
        # @param strategy_class [Class] The strategy class (must inherit from VerificationStrategy)
        # @raise [ArgumentError] If strategy class doesn't inherit from VerificationStrategy
        def register(type, strategy_class)
          unless strategy_class.ancestors.include?(VerificationStrategy)
            raise ArgumentError, "Strategy class must inherit from VerificationStrategy"
          end

          STRATEGIES[type.to_sym] = strategy_class
        end

        # Creates a verification hub with strategies
        # @param strategies_config [Array<Hash>] Array of strategy configurations
        # @param hub_config [Hash] Configuration for the verification hub
        # @param global_dependencies [Hash] Dependencies available to all strategies
        # @return [VerificationHub] Configured verification hub
        def create_hub(strategies_config: [], hub_config: {}, **global_dependencies)
          strategies = create_multiple(strategies_config, global_dependencies)
          VerificationHub.new(strategies: strategies, config: hub_config)
        end
      end
    end
  end
end
