# frozen_string_literal: true

module Agentic
  # Handles the task planning process for Agentic using LLM
  class TaskPlanner
    # @return [String] The goal to be accomplished
    attr_reader :goal

    # @return [Array<Hash>] The list of tasks to accomplish the goal
    attr_reader :tasks

    # @return [Hash] The expected answer format
    attr_reader :expected_answer

    # @return [LlmConfig] The configuration for the LLM
    attr_reader :llm_config

    # Initializes a new TaskPlanner
    # @param goal [String] The goal to be accomplished
    # @param llm_config [LlmConfig] The configuration for the LLM
    def initialize(goal, llm_config = LlmConfig.new)
      @goal = goal
      @tasks = []
      @expected_answer = {}
      @llm_config = llm_config
    end

    # Analyzes the goal and breaks it down into tasks using LLM
    # @return [void]
    def analyze_goal
      system_message = "You are an expert project planner. Your task is to break down complex goals into actionable tasks."
      user_message = "Goal: #{@goal}\n\nBreak this goal down into a series of tasks. For each task:\n1. Specify the type of agent best suited to complete it.\n2. Include a brief description of the agent\n3. Include a set of instructions that the agent can follow to perform this task."

      schema = StructuredOutputs::Schema.new("tasks") do |s|
        s.array :tasks, items: {
          type: "object",
          properties: {
            description: {type: "string"},
            agent: {
              type: "object",
              properties: {
                name: {type: "string"},
                description: {type: "string"},
                instructions: {type: "string"}
              },
              required: %w[name description instructions]
            }
          },
          required: %w[description agent]
        }
      end

      response = llm_request(system_message, user_message, schema)
      @tasks = response[:content]["tasks"]
    end

    # Determines the expected answer format using LLM
    # @return [void]
    def determine_expected_answer
      system_message = "You are an expert in report structuring and formatting. Your task is to determine the best format for a given report goal."
      user_message = "Goal: #{@goal}\n\nDetermine the optimal format, sections, and length for a report addressing this goal."

      schema = StructuredOutputs::Schema.new("answer_format") do |s|
        s.string :format
        s.array :sections, items: {type: "string"}
        s.string :length
      end

      response = llm_request(system_message, user_message, schema)
      @expected_answer = response[:content]
    end

    # Displays the execution plan
    # @return [String] The formatted execution plan
    def display_plan
      plan = "Execution Plan:\n\n"
      @tasks.each_with_index do |task, index|
        plan += "#{index + 1}. #{task["description"]} (Agent: #{task["agent"].inspect})\n"
      end
      plan += "\nExpected Answer:\n"
      plan += "Format: #{@expected_answer["format"]}\n"
      plan += "Sections: #{@expected_answer["sections"].join(", ")}\n"
      plan += "Length: #{@expected_answer["length"]}\n"
      plan
    end

    # Executes the entire planning process
    # @return [String] The formatted execution plan
    def plan
      analyze_goal
      determine_expected_answer
      display_plan
    end

    private

    # Makes a request to the LLM
    # @param system_message [String] The system message for the LLM
    # @param user_message [String] The user message for the LLM
    # @param schema [StructuredOutputs::Schema] The schema for structured output
    # @return [Hash] The LLM's response
    def llm_request(system_message, user_message, schema)
      messages = [
        {role: "system", content: system_message},
        {role: "user", content: user_message}
      ]
      llm_client.complete(messages, output_schema: schema)
    end

    def llm_client
      @llm_client ||= Agentic.client(@llm_config)
    end
  end
end
