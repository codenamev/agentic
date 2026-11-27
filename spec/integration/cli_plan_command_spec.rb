# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe "CLI plan command integration", :vcr do
  let(:output) { StringIO.new }

  # Cassette was recorded on the legacy ruby-openai transport.
  before { allow(Agentic.configuration).to receive(:llm_backend).and_return(:openai) }

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

      # Set up VCR to record the API call
      VCR.use_cassette("plan_ruby_coding_agent") do
        # Execute the plan command
        Agentic::CLI.start(["plan", "Create a Ruby coding agent"])
      end

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

        # Set up VCR to record the API call
        VCR.use_cassette("plan_ruby_coding_agent") do
          # Execute the plan command with save option
          Agentic::CLI.start(["plan", "Create a Ruby coding agent", "--save=#{file_path}", "--output=json"])
        end

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

      # Set up VCR to record the API call
      VCR.use_cassette("plan_ruby_coding_agent") do
        # Execute the plan command with JSON output
        Agentic::CLI.start(["plan", "Create a Ruby coding agent", "--output=json"])
      end

      # Verify output includes JSON markers
      expect(output.string).to include('"tasks":')
      expect(output.string).to include('"expected_answer":')
    end
  end
end
