# frozen_string_literal: true

module Agentic
  class Agent
    include FactoryMethods

    configurable :role, :purpose, :backstory, :tools

    assembly do |agent|
      agent.tools ||= Set.new
    end

    def execute(task)
      task.perform(self)
    end
  end
end
