# frozen_string_literal: true

require "zeitwerk"

# Zeitwerk is the single code loader for this gem: every constant under
# Agentic:: is autoloaded on first reference, including the CLI, so
# library consumers never pay for Thor or the tty-* UI stack at require
# time. Files must not require_relative their siblings - reference the
# constant and let the loader resolve it.
loader = Zeitwerk::Loader.for_gem

# Configure Zeitwerk to handle the CLI class name properly
loader.inflector.inflect(
  "cli" => "CLI",
  "ui" => "UI"
)

# The CLI is only autoloaded on demand (exe/agentic), never eager loaded
loader.do_not_eager_load("#{__dir__}/agentic/cli")

loader.setup

module Agentic
  class Error < StandardError; end

  class << self
    attr_accessor :logger
  end

  # Library etiquette: quiet by default. The CLI raises verbosity for
  # interactive use; library consumers opt in via Agentic.logger.level=
  self.logger ||= Logger.new($stdout, level: :warn)

  # Runtime configuration object (named to avoid colliding with the
  # Agentic::Configuration schema module)
  class LegacyConfiguration
    attr_accessor :access_token, :agent_store_path, :api_base_url

    def initialize
      @access_token = ENV["OPENAI_ACCESS_TOKEN"] || ENV["AGENTIC_API_TOKEN"]
      @agent_store_path = ENV["AGENTIC_AGENT_STORE_PATH"] || File.join(Dir.home, ".agentic", "agents")
      @api_base_url = ENV["AGENTIC_API_BASE_URL"] || ENV["OPENAI_BASE_URL"]
    end

    # Verifies that the configuration can reach an LLM: either an access
    # token (hosted APIs) or a custom base URL (local endpoints such as
    # Ollama, which accept any token).
    #
    # @return [LegacyConfiguration] self, for chaining
    # @raise [Errors::ConfigurationError] when no credentials are configured
    def validate!
      return self if access_token || api_base_url

      raise Errors::ConfigurationError,
        "No LLM credentials configured. Set OPENAI_ACCESS_TOKEN (or " \
        "AGENTIC_API_TOKEN), configure an api_base_url for a local " \
        "endpoint, or use Agentic.configure { |c| c.access_token = ... }"
    end
  end

  class << self
    attr_writer :configuration, :observability_engine
    attr_reader :agent_capability_registry, :agent_assembly_engine, :agent_store
  end

  # Central coordinator for observability events, created lazily
  # @return [ObservabilityEngine] The engine instance
  def self.observability_engine
    @observability_engine ||= ObservabilityEngine.new
  end

  def self.configuration
    @configuration ||= LegacyConfiguration.new
  end

  def self.configure
    yield(configuration)
  end

  def self.client(config)
    LlmClient.new(config)
  end

  # Plan and execute a goal in one call - the 80% path
  #
  # @example Plan and execute a goal (illustrative: requires LLM credentials)
  #   result = Agentic.run("Summarize this week's support tickets")
  #   puts result.results.values.map(&:output) if result.successful?
  #
  # @param goal [String] What you want done, in plain language
  # @param model [String, nil] Optional LLM model override
  # @param concurrency [Integer] Maximum number of tasks to run at once
  # @return [PlanExecutionResult] The structured execution results
  def self.run(goal, model: nil, concurrency: 5)
    config = LlmConfig.new
    config.model = model if model

    plan = TaskPlanner.new(goal, config).plan

    orchestrator = PlanOrchestrator.new(concurrency_limit: concurrency)
    plan.tasks.each { |task_def| orchestrator.add_task(task_def.to_task) }

    orchestrator.execute_plan(DefaultAgentProvider.new(config))
  end

  # Guards lazy initialization of the agent assembly system
  ASSEMBLY_LOCK = Mutex.new
  private_constant :ASSEMBLY_LOCK

  # Initialize the core agent self-assembly components
  #
  # Thread-safe: concurrent callers initialize the registry, store, and
  # assembly engine exactly once.
  def self.initialize_agent_assembly
    return if @agent_capability_registry

    ASSEMBLY_LOCK.synchronize do
      # Re-check inside the lock - another thread may have won the race
      return if @agent_capability_registry

      registry = AgentCapabilityRegistry.instance
      @agent_store = PersistentAgentStore.new(configuration.agent_store_path, registry)
      @agent_assembly_engine = AgentAssemblyEngine.new(registry, @agent_store)

      # Register standard capabilities
      Capabilities.register_standard_capabilities

      # Initialize the security and configuration subsystems. Performance
      # initializes lazily on first use (Performance.ensure_initialized!)
      initialize_security
      initialize_configuration

      # Assigned last: this ivar doubles as the initialized flag, so it must
      # only become visible once the store and engine are fully built
      @agent_capability_registry = registry

      logger.info("Initialized agent assembly system")
    end
  end

  # Initialize security system with environment-appropriate settings
  def self.initialize_security
    env = ENV["AGENTIC_ENV"] || ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
    Security.initialize_for_environment(env)
    logger&.debug("Security initialized for #{env} environment (level: #{Security::Config.current_config[:sanitization_level]})")
  rescue => e
    logger&.warn("Failed to initialize security: #{e.message}")
    # Fallback to basic security configuration
    Security::Config.configure(sanitization_level: :basic)
  end

  # Initialize configuration system
  def self.initialize_configuration
    Configuration.initialize!
    logger&.debug("Configuration system initialized with #{Configuration.list_schemas.size} schemas")
  rescue => e
    logger&.warn("Failed to initialize configuration system: #{e.message}")
  end

  # Initialize performance optimization system
  #
  # Not called at boot: Performance builds itself with the environment
  # preset the first time it is used. Call this to build it eagerly.
  def self.initialize_performance
    Performance.ensure_initialized!
    logger&.debug("Performance system initialized (#{Performance.optimizer.config[:strategy]} strategy)")
  rescue => e
    logger&.warn("Failed to initialize performance system: #{e.message}")
  end

  # Register a capability with the system
  # @param capability [CapabilitySpecification] The capability to register
  # @param provider [CapabilityProvider] The provider for the capability
  # @return [CapabilitySpecification] The registered capability
  def self.register_capability(capability, provider)
    initialize_agent_assembly
    agent_capability_registry.register(capability, provider)
  end

  # Assemble an agent for a task
  # @param task [Task] The task to assemble an agent for
  # @param strategy [AgentCompositionStrategy, nil] The strategy to use
  # @param store [Boolean] Whether to use the agent store
  # @param use_llm [Boolean] Whether to use LLM-assisted strategy if no strategy provided
  # @return [Agent] The assembled agent
  def self.assemble_agent(task, strategy: nil, store: true, use_llm: false)
    initialize_agent_assembly

    # Use LLM-assisted strategy if requested and no strategy provided
    if use_llm && strategy.nil?
      strategy = LlmAssistedCompositionStrategy.new
    end

    agent_assembly_engine.assemble_agent(task, strategy: strategy, store: store)
  end

  # Create an LLM-assisted composition strategy
  # @param llm_config [LlmConfig, nil] The LLM config to use
  # @return [LlmAssistedCompositionStrategy] The strategy
  def self.llm_assisted_strategy(llm_config = nil)
    LlmAssistedCompositionStrategy.new(llm_config)
  end
end
