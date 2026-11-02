# frozen_string_literal: true

module Agentic
  module Observability
    # Factory for creating observability adapters
    # Provides consistent interface for adapter instantiation and configuration
    class AdapterFactory
      # Registry of available adapter types
      ADAPTER_TYPES = {
        console: ConsoleAdapter,
        file: FileAdapter
      }.freeze

      # Create an adapter of the specified type
      # @param type [Symbol, String] The adapter type
      # @param config [Hash] Configuration for the adapter
      # @return [BaseAdapter] The created adapter instance
      # @raise [ArgumentError] If adapter type is unknown
      def self.create(type, config = {})
        adapter_class = ADAPTER_TYPES[type.to_sym]
        raise ArgumentError, "Unknown adapter type: #{type}. Available: #{available_types.join(", ")}" unless adapter_class

        adapter_class.new(config)
      end

      # Get list of available adapter types
      # @return [Array<Symbol>] Available adapter types
      def self.available_types
        ADAPTER_TYPES.keys
      end

      # Register a new adapter type
      # @param type [Symbol] The adapter type name
      # @param adapter_class [Class] The adapter class
      # @raise [ArgumentError] If adapter_class doesn't inherit from BaseAdapter
      def self.register(type, adapter_class)
        unless adapter_class < BaseAdapter
          raise ArgumentError, "Adapter class must inherit from BaseAdapter"
        end

        ADAPTER_TYPES[type.to_sym] = adapter_class
      end

      # Check if an adapter type is registered
      # @param type [Symbol, String] The adapter type to check
      # @return [Boolean] True if adapter type is available
      def self.registered?(type)
        ADAPTER_TYPES.key?(type.to_sym)
      end

      # Create multiple adapters from configuration
      # @param config [Hash] Configuration hash with adapter definitions
      # @return [Array<BaseAdapter>] Array of created adapters
      #
      # Example config:
      # {
      #   console: { enabled: true, color: true },
      #   file: { enabled: true, log_path: "/tmp/events.jsonl" }
      # }
      def self.create_from_config(config)
        return [] unless config.is_a?(Hash)

        adapters = []
        config.each do |type, adapter_config|
          next unless registered?(type)

          begin
            adapter = create(type, adapter_config || {})
            adapters << adapter
          rescue => error
            if Agentic.logger
              Agentic.logger.warn("Failed to create #{type} adapter: #{error.message}")
            else
              warn "Failed to create #{type} adapter: #{error.message}"
            end
          end
        end

        adapters
      end

      # Get default configuration for CLI usage
      # @param options [Hash] Optional overrides
      # @return [Hash] Default adapter configuration
      def self.default_cli_config(options = {})
        {
          console: {
            enabled: !options[:quiet],
            color: options.fetch(:color, true),
            verbose: options.fetch(:verbose, false)
          },
          file: {
            enabled: options.fetch(:enable_file_logging, true),
            log_path: options[:log_path]
          }.compact
        }
      end

      # Validate adapter configuration
      # @param config [Hash] Configuration to validate
      # @return [Array<String>] Array of validation errors (empty if valid)
      def self.validate_config(config)
        errors = []
        return errors unless config.is_a?(Hash)

        config.each do |type, adapter_config|
          unless registered?(type)
            errors << "Unknown adapter type: #{type}"
            next
          end

          # Validate adapter-specific configuration
          case type.to_sym
          when :console
            validate_console_config(adapter_config, errors)
          when :file
            validate_file_config(adapter_config, errors)
          end
        end

        errors
      end

      private_class_method def self.validate_console_config(config, errors)
        return unless config.is_a?(Hash)

        if config[:output_stream] && !config[:output_stream].respond_to?(:puts)
          errors << "Console adapter output_stream must respond to :puts"
        end

        if config[:timestamp_format] && !config[:timestamp_format].is_a?(String)
          errors << "Console adapter timestamp_format must be a string"
        end
      end

      private_class_method def self.validate_file_config(config, errors)
        return unless config.is_a?(Hash)

        if config[:log_path] && !config[:log_path].is_a?(String)
          errors << "File adapter log_path must be a string"
        end

        if config[:max_file_size] && (!config[:max_file_size].is_a?(Integer) || config[:max_file_size] <= 0)
          errors << "File adapter max_file_size must be a positive integer"
        end

        if config[:max_files] && (!config[:max_files].is_a?(Integer) || config[:max_files] <= 0)
          errors << "File adapter max_files must be a positive integer"
        end
      end
    end
  end
end
