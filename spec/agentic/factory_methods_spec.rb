# frozen_string_literal: true

require "rspec"
require_relative "../support/mock_agent"

RSpec.describe Agentic::FactoryMethods do
  describe ".build" do
    it "configures and builds an agent with default values" do
      agent = Agentic::MockAgent.build

      expect(agent.role).to eq("Mock")
      expect(agent.goal).to eq("Default Goal")
      expect(agent.backstory).to eq("Default Backstory")
    end

    it "configures and builds an agent with custom values" do
      agent = Agentic::MockAgent.build do |builder|
        builder.role = "Custom Role"
        builder.goal = "Custom Goal"
        builder.backstory = "Custom Backstory"
      end

      expect(agent.role).to eq("Custom Role")
      expect(agent.goal).to eq("Custom Goal")
      expect(agent.backstory).to eq("Custom Backstory")
    end
  end
end
