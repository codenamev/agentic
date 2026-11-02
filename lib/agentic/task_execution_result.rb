# frozen_string_literal: true

module Agentic
  # Value object representing the execution result of a task
  class TaskExecutionResult
    # @return [Symbol] The status of the task execution (:completed, :failed, :canceled, :skipped)
    attr_reader :status

    # @return [Hash, nil] The output produced by the task (only if successful)
    attr_reader :output

    # @return [TaskFailure, nil] The failure details (if failed, or why the task was skipped)
    attr_reader :failure

    # @param status [Symbol] The status of the task execution
    # @param output [Hash, nil] The output produced by the task
    # @param failure [TaskFailure, nil] The failure details
    def initialize(status:, output: nil, failure: nil)
      @status = status
      @output = output
      @failure = failure
    end

    # Creates a successful execution result
    # @param output [Hash] The task output
    # @return [TaskExecutionResult] A successful execution result
    def self.success(output)
      new(status: :completed, output: output)
    end

    # Creates a failed execution result
    # @param failure [TaskFailure] The failure details
    # @return [TaskExecutionResult] A failed execution result
    def self.failure(failure)
      new(status: :failed, failure: failure)
    end

    # Creates a canceled execution result
    # @return [TaskExecutionResult] A canceled execution result
    def self.canceled
      new(status: :canceled)
    end

    # Creates a skipped execution result - the task never ran because a
    # dependency failed. The failure names that dependency.
    # @param failure [TaskFailure] Why the task was skipped
    # @return [TaskExecutionResult] A skipped execution result
    def self.skipped(failure)
      new(status: :skipped, failure: failure)
    end

    # Creates a task execution result from a hash
    # @param hash [Hash] The hash representation of a task execution result
    # @return [TaskExecutionResult] A task execution result
    def self.from_hash(hash)
      # Handle the case where hash is not actually a hash (could be nil, Integer, etc.)
      return new(status: :completed) unless hash.is_a?(Hash)

      # Convert string keys to symbols if necessary
      hash = hash.transform_keys(&:to_sym) if hash.keys.first.is_a?(String)

      failure = hash[:failure] ? TaskFailure.from_hash(hash[:failure]) : nil
      new(
        status: hash[:status] || :completed,
        output: hash[:output],
        failure: failure
      )
    end

    # Checks if the task execution was successful
    # @return [Boolean] True if successful, false otherwise
    def successful?
      @status == :completed
    end

    # Checks if the task execution failed
    # @return [Boolean] True if failed, false otherwise
    def failed?
      @status == :failed
    end

    # Checks if the task execution was canceled
    # @return [Boolean] True if canceled, false otherwise
    def canceled?
      @status == :canceled
    end

    # Checks if the task was skipped because a dependency failed
    # @return [Boolean] True if skipped, false otherwise
    def skipped?
      @status == :skipped
    end

    # Returns a hash representation of the execution result
    # @return [Hash] The execution result as a hash
    def to_h
      {
        status: @status,
        output: @output,
        failure: @failure&.to_h
      }
    end
  end
end
