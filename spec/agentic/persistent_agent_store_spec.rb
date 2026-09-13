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

    it "rejects an agent id that would leave the storage directory" do
      agent.id = "../../escaped"

      expect { store.store(agent) }.to raise_error(ArgumentError, /agent id/)
      expect(File.exist?(File.join(temp_dir, "..", "escaped"))).to be false
    end

    it "rejects an agent id with a path separator" do
      agent.id = "team/researcher"

      expect { store.store(agent) }.to raise_error(ArgumentError, /agent id/)
    end

    it "accepts a caller-assigned plain id" do
      agent.id = "researcher-v2_final"

      expect(store.store(agent)).to eq("researcher-v2_final")
      expect(File.exist?(File.join(temp_dir, "researcher-v2_final", "1.0.0.json"))).to be true
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
  end

  describe "path guarding" do
    let(:store) { described_class.new(temp_dir) }
    let(:agent) do
      Agentic::Agent.build do |a|
        a.role = "Test Agent"
      end
    end

    before { agent.add_capability("text_generation") }

    it "rejects a version that would leave the agent directory on read" do
      id = store.store(agent)
      outside = File.join(temp_dir, "outside.json")
      File.write(outside, JSON.generate({agent: {role: "Smuggled"}, capabilities: []}))

      expect { store.build_agent(id, version: "../outside") }.to raise_error(ArgumentError, /version/)
    end

    it "ignores index entries with unsafe ids and never touches paths outside the store" do
      outside = File.join(temp_dir, "..", "agentic_store_escape_#{SecureRandom.hex(4)}.json")
      File.write(outside, "{}")
      File.write(File.join(temp_dir, "index.json"), JSON.generate({
        "../agentic_store_escape" => {"1.0.0" => {name: "evil", timestamp: Time.now.iso8601, capabilities: [], metadata: {}}},
        "legit" => {"1.0.0" => {name: "fine", timestamp: Time.now.iso8601, capabilities: [], metadata: {}}}
      }))

      logger = instance_double(Logger, warn: nil, error: nil, info: nil, debug: nil)
      store = described_class.new(temp_dir, registry, logger: logger)

      expect(logger).to have_received(:warn).with(/unsafe key/)
      expect(store.all.map { |a| a[:id] }).to eq(["legit"])
      expect(store.delete("../agentic_store_escape")).to be false
      expect(File.exist?(outside)).to be true
    ensure
      File.delete(outside) if outside && File.exist?(outside)
    end

    it "ignores index entries with unsafe version keys" do
      File.write(File.join(temp_dir, "index.json"), JSON.generate({
        "legit" => {"../../etc/passwd" => {name: "evil", timestamp: Time.now.iso8601, capabilities: [], metadata: {}}}
      }))

      store = described_class.new(temp_dir)

      expect(store.all).to be_empty
      expect(store.version_history("legit")).to be_empty
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
