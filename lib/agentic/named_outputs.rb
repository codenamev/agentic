# frozen_string_literal: true

module Agentic
  # Dependency outputs addressed by the name the consumer chose, not by
  # task id. Built by the orchestrator for tasks added with `needs:`:
  #
  #   orchestrator.add_task(digest, needs: {shipped: commits, owed: debt})
  #   # inside the agent:
  #   task.needs.shipped   # or task.needs[:shipped]
  class NamedOutputs
    def initialize
      @outputs = {}
      @failures = {}
    end

    # Assigns a named output (called by the orchestrator)
    # @param name [Symbol, String] The name declared in needs:
    # @param value [Object] The dependency's output
    def []=(name, value)
      @outputs[name.to_sym] = value
    end

    # @param name [Symbol, String] The declared name
    # @return [Object, nil] The named dependency's output
    def [](name)
      @outputs[name.to_sym]
    end

    # @param name [Symbol, String] The declared name
    # @return [Boolean] True when the named output has been assigned
    def key?(name)
      @outputs.key?(name.to_sym)
    end

    # @return [Hash{Symbol=>Object}] A copy of all named outputs
    def to_h
      @outputs.dup
    end

    # Records a named dependency's failure when the graph continued past
    # it (called by the orchestrator for on_failure: :continue)
    # @param name [Symbol, String] The declared name
    # @param failure [TaskFailure] The dependency's failure
    # @return [void]
    def record_failure(name, failure)
      @failures[name.to_sym] = failure
    end

    # @param name [Symbol, String] The declared name
    # @return [Boolean] True when the named dependency produced an output
    def succeeded?(name)
      @outputs.key?(name.to_sym)
    end

    # @param name [Symbol, String] The declared name
    # @return [TaskFailure, nil] The named dependency's failure, if it was tolerated
    def failure_of(name)
      @failures[name.to_sym]
    end

    # Named outputs read as methods: task.needs.shipped
    def method_missing(name, *args)
      return @outputs[name] if args.empty? && @outputs.key?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      @outputs.key?(name) || super
    end
  end
end
