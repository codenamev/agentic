# frozen_string_literal: true

require "time" # Time#iso8601/Time.parse - require what you use
require "did_you_mean/levenshtein"

module Agentic
  # Engine for assembling agents based on task requirements
  # @attr_reader [AgentCapabilityRegistry] registry The capability registry
  # @attr_reader [PersistentAgentStore, nil] agent_store The agent store for persistence
  class AgentAssemblyEngine
    attr_reader :registry, :agent_store

    # Initialize a new agent assembly engine
    # @param registry [AgentCapabilityRegistry] The capability registry to use
    # @param agent_store [PersistentAgentStore, nil] The agent store for persistence
    def initialize(registry = AgentCapabilityRegistry.instance, agent_store = nil)
      @registry = registry
      @agent_store = agent_store
    end

    # Assemble an agent for a task
    # @param task [Task] The task to assemble an agent for
    # @param strategy [AgentCompositionStrategy, nil] The strategy to use for assembly
    # @param store [Boolean] Whether to use the agent store for finding and storing agents
    # @return [Agent] The assembled agent
    def assemble_agent(task, strategy: nil, store: true)
      # Check if we should try to find an existing agent in the store
      if store && @agent_store
        notify_observability(:agent_assembly_searching_store, task_id: task.id)
        existing_agent = find_suitable_agent(task)
        if existing_agent
          Agentic.logger.info("Using existing agent from store for task: #{task.id}")
          notify_observability(:agent_assembly_found_existing, task_id: task.id, agent_role: existing_agent.role)
          return existing_agent
        end
        notify_observability(:agent_assembly_no_existing, task_id: task.id)
      end

      # Use the default strategy if none provided
      strategy ||= DefaultCompositionStrategy.new

      # Analyze task requirements
      notify_observability(:agent_assembly_analyzing_requirements, task_id: task.id, task_description: task.description)
      requirements = analyze_requirements(task)
      notify_observability(:agent_assembly_requirements_analyzed, task_id: task.id, requirements: requirements.keys, count: requirements.size)

      # Select capabilities based on requirements
      notify_observability(:agent_assembly_selecting_capabilities, task_id: task.id, requirement_count: requirements.size)
      capabilities = select_capabilities(requirements, strategy)
      notify_observability(:agent_assembly_capabilities_selected, task_id: task.id, capabilities: capabilities.map { |c| c[:name] }, count: capabilities.size)

      # Create a new agent with the selected capabilities
      notify_observability(:agent_assembly_building_agent, task_id: task.id, capability_count: capabilities.size)
      agent = build_agent(task, capabilities)
      notify_observability(:agent_assembly_agent_built, task_id: task.id, agent_role: agent.role, agent_purpose: agent.purpose)

      # Store the assembled agent if requested
      if store && @agent_store
        notify_observability(:agent_assembly_storing_agent, task_id: task.id, agent_role: agent.role)
        store_agent(agent, task, requirements)
      end

      # Return the assembled agent
      agent
    end

    # Analyze task requirements to determine needed capabilities
    # @param task [Task] The task to analyze
    # @return [Hash] The capability requirements
    def analyze_requirements(task)
      # Extract requirements from the task description and agent specification
      requirements = {}

      # Capabilities the plan named come first, at full importance: the
      # plan's choice is honored and inference below only fills gaps
      seed_planned_capabilities(task, requirements)

      # Use the task description to infer capabilities
      infer_capabilities_from_description(task.description, requirements)

      # Use the agent specification to infer capabilities
      if task.agent_spec
        infer_capabilities_from_agent_spec(task.agent_spec, requirements)
      end

      # Use the task input to infer capabilities
      if task.input && !task.input.empty?
        infer_capabilities_from_input(task.input, requirements)
      end

      requirements
    end

    # Select capabilities based on requirements
    # @param requirements [Hash] The capability requirements
    # @param strategy [AgentCompositionStrategy] The strategy to use for selection
    # @return [Array<Hash>] The selected capabilities
    def select_capabilities(requirements, strategy)
      # Use the strategy to select capabilities
      strategy.select_capabilities(requirements, @registry)
    end

    # Build an agent with the selected capabilities
    # @param task [Task] The task the agent will perform
    # @param capabilities [Array<Hash>] The selected capabilities
    # @return [Agent] The assembled agent
    def build_agent(task, capabilities)
      # Create a new agent
      agent = Agent.build do |a|
        # Set basic agent properties from the task agent spec
        if task.agent_spec
          a.role = task.agent_spec.name
          a.purpose = task.agent_spec.description
          a.backstory = task.agent_spec.instructions
        end
      end

      # Add capabilities to the agent
      capabilities.each do |capability_info|
        agent.add_capability(capability_info[:name], capability_info[:version])
      rescue => e
        Agentic.logger.warn("Failed to add capability: #{capability_info[:name]} v#{capability_info[:version]} - #{e.message}")
      end

      agent
    end

    # Find a suitable agent in the store for a task
    # @param task [Task] The task to find an agent for
    # @return [Agent, nil] A suitable agent or nil if none found
    def find_suitable_agent(task)
      return nil unless @agent_store

      # Get all stored agents
      all_agents = @agent_store.all
      return nil if all_agents.empty?

      # Generate the name and extract description for the current task
      candidate_name = generate_agent_name(task)
      candidate_description = task.description

      # Analyze task requirements for capability comparison
      requirements = analyze_requirements(task)
      candidate_capabilities = requirements.keys.sort

      # Score each agent based on Levenshtein distance similarity
      scored_agents = all_agents.map do |agent_config|
        agent_capabilities = (agent_config[:capabilities] || []).map { |c| c[:name] }.sort
        capability_score = capability_similarity(agent_capabilities, candidate_capabilities)

        similarity_score = calculate_agent_similarity(
          agent_config,
          candidate_name,
          candidate_description,
          candidate_capabilities
        )
        {config: agent_config, score: similarity_score, capability_score: capability_score}
      end

      # Sort by score (highest first)
      scored_agents.sort_by! { |a| -a[:score] }

      # Get the best match
      best_match = scored_agents.first

      # If the best match has a score below threshold, don't use it
      # Using 0.5 as threshold to allow for flexibility in capability inference
      # This accounts for cases where requirements analysis may infer extra capabilities
      return nil if best_match[:score] < 0.5

      # Also return nil if capability similarity is too low (< 0.5)
      # This prevents matching agents that have significantly different capabilities
      return nil if best_match[:capability_score] < 0.5

      Agentic.logger.info("Found similar agent '#{best_match[:config][:name]}' with similarity score: #{best_match[:score].round(3)}")

      # Build the agent from the stored configuration
      @agent_store.build_agent(best_match[:config][:id])
    end

    # Store an assembled agent in the persistent store
    # @param agent [Agent] The agent to store
    # @param task [Task] The task the agent was assembled for
    # @param requirements [Hash] The capability requirements
    # @return [String, nil] The ID of the stored agent or nil if not stored
    def store_agent(agent, task, requirements)
      return nil unless @agent_store

      # Generate a name for the agent based on the task
      name = generate_agent_name(task)

      # Generate metadata for the agent
      metadata = {
        task_id: task.id,
        task_description: task.description,
        assembled_at: Time.now.iso8601,
        requirements: requirements,
        assembly_engine_version: "1.0.0"  # Add version tracking
      }

      # Store the agent
      @agent_store.store(agent, name: name, metadata: metadata)
    end

    private

    # Calculate similarity score (0.0 to 1.0) based on Levenshtein distance
    # @param str1 [String] First string
    # @param str2 [String] Second string
    # @return [Float] Similarity score (1.0 = identical, 0.0 = completely different)
    def string_similarity(str1, str2)
      return 1.0 if str1 == str2
      return 0.0 if str1.nil? || str2.nil? || str1.empty? || str2.empty?

      # Normalize strings (downcase and strip whitespace)
      s1 = str1.to_s.downcase.strip
      s2 = str2.to_s.downcase.strip

      # Use Ruby's built-in Levenshtein distance calculation from DidYouMean
      distance = DidYouMean::Levenshtein.distance(s1, s2)
      max_length = [s1.length, s2.length].max

      # Convert distance to similarity (0.0 to 1.0)
      1.0 - (distance.to_f / max_length)
    end

    # Calculate similarity between two capability lists
    # @param caps1 [Array<String>] First capability list
    # @param caps2 [Array<String>] Second capability list
    # @return [Float] Similarity score (0.0 to 1.0)
    def capability_similarity(caps1, caps2)
      return 1.0 if caps1.empty? && caps2.empty?
      return 0.0 if caps1.empty? || caps2.empty?

      # Count matching capabilities
      matching = (caps1 & caps2).size
      total = (caps1 | caps2).size

      # Jaccard similarity coefficient
      matching.to_f / total
    end

    # Calculate overall similarity between an agent and a candidate task
    # @param agent_config [Hash] The stored agent configuration
    # @param candidate_name [String] Generated name for candidate agent
    # @param candidate_description [String] Task description
    # @param candidate_capabilities [Array<String>] Required capabilities
    # @return [Float] Overall similarity score (0.0 to 1.0)
    def calculate_agent_similarity(agent_config, candidate_name, candidate_description, candidate_capabilities)
      # Extract agent information
      agent_name = agent_config[:name]
      agent_description = agent_config.dig(:metadata, :task_description) || ""
      agent_capabilities = (agent_config[:capabilities] || []).map { |c| c[:name] }.sort

      # Calculate individual similarity scores
      name_score = string_similarity(agent_name, candidate_name)

      # If description is missing from metadata, rely more heavily on capabilities
      # This handles cases where agents are stored without task metadata
      if agent_description.empty? && !candidate_description.to_s.empty?
        # When description is missing, weight capabilities more heavily
        capability_score = capability_similarity(agent_capabilities, candidate_capabilities)
        weighted_score = (name_score * 0.4) + (capability_score * 0.6)
      else
        # Normal case with description available
        description_score = string_similarity(agent_description, candidate_description)
        capability_score = capability_similarity(agent_capabilities, candidate_capabilities)
        weighted_score = (name_score * 0.4) + (description_score * 0.3) + (capability_score * 0.3)
      end

      weighted_score
    end

    # Calculate a score for how well an agent matches requirements
    # @param agent_config [Hash] The agent configuration
    # @param requirements [Hash] The capability requirements
    # @return [Float] The match score (0.0 to 1.0)
    def calculate_agent_match_score(agent_config, requirements)
      # Start with a base score
      score = 0.0
      max_score = 0.0

      # Get the agent's capabilities
      agent_capabilities = agent_config[:capabilities].map { |c| c[:name] }

      # Score each requirement
      requirements.each do |capability_name, info|
        # Add the importance to the max possible score
        max_score += info[:importance]

        # If the agent has the capability, add its importance to the score
        if agent_capabilities.include?(capability_name)
          score += info[:importance]
        end
      end

      # Normalize the score (0.0 to 1.0)
      (max_score > 0) ? score / max_score : 0.0
    end

    # Generate a name for an agent based on a task
    # @param task [Task] The task the agent is for
    # @return [String] A name for the agent
    def generate_agent_name(task)
      # Extract key words from the task description
      words = task.description.downcase.scan(/\b[a-z]{3,}\b/).first(3)

      # Get the task type from the agent spec if available
      task_type = task.agent_spec ? task.agent_spec.name.downcase.gsub(/\s+/, "_") : "agent"

      # Generate a name with task type and words
      if words.empty?
        "#{task_type}_#{SecureRandom.hex(4)}"
      else
        "#{task_type}_#{words.join("_")}"
      end
    end

    # Infer capabilities from a task description
    # @param description [String] The task description
    # @param requirements [Hash] The requirements hash to update
    # @return [void]
    # Seed requirements with the capabilities the planner chose for the task
    # @param task [Task] The task, which may carry plan-time capability names
    # @param requirements [Hash] The requirements hash to seed
    # @return [void]
    def seed_planned_capabilities(task, requirements)
      return unless task.respond_to?(:capabilities)

      Array(task.capabilities).each do |name|
        requirements[name.to_s] = {importance: 1.0, version_constraint: nil}
      end
    end

    def infer_capabilities_from_description(description, requirements)
      # Extract capability names from description using simple pattern matching
      # This is a basic implementation that should be enhanced with NLP or LLM-based analysis

      # Example: Look for known capability keywords
      known_capabilities = [
        "document_analysis", "structure_extraction", "text_generation",
        "web_search", "data_analysis", "code_generation", "uml_generation",
        "dependency_analysis", "testing", "performance_analysis", "code_metrics"
      ]

      known_capabilities.each do |capability|
        next unless description_mentions_capability?(description, capability)

        if requirements[capability]
          # Mentions across multiple sources (description, agent spec name,
          # instructions, ...) compound the capability's importance
          requirements[capability][:importance] = [requirements[capability][:importance] + 0.15, 1.0].min
        else
          requirements[capability] = {
            importance: 0.5,  # Default importance
            version_constraint: nil  # Any version
          }
        end

        # Increase importance if mentioned multiple times in this source
        count = description.downcase.scan(capability.downcase).count
        requirements[capability][:importance] += 0.1 * count if count > 1
      end

      # Special case for code-generation tasks: a strong signal that should
      # raise the importance even when keyword matching already found it
      if description.downcase.include?("code") && description.downcase.include?("generate")
        requirement = (requirements["code_generation"] ||= {importance: 0.0, version_constraint: nil})
        requirement[:importance] = [requirement[:importance], 0.8].max
      end

      # Add common capabilities for all tasks
      requirements["text_generation"] ||= {
        importance: 0.3,  # Lower importance as it's a default capability
        version_constraint: nil
      }
    end

    # Check whether a description mentions a capability, either literally
    # ("data_analysis"), space-separated ("data analysis"), or via word stems
    # so that "Analyze the data" still matches "data_analysis"
    # @param description [String] The text to search
    # @param capability [String] The capability name (underscore-separated)
    # @return [Boolean] True if the description mentions the capability
    def description_mentions_capability?(description, capability)
      text = description.downcase
      return true if text.include?(capability.downcase) || text.include?(capability.tr("_", " "))

      capability.split("_").all? do |word|
        stem = word[0, 5]
        stem.length >= 3 && text.include?(stem)
      end
    end

    # Infer capabilities from an agent specification
    # @param agent_spec [AgentSpecification] The agent specification
    # @param requirements [Hash] The requirements hash to update
    # @return [void]
    def infer_capabilities_from_agent_spec(agent_spec, requirements)
      # Extract capabilities from agent name
      infer_capabilities_from_description(agent_spec.name, requirements)

      # Extract capabilities from agent description
      if agent_spec.description
        infer_capabilities_from_description(agent_spec.description, requirements)
      end

      # Extract capabilities from agent instructions
      if agent_spec.instructions
        infer_capabilities_from_description(agent_spec.instructions, requirements)
      end

      # If the agent spec mentions tools explicitly, prioritize those
      if agent_spec.respond_to?(:tools) && agent_spec.tools
        agent_spec.tools.each do |tool|
          tool_name = tool.to_s
          requirements[tool_name] ||= {
            importance: 0.8,  # High importance for explicitly mentioned tools
            version_constraint: nil  # Any version
          }
        end
      end

      # If the agent spec mentions capabilities explicitly, prioritize those
      if agent_spec.respond_to?(:capabilities) && agent_spec.capabilities
        agent_spec.capabilities.each do |capability|
          capability_name = capability.to_s
          requirements[capability_name] ||= {
            importance: 0.9,  # Very high importance for explicitly mentioned capabilities
            version_constraint: nil  # Any version
          }
        end
      end
    end

    # Infer capabilities from task input
    # @param input [Hash] The task input
    # @param requirements [Hash] The requirements hash to update
    # @return [void]
    def infer_capabilities_from_input(input, requirements)
      # Check if input contains capability requirements directly
      if input[:capabilities] || input["capabilities"]
        capabilities = input[:capabilities] || input["capabilities"]

        if capabilities.is_a?(Array)
          capabilities.each do |capability|
            if capability.is_a?(String)
              # Explicitly requested capabilities outrank keyword inference
              requirement = (requirements[capability] ||= {importance: 0.0, version_constraint: nil})
              requirement[:importance] = [requirement[:importance], 0.9].max
            elsif capability.is_a?(Hash)
              name = capability[:name] || capability["name"]
              version = capability[:version] || capability["version"]
              importance = capability[:importance] || capability["importance"] || 0.9

              if name
                requirement = (requirements[name] ||= {importance: 0.0, version_constraint: version})
                requirement[:importance] = [requirement[:importance], importance].max
                requirement[:version_constraint] ||= version
              end
            end
          end
        end
      end

      # Analyze input keys for capability hints
      input.each do |key, value|
        key_str = key.to_s

        # Check if key suggests a capability
        known_capability_indicators = [
          "analyze", "generate", "search", "extract", "compute",
          "test", "verify", "optimize", "format", "translate"
        ]

        known_capability_indicators.each do |indicator|
          if key_str.include?(indicator)
            capability_name = "#{indicator}_#{key_str.sub(indicator, "")}"
            requirements[capability_name] ||= {
              importance: 0.6,  # Medium importance for inferred capabilities
              version_constraint: nil  # Any version
            }
          end
        end
      end
    end

    # Notify the observability engine about assembly events
    # @param event_type [Symbol] The event type
    # @param data [Hash] The event data
    # @return [void]
    def notify_observability(event_type, **data)
      return unless Agentic.respond_to?(:observability_engine)

      Agentic.observability_engine.notify(
        event_type,
        data: data,
        source: "agent_assembly_engine"
      )
    rescue => e
      Agentic.logger.debug("Failed to notify observability engine: #{e.message}")
    end
  end

  # Base class for agent composition strategies
  class AgentCompositionStrategy
    # Select capabilities based on requirements
    # @param requirements [Hash] The capability requirements
    # @param registry [AgentCapabilityRegistry] The capability registry
    # @return [Array<Hash>] The selected capabilities
    def select_capabilities(requirements, registry)
      raise NotImplementedError, "Subclasses must implement select_capabilities"
    end
  end

  # Default strategy for agent composition
  class DefaultCompositionStrategy < AgentCompositionStrategy
    # Select capabilities based on requirements
    # @param requirements [Hash] The capability requirements
    # @param registry [AgentCapabilityRegistry] The capability registry
    # @return [Array<Hash>] The selected capabilities
    def select_capabilities(requirements, registry)
      selected = []

      # Sort requirements by importance (highest first)
      sorted_requirements = requirements.sort_by { |_, info| -info[:importance] }

      # Select capabilities for each requirement
      sorted_requirements.each do |name, info|
        # Find the capability in the registry
        capability = registry.get(name, info[:version_constraint])

        # Skip if not found
        next unless capability

        # Add to selected capabilities
        selected << {
          name: capability.name,
          version: capability.version
        }

        # Add dependencies
        capability.dependencies.each do |dep|
          # Check if we already selected this dependency
          next if selected.any? { |sel| sel[:name] == dep[:name] }

          # Find the dependency in the registry
          dep_capability = registry.get(dep[:name], dep[:version])

          # Skip if not found
          next unless dep_capability

          # Add to selected capabilities
          selected << {
            name: dep_capability.name,
            version: dep_capability.version
          }
        end
      end

      # If no capabilities were selected, add a default text generation capability
      if selected.empty?
        default_capability = registry.get("text_generation")
        if default_capability
          selected << {
            name: default_capability.name,
            version: default_capability.version
          }
        end
      end

      selected
    end
  end
end
