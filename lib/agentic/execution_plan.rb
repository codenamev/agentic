# frozen_string_literal: true

module Agentic
  # Value object representing an execution plan with tasks and expected answer
  #
  # This class is part of the data-presentation separation pattern:
  # 1. TaskPlanner generates the core plan data
  # 2. ExecutionPlan serves as a structured value object to hold this data
  # 3. The to_s method provides presentation capabilities when needed
  #
  # Using a value object instead of raw hashes provides:
  # - Type safety
  # - Domain-specific methods
  # - Encapsulation of presentation logic
  # - Clearer interfaces between components
  #
  # Tasks may declare a dependency graph through their plan-local ids
  # (see TaskDefinition#depends_on and #needs). The plan itself is the
  # wire format for that graph, so it is also where the graph is checked:
  # {#validate!} rejects duplicate ids, references to ids no task carries,
  # and cycles, before any task reaches an orchestrator.
  class ExecutionPlan
    # Raised by {#validate!} when the plan's dependency graph cannot run
    class InvalidPlanError < ArgumentError; end

    # @return [Array<TaskDefinition>] The list of tasks to accomplish the goal
    attr_reader :tasks

    # @return [ExpectedAnswerFormat] The expected answer format
    attr_reader :expected_answer

    # @param tasks [Array<TaskDefinition>] The list of tasks to accomplish the goal
    # @param expected_answer [ExpectedAnswerFormat] The expected answer format
    def initialize(tasks, expected_answer)
      @tasks = tasks
      @expected_answer = expected_answer
    end

    # Rebuilds a plan from its hash form (as produced by {#to_h}, or parsed
    # from the JSON that `agentic plan` writes). Accepts string or symbol
    # keys at the top level; task hashes use string keys as TaskDefinition
    # does. Tasks without graph fields load as flat, so older plan files
    # remain valid.
    # @param hash [Hash] The hash representation
    # @return [ExecutionPlan] A new execution plan
    def self.from_hash(hash)
      tasks = Array(hash["tasks"] || hash[:tasks]).map { |task| TaskDefinition.from_hash(task) }
      answer = hash["expected_answer"] || hash[:expected_answer]
      new(tasks, ExpectedAnswerFormat.from_hash(answer))
    end

    # Checks that the dependency graph the tasks declare can actually be
    # scheduled: every referenced id names exactly one task, no task
    # depends on itself, and no cycle exists. Flat plans pass trivially.
    # @return [self]
    # @raise [InvalidPlanError] Naming every offending task and what is wrong with it
    def validate!
      errors = []

      ids = @tasks.filter_map(&:id)
      duplicates = ids.tally.select { |_, count| count > 1 }.keys
      errors << "duplicate task id(s): #{duplicates.join(", ")}" if duplicates.any?

      known = ids.uniq
      @tasks.each do |task|
        unknown = task.dependencies.reject { |dep| known.include?(dep) }
        next if unknown.empty?

        diagnosed = unknown.map { |dep| "#{dep}#{Suggestions.hint(dep, known)}" }
        errors << "#{label(task)} depends on unknown task(s) #{diagnosed.join(", ")}"
      end

      @tasks.each do |task|
        errors << "#{label(task)} depends on itself" if task.id && task.dependencies.include?(task.id)
      end

      if errors.empty?
        stuck = unrunnable_tasks
        errors << "dependency cycle leaves task(s) unrunnable: #{stuck.map { |t| label(t) }.join(", ")}" if stuck.any?
      end

      raise InvalidPlanError, errors.join("; ") if errors.any?

      self
    end

    # @return [Boolean] Whether {#validate!} would pass
    def valid?
      validate!
      true
    rescue InvalidPlanError
      false
    end

    # Returns a hash representation of the execution plan
    # @return [Hash] The execution plan as a hash
    def to_h
      {
        tasks: @tasks.map(&:to_h),
        expected_answer: @expected_answer.to_h
      }
    end

    # Returns a formatted string representation of the execution plan
    # @return [String] The formatted execution plan
    def to_s
      plan = "Execution Plan:\n\n"
      @tasks.each_with_index do |task, index|
        line = "#{index + 1}. #{task.description} (Agent: #{task.agent.name})"
        line += " [#{task.id}]" if task.id
        line += " (after: #{task.dependencies.join(", ")})" unless task.dependencies.empty?
        plan += "#{line}\n"
      end
      plan += "\nExpected Answer:\n"
      plan += "Format: #{@expected_answer.format}\n"
      plan += "Sections: #{@expected_answer.sections.join(", ")}\n"
      plan += "Length: #{@expected_answer.length}\n"
      plan
    end

    private

    # Human-readable handle for error messages: the id when there is one,
    # otherwise the description
    def label(task)
      task.id || task.description
    end

    # Kahn's algorithm over the tasks; whatever never becomes ready sits
    # on a cycle. Mirrors PlanOrchestrator#kahn_order so the plan rejects
    # exactly the graphs the orchestrator would refuse to execute.
    # Only called once ids are known unique and every reference resolves.
    def unrunnable_tasks
      by_id = @tasks.select(&:id).to_h { |task| [task.id, task] }
      remaining = by_id.transform_values { |task| task.dependencies.dup }
      ready = remaining.select { |_, deps| deps.empty? }.keys
      done = []

      until ready.empty?
        current = ready.shift
        done << current
        remaining.each do |candidate, deps|
          next unless deps.delete(current)

          ready << candidate if deps.empty? && !done.include?(candidate)
        end
      end

      (by_id.keys - done).map { |id| by_id[id] }
    end
  end
end
