# frozen_string_literal: true

module Agentic
  module Configuration
    # Pre-defined schemas for core Agentic configuration objects
    module Schemas
      # LLM Configuration Schema
      LLM_CONFIG_SCHEMA = Schema.new("llm_config", version: "1.0.0").tap do |schema|
        schema.field(:model, type: :string, required: true,
          description: "The LLM model to use (e.g., 'gpt-4', 'gpt-3.5-turbo')",
          example: "gpt-4")

        schema.field(:temperature, type: :float, required: false, default: 0.7,
          constraints: [->(v) { v.between?(0.0, 2.0) }],
          description: "Controls randomness in responses (0.0 to 2.0)",
          example: 0.7)

        schema.field(:max_tokens, type: :integer, required: false, default: 1000,
          constraints: [->(v) { v > 0 && v <= 100000 }],
          description: "Maximum number of tokens in the response",
          example: 2000)

        schema.field(:top_p, type: :float, required: false, default: 1.0,
          constraints: [->(v) { v.between?(0.0, 1.0) }],
          description: "Nucleus sampling parameter",
          example: 0.9)

        schema.field(:frequency_penalty, type: :float, required: false, default: 0.0,
          constraints: [->(v) { v.between?(-2.0, 2.0) }],
          description: "Penalize repeated tokens",
          example: 0.1)

        schema.field(:presence_penalty, type: :float, required: false, default: 0.0,
          constraints: [->(v) { v.between?(-2.0, 2.0) }],
          description: "Penalize tokens that have appeared",
          example: 0.1)

        schema.field(:stop, type: :array, required: false,
          constraints: [->(v) { v.all? { |item| item.is_a?(String) } }],
          description: "Stop sequences for generation",
          example: ["\n", "END"])

        schema.field(:timeout, type: :integer, required: false, default: 120,
          constraints: [->(v) { v > 0 }],
          description: "Request timeout in seconds",
          example: 60)

        schema.validate("Temperature and top_p cannot both be modified from defaults") do |config|
          temperature_modified = (config[:temperature] - 0.7).abs > Float::EPSILON
          top_p_modified = (config[:top_p] - 1.0).abs > Float::EPSILON
          !(temperature_modified && top_p_modified)
        end
      end

      # Agent Configuration Schema
      AGENT_CONFIG_SCHEMA = Schema.new("agent_config", version: "1.0.0").tap do |schema|
        schema.field(:name, type: :string, required: true,
          description: "Unique name for the agent",
          example: "data_analyst")

        schema.field(:description, type: :string, required: false,
          description: "Human-readable description of the agent",
          example: "Analyzes datasets and generates reports")

        schema.field(:capabilities, type: :array, required: true,
          constraints: [->(v) { v.all? { |cap| cap.is_a?(String) } && v.any? }],
          description: "List of capability names this agent provides",
          example: ["data_analysis", "report_generation"])

        schema.field(:max_concurrent_tasks, type: :integer, required: false, default: 1,
          constraints: [->(v) { v > 0 }],
          description: "Maximum number of concurrent tasks",
          example: 3)

        schema.field(:timeout, type: :integer, required: false, default: 300,
          constraints: [->(v) { v > 0 }],
          description: "Task execution timeout in seconds",
          example: 600)

        schema.field(:retry_attempts, type: :integer, required: false, default: 3,
          constraints: [->(v) { v >= 0 }],
          description: "Number of retry attempts for failed tasks",
          example: 5)

        schema.field(:metadata, type: :hash, required: false, default: {},
          description: "Additional metadata for the agent",
          example: {domain: "finance", priority: "high"})

        schema.nested(:llm_config, LLM_CONFIG_SCHEMA, required: false)
      end

      # Task Configuration Schema
      TASK_CONFIG_SCHEMA = Schema.new("task_config", version: "1.0.0").tap do |schema|
        schema.field(:id, type: :string, required: false,
          description: "Unique identifier for the task (auto-generated if not provided)")

        schema.field(:description, type: :string, required: true,
          description: "Clear description of what the task should accomplish",
          example: "Analyze sales data and generate quarterly report")

        schema.field(:input, type: :any, required: false,
          description: "Input data or parameters for the task",
          example: {dataset: "sales_q4.csv", format: "pdf"})

        schema.field(:expected_output_format, type: :string, required: false,
          description: "Expected format of the task output",
          example: "json")

        schema.field(:deadline, type: :time, required: false,
          description: "Task completion deadline",
          example: Time.new(2024, 12, 31))

        schema.field(:priority, type: :symbol, required: false, default: :normal,
          constraints: [->(v) { [:low, :normal, :high, :critical].include?(v) }],
          description: "Task priority level",
          example: :high)

        schema.field(:tags, type: :array, required: false, default: [],
          constraints: [->(v) { v.all? { |tag| tag.is_a?(String) || tag.is_a?(Symbol) } }],
          description: "Tags for task categorization",
          example: ["analytics", "quarterly"])

        schema.field(:metadata, type: :hash, required: false, default: {},
          description: "Additional task metadata")

        schema.computed(:estimated_duration, dependencies: [:priority]) do |config, priority|
          case priority
          when :critical then 3600  # 1 hour
          when :high then 7200      # 2 hours
          when :normal then 14400   # 4 hours
          when :low then 28800      # 8 hours
          end
        end
      end

      # Observability Configuration Schema
      OBSERVABILITY_CONFIG_SCHEMA = Schema.new("observability_config", version: "1.0.0").tap do |schema|
        schema.field(:enable_advanced_dispatching, type: :boolean, required: false, default: false,
          description: "Enable advanced event dispatching with routing and filtering")

        schema.field(:max_buffer_size, type: :integer, required: false, default: 1000,
          constraints: [->(v) { v > 0 }],
          description: "Maximum size of event buffer")

        schema.field(:batch_size, type: :integer, required: false, default: 50,
          constraints: [->(v) { v > 0 && v <= 1000 }],
          description: "Number of events to process in a batch")

        schema.field(:batch_timeout, type: :float, required: false, default: 0.1,
          constraints: [->(v) { v > 0.0 }],
          description: "Timeout for batch processing in seconds")

        schema.field(:enable_priority_routing, type: :boolean, required: false, default: true,
          description: "Enable priority-based event routing")

        schema.field(:enable_correlation_filtering, type: :boolean, required: false, default: true,
          description: "Enable correlation context-based filtering")

        schema.field(:enable_performance_metrics, type: :boolean, required: false, default: true,
          description: "Enable performance metrics collection")

        schema.field(:enable_pipeline_integration, type: :boolean, required: false, default: true,
          description: "Enable EventPipeline integration")

        schema.field(:pipeline_config, type: :hash, required: false, default: {},
          description: "Configuration for EventPipeline")

        schema.validate("Batch size must be less than max buffer size") do |config|
          config[:batch_size] <= config[:max_buffer_size]
        end
      end

      # Security Configuration Schema
      SECURITY_CONFIG_SCHEMA = Schema.new("security_config", version: "1.0.0").tap do |schema|
        schema.field(:sanitization_level, type: :symbol, required: false, default: :standard,
          constraints: [->(v) { [:none, :basic, :standard, :strict, :paranoid].include?(v) }],
          description: "Level of PII sanitization")

        schema.field(:enable_pii_detection, type: :boolean, required: false, default: true,
          description: "Enable PII pattern detection")

        schema.field(:log_security_events, type: :boolean, required: false, default: false,
          description: "Log security-related events")

        schema.field(:custom_patterns, type: :hash, required: false, default: {},
          description: "Custom PII patterns for sanitization")

        schema.field(:custom_replacements, type: :hash, required: false, default: {},
          description: "Custom replacement text for PII patterns")

        schema.field(:performance_cache_enabled, type: :boolean, required: false, default: true,
          description: "Enable performance caching for sanitization")

        schema.field(:backtrace_sanitization, type: :boolean, required: false, default: true,
          description: "Enable sanitization of error backtraces")
      end

      # Verification Configuration Schema
      VERIFICATION_CONFIG_SCHEMA = Schema.new("verification_config", version: "1.0.0").tap do |schema|
        schema.field(:enabled_strategies, type: :array, required: false,
          default: [:schema, :llm],
          constraints: [->(v) { v.all? { |s| [:schema, :llm, :custom].include?(s) } }],
          description: "Enabled verification strategies")

        schema.field(:confidence_threshold, type: :float, required: false, default: 0.8,
          constraints: [->(v) { v.between?(0.0, 1.0) }],
          description: "Minimum confidence threshold for verification")

        schema.field(:max_retry_attempts, type: :integer, required: false, default: 3,
          constraints: [->(v) { v >= 0 }],
          description: "Maximum number of verification retry attempts")

        schema.field(:timeout, type: :integer, required: false, default: 60,
          constraints: [->(v) { v > 0 }],
          description: "Verification timeout in seconds")

        schema.field(:parallel_verification, type: :boolean, required: false, default: true,
          description: "Enable parallel verification strategies")

        schema.nested(:llm_config, LLM_CONFIG_SCHEMA, required: false)
      end

      # Main Agentic Configuration Schema
      AGENTIC_CONFIG_SCHEMA = Schema.new("agentic_config", version: "1.0.0").tap do |schema|
        schema.field(:access_token, type: :string, required: false,
          description: "API access token for LLM services")

        schema.field(:agent_store_path, type: :string, required: false,
          description: "Path to agent storage directory")

        schema.field(:api_base_url, type: :string, required: false,
          description: "Base URL for API services")

        schema.field(:log_level, type: :symbol, required: false, default: :info,
          constraints: [->(v) { [:debug, :info, :warn, :error, :fatal].include?(v) }],
          description: "Logging level")

        schema.field(:environment, type: :string, required: false, default: "development",
          constraints: [->(v) { %w[development test staging production].include?(v) }],
          description: "Application environment")

        schema.nested(:security, SECURITY_CONFIG_SCHEMA, required: false)
        schema.nested(:observability, OBSERVABILITY_CONFIG_SCHEMA, required: false)
        schema.nested(:verification, VERIFICATION_CONFIG_SCHEMA, required: false)
      end

      # Register all schemas with the registry
      def self.register_all!
        [
          LLM_CONFIG_SCHEMA,
          AGENT_CONFIG_SCHEMA,
          TASK_CONFIG_SCHEMA,
          OBSERVABILITY_CONFIG_SCHEMA,
          SECURITY_CONFIG_SCHEMA,
          VERIFICATION_CONFIG_SCHEMA,
          AGENTIC_CONFIG_SCHEMA
        ].each { |schema| SchemaRegistry.register(schema) }
      end
    end
  end
end
