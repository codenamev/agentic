# frozen_string_literal: true

module Agentic
  module Configuration
    # Configuration builder with fluent interface and validation
    #
    # Provides a convenient way to build, validate, and manage configurations
    # using the schema system with a fluent, Ruby-idiomatic API.
    class Builder
      attr_reader :schema, :data

      def initialize(schema_name_or_schema)
        @schema = case schema_name_or_schema
        when String, Symbol
          SchemaRegistry.get(schema_name_or_schema.to_s) ||
            raise(ArgumentError, "Unknown schema: #{schema_name_or_schema}")
        when Schema
          schema_name_or_schema
        else
          raise ArgumentError, "Expected schema name or Schema object"
        end

        @data = {}
      end

      # Set a configuration value
      # @param key [Symbol, String] Configuration key
      # @param value [Object] Configuration value
      # @return [Builder] Self for chaining
      def set(key, value)
        @data[key.to_sym] = value
        self
      end

      # Set multiple configuration values
      # @param hash [Hash] Configuration key-value pairs
      # @return [Builder] Self for chaining
      def merge(hash)
        hash.each { |key, value| set(key, value) }
        self
      end

      # Get a configuration value
      # @param key [Symbol, String] Configuration key
      # @return [Object] Configuration value
      def get(key)
        @data[key.to_sym]
      end

      # Check if a key is set
      # @param key [Symbol, String] Configuration key
      # @return [Boolean] True if key exists
      def key?(key)
        @data.key?(key.to_sym)
      end

      # Remove a configuration value
      # @param key [Symbol, String] Configuration key
      # @return [Builder] Self for chaining
      def unset(key)
        @data.delete(key.to_sym)
        self
      end

      # Build and validate the configuration
      # @param strict [Boolean] Whether to reject unknown fields
      # @return [ConfigurationInstance] Validated configuration instance
      def build(strict: false)
        @schema.create(@data, strict: strict)
      end

      # Check if current configuration is valid
      # @param strict [Boolean] Whether to reject unknown fields
      # @return [Boolean] True if valid
      def valid?(strict: false)
        @schema.create(@data, strict: strict)
        true
      rescue Schema::ValidationError
        false
      end

      # Get validation errors without raising
      # @param strict [Boolean] Whether to reject unknown fields
      # @return [Array<String>] Array of error messages, empty if valid
      def validation_errors(strict: false)
        @schema.create(@data, strict: strict)
        []
      rescue Schema::ValidationError => e
        [e.message]
      end

      # Create a nested builder for a nested schema field
      # @param field_name [Symbol, String] Name of the nested field
      # @return [Builder] Builder for the nested schema
      def nested(field_name)
        field_name = field_name.to_sym
        nested_spec = @schema.instance_variable_get(:@nested_schemas)[field_name]

        unless nested_spec
          raise ArgumentError, "No nested schema found for field: #{field_name}"
        end

        nested_builder = Builder.new(nested_spec[:schema])

        # If we already have data for this field, populate the nested builder
        if @data.key?(field_name)
          existing_data = @data[field_name]
          if existing_data.is_a?(Hash)
            nested_builder.merge(existing_data)
          end
        end

        nested_builder
      end

      # Set a nested configuration using a builder block
      # @param field_name [Symbol, String] Name of the nested field
      # @param block [Proc] Block to configure the nested builder
      # @return [Builder] Self for chaining
      def configure_nested(field_name, &block)
        nested_builder = nested(field_name)
        block&.call(nested_builder)
        set(field_name, nested_builder.data)
        self
      end

      # Convert current data to hash
      # @return [Hash] Current configuration data
      def to_h
        @data.dup
      end

      # Pretty print the configuration
      # @return [String] Formatted configuration
      def inspect
        "#<#{self.class.name} schema=#{@schema.name} data=#{@data.inspect}>"
      end

      # Fluent interface methods for common configuration patterns

      # LLM Configuration methods
      class << self
        # Create builder for LLM configuration
        # @return [Builder] LLM configuration builder
        def llm_config
          new(Schemas::LLM_CONFIG_SCHEMA)
        end

        # Create builder for agent configuration
        # @return [Builder] Agent configuration builder
        def agent_config
          new(Schemas::AGENT_CONFIG_SCHEMA)
        end

        # Create builder for task configuration
        # @return [Builder] Task configuration builder
        def task_config
          new(Schemas::TASK_CONFIG_SCHEMA)
        end

        # Create builder for observability configuration
        # @return [Builder] Observability configuration builder
        def observability_config
          new(Schemas::OBSERVABILITY_CONFIG_SCHEMA)
        end

        # Create builder for security configuration
        # @return [Builder] Security configuration builder
        def security_config
          new(Schemas::SECURITY_CONFIG_SCHEMA)
        end

        # Create builder for verification configuration
        # @return [Builder] Verification configuration builder
        def verification_config
          new(Schemas::VERIFICATION_CONFIG_SCHEMA)
        end

        # Create builder for main Agentic configuration
        # @return [Builder] Main Agentic configuration builder
        def agentic_config
          new(Schemas::AGENTIC_CONFIG_SCHEMA)
        end
      end

      # Convenience methods for LLM config
      def model(name)
        set(:model, name)
      end

      def temperature(value)
        set(:temperature, value)
      end

      def max_tokens(value)
        set(:max_tokens, value)
      end

      def timeout(seconds)
        set(:timeout, seconds)
      end

      # Convenience methods for Agent config
      def name(agent_name)
        set(:name, agent_name)
      end

      def description(desc)
        set(:description, desc)
      end

      def capabilities(*caps)
        set(:capabilities, caps.flatten)
      end

      def metadata(meta)
        set(:metadata, meta)
      end

      # Convenience methods for Task config
      def task_description(desc)
        set(:description, desc)
      end

      def input(data)
        set(:input, data)
      end

      def priority(level)
        set(:priority, level)
      end

      def tags(*tag_list)
        set(:tags, tag_list.flatten)
      end

      def deadline(time)
        set(:deadline, time)
      end

      # Convenience methods for Security config
      def sanitization_level(level)
        set(:sanitization_level, level)
      end

      def enable_pii_detection(enabled = true)
        set(:enable_pii_detection, enabled)
      end

      def log_security_events(enabled = true)
        set(:log_security_events, enabled)
      end

      # Convenience methods for Observability config
      def enable_advanced_dispatching(enabled = true)
        set(:enable_advanced_dispatching, enabled)
      end

      def batch_size(size)
        set(:batch_size, size)
      end

      def enable_performance_metrics(enabled = true)
        set(:enable_performance_metrics, enabled)
      end
    end
  end
end
