# frozen_string_literal: true

module Agentic
  # Value object representing a task definition
  #
  # A definition may carry a plan-local +id+ so that other definitions in
  # the same plan can name it in +depends_on+ (plain ordering) or +needs+
  # (named output wiring, +{"findings" => "research"}+). Ids are labels
  # scoped to the plan document; the orchestrator assigns its own runtime
  # ids when definitions become tasks. All three fields are optional, so a
  # flat plan with none of them is unchanged in shape and behavior.
  #
  # +on_failure+ says what the graph does when this task fails for good:
  # +"skip_dependents"+ (default) skips everything downstream, +"continue"+
  # lets dependents run and read the failure via +Task#failure_of+.
  class TaskDefinition
    # Accepted on_failure policies, as strings because plans are JSON
    ON_FAILURE_POLICIES = %w[skip_dependents continue].freeze

    # @return [String] A description of the task
    attr_reader :description

    # @return [AgentSpecification] The agent specification for this task
    attr_reader :agent

    # @return [String, nil] Plan-local id other tasks may reference
    attr_reader :id

    # @return [Array<String>] Plan-local ids this task runs after
    attr_reader :depends_on

    # @return [Hash{String=>String}] Named inputs mapped to the plan-local id whose output supplies them
    attr_reader :needs

    # @return [String] What dependents do when this task fails terminally
    attr_reader :on_failure

    # Initializes a new task definition
    # @param description [String] A description of the task
    # @param agent [AgentSpecification] The agent specification for this task
    # @param id [String, nil] Plan-local id other tasks may reference
    # @param depends_on [Array<String>] Plan-local ids this task runs after
    # @param needs [Hash{String=>String}] Named inputs mapped to upstream plan-local ids
    # @param on_failure [String, Symbol, nil] "skip_dependents" (default) or "continue"
    # @raise [ArgumentError] If on_failure is not a known policy
    def initialize(description:, agent:, id: nil, depends_on: [], needs: {}, on_failure: nil)
      @description = description
      @agent = agent
      @id = id&.to_s
      @depends_on = Array(depends_on).map(&:to_s)
      @needs = (needs || {}).to_h { |name, dep| [name.to_s, dep.to_s] }
      @on_failure = (on_failure || "skip_dependents").to_s
      unless ON_FAILURE_POLICIES.include?(@on_failure)
        raise ArgumentError, "on_failure must be one of #{ON_FAILURE_POLICIES.join(", ")}, got #{@on_failure.inspect}"
      end
    end

    # Whether dependents should run even if this task fails terminally
    # @return [Boolean]
    def continue_on_failure?
      @on_failure == "continue"
    end

    # Every upstream id this task references, whether by ordering or by wiring
    # @return [Array<String>] Unique plan-local ids
    def dependencies
      @depends_on | @needs.values
    end

    # Builds an executable Task from this definition
    # @param input [Hash] Input data for the task
    # @param payload [Object, nil] Arbitrary domain data for the executing agent
    # @return [Task] A new task ready for the orchestrator
    def to_task(input: {}, payload: nil)
      Task.new(description: description, agent_spec: agent, input: input, payload: payload)
    end

    # Returns a serializable representation of the task definition.
    # Graph fields are emitted only when set, so flat plans serialize
    # exactly as they did before these fields existed.
    # @return [Hash] The task definition as a hash
    def to_h
      hash = {
        "description" => @description,
        "agent" => @agent.to_h
      }
      hash["id"] = @id if @id
      hash["depends_on"] = @depends_on.dup unless @depends_on.empty?
      hash["needs"] = @needs.dup unless @needs.empty?
      hash["on_failure"] = @on_failure if continue_on_failure?
      hash
    end

    # Creates a TaskDefinition from a hash. Missing graph fields read as
    # a task with no dependencies, so plans written before they existed
    # load unchanged.
    # @param hash [Hash] The hash representation
    # @return [TaskDefinition] A new task definition
    def self.from_hash(hash)
      new(
        description: hash["description"],
        agent: AgentSpecification.from_hash(hash["agent"]),
        id: hash["id"],
        depends_on: hash["depends_on"] || [],
        needs: hash["needs"] || {},
        on_failure: hash["on_failure"]
      )
    end
  end
end
