# frozen_string_literal: true

module Agentic
  # Coordinates artifact generation using LLM agents
  #
  # ArtifactGenerator provides a high-level API for generating code files and
  # artifacts within an isolated workspace. It wraps the FileGenerationCapability
  # with a cleaner interface and proper result handling.
  #
  # @example Basic usage
  #   workspace = Workspace.new("/tmp/my_project")
  #   agent = create_llm_agent()
  #   generator = ArtifactGenerator.new(agent, workspace)
  #
  #   result = generator.generate("Create a Ruby User class with name and email")
  #   if result.successful?
  #     puts "Generated #{result.artifact_count} files"
  #     result.artifacts.each { |a| puts "- #{a.name}" }
  #   end
  #
  # @example With constraints
  #   result = generator.generate(
  #     "Create model and service classes",
  #     constraints: { max_files: 5, allowed_types: [:ruby_class] }
  #   )
  #
  # @example With input context
  #   result = generator.generate(
  #     "Create a User model",
  #     input: { attributes: ["name", "email", "created_at"] }
  #   )
  class ArtifactGenerator
    # @return [Agent] The agent used for generation
    attr_reader :agent

    # @return [Workspace] The workspace for artifact storage
    attr_reader :workspace

    # @return [Hash] Configuration options
    attr_reader :config

    # Initialize a new artifact generator
    #
    # @param agent [Agent] Agent configured with LLM capabilities
    # @param workspace [Workspace] Isolated workspace for file generation
    # @param config [Hash] Configuration options
    # @option config [Boolean] :verify_artifacts Run quality verification (default: true)
    # @option config [Hash] :default_constraints Default generation constraints
    def initialize(agent, workspace, config = {})
      @agent = agent
      @workspace = workspace
      @config = {
        verify_artifacts: true,
        default_constraints: {}
      }.merge(config)
    end

    # Generate artifacts from a task description
    #
    # Uses the agent to generate artifact descriptions, then creates and
    # validates each artifact before adding to the workspace.
    #
    # @param task_description [String] Description of files to generate
    # @param input [Hash] Additional input context for generation
    # @param constraints [Hash] Generation constraints
    # @option constraints [Integer] :max_files Maximum files to generate
    # @option constraints [Array<Symbol>] :allowed_types Allowed artifact types
    # @return [ArtifactGenerationResult] Result containing artifacts and status
    #
    # @example
    #   result = generator.generate("Create a User class with validation")
    #   result.successful? # => true
    #   result.artifacts.first.name # => "user.rb"
    def generate(task_description, input: {}, constraints: {})
      merged_constraints = @config[:default_constraints].merge(constraints)

      # Build full task description with input context
      full_description = build_task_description(task_description, input)

      # Execute file generation capability
      capability_result = execute_file_generation(full_description, merged_constraints)

      # Convert capability result to ArtifactGenerationResult
      build_result(capability_result)
    rescue SecurityError, StandardError => e
      Agentic.logger.error("Artifact generation failed: #{e.message}")
      ArtifactGenerationResult.failure(
        errors: [e.message],
        workspace: @workspace,
        metadata: {exception_class: e.class.name}
      )
    end

    # Generate artifacts with additional workspace context
    #
    # Includes existing workspace artifacts in the generation context,
    # useful for generating files that should reference existing code.
    #
    # @param task_description [String] Description of files to generate
    # @param input [Hash] Additional input context
    # @param constraints [Hash] Generation constraints
    # @return [ArtifactGenerationResult] Result containing artifacts and status
    def generate_with_context(task_description, input: {}, constraints: {})
      # Add existing artifacts to input context
      context_input = input.merge(
        existing_artifacts: @workspace.all_artifacts.map do |artifact|
          {name: artifact.name, type: artifact.type, references: artifact.references}
        end
      )

      generate(task_description, input: context_input, constraints: constraints)
    end

    private

    # Build complete task description with input context
    #
    # @param description [String] Base task description
    # @param input [Hash] Input context
    # @return [String] Full description with context
    def build_task_description(description, input)
      return description if input.empty?

      parts = [description]
      parts << "\n[Input Context]"
      parts << JSON.pretty_generate(input)

      parts.join("\n")
    end

    # Execute the file generation capability
    #
    # @param task_description [String] Task description
    # @param constraints [Hash] Generation constraints
    # @return [Hash] Capability execution result
    def execute_file_generation(task_description, constraints)
      Capabilities::FileGenerationCapability.execute(
        agent: @agent,
        inputs: {
          task_description: task_description,
          workspace: @workspace,
          constraints: constraints
        }
      )
    end

    # Build ArtifactGenerationResult from capability result
    #
    # @param capability_result [Hash] Result from FileGenerationCapability
    # @return [ArtifactGenerationResult] Structured result object
    def build_result(capability_result)
      if capability_result[:success]
        # Retrieve actual Artifact objects from workspace
        artifacts = retrieve_artifacts(capability_result[:artifacts])

        ArtifactGenerationResult.success(
          artifacts: artifacts,
          workspace: @workspace,
          metadata: {
            artifact_count: capability_result[:artifact_count],
            workspace_id: capability_result[:workspace_id]
          }
        )
      else
        ArtifactGenerationResult.failure(
          errors: [capability_result[:error]].compact,
          workspace: @workspace,
          artifacts: [],
          metadata: {
            partial_artifacts: capability_result[:artifacts]
          }
        )
      end
    end

    # Retrieve Artifact objects from workspace based on result hashes
    #
    # @param artifact_hashes [Array<Hash>] Artifact data from capability
    # @return [Array<Artifact>] Artifact objects from workspace
    def retrieve_artifacts(artifact_hashes)
      artifact_hashes.map do |hash|
        name = hash[:name] || hash["name"]
        @workspace.find_artifact(name: name)
      end.compact
    end
  end
end
