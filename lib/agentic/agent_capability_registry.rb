# frozen_string_literal: true

require "singleton"

module Agentic
  # Central registry for agent capabilities
  # @attr_reader [Hash] capabilities The registered capabilities by name and version
  # @attr_reader [Hash] providers The registered capability providers by name and version
  class AgentCapabilityRegistry
    include Singleton

    # Specification attributes #find accepts as bare criteria keys, beyond the
    # named comparators (min_version, has_input, ...). Mirrors
    # CapabilitySpecification#to_h.
    QUERYABLE_ATTRIBUTES = %i[name description version inputs outputs dependencies].freeze

    attr_reader :capabilities, :providers

    def initialize
      @capabilities = {}
      @providers = {}
      @capability_versions = {}
    end

    # Register a capability with the registry
    # @param capability [CapabilitySpecification] The capability to register
    # @param provider [CapabilityProvider] The provider of the capability
    # @return [CapabilitySpecification] The registered capability
    def register(capability, provider)
      validate_capability!(capability)

      # Store by name and version
      @capabilities[capability.name] ||= {}
      @capabilities[capability.name][capability.version] = capability

      # Track the provider
      @providers[capability.name] ||= {}
      @providers[capability.name][capability.version] = provider

      # Update version tracking
      update_version_tracking(capability)

      # Log the registration
      Agentic.logger.info("Registered capability: #{capability.name} v#{capability.version}")

      capability
    end

    # Get a capability by name and version
    # @param name [String] The name of the capability
    # @param version [String, nil] The version of the capability, or nil for latest
    # @return [CapabilitySpecification, nil] The capability or nil if not found
    def get(name, version = nil)
      return nil unless @capabilities[name]

      if version.nil?
        # Get the latest version
        version = get_latest_version(name)
        return nil unless version
      end

      @capabilities[name][version]
    end

    # Get the provider for a capability
    # @param name [String] The name of the capability
    # @param version [String, nil] The version of the capability, or nil for latest
    # @return [CapabilityProvider, nil] The provider or nil if not found
    def get_provider(name, version = nil)
      return nil unless @providers[name]

      if version.nil?
        # Get the latest version
        version = get_latest_version(name)
        return nil unless version
      end

      @providers[name][version]
    end

    # Find capabilities matching criteria
    # @param criteria [Hash] The search criteria
    # @return [Array<CapabilitySpecification>] Matching capabilities
    def find(criteria = {})
      # Filter capabilities based on criteria
      results = []

      @capabilities.each do |name, versions|
        versions.each do |version, capability|
          if matches_criteria?(capability, criteria)
            results << capability
          end
        end
      end

      results
    end

    # List all registered capabilities
    # @param include_providers [Boolean] Whether to include providers in the output
    # @return [Hash] Map of capability names to arrays of version strings
    def list(include_providers: false)
      result = {}

      @capabilities.each do |name, versions|
        result[name] = {
          versions: versions.keys,
          latest: get_latest_version(name)
        }

        if include_providers
          result[name][:providers] = {}
          versions.each do |version, _|
            result[name][:providers][version] = @providers[name][version] if @providers[name][version]
          end
        end
      end

      result
    end

    # Compose capabilities into a new capability
    #
    # The composition may declare its own inputs/outputs contract; when it
    # does, the composed capability is validated at its boundary exactly
    # like a primitive one.
    #
    # @param name [String] The name of the composed capability
    # @param description [String] Description of the composed capability
    # @param version [String] The version of the composed capability
    # @param capabilities [Array<Hash>] The capabilities to compose
    # @param compose_fn [Proc] The function to use for composition
    # @param inputs [Hash] Optional declared inputs for the composition as a whole
    # @param outputs [Hash] Optional declared outputs for the composition as a whole
    # @return [CapabilitySpecification] The composed capability
    def compose(name, description, version, capabilities, compose_fn, inputs: {}, outputs: {})
      # Get the individual capabilities
      capability_instances = []
      capability_providers = []

      capabilities.each do |cap_spec|
        cap_name = cap_spec[:name]
        cap_version = cap_spec[:version]

        capability = get(cap_name, cap_version)
        raise "Capability not found: #{cap_name} v#{cap_version}" unless capability

        provider = get_provider(cap_name, cap_version)
        raise "Provider not found for capability: #{cap_name} v#{cap_version}" unless provider

        capability_instances << capability
        capability_providers << provider
      end

      # Create the composed capability
      dependencies = capabilities.map do |cap_spec|
        {
          name: cap_spec[:name],
          version: cap_spec[:version] || get_latest_version(cap_spec[:name])
        }
      end

      composed_capability = CapabilitySpecification.new(
        name: name,
        description: description,
        version: version,
        inputs: inputs,
        outputs: outputs,
        dependencies: dependencies
      )

      # Create the composed provider
      composed_provider = CapabilityProvider.new(
        capability: composed_capability,
        implementation: lambda do |inputs|
          # Call the composition function with the individual providers and inputs
          compose_fn.call(capability_providers, inputs)
        end
      )

      # Register the composed capability
      register(composed_capability, composed_provider)
    end

    # Clear all registered capabilities
    # @return [void]
    def clear
      @capabilities = {}
      @providers = {}
      @capability_versions = {}
    end

    private

    def validate_capability!(capability)
      # Validate the capability specification
      raise "Capability must be a CapabilitySpecification" unless capability.is_a?(CapabilitySpecification)
      raise "Capability name cannot be empty" if capability.name.nil? || capability.name.empty?
      raise "Capability version cannot be empty" if capability.version.nil? || capability.version.empty?
    end

    def update_version_tracking(capability)
      # Update version tracking for the capability
      @capability_versions[capability.name] ||= []
      @capability_versions[capability.name] << capability.version
      @capability_versions[capability.name].uniq!
    end

    def get_latest_version(name)
      # Get the latest version of a capability
      return nil unless @capability_versions[name] && !@capability_versions[name].empty?

      # Sort versions semantically
      # For now, just sort by splitting into parts and comparing numerically
      @capability_versions[name].max do |a, b|
        a_parts = a.split(".").map(&:to_i)
        b_parts = b.split(".").map(&:to_i)

        # Compare major version
        major_comparison = a_parts[0] <=> b_parts[0]
        next major_comparison unless major_comparison == 0

        # Compare minor version
        minor_comparison = a_parts[1] <=> b_parts[1]
        next minor_comparison unless minor_comparison == 0

        # Compare patch version
        a_parts[2] <=> b_parts[2]
      end
    end

    def matches_criteria?(capability, criteria)
      # Check if a capability matches the given criteria
      criteria.all? do |key, value|
        case key
        when :name, "name"
          capability.name == value
        when :version, "version"
          capability.version == value
        when :min_version, "min_version"
          compare_versions(capability.version, value) >= 0
        when :max_version, "max_version"
          compare_versions(capability.version, value) <= 0
        when :has_input, "has_input"
          capability.inputs.key?(value.to_sym) || capability.inputs.key?(value.to_s)
        when :has_output, "has_output"
          capability.outputs.key?(value.to_sym) || capability.outputs.key?(value.to_s)
        when :has_dependency, "has_dependency"
          capability.dependencies.any? { |dep| dep[:name] == value || dep["name"] == value }
        else
          # Any other key must name one of the specification's data attributes.
          # Criteria can arrive from a filter hash an LLM helped build, so an
          # unknown key means "no match", never an open method call.
          QUERYABLE_ATTRIBUTES.include?(key.to_sym) && capability.public_send(key) == value
        end
      end
    end

    def compare_versions(version_a, version_b)
      # Compare two version strings
      a_parts = version_a.split(".").map(&:to_i)
      b_parts = version_b.split(".").map(&:to_i)

      # Compare major version
      major_comparison = a_parts[0] <=> b_parts[0]
      return major_comparison unless major_comparison == 0

      # Compare minor version
      minor_comparison = a_parts[1] <=> b_parts[1]
      return minor_comparison unless minor_comparison == 0

      # Compare patch version
      a_parts[2] <=> b_parts[2]
    end
  end
end
