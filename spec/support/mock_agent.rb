# frozen_string_literal: true

module Agentic
  class MockAgent
    include FactoryMethods

    configurable :role, :goal, :backstory

    assembly do |agent|
      agent.role ||= "Mock"
      agent.goal ||= "Default Goal"
      agent.backstory ||= "Default Backstory"
    end

    def execute(task)
      task.perform(self)
    end
  end
end
