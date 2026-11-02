# frozen_string_literal: true

module Agentic
  module Capabilities
    # Register the file_generation capability with the registry
    #
    # This file is automatically loaded by the gem initializer to register
    # the file_generation capability, making it available to all agents.
    module RegisterFileGeneration
      def self.register
        spec_data = FileGenerationCapability.specification

        # Create capability specification
        capability_spec = CapabilitySpecification.new(
          name: spec_data[:name],
          description: spec_data[:description],
          version: spec_data[:version],
          inputs: spec_data[:inputs],
          outputs: spec_data[:outputs]
        )

        # Create capability provider with lambda that wraps the execute method
        provider = CapabilityProvider.new(
          capability: capability_spec,
          implementation: lambda do |inputs|
            # The agent must be available in the execution context
            # For capabilities that need the agent, we need to enhance the provider pattern
            # For now, we'll raise if agent is not provided
            unless inputs[:agent]
              raise ArgumentError, "file_generation capability requires :agent in inputs"
            end

            agent = inputs.delete(:agent)
            FileGenerationCapability.execute(agent: agent, inputs: inputs)
          end
        )

        # Register with the global registry
        registry = AgentCapabilityRegistry.instance
        registry.register(capability_spec, provider)

        Agentic.logger&.info("Registered file_generation capability v#{spec_data[:version]}")
      end
    end
  end
end

# NOTE: Auto-registration removed. Registration is triggered via
# Capabilities.register_standard_capabilities which is called during
# Agentic.initialize_agent_assembly after the logger is available.
