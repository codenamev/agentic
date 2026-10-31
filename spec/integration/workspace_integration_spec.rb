# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Workspace Integration", :integration do
  let(:temp_dir) { Dir.mktmpdir("workspace_integration_spec") }
  let(:workspace) { Agentic::Workspace.new(temp_dir) }

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  describe "Task with Workspace" do
    it "creates a task with workspace" do
      task = Agentic::Task.new(
        description: "Generate a Ruby class",
        agent_spec: {
          "name" => "Ruby Coder",
          "instructions" => "Generate Ruby code"
        },
        workspace: workspace
      )

      expect(task.has_workspace?).to be true
      expect(task.workspace).to eq(workspace)
      expect(task.workspace_path).to eq(temp_dir)
    end

    it "creates a task without workspace" do
      task = Agentic::Task.new(
        description: "Analyze data",
        agent_spec: {
          "name" => "Data Analyst",
          "instructions" => "Analyze the data"
        }
      )

      expect(task.has_workspace?).to be false
      expect(task.workspace).to be_nil
      expect(task.workspace_path).to be_nil
    end

    it "includes workspace info in to_h when present" do
      task = Agentic::Task.new(
        description: "Generate files",
        agent_spec: {"name" => "Coder"},
        workspace: workspace
      )

      hash = task.to_h
      expect(hash[:workspace]).to be_a(Hash)
      expect(hash[:workspace][:id]).to eq(workspace.id)
      expect(hash[:workspace][:path]).to eq(workspace.path)
    end

    it "does not include workspace info in to_h when absent" do
      task = Agentic::Task.new(
        description: "Analyze",
        agent_spec: {"name" => "Analyst"}
      )

      hash = task.to_h
      expect(hash[:workspace]).to be_nil
    end
  end

  describe "Agent with Workspace Context" do
    let(:agent) do
      Agentic::Agent.new do |a|
        a.role = "Ruby Developer"
        a.purpose = "Generate Ruby code"
      end
    end

    it "builds workspace context for agent" do
      context = agent.send(:build_workspace_context, workspace)

      expect(context).to include("Workspace ID: #{workspace.id}")
      expect(context).to include("Workspace path: #{temp_dir}")
      expect(context).to include("artifacts")
      expect(context).to include("JSON")
    end

    it "execute_with_workspace includes context in prompt" do
      # Mock the execute_prompt method to capture the prompt
      captured_prompt = nil
      allow(agent).to receive(:execute_prompt) do |prompt|
        captured_prompt = prompt
        '{"artifacts": []}'
      end

      agent.execute_with_workspace("Generate a User class", workspace)

      expect(captured_prompt).to include("Workspace Information")
      expect(captured_prompt).to include("Generate a User class")
    end
  end

  describe "Artifact Verification" do
    it "verifies artifacts on add" do
      artifact = Agentic::Artifact.new(
        name: "user.rb",
        type: :ruby_class,
        content: "class User; end"
      )

      expect { workspace.add_artifact(artifact) }.not_to raise_error
      expect(workspace.artifact_count).to eq(1)
    end

    it "raises error for empty artifact content" do
      artifact = Agentic::Artifact.new(
        name: "empty.rb",
        type: :ruby_class,
        content: ""
      )

      expect {
        workspace.add_artifact(artifact)
      }.to raise_error(Agentic::Verification::ArtifactVerificationError, /empty/)
    end

    it "can skip verification if requested" do
      artifact = Agentic::Artifact.new(
        name: "empty.rb",
        type: :ruby_class,
        content: ""
      )

      expect {
        workspace.add_artifact(artifact, verify: false)
      }.not_to raise_error
    end

    it "rejects artifact with invalid encoding" do
      invalid_content = +"class User\n  # \xFF\xFE Invalid UTF-8\nend"
      invalid_content.force_encoding("UTF-8")  # Force UTF-8 on invalid byte sequence

      artifact = Agentic::Artifact.new(
        name: "invalid.rb",
        type: :ruby_class,
        content: invalid_content
      )

      # Security validation catches invalid encoding before verification
      expect {
        workspace.add_artifact(artifact)
      }.to raise_error(SecurityError, /invalid encoding/)
    end
  end

  describe "Verification Strategies" do
    it "uses BasicArtifactVerificationStrategy for unknown types" do
      artifact = Agentic::Artifact.new(
        name: "file.txt",
        type: :unknown,
        content: "Hello world"
      )

      strategy = Agentic::Verification::ArtifactVerificationStrategy.for_type(:unknown)
      expect(strategy).to be_a(Agentic::Verification::BasicArtifactVerificationStrategy)

      result = strategy.verify(artifact)
      expect(result.passed?).to be true
    end

    it "uses RubyArtifactVerificationStrategy for Ruby artifacts" do
      artifact = Agentic::Artifact.new(
        name: "user.rb",
        type: :ruby_class,
        content: "class User; end"
      )

      strategy = Agentic::Verification::ArtifactVerificationStrategy.for_type(:ruby_class)
      expect(strategy).to be_a(Agentic::Verification::RubyArtifactVerificationStrategy)

      result = strategy.verify(artifact)
      expect(result.passed?).to be true
      expect(result.details[:type]).to eq(:ruby_class)
    end

    it "uses JavaScriptArtifactVerificationStrategy for JS artifacts" do
      artifact = Agentic::Artifact.new(
        name: "component.js",
        type: :javascript_module,
        content: "export const Component = () => {}"
      )

      strategy = Agentic::Verification::ArtifactVerificationStrategy.for_type(:javascript_module)
      expect(strategy).to be_a(Agentic::Verification::JavaScriptArtifactVerificationStrategy)

      result = strategy.verify(artifact)
      expect(result.passed?).to be true
    end

    it "uses PythonArtifactVerificationStrategy for Python artifacts" do
      artifact = Agentic::Artifact.new(
        name: "user.py",
        type: :python_module,
        content: "class User:\n    pass"
      )

      strategy = Agentic::Verification::ArtifactVerificationStrategy.for_type(:python_module)
      expect(strategy).to be_a(Agentic::Verification::PythonArtifactVerificationStrategy)

      result = strategy.verify(artifact)
      expect(result.passed?).to be true
    end
  end

  describe "ArtifactVerificationStrategy.for_artifact" do
    it "keys the strategy off the file extension, not the declared type" do
      artifact = Agentic::Artifact.new(
        name: "user.rb",
        type: :markdown,
        content: "class User; end"
      )

      strategy = Agentic::Verification::ArtifactVerificationStrategy.for_artifact(artifact)
      expect(strategy).to be_a(Agentic::Verification::RubyArtifactVerificationStrategy)
    end

    it "does not let a declared code type promote a non-code extension" do
      artifact = Agentic::Artifact.new(
        name: "README.md",
        type: :ruby_class,
        content: "# Readme"
      )

      strategy = Agentic::Verification::ArtifactVerificationStrategy.for_artifact(artifact)
      expect(strategy).to be_a(Agentic::Verification::BasicArtifactVerificationStrategy)
      expect(strategy).not_to be_a(Agentic::Verification::RubyArtifactVerificationStrategy)
    end

    it "is case-insensitive on the extension" do
      artifact = Agentic::Artifact.new(name: "Script.PY", type: :python_module, content: "pass")

      strategy = Agentic::Verification::ArtifactVerificationStrategy.for_artifact(artifact)
      expect(strategy).to be_a(Agentic::Verification::PythonArtifactVerificationStrategy)
    end

    it "warns when the declared type disagrees with the extension" do
      artifact = Agentic::Artifact.new(name: "user.rb", type: :markdown, content: "class User; end")

      expect(Agentic.logger).to receive(:warn).with(/user\.rb declares type :markdown/)
      Agentic::Verification::ArtifactVerificationStrategy.for_artifact(artifact)
    end

    it "stays quiet when a non-code type lands on a non-code extension" do
      artifact = Agentic::Artifact.new(name: "notes.txt", type: :text, content: "hi")

      expect(Agentic.logger).not_to receive(:warn)
      Agentic::Verification::ArtifactVerificationStrategy.for_artifact(artifact)
    end
  end

  describe "FileGenerationCapability" do
    it "validates required inputs" do
      expect {
        Agentic::Capabilities::FileGenerationCapability.validate_inputs({})
      }.to raise_error(ArgumentError, /task_description/)
    end

    it "validates workspace input type" do
      expect {
        Agentic::Capabilities::FileGenerationCapability.validate_inputs({
          task_description: "Generate code",
          workspace: "not a workspace"
        })
      }.to raise_error(ArgumentError, /Workspace instance/)
    end

    it "builds file generation prompt with task description" do
      prompt = Agentic::Capabilities::FileGenerationCapability.build_file_generation_prompt(
        "Create a User class",
        {}
      )

      expect(prompt).to include("Create a User class")
      expect(prompt).to include("artifacts")
      expect(prompt).to include("JSON")
    end

    it "includes constraints in prompt" do
      prompt = Agentic::Capabilities::FileGenerationCapability.build_file_generation_prompt(
        "Create files",
        {max_files: 5, allowed_types: [:ruby_class]}
      )

      expect(prompt).to include("Constraints")
      expect(prompt).to include("max_files")
      expect(prompt).to include("allowed_types")
    end

    it "parses artifact descriptions from JSON response" do
      response = <<~JSON
        {
          "artifacts": [
            {
              "name": "user.rb",
              "type": "ruby_class",
              "content": "class User; end"
            }
          ]
        }
      JSON

      descriptions = Agentic::Capabilities::FileGenerationCapability.parse_artifact_descriptions(response)
      expect(descriptions).to be_an(Array)
      expect(descriptions.size).to eq(1)
      expect(descriptions.first["name"]).to eq("user.rb")
    end

    it "extracts JSON from markdown code blocks" do
      response = <<~MD
        ```json
        {
          "artifacts": []
        }
        ```
      MD

      json = Agentic::Capabilities::FileGenerationCapability.extract_json(response)
      expect(json).not_to include("```")
      expect(json).to include('"artifacts"')
    end

    it "creates artifact from description" do
      desc = {
        "name" => "user.rb",
        "type" => "ruby_class",
        "content" => "class User; end",
        "references" => ["base.rb"]
      }

      artifact = Agentic::Capabilities::FileGenerationCapability.create_artifact_from_description(desc)

      expect(artifact.name).to eq("user.rb")
      expect(artifact.type).to eq(:ruby_class)
      expect(artifact.content).to eq("class User; end")
      expect(artifact.references).to eq(["base.rb"])
    end

    it "infers type from filename" do
      expect(Agentic::Capabilities::FileGenerationCapability.infer_type_from_name("file.rb")).to eq(:ruby_class)
      expect(Agentic::Capabilities::FileGenerationCapability.infer_type_from_name("file.js")).to eq(:javascript_module)
      expect(Agentic::Capabilities::FileGenerationCapability.infer_type_from_name("file.py")).to eq(:python_module)
      expect(Agentic::Capabilities::FileGenerationCapability.infer_type_from_name("file.json")).to eq(:json)
      expect(Agentic::Capabilities::FileGenerationCapability.infer_type_from_name("file.md")).to eq(:markdown)
      expect(Agentic::Capabilities::FileGenerationCapability.infer_type_from_name("file.unknown")).to eq(:text)
    end
  end

  describe "Full Integration Flow" do
    it "completes end-to-end file generation workflow" do
      # Create agent with mocked LLM response
      agent = Agentic::Agent.new do |a|
        a.role = "Ruby Developer"
        a.purpose = "Generate Ruby code"
        a.instructions = "Create clean, well-documented Ruby code"
      end

      # Mock execute_prompt to return artifact JSON
      allow(agent).to receive(:execute_prompt).and_return(
        <<~JSON
          {
            "artifacts": [
              {
                "name": "models/user.rb",
                "type": "ruby_class",
                "content": "class User\\n  attr_accessor :name, :email\\n\\n  def initialize(name:, email:)\\n    @name = name\\n    @email = email\\n  end\\nend"
              },
              {
                "name": "models/post.rb",
                "type": "ruby_class",
                "content": "class Post\\n  attr_accessor :title, :content\\nend"
              }
            ]
          }
        JSON
      )

      # Execute capability
      result = Agentic::Capabilities::FileGenerationCapability.execute(
        agent: agent,
        inputs: {
          task_description: "Create User and Post models",
          workspace: workspace
        }
      )

      # Verify results
      expect(result[:success]).to be true
      expect(result[:artifact_count]).to eq(2)
      expect(result[:workspace_id]).to eq(workspace.id)

      # Verify artifacts in workspace
      expect(workspace.artifact_count).to eq(2)
      user_artifact = workspace.find_artifact(name: "models/user.rb")
      expect(user_artifact).not_to be_nil
      expect(user_artifact.type).to eq(:ruby_class)

      # Verify files on disk
      expect(File.exist?(File.join(temp_dir, "models/user.rb"))).to be true
      expect(File.exist?(File.join(temp_dir, "models/post.rb"))).to be true

      user_content = File.read(File.join(temp_dir, "models/user.rb"))
      expect(user_content).to include("class User")
      expect(user_content).to include("attr_accessor")
    end

    it "handles constraint violations" do
      agent = Agentic::Agent.new do |a|
        a.role = "Developer"
      end

      # Mock response with 3 artifacts
      allow(agent).to receive(:execute_prompt).and_return(
        <<~JSON
          {
            "artifacts": [
              {"name": "file1.rb", "type": "ruby_class", "content": "# File 1"},
              {"name": "file2.rb", "type": "ruby_class", "content": "# File 2"},
              {"name": "file3.rb", "type": "ruby_class", "content": "# File 3"}
            ]
          }
        JSON
      )

      # Execute with max_files constraint
      result = Agentic::Capabilities::FileGenerationCapability.execute(
        agent: agent,
        inputs: {
          task_description: "Create files",
          workspace: workspace,
          constraints: {max_files: 2}
        }
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include("max_files constraint")
    end
  end

  describe "Task Workspace Cleanup" do
    it "cleans up non-persistent workspace after completion" do
      task_workspace = Agentic::Workspace.new(File.join(temp_dir, "task_workspace"))
      task = Agentic::Task.new(
        description: "Generate file",
        agent_spec: {"name" => "Coder"},
        workspace: task_workspace
      )

      # Manually set status to completed
      task.instance_variable_set(:@status, :completed)

      expect(task.should_cleanup_workspace?).to be true
      expect(Dir.exist?(task_workspace.path)).to be true

      result = task.cleanup_workspace
      expect(result).to be true
      expect(Dir.exist?(task_workspace.path)).to be false
    end

    it "does not clean up persistent workspace" do
      persistent_workspace = Agentic::Workspace.new(
        File.join(temp_dir, "persistent"),
        persistent: true
      )

      task = Agentic::Task.new(
        description: "Generate file",
        agent_spec: {"name" => "Coder"},
        workspace: persistent_workspace
      )

      task.instance_variable_set(:@status, :completed)

      expect(task.should_cleanup_workspace?).to be false
      result = task.cleanup_workspace
      expect(result).to be false
      expect(Dir.exist?(persistent_workspace.path)).to be true
    end
  end
end
