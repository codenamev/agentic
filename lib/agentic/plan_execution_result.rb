# frozen_string_literal: true

module Agentic
  # Value object representing the execution result of a plan
  class PlanExecutionResult
    # @return [String] The unique identifier for the plan
    attr_reader :plan_id

    # @return [Symbol] The overall status of the plan (:completed, :in_progress, :partial_failure)
    attr_reader :status

    # @return [Float] The execution time in seconds
    attr_reader :execution_time

    # @return [Hash] Map of task ids to serialized Task objects
    attr_reader :tasks

    # @return [Hash<String, TaskExecutionResult>] The execution results for each task
    attr_reader :results

    # Initializes a new plan execution result
    # @param plan_id [String] The unique identifier for the plan
    # @param status [Symbol] The overall status of the plan
    # @param execution_time [Float] The execution time in seconds
    # @param tasks [Hash] Map of task ids to serialized Task objects
    # @param results [Hash] Map of task ids to raw execution results
    def initialize(plan_id:, status:, execution_time:, tasks:, results:)
      @plan_id = plan_id
      @status = status
      @execution_time = execution_time
      @tasks = tasks
      @results = convert_raw_results(results)
    end

    # Creates a plan execution result from a hash
    # @param hash [Hash] The hash representation of a plan execution result
    # @return [PlanExecutionResult] A plan execution result
    def self.from_hash(hash)
      new(
        plan_id: hash[:plan_id],
        status: hash[:status],
        execution_time: hash[:execution_time],
        tasks: hash[:tasks],
        results: hash[:results]
      )
    end

    # Checks if the plan execution was successful
    # @return [Boolean] True if successful, false otherwise
    def successful?
      @status == :completed
    end

    # Checks if the plan execution failed partially
    # @return [Boolean] True if partially failed, false otherwise
    def partial_failure?
      @status == :partial_failure
    end

    # Checks if the plan execution is still in progress
    # @return [Boolean] True if in progress, false otherwise
    def in_progress?
      @status == :in_progress
    end

    # Gets the result for a specific task
    # @param task_id [String] The ID of the task
    # @return [TaskExecutionResult, nil] The execution result for the task, or nil if not found
    def task_result(task_id)
      @results[task_id]
    end

    # Gets the serialized task data for a specific task
    # @param task_id [String] The ID of the task
    # @return [Hash, nil] The serialized task data, or nil if not found
    def task_data(task_id)
      @tasks[task_id]
    end

    # Gets the number of completed tasks
    # @return [Integer] The number of completed tasks
    def completed_tasks_count
      @results.count { |_, result| result.successful? }
    end

    # Gets the number of failed tasks
    # @return [Integer] The number of failed tasks
    def failed_tasks_count
      @results.count { |_, result| result.failed? }
    end

    # Gets the number of tasks skipped because a dependency failed
    # @return [Integer] The number of skipped tasks
    def skipped_tasks_count
      @results.count { |_, result| result.skipped? }
    end

    # Gets the successful task results
    # @return [Hash<String, TaskExecutionResult>] The successful task results
    def successful_task_results
      @results.select { |_, result| result.successful? }
    end

    # Gets the failed task results
    # @return [Hash<String, TaskExecutionResult>] The failed task results
    def failed_task_results
      @results.select { |_, result| result.failed? }
    end

    # Gets the results of tasks skipped because a dependency failed
    # @return [Hash<String, TaskExecutionResult>] The skipped task results
    def skipped_task_results
      @results.select { |_, result| result.skipped? }
    end

    # Returns a hash representation of the plan execution result
    # @return [Hash] The plan execution result as a hash
    def to_h
      {
        plan_id: @plan_id,
        status: @status,
        execution_time: @execution_time,
        tasks: @tasks,
        results: @results.transform_values(&:to_h)
      }
    end

    private

    # Converts raw results to TaskExecutionResult objects
    # @param raw_results [Hash] Map of task ids to raw execution results
    # @return [Hash<String, TaskExecutionResult>] The converted results
    def convert_raw_results(raw_results)
      raw_results.transform_values do |result|
        result.is_a?(TaskExecutionResult) ? result : TaskExecutionResult.from_hash(result)
      end
    end
  end
end
