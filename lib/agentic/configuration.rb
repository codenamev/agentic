# frozen_string_literal: true

module Agentic
  # Unified configuration system with schema validation and type checking
  #
  # Provides a comprehensive configuration management system with:
  # - Type-safe schema validation
  # - Fluent builder interface
  # - Extensible plugin support
  # - Migration and versioning capabilities
  # - Performance-optimized validation
  #
  # @example Basic usage
  #   # Define a custom schema
  #   schema = Agentic::Configuration::Schema.new('my_service').tap do |s|
  #     s.field(:api_key, type: :string, required: true)
  #     s.field(:timeout, type: :integer, default: 30)
  #   end
  #
  #   # Register the schema
  #   Agentic::Configuration::SchemaRegistry.register(schema)
  #
  #   # Build configuration
  #   config = Agentic::Configuration::Builder.new('my_service')
  #     .set(:api_key, 'secret-key')
  #     .build
  #
  # @example Using predefined schemas
  #   llm_config = Agentic::Configuration::Builder.llm_config
  #     .model('gpt-4')
  #     .temperature(0.8)
  #     .max_tokens(2000)
  #     .build
  #
  #   agent_config = Agentic::Configuration::Builder.agent_config
  #     .name('data_analyst')
  #     .capabilities('analysis', 'visualization')
  #     .configure_nested(:llm_config) { |llm| llm.model('gpt-4') }
  #     .build
  module Configuration
    class << self
      # Initialize the configuration system
      def initialize!
        Schemas.register_all!
        @initialized = true
      end

      # Check if configuration system is initialized
      # @return [Boolean] True if initialized
      def initialized?
        @initialized ||= false
      end

      # Get a schema by name
      # @param name [String, Symbol] Schema name
      # @return [Schema, nil] The schema or nil if not found
      def schema(name)
        initialize! unless initialized?
        SchemaRegistry.get(name)
      end

      # Create a builder for a schema
      # @param schema_name [String, Symbol] Schema name
      # @return [Builder] Configuration builder
      def builder(schema_name)
        initialize! unless initialized?
        Builder.new(schema_name)
      end

      # Validate configuration against a schema
      # @param schema_name [String, Symbol] Schema name
      # @param config [Hash] Configuration to validate
      # @param strict [Boolean] Whether to reject unknown fields
      # @return [Boolean] True if valid
      def valid?(schema_name, config, strict: false)
        schema = self.schema(schema_name)
        return false unless schema

        schema.valid?(config, strict: strict)
      end

      # Validate and create configuration instance
      # @param schema_name [String, Symbol] Schema name
      # @param config [Hash] Configuration data
      # @param strict [Boolean] Whether to reject unknown fields
      # @return [ConfigurationInstance] Validated configuration
      def create(schema_name, config = {}, strict: false)
        schema = self.schema(schema_name)
        raise ArgumentError, "Unknown schema: #{schema_name}" unless schema

        schema.create(config, strict)
      end

      # Get documentation for all or specific schema
      # @param schema_name [String, Symbol, nil] Optional schema name
      # @return [Hash] Schema documentation
      def documentation(schema_name = nil)
        initialize! unless initialized?

        if schema_name
          schema = self.schema(schema_name)
          schema&.documentation
        else
          SchemaRegistry.documentation
        end
      end

      # Register a custom schema
      # @param schema [Schema] Schema to register
      def register_schema(schema)
        initialize! unless initialized?
        SchemaRegistry.register(schema)
      end

      # List all registered schemas
      # @return [Array<String>] Schema names
      def list_schemas
        initialize! unless initialized?
        SchemaRegistry.list
      end

      # Create configurations from environment variables
      # @param prefix [String] Environment variable prefix
      # @return [Hash] Configurations by schema name
      def from_env(prefix = "AGENTIC")
        initialize! unless initialized?

        configs = {}
        env_vars = ENV.select { |key, _| key.start_with?(prefix) }

        env_vars.each do |key, value|
          # Parse environment variables like AGENTIC_LLM_CONFIG_MODEL=gpt-4
          parts = key.split("_")
          next if parts.length < 3

          schema_name = parts[1...-1].join("_").downcase
          field_name = parts.last.downcase.to_sym

          configs[schema_name] ||= {}
          configs[schema_name][field_name] = parse_env_value(value)
        end

        # Create configuration instances
        configs.transform_values do |config_data|
          schema_name = config_data.first.first # Get schema name from first key
          begin
            create(schema_name, config_data)
          rescue
            config_data
          end
        end
      end

      # Migration support for configuration evolution
      # @param old_config [Hash] Old configuration format
      # @param from_version [String] Source version
      # @param to_version [String] Target version
      # @return [Hash] Migrated configuration
      def migrate(old_config, from_version:, to_version:)
        # Placeholder for migration logic
        # In a real implementation, this would:
        # 1. Look up migration rules for version transition
        # 2. Apply transformations to convert old format to new
        # 3. Validate against new schema

        case "#{from_version}_to_#{to_version}"
        when "1.0.0_to_2.0.0"
          # Example migration: rename 'max_length' to 'max_tokens'
          migrated = old_config.dup
          if migrated.key?(:max_length)
            migrated[:max_tokens] = migrated.delete(:max_length)
          end
          migrated
        else
          old_config # No migration rules available
        end
      end

      # Performance optimization: precompile schemas for faster validation
      def precompile_schemas!
        initialize! unless initialized?

        SchemaRegistry.list.each do |schema_name|
          schema = SchemaRegistry.get(schema_name)
          next unless schema

          # Pre-validate against an empty configuration to compile validators
          begin
            schema.valid?({})
          rescue Schema::ValidationError
            # Expected for schemas with required fields
          end
        end
      end

      private

      # Parse environment variable values with type inference
      def parse_env_value(value)
        case value.downcase
        when "true", "yes", "1"
          true
        when "false", "no", "0"
          false
        when /^\d+$/
          value.to_i
        when /^\d+\.\d+$/
          value.to_f
        when /^\[.*\]$/ # Simple array parsing
          value[1...-1].split(",").map(&:strip)
        else
          value
        end
      end
    end

    # Convenience methods for common configuration patterns
    module Convenience
      # Quick LLM configuration
      def self.llm(model:, **options)
        Agentic::Configuration.builder("llm_config")
          .model(model)
          .merge(options)
          .build
      end

      # Quick agent configuration
      def self.agent(name:, capabilities:, **options)
        builder = Agentic::Configuration.builder("agent_config")
          .name(name)
          .capabilities(*capabilities)
          .merge(options)

        if options[:llm_model]
          builder.configure_nested(:llm_config) do |llm|
            llm.model(options[:llm_model])
          end
        end

        builder.build
      end

      # Quick task configuration
      def self.task(description:, **options)
        Agentic::Configuration.builder("task_config")
          .task_description(description)
          .merge(options)
          .build
      end

      # Security configuration for environment
      def self.security_for_env(env = "development")
        level = case env.to_s
        when "development", "test" then :basic
        when "staging" then :standard
        when "production" then :strict
        else :standard
        end

        Agentic::Configuration.builder("security_config")
          .sanitization_level(level)
          .enable_pii_detection(env != "development")
          .log_security_events(env != "production")
          .build
      end
    end
  end
end
