# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "fileutils"
require "timecop"

RSpec.describe Agentic::AgentAssemblyEngine do
  let(:registry) { Agentic::AgentCapabilityRegistry.instance }
  let(:temp_dir) { Dir.mktmpdir("agentic_agent_store_test") }
  let(:agent_store) { Agentic::PersistentAgentStore.new(temp_dir, registry) }
  let(:engine) { described_class.new(registry, agent_store) }

  # Define capabilities for testing
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

  let(:web_search_capability) do
    Agentic::CapabilitySpecification.new(
      name: "web_search",
      description: "Searches the web",
      version: "1.0.0",
      inputs: {
        query: {type: "string", required: true, description: "The search query"}
      },
      outputs: {
        results: {type: "array", description: "The search results"}
      }
    )
  end

  let(:web_search_provider) do
    Agentic::CapabilityProvider.new(
      capability: web_search_capability,
      implementation: ->(inputs) { {results: ["Result 1 for #{inputs[:query]}", "Result 2 for #{inputs[:query]}"]} }
    )
  end

  let(:code_gen_capability) do
    Agentic::CapabilitySpecification.new(
      name: "code_generation",
      description: "Generates code based on requirements",
      version: "1.0.0",
      inputs: {
        requirements: {type: "string", required: true, description: "The code requirements"},
        language: {type: "string", required: true, description: "The programming language"}
      },
      outputs: {
        code: {type: "string", description: "The generated code"}
      },
      dependencies: [
        {name: "text_generation", version: "1.0.0"}
      ]
    )
  end

  let(:code_gen_provider) do
    Agentic::CapabilityProvider.new(
      capability: code_gen_capability,
      implementation: ->(inputs) { {code: "// Generated code for #{inputs[:requirements]} in #{inputs[:language]}"} }
    )
  end

  # An agent spec whose words match no capability name, for description-only inference
  let(:plain_spec) { Agentic::AgentSpecification.new(name: "Worker", description: "", instructions: "") }

  # Define a sample task for testing
  let(:task) do
    agent_spec = Agentic::AgentSpecification.new(
      name: "Test Agent",
      description: "An agent for testing",
      instructions: "Test the assembly engine"
    )

    Agentic::Task.new(
      description: "Generate some code and search the web for information",
      agent_spec: agent_spec,
      input: {
        language: "Ruby",
        query: "best practices",
        capabilities: [
          {name: "code_generation", importance: 0.9},
          {name: "web_search", importance: 0.8},
          {name: "text_generation", importance: 0.7}
        ]
      }
    )
  end

  before do
    # Reset the registry
    registry.clear

    # Register capabilities for testing
    registry.register(text_gen_capability, text_gen_provider)
    registry.register(web_search_capability, web_search_provider)
    registry.register(code_gen_capability, code_gen_provider)
  end

  after do
    # Clean up temp directory
    FileUtils.remove_entry(temp_dir)

    # Reset timecop
    Timecop.return
  end

  describe "#initialize" do
    it "initializes with a registry and agent store" do
      expect(engine.registry).to eq(registry)
      expect(engine.agent_store).to eq(agent_store)
    end

    it "initializes with a registry only" do
      engine = described_class.new(registry)
      expect(engine.registry).to eq(registry)
      expect(engine.agent_store).to be_nil
    end

    it "initializes with default registry" do
      engine = described_class.new
      expect(engine.registry).to eq(Agentic::AgentCapabilityRegistry.instance)
      expect(engine.agent_store).to be_nil
    end
  end

  describe "#analyze_requirements" do
    it "extracts requirements from task description" do
      requirements = engine.analyze_requirements(task)
      expect(requirements).to include("code_generation")
      expect(requirements).to include("web_search")
      expect(requirements).to include("text_generation")
    end

    it "assigns higher importance to capabilities mentioned in task input" do
      # Task input has 'language' which should suggest code_generation
      requirements = engine.analyze_requirements(task)
      expect(requirements["code_generation"][:importance]).to be > 0.5
    end

    context "with capabilities the registry holds beyond the built-in names" do
      def task_for(description)
        Agentic::Task.new(description: description, agent_spec: plain_spec)
      end

      def register_simple(name, description)
        capability = Agentic::CapabilitySpecification.new(
          name: name,
          description: description,
          version: "1.0.0",
          inputs: {text: {type: "string", required: true, description: "Input text"}},
          outputs: {result: {type: "string", description: "Output"}}
        )
        registry.register(capability, Agentic::CapabilityProvider.new(
          capability: capability,
          implementation: ->(inputs) { {result: inputs[:text]} }
        ))
      end

      before do
        register_simple("summarization", "Summarizes text")
        register_simple("brainstorming", "Generates ideas")
        register_simple("structured_extraction", "Extracts structured data")
        register_simple("invoice_parsing", "Parses invoices")
      end

      it "infers any registered capability the description mentions" do
        {
          "Summarize this quarterly report into five bullet points" => "summarization",
          "Brainstorm ten names for a coffee brand" => "brainstorming",
          "Extract structured data from the attached invoice" => "structured_extraction",
          "Run invoice parsing on the attached PDF" => "invoice_parsing"
        }.each do |description, capability|
          requirements = engine.analyze_requirements(task_for(description))
          expect(requirements.keys).to include(capability), "expected #{capability.inspect} from #{description.inspect}"
        end
      end

      it "matches a name only at a word boundary" do
        register_simple("db", "Database access")
        register_simple("ai", "Chat with a model")
        requirements = engine.analyze_requirements(task_for("Maintain the feedback form"))
        expect(requirements.keys).not_to include("db", "ai")

        requirements = engine.analyze_requirements(task_for("Load the db and ask the ai"))
        expect(requirements.keys).to include("db", "ai")
      end

      it "does not infer names nothing has registered" do
        requirements = engine.analyze_requirements(task_for("Generate a UML diagram and run the dependency analysis"))
        expect(requirements.keys).not_to include("uml_generation", "dependency_analysis")
      end

      it "selects the inferred capability through the default strategy" do
        strategy = Agentic::DefaultCompositionStrategy.new
        requirements = engine.analyze_requirements(task_for("Extract structured data via invoice parsing"))
        names = engine.select_capabilities(requirements, strategy).map { |c| c[:name] }
        expect(names).to include("structured_extraction", "invoice_parsing")
      end
    end

    it "infers nothing from the description when the registry is empty" do
      registry.clear
      requirements = engine.analyze_requirements(Agentic::Task.new(description: "Search the web", agent_spec: plain_spec))
      expect(requirements.keys).to eq(["text_generation"])
    end
  end

  describe "#select_capabilities" do
    let(:strategy) { Agentic::DefaultCompositionStrategy.new }

    it "selects capabilities based on requirements" do
      requirements = {
        "code_generation" => {importance: 0.8, version_constraint: nil},
        "web_search" => {importance: 0.7, version_constraint: nil}
      }

      capabilities = engine.select_capabilities(requirements, strategy)
      expect(capabilities.size).to be >= 2
      expect(capabilities.map { |c| c[:name] }).to include("code_generation", "web_search")
    end

    it "includes dependency capabilities" do
      requirements = {
        "code_generation" => {importance: 0.8, version_constraint: nil}
      }

      capabilities = engine.select_capabilities(requirements, strategy)
      expect(capabilities.size).to be >= 2
      expect(capabilities.map { |c| c[:name] }).to include("code_generation", "text_generation")
    end

    it "selects a capability once when it is both required and a dependency" do
      requirements = {
        "code_generation" => {importance: 0.8, version_constraint: nil},
        "text_generation" => {importance: 0.3, version_constraint: nil}
      }

      names = engine.select_capabilities(requirements, strategy).map { |c| c[:name] }
      expect(names).to eq(names.uniq)
      expect(names).to contain_exactly("code_generation", "text_generation")
    end

    it "adds a default text_generation capability when requirements are empty" do
      requirements = {}

      capabilities = engine.select_capabilities(requirements, strategy)
      expect(capabilities.size).to eq(1)
      expect(capabilities.first[:name]).to eq("text_generation")
    end
  end

  describe "#build_agent" do
    it "builds an agent with the specified capabilities" do
      capabilities = [
        {name: "text_generation", version: "1.0.0"},
        {name: "web_search", version: "1.0.0"}
      ]

      agent = engine.build_agent(task, capabilities)
      expect(agent).to be_a(Agentic::Agent)
      expect(agent.role).to eq(task.agent_spec.name)
      expect(agent.purpose).to eq(task.agent_spec.description)
      expect(agent.backstory).to eq(task.agent_spec.instructions)
      expect(agent.capabilities.keys).to include("text_generation", "web_search")
    end

    it "handles failures when adding capabilities" do
      capabilities = [
        {name: "text_generation", version: "1.0.0"},
        {name: "non_existent_capability", version: "1.0.0"}
      ]

      # Should not raise an error
      agent = engine.build_agent(task, capabilities)
      expect(agent).to be_a(Agentic::Agent)
      expect(agent.capabilities.keys).to include("text_generation")
      expect(agent.capabilities.keys).not_to include("non_existent_capability")
    end
  end

  describe "#assemble_agent" do
    it "assembles an agent with appropriate capabilities for a task" do
      agent = engine.assemble_agent(task)
      expect(agent).to be_a(Agentic::Agent)
      expect(agent.capabilities.keys).to include("code_generation", "text_generation")
    end

    it "uses a custom strategy if provided" do
      custom_strategy = instance_double(Agentic::AgentCompositionStrategy)
      expect(custom_strategy).to receive(:select_capabilities).and_return([
        {name: "text_generation", version: "1.0.0"}
      ])

      agent = engine.assemble_agent(task, strategy: custom_strategy)
      expect(agent).to be_a(Agentic::Agent)
      expect(agent.capabilities.keys).to include("text_generation")
    end

    context "with agent store" do
      it "finds an existing agent from the store if suitable" do
        # Create and store an agent with required capabilities
        stored_agent = Agentic::Agent.build do |a|
          a.role = "Stored Agent"
          a.purpose = "Testing"
        end
        stored_agent.add_capability("code_generation")
        stored_agent.add_capability("web_search")

        agent_store.store(stored_agent, metadata: {
          task_description: "Generate some code and search the web for information"
        })

        # When assembling, it should find the stored agent
        agent = engine.assemble_agent(task)
        expect(agent.role).to eq(stored_agent.role)
        expect(agent.capabilities.keys).to include("code_generation", "web_search")
      end

      it "stores the assembled agent when store=true" do
        # Should store the agent
        engine.assemble_agent(task, store: true)

        # Check that the agent was stored
        agents = agent_store.all
        expect(agents.size).to eq(1)
        expect(agents.first[:capabilities].map { |c| c[:name] }).to include("code_generation")
      end

      it "doesn't use or store agents when store=false" do
        # Create and store an agent with required capabilities
        stored_agent = Agentic::Agent.build do |a|
          a.role = "Stored Agent"
          a.purpose = "Testing"
        end
        stored_agent.add_capability("code_generation")
        stored_agent.add_capability("web_search")

        agent_store.store(stored_agent)

        # Clear the store to check if a new agent is stored
        previous_count = agent_store.all.size

        # When assembling with store=false, it should not use or store agents
        agent = engine.assemble_agent(task, store: false)
        expect(agent.role).to eq(task.agent_spec.name)

        # Check that no new agent was stored
        expect(agent_store.all.size).to eq(previous_count)
      end
    end
  end

  describe "#find_suitable_agent" do
    before do
      # Create and store some agents with different capabilities
      agent1 = Agentic::Agent.build do |a|
        a.role = "Agent 1"
        a.purpose = "Testing"
      end
      agent1.add_capability("text_generation")

      agent2 = Agentic::Agent.build do |a|
        a.role = "Agent 2"
        a.purpose = "Testing"
      end
      agent2.add_capability("text_generation")
      agent2.add_capability("web_search")

      agent3 = Agentic::Agent.build do |a|
        a.role = "Agent 3"
        a.purpose = "Testing"
      end
      agent3.add_capability("text_generation")
      agent3.add_capability("web_search")
      agent3.add_capability("code_generation")

      @id1 = agent_store.store(agent1)
      @id2 = agent_store.store(agent2)
      @id3 = agent_store.store(agent3)
    end

    it "finds the most suitable agent for a task" do
      # Agent 3 has all required capabilities
      agent = engine.find_suitable_agent(task)
      expect(agent).to be_a(Agentic::Agent)
      expect(agent.capabilities.keys).to include("code_generation", "web_search", "text_generation")
    end

    it "returns nil if no suitable agent is found" do
      # Create a task with very different requirements that result in low similarity
      # Using explicit capabilities in input to ensure they're extracted
      task_spec = Agentic::AgentSpecification.new(
        name: "Database Migration Agent",
        description: "An agent for database operations",
        instructions: "Perform database migrations"
      )

      special_task = Agentic::Task.new(
        description: "Migrate database schema and run SQL operations",
        agent_spec: task_spec,
        input: {
          capabilities: [
            {name: "database_migration", importance: 0.9},
            {name: "sql_execution", importance: 0.9}
          ]
        }
      )

      agent = engine.find_suitable_agent(special_task)
      # Should return nil because stored agents have different capabilities
      # and the overall similarity score will be low
      expect(agent).to be_nil
    end
  end

  describe "#store_agent" do
    it "stores an agent with task-related metadata" do
      agent = Agentic::Agent.build do |a|
        a.role = "Test Agent"
        a.purpose = "Testing"
      end
      agent.add_capability("text_generation")

      requirements = {"text_generation" => {importance: 0.8}}

      id = engine.store_agent(agent, task, requirements)
      expect(id).not_to be_nil

      # Check that the agent was stored with the correct metadata
      stored_agents = agent_store.all
      expect(stored_agents.size).to eq(1)
      expect(stored_agents.first[:metadata][:task_id]).to eq(task.id)
      expect(stored_agents.first[:metadata][:requirements]).to eq(requirements)
    end

    it "generates a name based on the task" do
      agent = Agentic::Agent.build do |a|
        a.role = "Test Agent"
        a.purpose = "Testing"
      end
      agent.add_capability("text_generation")

      engine.store_agent(agent, task, {})

      # Check that the agent was stored with a name based on the task
      stored_agents = agent_store.all
      expect(stored_agents.first[:name]).to include("test_agent")
      expect(stored_agents.first[:name]).to include("generate")
      expect(stored_agents.first[:name]).to include("code")
    end
  end
end
