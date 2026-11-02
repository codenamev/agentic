# frozen_string_literal: true

require "securerandom"
require "json"

module Agentic
  # Represents an individual task to be executed by an agent
  # @attr_reader [String] id Unique identifier for the task
  # @attr_reader [String] description Human-readable description of the task
  # @attr_reader [Hash] agent_spec Requirements for the agent that will execute this task
  # @attr_reader [Hash] input Input data for the task
  # @attr_reader [Hash, nil] output Output produced by the task, nil if not yet executed
  # @attr_reader [Symbol] status Current status of the task (:pending, :in_progress, :completed, :failed)
  # @attr_reader [TaskFailure, nil] failure Failure information if the task failed, nil otherwise
  # @attr_reader [Boolean, nil] ready_to_execute Flag indicating if the task is ready to be executed
  # @attr_reader [Workspace, nil] workspace Optional workspace for file generation
  # @attr_reader [Boolean] artifact_mode Whether this task generates artifacts
  # @attr_accessor [Integer, nil] retry_count Number of times the task has been retried
  # @attr_accessor [Symbol, nil] output_schema_name Name of the output schema to use
  class Task
    include Agentic::Observable

    attr_reader :id, :description, :agent_spec, :input, :output, :status, :failure, :ready_to_execute, :workspace, :artifact_mode
    attr_accessor :retry_count, :output_schema_name

    # @return [Object, nil] Arbitrary domain object carried by the task,
    #   opaque to the framework - available to agents via the task itself
    attr_accessor :payload

    # Initializes a new task
    # @param description [String] Human-readable description of the task
    # @param agent_spec [Hash, AgentSpecification] Requirements for the agent that will execute this task
    # @param input [Hash] Input data for the task
    # @param payload [Object, nil] Arbitrary domain data for the agent executing this task
    # @param workspace [Workspace, nil] Optional workspace for file generation
    # @param output_schema_name [Symbol, nil] Name of the output schema to use for structured output
    # @param artifact_mode [Boolean] Whether this task generates artifacts (default: false)
    # @return [Task] A new task instance
    def initialize(description:, agent_spec:, input: {}, payload: nil, workspace: nil, output_schema_name: nil, artifact_mode: false)
      @id = SecureRandom.uuid
      @description = description

      # Convert agent_spec to AgentSpecification if it's a hash
      @agent_spec = if agent_spec.is_a?(Hash)
        AgentSpecification.new(
          name: agent_spec["name"],
          description: agent_spec["description"] || "",
          instructions: agent_spec["instructions"]
        )
      else
        agent_spec
      end

      @input = input
      @payload = payload
      @workspace = workspace
      @output = nil
      @failure = nil
      @status = :pending
      @ready_to_execute = nil
      @output_schema_name = output_schema_name
      @dependency_outputs = {}
      @dependency_failures = {}
      @artifact_mode = artifact_mode
    end

    # Creates a task from a TaskDefinition
    # @param definition [TaskDefinition] The task definition
    # @param input [Hash] Input data for the task
    # @return [Task] A new task instance
    def self.from_definition(definition, input = {})
      new(
        description: definition.description,
        agent_spec: definition.agent,
        input: input
      )
    end

    # Outputs of completed dependency tasks, keyed by task id. Populated
    # by the orchestrator before this task executes.
    # @return [Hash{String=>Object}] Dependency task id => output
    attr_reader :dependency_outputs

    # Records the output of a completed dependency (called by the orchestrator)
    # @param dependency_id [String] The dependency task's id
    # @param output [Object] The dependency's output
    # @return [void]
    def record_dependency_output(dependency_id, output)
      @dependency_outputs[dependency_id] = output
    end

    # The output a dependency produced, looked up by task or id
    # @param task_or_id [Task, String] The dependency task (or its id)
    # @return [Object, nil] The dependency's output
    def output_of(task_or_id)
      @dependency_outputs[task_or_id.respond_to?(:id) ? task_or_id.id : task_or_id]
    end

    # Records why a dependency failed when the graph chose to run this task
    # anyway (on_failure: :continue). Called by the orchestrator
    # @param dependency_id [String] The dependency task's id
    # @param failure [TaskFailure] The dependency's failure
    # @return [void]
    def record_dependency_failure(dependency_id, failure)
      @dependency_failures[dependency_id] = failure
    end

    # Whether a dependency produced an output rather than a tolerated failure
    # @param task_or_id [Task, String] The dependency task (or its id)
    # @return [Boolean]
    def succeeded?(task_or_id)
      @dependency_outputs.key?(task_or_id.respond_to?(:id) ? task_or_id.id : task_or_id)
    end

    # The failure a dependency recorded, when the graph continued past it
    # @param task_or_id [Task, String] The dependency task (or its id)
    # @return [TaskFailure, nil]
    def failure_of(task_or_id)
      @dependency_failures[task_or_id.respond_to?(:id) ? task_or_id.id : task_or_id]
    end

    # The output of this task's sole (or first-completed) dependency -
    # the common case in a chain, where naming the dependency is noise
    # @return [Object, nil] The dependency's output
    def previous_output
      @dependency_outputs.values.first
    end

    # Dependency outputs addressed by the names declared via
    # add_task(task, needs: {name: dependency})
    # @return [NamedOutputs]
    def needs
      @needs ||= NamedOutputs.new
    end

    # Executes the task using the given agent
    # @param agent [Agent] The agent that will execute this task
    # @return [TaskResult] The result of the task execution
    def perform(agent)
      old_status = @status
      @status = :in_progress

      notify_observers(:status_change, old_status, @status)

      begin
        @output = if has_output_schema?
          agent.execute_with_schema(build_prompt, output_schema)
        else
          agent.execute(build_prompt)
        end
        old_status = @status
        @status = :completed

        notify_observers(:status_change, old_status, @status)

        TaskResult.new(
          task_id: @id,
          success: true,
          output: @output
        )
      rescue => e
        @failure = TaskFailure.from_exception(e, {
          agent_id: agent.respond_to?(:id) ? agent.id : nil
        })

        old_status = @status
        @status = :failed

        notify_observers(:status_change, old_status, @status)
        notify_observers(:failure_occurred, @failure)

        # Use secure logging for task failure
        if @failure.respond_to?(:to_secure_hash)
          secure_data = @failure.to_secure_hash
          Agentic.logger.error("Task execution failed: #{secure_data[:message]}")
          Agentic.logger.debug("Task failure context: #{secure_data[:context]}") if secure_data[:context]
        else
          safe_message = Security::Config.sanitizer.sanitize_error("Task execution failed: #{e.message}")
          Agentic.logger.error(safe_message)
        end

        TaskResult.new(
          task_id: @id,
          success: false,
          failure: @failure
        )
      end
    end

    # Retries a failed task
    # @param agent [Agent] The agent that will execute this task
    # @return [TaskResult] The result of the task execution
    # @raise [StandardError] If the task is not in a failed state
    def retry(agent)
      raise "Cannot retry a task that is not in a failed state" unless @status == :failed

      old_status = @status
      @status = :retrying

      notify_observers(:status_change, old_status, @status)

      perform(agent)
    end

    # Returns a serializable representation of the task
    # @return [Hash] The task as a hash
    def to_h
      hash = {
        id: @id,
        description: @description,
        agent_spec: @agent_spec.is_a?(AgentSpecification) ? @agent_spec.to_h : @agent_spec,
        input: @input,
        output: @output,
        status: @status,
        failure: @failure&.to_h
      }

      # Include workspace info if present
      if has_workspace?
        hash[:workspace] = {
          id: @workspace.id,
          path: @workspace.path,
          artifact_count: @workspace.artifact_count,
          persistent: @workspace.metadata[:persistent]
        }
      end

      hash
    end

    # Returns the output schema for this task
    # @return [Agentic::StructuredOutputs::Schema, nil] The schema or nil if none specified
    def output_schema
      return nil unless @output_schema_name
      TaskOutputSchemas.get(@output_schema_name)
    end

    # Checks if this task has a structured output schema
    # @return [Boolean] True if task has an output schema
    def has_output_schema?
      !@output_schema_name.nil? && TaskOutputSchemas.exists?(@output_schema_name)
    end

    # Sets the output schema for this task
    # @param schema_name [Symbol] The name of the schema to use
    def set_output_schema(schema_name)
      @output_schema_name = schema_name
    end

    # Checks if this task has a workspace for file generation
    # @return [Boolean] True if task has a workspace
    def has_workspace?
      !@workspace.nil?
    end

    # Checks if this task requires artifact generation
    # @return [Boolean] True if artifact_mode is enabled or task has a workspace
    def requires_artifacts?
      @artifact_mode || has_workspace?
    end

    # Gets the workspace path for agent to use
    # @return [String, nil] The workspace path or nil if no workspace
    def workspace_path
      @workspace&.path
    end

    # Cleans up the workspace if it's not persistent
    # @return [Boolean] True if cleanup occurred, false if skipped
    def cleanup_workspace
      return false unless has_workspace?
      return false if @workspace.metadata[:persistent]

      @workspace.cleanup
    end

    # Determines if workspace should be automatically cleaned up
    # @return [Boolean] True if workspace should be cleaned up
    def should_cleanup_workspace?
      has_workspace? && status == :completed && !@workspace.metadata[:persistent]
    end

    private

    # Builds the prompt to be sent to the agent
    # @return [String] The formatted prompt
    def build_prompt
      output_requirements = if has_output_schema?
        "Provide your response as a structured JSON object that follows the specified schema. Do not include any markdown formatting, code blocks, or additional text - just the raw JSON."
      else
        "Provide your response as valid JSON only. Do not wrap the JSON in markdown code blocks or any other formatting. Return raw JSON that can be parsed directly."
      end

      <<~PROMPT
        [System Instructions]
        #{agent_spec.instructions}
        
        [Task Description]
        #{description}
        
        [Input Parameters]
        #{JSON.pretty_generate(input)}
        
        [Output Requirements]
        #{output_requirements}
      PROMPT
    end
  end
end
