# frozen_string_literal: true

module Agentic
  module Configuration
    # Central registry for managing configuration schemas
    #
    # Provides a centralized location to register, discover, and manage
    # configuration schemas for different components and plugins.
    class SchemaRegistry
      class << self
        # Register a schema with the registry
        # @param schema [Schema] The schema to register
        def register(schema)
          @schemas ||= {}
          @schemas[schema.name] = schema
        end

        # Get a schema by name
        # @param name [String, Symbol] The schema name
        # @return [Schema, nil] The schema or nil if not found
        def get(name)
          @schemas ||= {}
          @schemas[name.to_s]
        end

        # List all registered schema names
        # @return [Array<String>] Array of schema names
        def list
          @schemas ||= {}
          @schemas.keys
        end

        # Check if a schema is registered
        # @param name [String, Symbol] The schema name
        # @return [Boolean] True if schema exists
        def registered?(name)
          @schemas ||= {}
          @schemas.key?(name.to_s)
        end

        # Remove a schema from the registry
        # @param name [String, Symbol] The schema name
        def unregister(name)
          @schemas ||= {}
          @schemas.delete(name.to_s)
        end

        # Clear all schemas (primarily for testing)
        def clear!
          @schemas = {}
        end

        # Get documentation for all schemas
        # @return [Hash] Documentation for all registered schemas
        def documentation
          @schemas ||= {}
          @schemas.transform_values(&:documentation)
        end
      end
    end
  end
end
