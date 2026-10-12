# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "fileutils"
require "timecop"

RSpec.describe Agentic::PersistentAgentStore do
  let(:temp_dir) { Dir.mktmpdir("agentic_agent_store_test") }
  let(:registry) { Agentic::AgentCapabilityRegistry.instance }
  let(:text_gen_capability) do
    Agentic::CapabilitySpecification.new(
      name: "text_generation",
      description: "Generates text based on a prompt",
      version: "1.0.0",
      inputs: {
        prompt: {type: "string", required: true, description: "The prompt to generate text from"}
      },
      outputs: {
        response: {type: "string", description: "The generated text"}
      }
    )
  end
  let(:text_gen_provider) do
    Agentic::CapabilityProvider.new(
      capability: text_gen_capability,
      implementation: ->(inputs) { {response: "Generated text for: #{inputs[:prompt]}"} }
    )
  end

  before do
    # Reset the registry
    registry.clear

    # Register a capability for testing
    registry.register(text_gen_capability, text_gen_provider)
  end

  after do
    # Clean up temp directory
    FileUtils.remove_entry(temp_dir)

    # Reset timecop
    Timecop.return
  end

  describe "#initialize" do
    it "creates the storage directory if it doesn't exist" do
      described_class.new(temp_dir)
      expect(File.directory?(temp_dir)).to be true
    end

    it "loads the index if it exists" do
      # Create an index file
      index_path = File.join(temp_dir, "index.json")
      File.write(index_path, JSON.generate({
        "test_id" => {
          "1.0.0" => {
            name: "test_agent",
            timestamp: Time.now.iso8601,
            capabilities: [{name: "text_generation", version: "1.0.0"}],
            metadata: {}
          }
        }
      }))

      store = described_class.new(temp_dir)
      agents = store.all
      expect(agents.size).to eq(1)
      expect(agents.first[:name]).to eq("test_agent")
    end
  end

  describe "#store" do
    let(:store) { described_class.new(temp_dir) }
    let(:agent) do
      Agentic::Agent.build do |a|
        a.role = "Test Agent"
        a.purpose = "Testing the agent store"
        a.backstory = "I am a test agent"
      end
    end

    before do
      agent.add_capability("text_generation")
    end

    it "stores an agent and returns its ID" do
      id = store.store(agent)
      expect(id).not_to be_nil

      # Check that the agent file exists
      agent_dir = File.join(temp_dir, id)
      expect(File.directory?(agent_dir)).to be true
      expect(Dir.glob(File.join(agent_dir, "*.json")).size).to eq(1)
    end

    it "stores an agent with a custom name" do
      name = "my_custom_agent"
      store.store(agent, name: name)

      # Check that the name is stored
      agents = store.all
      expect(agents.size).to eq(1)
      expect(agents.first[:name]).to eq(name)
    end

    it "stores agent metadata" do
      metadata = {source: "test", tags: ["test", "agent"]}
      store.store(agent, metadata: metadata)

      # Check that the metadata is stored
      agents = store.all
      expect(agents.size).to eq(1)
      expect(agents.first[:metadata]).to eq(metadata)
    end

    it "increments the version when storing the same agent multiple times" do
      id = store.store(agent)

      # Store the same agent again
      store.store(agent)

      # Check that there are two versions
      versions = store.version_history(id)
      expect(versions.size).to eq(2)
      expect(versions.map { |v| v[:version] }).to include("1.0.0", "1.0.1")
    end
  end

  describe "#build_agent" do
    let(:store) { described_class.new(temp_dir) }
    let(:agent) do
      Agentic::Agent.build do |a|
        a.role = "Test Agent"
        a.purpose = "Testing the agent store"
        a.backstory = "I am a test agent"
      end
    end

    before do
      agent.add_capability("text_generation")
      @id = store.store(agent)
    end

    it "builds an agent from an ID" do
      built_agent = store.build_agent(@id)
      expect(built_agent).to be_a(Agentic::Agent)
      expect(built_agent.role).to eq(agent.role)
      expect(built_agent.purpose).to eq(agent.purpose)
      expect(built_agent.backstory).to eq(agent.backstory)
      expect(built_agent.has_capability?("text_generation")).to be true
    end

    it "builds an agent from a name" do
      name = "named_agent"
      store.store(agent, name: name)

      built_agent = store.build_agent(name)
      expect(built_agent).to be_a(Agentic::Agent)
      expect(built_agent.role).to eq(agent.role)
    end

    it "returns nil for a non-existent agent" do
      built_agent = store.build_agent("non_existent")
      expect(built_agent).to be_nil
    end

    context "when the stored capability version has been bumped" do
      let(:logger) { instance_double(Logger, info: nil, warn: nil, debug: nil, error: nil) }
      let(:store) { described_class.new(temp_dir, registry, logger: logger) }

      def register_only(version)
        registry.clear
        spec = Agentic::CapabilitySpecification.new(
          name: "text_generation",
          description: "Generates text based on a prompt",
          version: version,
          inputs: {prompt: {type: "string", required: true}},
          outputs: {response: {type: "string"}}
        )
        provider = Agentic::CapabilityProvider.new(
          capability: spec,
          implementation: ->(inputs) { {response: "v#{version}: #{inputs[:prompt]}"} }
        )
        registry.register(spec, provider)
      end

      it "resolves a minor bump to the newest compatible version and logs the upgrade" do
        register_only("1.1.0")

        built_agent = store.build_agent(@id)

        expect(built_agent.has_capability?("text_generation")).to be true
        expect(built_agent.capability_specification("text_generation").version).to eq("1.1.0")
        expect(logger).to have_received(:info).with(/Upgraded capability text_generation from v1\.0\.0 to v1\.1\.0/)
      end

      it "picks the newest compatible version when several are registered" do
        register_only("1.1.0")
        one_three = Agentic::CapabilitySpecification.new(
          name: "text_generation", description: "newer", version: "1.3.0"
        )
        registry.register(one_three, Agentic::CapabilityProvider.new(
          capability: one_three, implementation: ->(_) { {response: "1.3"} }
        ))
        two_oh = Agentic::CapabilitySpecification.new(name: "text_generation", description: "major", version: "2.0.0")
        registry.register(two_oh, Agentic::CapabilityProvider.new(capability: two_oh, implementation: ->(_) { {response: "2.0"} }))

        built_agent = store.build_agent(@id)

        expect(built_agent.capability_specification("text_generation").version).to eq("1.3.0")
      end

      it "raises at load time on a major bump instead of returning a degraded agent" do
        register_only("2.0.0")

        expect { store.build_agent(@id) }.to raise_error(Agentic::Errors::CapabilityNotFoundError) { |error|
          expect(error.capability_name).to eq("text_generation")
          expect(error.message).to include(@id)
          expect(error.message).to include("v1.0.0")
        }
      end

      it "raises at load time when the capability is no longer registered at all" do
        registry.clear

        expect { store.build_agent(@id) }.to raise_error(Agentic::Errors::CapabilityNotFoundError, /text_generation/)
      end
    end
  end

  describe "#all/#list_all" do
    let(:store) { described_class.new(temp_dir) }
    let(:agent1) do
      Agentic::Agent.build do |a|
        a.role = "Agent 1"
        a.purpose = "Testing"
      end
    end
    let(:agent2) do
      Agentic::Agent.build do |a|
        a.role = "Agent 2"
        a.purpose = "Testing"
      end
    end

    before do
      # Register another capability
      web_search_capability = Agentic::CapabilitySpecification.new(
        name: "web_search",
        description: "Searches the web",
        version: "1.0.0"
      )
      web_search_provider = Agentic::CapabilityProvider.new(
        capability: web_search_capability,
        implementation: ->(inputs) { {results: ["Result 1", "Result 2"]} }
      )
      registry.register(web_search_capability, web_search_provider)

      # Add capabilities to agents
      agent1.add_capability("text_generation")
      agent2.add_capability("text_generation")
      agent2.add_capability("web_search")

      # Store the agents
      @id1 = store.store(agent1, metadata: {category: "simple"})
      @id2 = store.store(agent2, metadata: {category: "advanced"})
    end

    it "lists all agents" do
      agents = store.all
      expect(agents.size).to eq(2)
    end

    it "filters agents by capability" do
      agents = store.all(filter: {capability: "web_search"})
      expect(agents.size).to eq(1)
      expect(agents.first[:id]).to eq(@id2)
    end

    it "filters agents by metadata" do
      agents = store.all(filter: {metadata: {category: "simple"}})
      expect(agents.size).to eq(1)
      expect(agents.first[:id]).to eq(@id1)
    end

    it "sorts agents by timestamp (newest first)" do
      # Store agent1 again with a newer timestamp
      Timecop.freeze(Time.now + 60) do
        store.store(agent1)
      end

      agents = store.all
      expect(agents.first[:id]).to eq(@id1)
    end
  end

  describe "#delete" do
    let(:store) { described_class.new(temp_dir) }
    let(:agent) do
      Agentic::Agent.build do |a|
        a.role = "Test Agent"
      end
    end

    before do
      agent.add_capability("text_generation")
      @id = store.store(agent)

      # Store another version
      Timecop.freeze(Time.now + 60) do
        store.store(agent)
      end
    end

    it "deletes a specific version of an agent" do
      result = store.delete(@id, version: "1.0.0")
      expect(result).to be true

      versions = store.version_history(@id)
      expect(versions.size).to eq(1)
      expect(versions.first[:version]).to eq("1.0.1")
    end

    it "deletes all versions of an agent" do
      result = store.delete(@id)
      expect(result).to be true

      agents = store.all
      expect(agents.size).to eq(0)
    end

    it "returns false for a non-existent agent" do
      result = store.delete("non_existent")
      expect(result).to be false
    end
  end

  describe "#version_history" do
    let(:store) { described_class.new(temp_dir) }
    let(:agent) do
      Agentic::Agent.build do |a|
        a.role = "Test Agent"
      end
    end

    before do
      agent.add_capability("text_generation")

      # Store the agent with different timestamps
      Timecop.freeze(Time.now) do
        @id = store.store(agent)
      end

      Timecop.freeze(Time.now + 60) do
        store.store(agent)
      end

      Timecop.freeze(Time.now + 120) do
        store.store(agent)
      end
    end

    it "returns the version history for an agent" do
      versions = store.version_history(@id)
      expect(versions.size).to eq(3)
      expect(versions.map { |v| v[:version] }).to include("1.0.0", "1.0.1", "1.0.2")
    end

    it "returns versions sorted by timestamp (newest first)" do
      versions = store.version_history(@id)
      timestamps = versions.map { |v| Time.parse(v[:timestamp]) }
      expect(timestamps).to eq(timestamps.sort.reverse)
    end

    it "returns an empty array for a non-existent agent" do
      versions = store.version_history("non_existent")
      expect(versions).to be_empty
    end
  end
end
