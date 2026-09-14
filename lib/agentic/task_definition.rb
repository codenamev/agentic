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
  class TaskDefinition
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

    # Initializes a new task definition
    # @param description [String] A description of the task
    # @param agent [AgentSpecification] The agent specification for this task
    # @param id [String, nil] Plan-local id other tasks may reference
    # @param depends_on [Array<String>] Plan-local ids this task runs after
    # @param needs [Hash{String=>String}] Named inputs mapped to upstream plan-local ids
    def initialize(description:, agent:, id: nil, depends_on: [], needs: {})
      @description = description
      @agent = agent
      @id = id&.to_s
      @depends_on = Array(depends_on).map(&:to_s)
      @needs = (needs || {}).to_h { |name, dep| [name.to_s, dep.to_s] }
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
        needs: hash["needs"] || {}
      )
    end
  end
end
