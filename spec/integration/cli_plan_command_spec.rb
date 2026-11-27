# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe "CLI plan command integration", :vcr do
  let(:output) { StringIO.new }

  # The cassette was recorded against /v1/chat/completions by ruby-openai;
  # RubyLLM's OpenAI provider calls /v1/responses, so HTTP replay can't
  # match. Feed the recorded completion bodies through the adapter instead:
  # the CLI, planner and LlmClient still run end to end on real model output.
  before do
    cassette = YAML.safe_load_file(
      File.expand_path("../vcr_cassettes/plan_ruby_coding_agent.yml", __dir__),
      permitted_classes: [Symbol], aliases: true
    )
    # ruby-openai recorded each step twice (stream attempt, then the
    # non-streaming fallback); the adapter answers in one call, so dedupe.
    bodies = cassette.fetch("http_interactions").map { |i| JSON.parse(i.dig("response", "body", "string")) }.uniq
    allow_any_instance_of(Agentic::RubyLlmAdapter).to receive(:chat) { bodies.shift || raise("cassette exhausted") }
  end

  # Capture stdout for testing CLI output
  around do |example|
    original_stdout = $stdout
    $stdout = output
    example.run
    $stdout = original_stdout
  end

  describe "agentic plan command" do
    # This is our main end-to-end test for the plan command
    it "creates a plan for building a Ruby coding agent" do
      # Stub check_api_token! to not raise an error
      allow_any_instance_of(Agentic::CLI).to receive(:check_api_token!).and_return(true)

      Agentic::CLI.start(["plan", "Create a Ruby coding agent"])

      # Verify output contains expected elements
      expect(output.string).to include("Creating plan for goal: Create a Ruby coding agent")

      # Verify that the plan contains tasks
      expect(output.string).to include("Tasks:")

      # Verify that agents are assigned to tasks
      expect(output.string).to include("Agent:")

      # Verify that expected answer format is present
      expect(output.string).to include("Expected Answer:")
    end

    it "saves the plan to a file when requested" do
      # Stub check_api_token! to not raise an error
      allow_any_instance_of(Agentic::CLI).to receive(:check_api_token!).and_return(true)

      # Create a temporary file for the test
      require "tempfile"
      temp_file = Tempfile.new(["test_plan", ".json"])
      file_path = temp_file.path
      temp_file.close

      begin
        # Simply expect File.write to be called with the right path
        expect(File).to receive(:write).with(file_path, anything)

        Agentic::CLI.start(["plan", "Create a Ruby coding agent", "--save=#{file_path}", "--output=json"])

        # Verify output indicates the plan was saved
        expect(output.string).to include("Plan saved to #{file_path}")
      ensure
        # Clean up temporary file
        File.unlink(file_path) if File.exist?(file_path)
      end
    end

    it "formats output as JSON when requested" do
      # Stub check_api_token! to not raise an error
      allow_any_instance_of(Agentic::CLI).to receive(:check_api_token!).and_return(true)

      Agentic::CLI.start(["plan", "Create a Ruby coding agent", "--output=json"])

      # Verify output includes JSON markers
      expect(output.string).to include('"tasks":')
      expect(output.string).to include('"expected_answer":')
    end
  end
end
