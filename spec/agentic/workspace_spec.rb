# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Agentic::Workspace do
  let(:temp_dir) { Dir.mktmpdir("workspace_spec") }
  let(:workspace) { described_class.new(temp_dir) }

  let(:user_artifact) do
    Agentic::Artifact.new(
      name: "user.rb",
      type: :ruby_class,
      content: "class User\n  attr_accessor :name\nend"
    )
  end

  let(:service_artifact) do
    Agentic::Artifact.new(
      name: "user_service.rb",
      type: :ruby_class,
      content: "require_relative 'user'\n\nclass UserService\nend",
      references: ["user.rb"]
    )
  end

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  describe "#initialize" do
    it "creates a workspace with a unique ID" do
      expect(workspace.id).to be_a(String)
      expect(workspace.id.length).to be > 0
    end

    it "creates a workspace at the specified path" do
      expect(workspace.path).to eq(temp_dir)
      expect(Dir.exist?(workspace.path)).to be true
    end

    it "creates the directory if it doesn't exist" do
      new_path = File.join(temp_dir, "new_workspace")
      described_class.new(new_path)

      expect(Dir.exist?(new_path)).to be true
      FileUtils.rm_rf(new_path)
    end

    it "initializes an empty artifact graph" do
      expect(workspace.artifact_graph).to be_a(Agentic::ArtifactGraph)
      expect(workspace.artifact_graph).to be_empty
    end

    it "sets creation timestamp" do
      expect(workspace.created_at).to be_a(Time)
      expect(workspace.created_at).to be <= Time.now
    end

    it "supports persistent workspace option" do
      persistent_workspace = described_class.new(temp_dir, persistent: true)
      expect(persistent_workspace.metadata[:persistent]).to be true
    end

    it "supports custom allowed extensions" do
      custom_workspace = described_class.new(temp_dir, allowed_extensions: [".tsx", ".jsx"])
      expect(custom_workspace.metadata[:allowed_extensions]).to include(".tsx", ".jsx")
    end

    it "supports custom max size limit" do
      custom_workspace = described_class.new(temp_dir, max_size_bytes: 1024)
      expect(custom_workspace.metadata[:max_size_bytes]).to eq(1024)
    end
  end

  describe "#add_artifact" do
    it "adds an artifact to the workspace" do
      workspace.add_artifact(user_artifact)

      expect(workspace.artifact_count).to eq(1)
      expect(workspace.find_artifact(name: "user.rb")).to eq(user_artifact)
    end

    it "writes artifact to filesystem" do
      workspace.add_artifact(user_artifact)

      file_path = File.join(workspace.path, "user.rb")
      expect(File.exist?(file_path)).to be true
      expect(File.read(file_path)).to eq(user_artifact.content)
    end

    it "creates parent directories if needed" do
      nested_artifact = Agentic::Artifact.new(
        name: "models/user.rb",
        type: :ruby_class,
        content: "class User; end"
      )

      workspace.add_artifact(nested_artifact)

      file_path = File.join(workspace.path, "models/user.rb")
      expect(File.exist?(file_path)).to be true
    end

    it "adds artifact to graph with references" do
      workspace.add_artifact(user_artifact)
      workspace.add_artifact(service_artifact)

      deps = workspace.artifacts_referenced_by(service_artifact)
      expect(deps).to eq([user_artifact])
    end

    it "raises SecurityError for path traversal in artifact name" do
      malicious_artifact = Agentic::Artifact.new(
        name: "../etc/passwd",
        type: :ruby_class,
        content: "malicious"
      )

      expect { workspace.add_artifact(malicious_artifact) }.to raise_error(SecurityError, /path traversal/)
    end

    it "raises SecurityError for absolute paths" do
      malicious_artifact = Agentic::Artifact.new(
        name: "/etc/passwd",
        type: :ruby_class,
        content: "malicious"
      )

      expect { workspace.add_artifact(malicious_artifact) }.to raise_error(SecurityError, /path traversal/)
    end

    it "raises SecurityError for unsafe characters in name" do
      malicious_artifact = Agentic::Artifact.new(
        name: "user$.rb",
        type: :ruby_class,
        content: "class User; end"
      )

      expect { workspace.add_artifact(malicious_artifact) }.to raise_error(SecurityError, /unsafe characters/)
    end

    it "raises SecurityError for disallowed file extensions" do
      malicious_artifact = Agentic::Artifact.new(
        name: "script.exe",
        type: :ruby_class,
        content: "malicious"
      )

      expect { workspace.add_artifact(malicious_artifact) }.to raise_error(SecurityError, /Disallowed file extension/)
    end

    it "allows custom extensions when configured" do
      custom_workspace = described_class.new(temp_dir, allowed_extensions: [".tsx"])

      tsx_artifact = Agentic::Artifact.new(
        name: "component.tsx",
        type: :javascript_module,
        content: "const Component = () => <div>Hello</div>"
      )

      expect { custom_workspace.add_artifact(tsx_artifact) }.not_to raise_error
    end

    it "raises SecurityError when artifact exceeds size limit" do
      large_artifact = Agentic::Artifact.new(
        name: "large.rb",
        type: :ruby_class,
        content: "x" * (described_class::MAX_ARTIFACT_SIZE + 1)
      )

      expect { workspace.add_artifact(large_artifact) }.to raise_error(SecurityError, /Artifact too large/)
    end

    it "raises SecurityError when workspace size limit exceeded" do
      small_workspace = described_class.new(temp_dir, max_size_bytes: 100)

      large_artifact = Agentic::Artifact.new(
        name: "file.rb",
        type: :ruby_class,
        content: "x" * 200
      )

      expect { small_workspace.add_artifact(large_artifact) }.to raise_error(SecurityError, /Workspace size limit exceeded/)
    end

    it "raises SecurityError for path traversal in references" do
      malicious_artifact = Agentic::Artifact.new(
        name: "service.rb",
        type: :ruby_class,
        content: "class Service; end",
        references: ["../../../etc/passwd"]
      )

      expect { workspace.add_artifact(malicious_artifact) }.to raise_error(SecurityError, /path traversal/)
    end

    context "when the workspace contains symlinks" do
      let(:outside_dir) { Dir.mktmpdir("workspace_spec_outside") }

      after do
        FileUtils.rm_rf(outside_dir) if Dir.exist?(outside_dir)
      end

      it "refuses to write through a file symlinked outside the workspace" do
        victim = File.join(outside_dir, "victim.rb")
        File.write(victim, "original")
        File.symlink(victim, File.join(temp_dir, "user.rb"))

        expect { workspace.add_artifact(user_artifact) }.to raise_error(SecurityError, /symlink outside the workspace/)
        expect(File.read(victim)).to eq("original")
        expect(workspace.artifact_count).to eq(0)
      end

      it "refuses a dangling symlinked file" do
        File.symlink(File.join(outside_dir, "gone.rb"), File.join(temp_dir, "user.rb"))

        expect { workspace.add_artifact(user_artifact) }.to raise_error(SecurityError, /dangling symlink/)
        expect(workspace.artifact_count).to eq(0)
      end

      it "refuses to write under a dangling symlinked directory" do
        File.symlink(File.join(outside_dir, "gone"), File.join(temp_dir, "lib"))
        artifact = Agentic::Artifact.new(name: "lib/user.rb", type: :ruby_class, content: "class User; end")

        expect { workspace.add_artifact(artifact) }.to raise_error(SecurityError, /dangling symlink/)
        expect(workspace.artifact_count).to eq(0)
      end

      it "writes through a symlinked file that resolves inside the workspace" do
        FileUtils.mkdir_p(File.join(temp_dir, "docs"))
        real_file = File.join(temp_dir, "docs", "user.rb")
        File.write(real_file, "original")
        File.symlink(real_file, File.join(temp_dir, "user.rb"))

        workspace.add_artifact(user_artifact)

        expect(File.read(real_file)).to eq(user_artifact.content)
      end

      it "writes again after cleanup removed the workspace root" do
        workspace.cleanup
        expect(Dir.exist?(temp_dir)).to be false

        workspace.add_artifact(user_artifact)

        expect(File.exist?(File.join(temp_dir, "user.rb"))).to be true
      end

      it "refuses to write under a directory that symlinks outside the workspace" do
        File.symlink(outside_dir, File.join(temp_dir, "lib"))
        artifact = Agentic::Artifact.new(name: "lib/user.rb", type: :ruby_class, content: "class User; end")

        expect { workspace.add_artifact(artifact) }.to raise_error(SecurityError, /outside the workspace/)
        expect(File.exist?(File.join(outside_dir, "user.rb"))).to be false
        expect(workspace.artifact_count).to eq(0)
      end

      it "refuses when the escaping symlink is above a directory that does not exist yet" do
        File.symlink(outside_dir, File.join(temp_dir, "lib"))
        artifact = Agentic::Artifact.new(name: "lib/models/user.rb", type: :ruby_class, content: "class User; end")

        expect { workspace.add_artifact(artifact) }.to raise_error(SecurityError, /outside the workspace/)
        expect(Dir.exist?(File.join(outside_dir, "models"))).to be false
      end

      it "allows a symlinked directory that resolves inside the workspace" do
        real_dir = File.join(temp_dir, "real")
        FileUtils.mkdir_p(real_dir)
        File.symlink(real_dir, File.join(temp_dir, "alias"))
        artifact = Agentic::Artifact.new(name: "alias/user.rb", type: :ruby_class, content: "class User; end")

        workspace.add_artifact(artifact)

        expect(File.read(File.join(real_dir, "user.rb"))).to eq("class User; end")
      end

      it "still writes when the workspace root itself is a symlink" do
        real_root = Dir.mktmpdir("workspace_spec_real_root")
        link_root = File.join(outside_dir, "linked_workspace")
        File.symlink(real_root, link_root)
        linked_workspace = described_class.new(link_root)

        linked_workspace.add_artifact(user_artifact)

        expect(File.exist?(File.join(real_root, "user.rb"))).to be true
      ensure
        FileUtils.rm_rf(real_root) if real_root && Dir.exist?(real_root)
      end
    end
  end

  describe "#find_artifact" do
    before do
      workspace.add_artifact(user_artifact)
    end

    it "finds artifact by name" do
      found = workspace.find_artifact(name: "user.rb")
      expect(found).to eq(user_artifact)
    end

    it "finds artifact by name and type" do
      found = workspace.find_artifact(name: "user.rb", type: :ruby_class)
      expect(found).to eq(user_artifact)
    end

    it "returns nil when artifact not found" do
      found = workspace.find_artifact(name: "nonexistent.rb")
      expect(found).to be_nil
    end

    it "returns nil when type doesn't match" do
      found = workspace.find_artifact(name: "user.rb", type: :javascript_module)
      expect(found).to be_nil
    end
  end

  describe "#artifacts_referencing" do
    before do
      workspace.add_artifact(user_artifact)
      workspace.add_artifact(service_artifact)
    end

    it "returns artifacts that reference the given artifact" do
      referencing = workspace.artifacts_referencing(user_artifact)
      expect(referencing).to eq([service_artifact])
    end

    it "returns empty array when no artifacts reference it" do
      referencing = workspace.artifacts_referencing(service_artifact)
      expect(referencing).to be_empty
    end

    it "works with artifact name as string" do
      referencing = workspace.artifacts_referencing("user.rb")
      expect(referencing).to eq([service_artifact])
    end
  end

  describe "#artifacts_referenced_by" do
    before do
      workspace.add_artifact(user_artifact)
      workspace.add_artifact(service_artifact)
    end

    it "returns artifacts referenced by the given artifact" do
      referenced = workspace.artifacts_referenced_by(service_artifact)
      expect(referenced).to eq([user_artifact])
    end

    it "returns empty array when artifact has no references" do
      referenced = workspace.artifacts_referenced_by(user_artifact)
      expect(referenced).to be_empty
    end

    it "works with artifact name as string" do
      referenced = workspace.artifacts_referenced_by("user_service.rb")
      expect(referenced).to eq([user_artifact])
    end
  end

  describe "#cleanup" do
    it "removes the workspace directory for non-persistent workspaces" do
      workspace.add_artifact(user_artifact)
      path = workspace.path

      expect(Dir.exist?(path)).to be true

      result = workspace.cleanup

      expect(result).to be true
      expect(Dir.exist?(path)).to be false
    end

    it "does nothing for persistent workspaces" do
      persistent_workspace = described_class.new(temp_dir, persistent: true)
      persistent_workspace.add_artifact(user_artifact)
      path = persistent_workspace.path

      result = persistent_workspace.cleanup

      expect(result).to be false
      expect(Dir.exist?(path)).to be true
    end

    it "handles cleanup when directory doesn't exist" do
      workspace.cleanup # First cleanup
      expect { workspace.cleanup }.not_to raise_error # Second cleanup
    end
  end

  describe "#size" do
    it "returns zero for empty workspace" do
      expect(workspace.size).to eq(0)
    end

    it "returns total size of all artifacts" do
      workspace.add_artifact(user_artifact)
      workspace.add_artifact(service_artifact)

      expected_size = user_artifact.content.bytesize + service_artifact.content.bytesize
      expect(workspace.size).to eq(expected_size)
    end
  end

  describe "#artifact_count" do
    it "returns zero for empty workspace" do
      expect(workspace.artifact_count).to eq(0)
    end

    it "returns count of artifacts" do
      workspace.add_artifact(user_artifact)
      expect(workspace.artifact_count).to eq(1)

      workspace.add_artifact(service_artifact)
      expect(workspace.artifact_count).to eq(2)
    end
  end

  describe "#empty?" do
    it "returns true for empty workspace" do
      expect(workspace).to be_empty
    end

    it "returns false for non-empty workspace" do
      workspace.add_artifact(user_artifact)
      expect(workspace).not_to be_empty
    end
  end

  describe "#all_artifacts" do
    it "returns empty array for empty workspace" do
      expect(workspace.all_artifacts).to be_empty
    end

    it "returns all artifacts" do
      workspace.add_artifact(user_artifact)
      workspace.add_artifact(service_artifact)

      artifacts = workspace.all_artifacts
      expect(artifacts).to match_array([user_artifact, service_artifact])
    end
  end

  describe "#to_s" do
    it "returns readable string representation" do
      workspace.add_artifact(user_artifact)

      str = workspace.to_s
      expect(str).to include("Workspace")
      expect(str).to include(workspace.id[0..7])
      expect(str).to include("artifacts=1")
    end
  end

  describe "#inspect" do
    it "returns detailed inspection string" do
      workspace.add_artifact(user_artifact)

      inspection = workspace.inspect
      expect(inspection).to include("Agentic::Workspace")
      expect(inspection).to include(workspace.id)
      expect(inspection).to include("artifacts=1")
      expect(inspection).to include("size=")
    end
  end

  describe "file permissions" do
    it "writes files with restrictive permissions" do
      workspace.add_artifact(user_artifact)

      file_path = File.join(workspace.path, "user.rb")
      file_mode = File.stat(file_path).mode

      # Check that file is readable and writable by owner
      expect(file_mode & 0o400).to be > 0 # owner readable
      expect(file_mode & 0o200).to be > 0 # owner writable
    end
  end
end
