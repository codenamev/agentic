# frozen_string_literal: true

module Agentic
  class Agent
    include FactoryMethods

    configurable :id, :name, :role, :purpose, :backstory, :instructions, :tools, :capabilities, :llm_client

    # @return [GenerationStats, nil] Token usage of the most recent LLM
    #   response this agent produced; nil when the last execution did not
    #   reach an LLM (capability path) or the provider reported no usage
    attr_reader :last_stats

    # Initialize with default values
    def initialize
      @capabilities = {}
      @tools = Set.new
      @llm_client = nil
      @last_stats = nil
    end

    # Executes a task using this agent
    # @param task [String, Task] The task to execute, either a task object or a prompt
    # @return [Object] The result of the task execution
    def execute(task)
      if task.is_a?(String)
        # Simple string prompt
        execute_prompt(task)
      elsif task.respond_to?(:requires_artifacts?) && task.requires_artifacts? && task.has_workspace?
        # Artifact generation task
        execute_artifact_task(task)
      else
        # Regular task object
        task.perform(self)
      end
    end

    # Executes a prompt with structured output schema
    #
    # The schema is a promise this method keeps: execution goes through the
    # LLM client, which enforces structured output. An agent that cannot
    # honor the schema says so instead of silently returning free text.
    #
    # @param prompt [String] The prompt to execute
    # @param schema [Agentic::StructuredOutputs::Schema] The output schema
    # @return [Object] The structured response
    # @raise [Errors::SchemaNotSupportedError] when only capability-based
    #   execution is available, which cannot enforce a schema
    # @raise [Errors::AgentNotConfiguredError] when no execution path exists
    def execute_with_schema(prompt, schema)
      @last_stats = nil
      if @llm_client
        response = remember_stats(@llm_client.complete(build_messages(prompt), output_schema: schema))
        if response.successful?
          response.content
        else
          raise Errors::LlmError.new("LLM execution failed: #{response.error.message}", context: {prompt: prompt})
        end
      elsif has_capability?("text_generation")
        raise Errors::SchemaNotSupportedError,
          "A structured-output schema was requested, but this agent only has " \
          "the text_generation capability, which cannot enforce schemas. " \
          "Configure an llm_client, or call #execute for free-form output."
      else
        raise Errors::AgentNotConfiguredError
      end
    end

    # Executes a prompt with workspace context for file generation
    # @param prompt [String] The prompt to execute
    # @param workspace [Workspace] The workspace for file generation
    # @return [String] The response with artifact descriptions
    def execute_with_workspace(prompt, workspace)
      workspace_context = build_workspace_context(workspace)
      full_prompt = "#{workspace_context}\n\n#{prompt}"

      execute_prompt(full_prompt)
    end

    # Adds a capability to the agent
    # @param capability_name [String] The name of the capability
    # @param version [String, nil] The version of the capability, or nil for latest
    # @return [Boolean] True if the capability was added successfully
    def add_capability(capability_name, version = nil)
      # Get the capability from the registry
      registry = AgentCapabilityRegistry.instance
      capability = registry.get(capability_name, version)
      raise Errors::CapabilityNotFoundError.new(capability_name, context: "not registered") unless capability

      # Get the provider
      provider = registry.get_provider(capability_name, version)
      raise Errors::CapabilityNotFoundError.new(capability_name, context: "no provider registered") unless provider

      # Add to the agent's capabilities
      @capabilities[capability_name] = {
        specification: capability,
        provider: provider
      }

      # Also add to tools for backward compatibility
      @tools.add(capability_name.to_sym)

      true
    end

    # Checks if the agent has a capability
    # @param capability_name [String] The name of the capability
    # @return [Boolean] True if the agent has the capability
    def has_capability?(capability_name)
      @capabilities.key?(capability_name)
    end

    # Gets the specification for a capability
    # @param capability_name [String] The name of the capability
    # @return [CapabilitySpecification, nil] The capability specification or nil if not found
    def capability_specification(capability_name)
      return nil unless @capabilities[capability_name]
      @capabilities[capability_name][:specification]
    end

    # Executes a capability
    # @param capability_name [String] The name of the capability
    # @param inputs [Hash] The inputs for the capability
    # @return [Hash] The outputs from the capability
    def execute_capability(capability_name, inputs = {})
      unless @capabilities.key?(capability_name)
        raise Errors::CapabilityNotFoundError.new(capability_name, context: "not added to this agent")
      end

      # Get the provider
      provider = @capabilities[capability_name][:provider]

      # For capabilities that need agent reference (like file_generation), inject it
      if requires_agent_context?(capability_name)
        inputs = inputs.merge(agent: self)
      end

      # Execute the capability
      provider.execute(inputs)
    end

    # Check if a capability requires agent context
    # @param capability_name [String] The name of the capability
    # @return [Boolean] True if capability needs agent reference
    def requires_agent_context?(capability_name)
      # Capabilities that need access to the agent itself
      %w[file_generation].include?(capability_name)
    end

    # Converts the agent to a hash representation
    # @return [Hash] The hash representation
    def to_h
      {
        role: @role,
        purpose: @purpose,
        backstory: @backstory,
        capability_names: @capabilities.keys
      }
    end

    # Creates an agent from a hash representation
    # @param hash [Hash] The hash representation
    # @return [Agent] The agent
    def self.from_h(hash)
      # Capabilities need to be added separately after creation
      # since they require the registry to be available
      build do |a|
        a.role = hash[:role] || hash["role"]
        a.purpose = hash[:purpose] || hash["purpose"]
        a.backstory = hash[:backstory] || hash["backstory"]
      end
    end

    private

    # Executes an artifact generation task
    # @param task [Task] Task with workspace and artifact_mode
    # @return [ArtifactGenerationResult] The generation result
    def execute_artifact_task(task)
      generator = ArtifactGenerator.new(self, task.workspace)
      generator.generate(task.description, input: task.input)
    end

    # Executes a simple string prompt
    # @param prompt [String] The prompt to execute
    # @return [String] The response
    def execute_prompt(prompt)
      @last_stats = nil
      # If the agent has a text_generation capability, use it
      if has_capability?("text_generation")
        execute_capability("text_generation", {prompt: prompt})[:response]
      elsif @llm_client
        # Use the configured LLM client
        response = remember_stats(@llm_client.complete(build_messages(prompt)))
        if response.successful?
          response.content
        else
          raise Errors::LlmError.new("LLM execution failed: #{response.error.message}", context: {prompt: prompt})
        end
      else
        raise Errors::AgentNotConfiguredError
      end
    end

    # Keeps the response's token usage where Task#perform can read it
    # @param response [LlmResponse] The response just received
    # @return [LlmResponse] The same response
    def remember_stats(response)
      @last_stats = response.stats if response.respond_to?(:stats)
      response
    end

    # Builds messages array for LLM completion
    # @param prompt [String] The user prompt
    # @return [Array<Hash>] The messages array
    def build_messages(prompt)
      messages = []

      # Add system message with agent context
      system_content = build_system_message
      messages << {role: "system", content: system_content} if system_content && !system_content.empty?

      # Add user prompt
      messages << {role: "user", content: prompt}

      messages
    end

    # Builds system message with agent personality and instructions
    # @return [String] The system message content
    def build_system_message
      parts = []

      parts << "You are #{@role}" if @role && !@role.empty?
      parts << "Purpose: #{@purpose}" if @purpose && !@purpose.empty?
      parts << "Background: #{@backstory}" if @backstory && !@backstory.empty?
      parts << "Instructions: #{@instructions}" if @instructions && !@instructions.empty?

      # Add capability information
      if @capabilities && !@capabilities.empty?
        capabilities_list = @capabilities.keys.join(", ")
        parts << "Available capabilities: #{capabilities_list}"
      end

      parts.join("\n\n")
    end

    # Builds workspace context for file generation tasks
    # @param workspace [Workspace] The workspace
    # @return [String] The workspace context
    def build_workspace_context(workspace)
      <<~CONTEXT
        [Workspace Information]
        You have access to an isolated workspace for generating files.
        Workspace ID: #{workspace.id}
        Workspace path: #{workspace.path}
        Current artifacts: #{workspace.artifact_count}

        [File Generation Instructions]
        When generating files, respond with JSON describing each artifact in this exact format:
        {
          "artifacts": [
            {
              "name": "relative/path/to/file.rb",
              "type": "ruby_class",
              "content": "complete file content here including all code",
              "references": ["other_file.rb"]
            }
          ]
        }

        Artifact types: ruby_class, javascript_module, python_module, json, markdown, text, yaml, css, html, xml, sql

        IMPORTANT:
        - Use relative paths from workspace root (no absolute paths, no ../)
        - Include complete, working file content
        - List all file references/dependencies
        - Generate only the files requested in the task
      CONTEXT
    end
  end
end
