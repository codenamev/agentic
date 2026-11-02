# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::Capabilities::FileGenerationCapability do
  let(:workspace_path) { "/tmp/agentic_filegen_#{SecureRandom.hex(8)}" }
  let(:workspace) { Agentic::Workspace.new(workspace_path) }

  after do
    FileUtils.rm_rf(workspace_path) if Dir.exist?(workspace_path)
  end

  def agent_returning(artifacts)
    agent = instance_double("Agentic::Agent")
    allow(agent).to receive(:execute_with_workspace)
      .and_return(JSON.generate("artifacts" => artifacts))
    agent
  end

  describe ".execute" do
    it "fails closed when the workspace rejects an artifact" do
      agent = agent_returning([
        {"name" => "notes.md", "content" => "# Notes"},
        {"name" => "../escape.md", "content" => "# Escape"}
      ])

      expect {
        described_class.execute(
          agent: agent,
          inputs: {workspace: workspace, task_description: "Write two files"}
        )
      }.to raise_error(SecurityError, /path traversal/)

      expect(File).not_to exist(File.expand_path("../escape.md", workspace_path))
    end

    it "skips an artifact that fails for a non-security reason and keeps the rest" do
      agent = agent_returning([
        {"name" => "notes.md", "content" => "# Notes"},
        {"name" => "broken.md", "content" => "# Broken"},
        {"name" => "README.md", "content" => "# Readme"}
      ])
      allow(workspace).to receive(:add_artifact).and_call_original
      allow(workspace).to receive(:add_artifact)
        .with(have_attributes(name: "broken.md"))
        .and_raise(StandardError, "disk full")
      allow(Agentic.logger).to receive(:error)

      result = described_class.execute(
        agent: agent,
        inputs: {workspace: workspace, task_description: "Write three files"}
      )

      expect(result[:success]).to be(true)
      expect(result[:artifacts].map { |a| a[:name] }).to eq(["notes.md", "README.md"])
      expect(Agentic.logger).to have_received(:error).with(/disk full/)
    end
  end
end
