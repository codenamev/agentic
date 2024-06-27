# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::TaskPlanner do
  let(:goal) { "Generate a market research report on the latest trends in AI technology." }
  let(:llm_config) { Agentic::LlmConfig.new }
  let(:planner) { described_class.new(goal, llm_config) }

  describe "#initialize" do
    it "sets the goal and llm_config" do
      expect(planner.goal).to eq(goal)
      expect(planner.llm_config).to eq(llm_config)
    end

    it "initializes tasks and expected_answer as empty" do
      expect(planner.tasks).to be_empty
      expect(planner.expected_answer).to be_empty
    end
  end

  describe "#plan" do
    before do
      allow_any_instance_of(Agentic::LlmClient).to receive(:complete).and_return(
        content: {
          "tasks" => [{"description" => "Research AI trends", "agent_type" => "ResearchAgent"}],
          "format" => "PDF",
          "sections" => ["Summary", "Trends"],
          "length" => "10 pages"
        }
      )
    end

    it "generates tasks and expected answer" do
      plan = planner.plan
      expect(planner.tasks).not_to be_empty
      expect(planner.expected_answer).not_to be_empty
      expect(plan).to include("Research AI trends")
      expect(plan).to include("Format: PDF")
      expect(plan).to include("Sections: Summary, Trends")
      expect(plan).to include("Length: 10 pages")
    end
  end

  describe "#analyze_goal" do
    it "uses LLM to generate tasks" do
      expect_any_instance_of(Agentic::LlmClient).to receive(:complete).and_return(
        {content: {"tasks" => [{"description" => "Research AI trends", "agent_type" => "ResearchAgent"}]}}
      )
      planner.analyze_goal
      expect(planner.tasks).to eq([{"description" => "Research AI trends", "agent_type" => "ResearchAgent"}])
    end
  end

  describe "#determine_expected_answer" do
    it "uses LLM to determine expected answer format" do
      expect_any_instance_of(Agentic::LlmClient).to receive(:complete).and_return(
        {content: {"format" => "PDF", "sections" => ["Summary", "Trends"], "length" => "10 pages"}}
      )
      planner.determine_expected_answer
      expect(planner.expected_answer).to eq({"format" => "PDF", "sections" => ["Summary", "Trends"], "length" => "10 pages"})
    end
  end
end
