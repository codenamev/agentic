# frozen_string_literal: true

module Agentic
  # LLM-assisted strategy for agent composition
  # Uses an LLM to analyze requirements and suggest capabilities
  class LlmAssistedCompositionStrategy < AgentCompositionStrategy
    # Initialize a new LLM-assisted composition strategy
    # @param llm_config_or_client [LlmConfig, LlmClient, nil] The LLM configuration or client to use
    def initialize(llm_config_or_client = nil)
      if llm_config_or_client.is_a?(LlmClient)
        @llm_client = llm_config_or_client
      else
        @llm_config = llm_config_or_client || LlmConfig.new
      end
    end

    # Select capabilities based on requirements
    # @param requirements [Hash] The capability requirements
    # @param registry [AgentCapabilityRegistry] The capability registry
    # @return [Array<Hash>] The selected capabilities
    def select_capabilities(requirements, registry)
      # Get all available capabilities from the registry
      available_capabilities = registry.list

      # Use existing client or create a new one
      client = @llm_client || Agentic.client(@llm_config)

      # Create a prompt for the LLM
      prompt = build_llm_prompt(requirements, available_capabilities)

      # Get LLM response
      response = client.complete([{role: "user", content: prompt}])

      # Parse the response (the prompt asks for JSON; the parser extracts it)
      suggested_capabilities = parse_llm_response(response.content.to_s, registry)

      # Fall back to default strategy if LLM suggestion fails
      if suggested_capabilities.empty?
        Agentic.logger.warn("LLM capability suggestion failed, falling back to default strategy")
        return DefaultCompositionStrategy.new.select_capabilities(requirements, registry)
      end

      # Add dependencies
      add_dependencies(suggested_capabilities, registry)
    end

    private

    # Build a prompt for the LLM to suggest capabilities
    # @param requirements [Hash] The capability requirements
    # @param available_capabilities [Hash] The available capabilities in the registry
    # @return [String] The prompt for the LLM
    def build_llm_prompt(requirements, available_capabilities)
      # Format the requirements
      req_text = requirements.map do |name, info|
        "- #{name} (importance: #{info[:importance]}, version: #{info[:version_constraint] || "any"})"
      end.join("\n")

      # Format the available capabilities
      avail_text = available_capabilities.map do |name, info|
        versions_text = info[:versions].join(", ")
        "- #{name} (versions: #{versions_text}, latest: #{info[:latest]})"
      end.join("\n")

      <<~PROMPT
        You are an AI assistant helping to select the most appropriate capabilities for an agent.

        Given the following requirements and available capabilities, select the most appropriate
        capabilities for the agent. Consider the importance of each requirement and ensure all
        high-importance requirements are satisfied.

        # Requirements:
        #{req_text.empty? ? "No specific requirements provided." : req_text}

        # Available Capabilities:
        #{avail_text}

        For each requirement, select the most appropriate capability and version.
        Also consider dependencies between capabilities and ensure all necessary capabilities are included.

        Provide your response in JSON format with this structure:
        {
          "selected_capabilities": [
            {"name": "capability_name", "version": "version_string", "reason": "Reason for selection"},
            ...
          ],
          "rationale": "Overall explanation of your selection logic"
        }
      PROMPT
    end

    # Parse the LLM response to get suggested capabilities
    # @param response [String] The LLM response
    # @param registry [AgentCapabilityRegistry] The capability registry
    # @return [Array<Hash>] The selected capabilities
    def parse_llm_response(response, registry)
      # Extract JSON from the response
      json_match = response.match(/\{.*"selected_capabilities".*\}/m)
      return [] unless json_match

      json_str = json_match[0]

      # Parse the JSON response
      json_response = JSON.parse(json_str, symbolize_names: true)

      # Extract the selected capabilities
      selected = json_response[:selected_capabilities] || []

      # Log the rationale if provided
      if json_response[:rationale]
        Agentic.logger.info("LLM capability selection rationale: #{json_response[:rationale]}")
      end

      # Validate the selected capabilities
      validated = []

      selected.each do |cap|
        name = cap[:name]
        version = cap[:version]

        # Log the reason if provided
        if cap[:reason]
          Agentic.logger.info("Selected #{name} v#{version}: #{cap[:reason]}")
        end

        # Check if the capability exists in the registry
        capability = registry.get(name, version)

        if capability
          validated << {
            name: capability.name,
            version: capability.version
          }
        else
          Agentic.logger.warn("LLM suggested non-existent capability: #{name} v#{version}")
        end
      end

      validated
    rescue => e
      Agentic.logger.error("Failed to parse LLM response: #{e.message}")
      []
    end

    # Add dependencies to the selected capabilities
    # @param selected [Array<Hash>] The selected capabilities
    # @param registry [AgentCapabilityRegistry] The capability registry
    # @return [Array<Hash>] The selected capabilities with dependencies
    def add_dependencies(selected, registry)
      # Track dependencies to add
      to_add = []

      # Check each selected capability for dependencies
      selected.each do |cap_info|
        capability = registry.get(cap_info[:name], cap_info[:version])
        next unless capability

        # Check each dependency
        capability.dependencies.each do |dep|
          # Skip if we already selected this dependency
          next if selected.any? { |sel| sel[:name] == dep[:name] } ||
            to_add.any? { |sel| sel[:name] == dep[:name] }

          # Find the dependency in the registry
          dep_capability = registry.get(dep[:name], dep[:version])

          # Skip if not found
          next unless dep_capability

          # Add to the list of dependencies to add
          to_add << {
            name: dep_capability.name,
            version: dep_capability.version
          }

          Agentic.logger.info("Added dependency: #{dep_capability.name} v#{dep_capability.version}")
        end
      end

      # Add the dependencies to the selected capabilities
      selected.concat(to_add)
      selected
    end
  end
end
