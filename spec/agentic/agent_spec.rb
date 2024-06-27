# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::Agent do
  describe ".build" do
    it "configures and builds an agent with default values" do
      agent = Agentic::Agent.build

      expect(agent.role).to be_nil
      expect(agent.purpose).to be_nil
      expect(agent.backstory).to be_nil
      expect(agent.tools).to eq(Set.new)
    end

    it "configures and builds an agent with custom values" do
      agent = Agentic::Agent.build do |builder|
        builder.role = "Custom Role"
        builder.purpose = "Custom Purpose"
        builder.backstory = "Custom Backstory"
        builder.tools = ["Custom Tool"]
      end

      expect(agent.role).to eq("Custom Role")
      expect(agent.purpose).to eq("Custom Purpose")
      expect(agent.backstory).to eq("Custom Backstory")
      expect(agent.tools).to eq(["Custom Tool"])
    end
  end
end
