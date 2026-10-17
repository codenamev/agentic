# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::ArtifactGraph do
  let(:user_artifact) do
    Agentic::Artifact.new(
      name: "user.rb",
      type: :ruby_class,
      content: "class User; end"
    )
  end

  let(:service_artifact) do
    Agentic::Artifact.new(
      name: "user_service.rb",
      type: :ruby_class,
      content: "require_relative 'user'\n\nclass UserService; end",
      references: ["user.rb"]
    )
  end

  let(:controller_artifact) do
    Agentic::Artifact.new(
      name: "user_controller.rb",
      type: :ruby_class,
      content: "require_relative 'user_service'\n\nclass UserController; end",
      references: ["user_service.rb"]
    )
  end

  describe "#initialize" do
    it "creates an empty graph" do
      graph = described_class.new
      expect(graph.size).to eq(0)
      expect(graph).to be_empty
    end
  end

  describe "#add_node" do
    it "adds an artifact to the graph" do
      graph = described_class.new
      graph.add_node(user_artifact)

      expect(graph.size).to eq(1)
      expect(graph.find_node(name: "user.rb")).to eq(user_artifact)
    end

    it "creates edges for artifact references" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      deps = graph.dependencies_of(service_artifact)
      expect(deps).to eq([user_artifact])
    end

    it "handles artifacts with no references" do
      graph = described_class.new
      graph.add_node(user_artifact)

      deps = graph.dependencies_of(user_artifact)
      expect(deps).to be_empty
    end

    it "creates vertices for referenced artifacts not yet added" do
      graph = described_class.new
      graph.add_node(service_artifact) # References user.rb but user.rb not added yet

      # Should not raise error
      expect { graph.dependencies_of(service_artifact) }.not_to raise_error
    end
  end

  describe "#dependencies_of" do
    it "returns direct dependencies of an artifact" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      deps = graph.dependencies_of(service_artifact)
      expect(deps).to eq([user_artifact])
    end

    it "returns empty array for artifact with no dependencies" do
      graph = described_class.new
      graph.add_node(user_artifact)

      deps = graph.dependencies_of(user_artifact)
      expect(deps).to be_empty
    end

    it "works with artifact name as string" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      deps = graph.dependencies_of("user_service.rb")
      expect(deps).to eq([user_artifact])
    end

    it "returns empty array for non-existent artifact" do
      graph = described_class.new
      deps = graph.dependencies_of("nonexistent.rb")
      expect(deps).to be_empty
    end
  end

  describe "#dependents_of" do
    it "returns artifacts that depend on given artifact" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      dependents = graph.dependents_of(user_artifact)
      expect(dependents).to eq([service_artifact])
    end

    it "returns empty array for artifact with no dependents" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      dependents = graph.dependents_of(service_artifact)
      expect(dependents).to be_empty
    end

    it "works with artifact name as string" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      dependents = graph.dependents_of("user.rb")
      expect(dependents).to eq([service_artifact])
    end

    it "returns multiple dependents if multiple artifacts reference it" do
      graph = described_class.new

      admin_service = Agentic::Artifact.new(
        name: "admin_service.rb",
        type: :ruby_class,
        content: "require_relative 'user'",
        references: ["user.rb"]
      )

      graph.add_node(user_artifact)
      graph.add_node(service_artifact)
      graph.add_node(admin_service)

      dependents = graph.dependents_of(user_artifact)
      expect(dependents).to match_array([service_artifact, admin_service])
    end
  end

  describe "#detect_cycles" do
    it "returns empty array when no cycles exist" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)
      graph.add_node(controller_artifact)

      cycles = graph.detect_cycles
      expect(cycles).to be_empty
    end

    it "detects simple circular dependency (A -> B -> A)" do
      graph = described_class.new

      a = Agentic::Artifact.new(
        name: "a.rb",
        type: :ruby_class,
        content: "require_relative 'b'",
        references: ["b.rb"]
      )

      b = Agentic::Artifact.new(
        name: "b.rb",
        type: :ruby_class,
        content: "require_relative 'a'",
        references: ["a.rb"]
      )

      graph.add_node(a)
      graph.add_node(b)

      cycles = graph.detect_cycles
      expect(cycles).not_to be_empty
      expect(cycles.first).to match_array(["a.rb", "b.rb"])
    end

    it "detects complex circular dependency (A -> B -> C -> A)" do
      graph = described_class.new

      a = Agentic::Artifact.new(
        name: "a.rb",
        type: :ruby_class,
        content: "require_relative 'b'",
        references: ["b.rb"]
      )

      b = Agentic::Artifact.new(
        name: "b.rb",
        type: :ruby_class,
        content: "require_relative 'c'",
        references: ["c.rb"]
      )

      c = Agentic::Artifact.new(
        name: "c.rb",
        type: :ruby_class,
        content: "require_relative 'a'",
        references: ["a.rb"]
      )

      graph.add_node(a)
      graph.add_node(b)
      graph.add_node(c)

      cycles = graph.detect_cycles
      expect(cycles).not_to be_empty
      expect(cycles.first).to match_array(["a.rb", "b.rb", "c.rb"])
    end

    it "reports only the artifacts that form the cycle" do
      graph = described_class.new

      a = Agentic::Artifact.new(name: "a.rb", type: :ruby_class, content: "", references: ["b.rb"])
      b = Agentic::Artifact.new(name: "b.rb", type: :ruby_class, content: "", references: ["a.rb"])
      bystander = Agentic::Artifact.new(name: "c.rb", type: :ruby_class, content: "", references: ["a.rb"])

      graph.add_node(a)
      graph.add_node(b)
      graph.add_node(bystander)

      expect(graph.detect_cycles).to contain_exactly(match_array(["a.rb", "b.rb"]))
    end

    it "treats a self-reference as a cycle" do
      graph = described_class.new
      graph.add_node(Agentic::Artifact.new(name: "a.rb", type: :ruby_class, content: "", references: ["a.rb"]))
      graph.add_node(user_artifact)

      expect(graph.detect_cycles).to eq([["a.rb"]])
      expect { graph.topological_sort }.to raise_error(Agentic::CircularDependencyError, /a\.rb/)
    end
  end

  describe "#has_cycles?" do
    it "returns false when no cycles exist" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      expect(graph).not_to have_cycles
    end

    it "returns true when cycles exist" do
      graph = described_class.new

      a = Agentic::Artifact.new(
        name: "a.rb",
        type: :ruby_class,
        content: "require_relative 'b'",
        references: ["b.rb"]
      )

      b = Agentic::Artifact.new(
        name: "b.rb",
        type: :ruby_class,
        content: "require_relative 'a'",
        references: ["a.rb"]
      )

      graph.add_node(a)
      graph.add_node(b)

      expect(graph).to have_cycles
    end
  end

  describe "#topological_sort" do
    it "returns artifacts in dependency order" do
      graph = described_class.new
      graph.add_node(controller_artifact)
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      sorted = graph.topological_sort

      # user.rb should come before user_service.rb
      user_index = sorted.index(user_artifact)
      service_index = sorted.index(service_artifact)
      controller_index = sorted.index(controller_artifact)

      expect(user_index).to be < service_index
      expect(service_index).to be < controller_index
    end

    it "raises error when circular dependencies exist" do
      graph = described_class.new

      a = Agentic::Artifact.new(
        name: "a.rb",
        type: :ruby_class,
        content: "require_relative 'b'",
        references: ["b.rb"]
      )

      b = Agentic::Artifact.new(
        name: "b.rb",
        type: :ruby_class,
        content: "require_relative 'a'",
        references: ["a.rb"]
      )

      graph.add_node(a)
      graph.add_node(b)

      expect { graph.topological_sort }.to raise_error(Agentic::CircularDependencyError)
    end
  end

  describe "#find_node" do
    it "finds artifact by name" do
      graph = described_class.new
      graph.add_node(user_artifact)

      found = graph.find_node(name: "user.rb")
      expect(found).to eq(user_artifact)
    end

    it "finds artifact by name and type" do
      graph = described_class.new
      graph.add_node(user_artifact)

      found = graph.find_node(name: "user.rb", type: :ruby_class)
      expect(found).to eq(user_artifact)
    end

    it "returns nil when artifact not found" do
      graph = described_class.new
      found = graph.find_node(name: "nonexistent.rb")
      expect(found).to be_nil
    end

    it "returns nil when type doesn't match" do
      graph = described_class.new
      graph.add_node(user_artifact)

      found = graph.find_node(name: "user.rb", type: :javascript_module)
      expect(found).to be_nil
    end
  end

  describe "#all_nodes" do
    it "returns all artifacts in graph" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      all = graph.all_nodes
      expect(all).to match_array([user_artifact, service_artifact])
    end

    it "returns empty array for empty graph" do
      graph = described_class.new
      expect(graph.all_nodes).to be_empty
    end
  end

  describe "#size" do
    it "returns count of artifacts" do
      graph = described_class.new
      expect(graph.size).to eq(0)

      graph.add_node(user_artifact)
      expect(graph.size).to eq(1)

      graph.add_node(service_artifact)
      expect(graph.size).to eq(2)
    end
  end

  describe "#empty?" do
    it "returns true for empty graph" do
      graph = described_class.new
      expect(graph).to be_empty
    end

    it "returns false for non-empty graph" do
      graph = described_class.new
      graph.add_node(user_artifact)
      expect(graph).not_to be_empty
    end
  end

  describe "Enumerable" do
    it "implements #each" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      artifacts = []
      graph.each { |artifact| artifacts << artifact }

      expect(artifacts).to match_array([user_artifact, service_artifact])
    end

    it "supports Enumerable methods" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      names = graph.map(&:name)
      expect(names).to match_array(["user.rb", "user_service.rb"])

      ruby_artifacts = graph.select { |a| a.type == :ruby_class }
      expect(ruby_artifacts.size).to eq(2)
    end
  end

  describe "#to_s" do
    it "returns readable string representation" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      str = graph.to_s
      expect(str).to include("ArtifactGraph")
      expect(str).to include("nodes=2")
      expect(str).to include("edges=1")
    end
  end

  describe "#inspect" do
    it "returns detailed inspection string" do
      graph = described_class.new
      graph.add_node(user_artifact)
      graph.add_node(service_artifact)

      inspection = graph.inspect
      expect(inspection).to include("Agentic::ArtifactGraph")
      expect(inspection).to include("nodes=2")
      expect(inspection).to include("edges=1")
    end

    it "shows first 5 artifact names" do
      graph = described_class.new
      (1..7).each do |i|
        artifact = Agentic::Artifact.new(
          name: "file#{i}.rb",
          type: :ruby_class,
          content: "# file #{i}"
        )
        graph.add_node(artifact)
      end

      inspection = graph.inspect
      expect(inspection).to include("...")
    end
  end
end
