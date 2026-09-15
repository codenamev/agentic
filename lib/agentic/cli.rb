# frozen_string_literal: true

require "thor"
require "json"
require "yaml"

module Agentic
  # Command Line Interface for Agentic
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: "-v", desc: "Enable verbose output"
    class_option :quiet, type: :boolean, aliases: "-q", desc: "Suppress output"
    class_option :config, type: :string, aliases: "-c", desc: "Specify config file"
    class_option :no_color, type: :boolean, desc: "Disable colored output"
    class_option :no_file_logging, type: :boolean, desc: "Disable file logging"
    class_option :log_path, type: :string, desc: "Custom path for observability logs"

    def self.exit_on_failure?
      true
    end

    # Global logging configuration based on options
    def initialize(*args)
      super
      configure_logging
    end

    desc "version", "Display version information"
    def version
      version_box = UI.box(
        "Agentic",
        [
          "Version: #{UI.colorize(Agentic::VERSION, :green)}",
          "Ruby: #{UI.colorize(RUBY_VERSION, :blue)}",
          "Platform: #{UI.colorize(RUBY_PLATFORM, :yellow)}"
        ].join("\n"),
        padding: [1, 2, 1, 2],
        style: {border: {fg: :blue}}
      )
      puts version_box
    end

    desc "plan GOAL", "Create an execution plan for a goal"
    long_desc <<-LONGDESC
      Creates an execution plan for the given goal using the TaskPlanner.

      Example:
        $ agentic plan "Generate a market research report on AI trends"

      You can also save the plan to a file:
        $ agentic plan "Generate a market research report" --save plan.json

      Use a workspace for file generation tasks:
        $ agentic plan "Create a Ruby User class" --workspace /tmp/project --execute
    LONGDESC
    option :output, type: :string, aliases: "-o",
      enum: %w[json yaml text], default: "text",
      desc: "Output format (json, yaml, or text)"
    option :save, type: :string, aliases: "-s",
      desc: "Save plan to a file (defaults to plan-TIMESTAMP.json)"
    option :model, type: :string, aliases: "-m",
      desc: "LLM model to use (defaults to configuration)"
    option :no_interactive, type: :boolean,
      desc: "Skip interactive plan adjustment prompt"
    option :execute, type: :boolean,
      desc: "Execute the plan immediately after generation"
    option :workspace, type: :string, aliases: "-w",
      desc: "Workspace path for file generation tasks"
    def plan(goal)
      check_api_token!

      say UI.colorize("Creating plan for goal: #{goal}", :green) unless options[:quiet]

      # Configure the LLM
      config = LlmConfig.new
      config.model = options[:model] if options[:model]

      # Create and run the task planner with progress tracking
      execution_plan = if options[:quiet]
        planner = TaskPlanner.new(goal, config)
        planner.plan
      else
        plan_with_progress_tracking(goal, config)
      end

      # Show the plan to the user
      unless options[:quiet]
        puts format_plan(execution_plan)
        puts
      end

      # Ask user if they want to adjust the plan
      if !options[:quiet] && !options[:no_interactive] && ask_user_for_plan_adjustment
        execution_plan = adjust_plan_with_user_input(execution_plan, config)
      end

      # Output the plan based on format option (only if saving to file or different format)
      if options[:save] || options[:output] != "text"
        output_plan(execution_plan, options)
      end

      # Ask user if they want to execute the plan
      if options[:execute] || (should_ask_for_execution? && ask_user_for_execution)
        execute_plan_immediately(execution_plan)
      end
    end

    desc "execute", "Execute a plan"
    long_desc <<-LONGDESC
      Executes a plan created by the 'plan' command.

      You can provide a plan file:
        $ agentic execute --plan plan.json

      Or pipe in a plan:
        $ cat plan.json | agentic execute --from-stdin

      Use a workspace for file generation tasks:
        $ agentic execute --plan plan.json --workspace /tmp/project
    LONGDESC
    option :plan, type: :string, aliases: "-p",
      desc: "Path to a plan file"
    option :from_stdin, type: :boolean,
      desc: "Read plan from stdin"
    option :async, type: :boolean, default: true,
      desc: "Execute tasks asynchronously"
    option :max_concurrency, type: :numeric, default: 10,
      desc: "Maximum concurrent tasks"
    option :file, type: :string, aliases: "-f",
      desc: "Output file path (defaults to result-TIMESTAMP.json)"
    option :model, type: :string, aliases: "-m",
      desc: "LLM model to use (defaults to configuration)"
    option :workspace, type: :string, aliases: "-w",
      desc: "Workspace path for file generation tasks"
    def execute
      check_api_token!

      # Load the plan
      plan_data = load_plan_data

      unless plan_data
        raise Thor::Error, "No plan provided. Use --plan FILE or --from-stdin"
      end

      # Initialize task instances from the plan
      tasks = initialize_tasks(plan_data)

      # Execute the tasks
      execute_tasks(tasks)
    end

    # Agent commands
    class AgentCommands < Thor
      desc "list", "List available agents"
      option :detailed, type: :boolean, aliases: "-d",
        desc: "Show detailed information"
      def list
        # Initialize agent assembly system
        Agentic.initialize_agent_assembly

        # Get stored agents
        agents = Agentic.agent_store.all

        if agents.empty?
          puts UI.box(
            "Available Agents",
            "No agents stored yet.\n\n" \
            "You can create a new agent with:\n" \
            "  #{UI.colorize("agentic agent create NAME --role=ROLE --purpose=PURPOSE", :blue)}",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :blue}}
          )
          return
        end

        output = ""
        agents.each do |agent|
          output += "#{UI.colorize(agent[:name], :blue)} (#{agent[:id]}):\n"
          output += "  Stored: #{agent[:timestamp]}\n"

          if options[:detailed]
            output += "  Role: #{agent[:agent][:role]}\n" if agent[:agent] && agent[:agent][:role]
            output += "  Purpose: #{agent[:agent][:purpose]}\n" if agent[:agent] && agent[:agent][:purpose]

            if agent[:capabilities] && !agent[:capabilities].empty?
              output += "  Capabilities:\n"
              agent[:capabilities].each do |capability|
                output += "    - #{capability[:name]} (v#{capability[:version]})\n"
              end
            end

            if agent[:metadata] && !agent[:metadata].empty?
              output += "  Metadata:\n"
              agent[:metadata].each do |key, value|
                output += "    - #{key}: #{value}\n" unless key.to_s == "requirements"
              end
            end
          else
            capabilities_count = agent[:capabilities] ? agent[:capabilities].size : 0
            output += "  Capabilities: #{capabilities_count}\n"
          end

          output += "\n"
        end

        puts UI.box(
          "Available Agents",
          output,
          padding: [1, 2, 1, 2],
          style: {border: {fg: :blue}}
        )
      end

      desc "create NAME", "Create a new agent"
      option :role, type: :string, required: true, desc: "Role of the agent"
      option :purpose, type: :string, required: true, desc: "Purpose of the agent"
      option :backstory, type: :string, desc: "Backstory for the agent"
      option :capabilities, type: :array, desc: "Capabilities to add to the agent"
      def create(name)
        # Initialize agent assembly system
        Agentic.initialize_agent_assembly

        # Create spinner for agent creation
        agent = UI.with_spinner("Creating agent: #{name}") do
          # Create new agent (Agent.build yields the configurable; Agent.new does not)
          agent = Agentic::Agent.build do |a|
            a.role = options[:role]
            a.purpose = options[:purpose]
            a.backstory = options[:backstory] || ""
          end

          # Add capabilities if specified
          options[:capabilities]&.each do |capability_name|
            agent.add_capability(capability_name)
          rescue => e
            Agentic.logger.warn("Failed to add capability: #{capability_name} - #{e.message}")
          end

          # Store the agent
          Agentic.agent_store.store(agent, name: name)

          agent
        end

        # Format capabilities list
        capabilities = agent.capabilities.keys.map { |c| "- #{c}" }.join("\n")
        capabilities = "None" if capabilities.empty?

        # Show success message with agent details
        details = [
          "Name: #{UI.colorize(name, :blue)}",
          "Role: #{UI.colorize(agent.role, :magenta)}",
          "Purpose: #{agent.purpose}",
          "Capabilities:\n#{capabilities}"
        ].join("\n")

        puts UI.box(
          "Agent Created",
          details,
          padding: [1, 2, 1, 2],
          style: {border: {fg: :green}}
        )
      end

      desc "show ID_OR_NAME", "Show details of a specific agent"
      def show(id_or_name)
        # Initialize agent assembly system
        Agentic.initialize_agent_assembly

        # Find the agent
        agent_config = nil
        Agentic.agent_store.all.each do |config|
          if config[:id] == id_or_name || config[:name] == id_or_name
            agent_config = config
            break
          end
        end

        unless agent_config
          puts UI.box(
            "Error",
            "Agent '#{UI.colorize(id_or_name, :yellow)}' not found.",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :red}}
          )
          exit 1
        end

        # Format the agent details
        output = ""
        output += "ID: #{UI.colorize(agent_config[:id], :blue)}\n"
        output += "Name: #{UI.colorize(agent_config[:name], :blue)}\n"
        output += "Stored: #{agent_config[:timestamp]}\n"
        output += "Version: #{agent_config[:version]}\n\n"

        if agent_config[:agent]
          output += "Role: #{agent_config[:agent][:role]}\n" if agent_config[:agent][:role]
          output += "Purpose: #{agent_config[:agent][:purpose]}\n" if agent_config[:agent][:purpose]
          output += "Backstory: #{agent_config[:agent][:backstory]}\n" if agent_config[:agent][:backstory]
          output += "\n"
        end

        if agent_config[:capabilities] && !agent_config[:capabilities].empty?
          output += "Capabilities:\n"
          agent_config[:capabilities].each do |capability|
            output += "  - #{UI.colorize(capability[:name], :magenta)} (v#{capability[:version]})\n"
          end
          output += "\n"
        end

        if agent_config[:metadata] && !agent_config[:metadata].empty?
          output += "Metadata:\n"
          agent_config[:metadata].each do |key, value|
            next if key.to_s == "requirements" # Skip complex requirements object
            output += "  - #{key}: #{value}\n"
          end
        end

        puts UI.box(
          "Agent Details",
          output,
          padding: [1, 2, 1, 2],
          style: {border: {fg: :blue}}
        )
      end

      desc "delete ID_OR_NAME", "Delete an agent"
      def delete(id_or_name)
        # Initialize agent assembly system
        Agentic.initialize_agent_assembly

        # Create spinner for agent deletion
        success = UI.with_spinner("Deleting agent: #{id_or_name}") do
          Agentic.agent_store.delete(id_or_name)
        end

        if success
          puts UI.box(
            "Agent Deleted",
            "Agent #{UI.colorize(id_or_name, :blue)} has been deleted successfully.",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :yellow}}
          )
        else
          puts UI.box(
            "Error",
            "Agent #{UI.colorize(id_or_name, :blue)} could not be deleted. Please check the ID or name.",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :red}}
          )
        end
      end

      desc "build ID_OR_NAME", "Build an agent from storage"
      def build(id_or_name)
        # Initialize agent assembly system
        Agentic.initialize_agent_assembly

        # Build the agent
        agent = UI.with_spinner("Building agent: #{id_or_name}") do
          Agentic.agent_store.build_agent(id_or_name)
        end

        unless agent
          puts UI.box(
            "Error",
            "Agent '#{UI.colorize(id_or_name, :yellow)}' not found or could not be built.",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :red}}
          )
          exit 1
        end

        # Format capabilities list
        capabilities = agent.capabilities.keys.map { |c| "- #{c}" }.join("\n")
        capabilities = "None" if capabilities.empty?

        # Show success message with agent details
        details = [
          "Role: #{UI.colorize(agent.role, :magenta)}",
          "Purpose: #{agent.purpose}",
          "Capabilities:\n#{capabilities}"
        ].join("\n")

        puts UI.box(
          "Agent Built Successfully",
          details,
          padding: [1, 2, 1, 2],
          style: {border: {fg: :green}}
        )
      end
    end

    desc "agent", "Manage agents"
    subcommand "agent", AgentCommands

    # Configuration commands
    class ConfigCommands < Thor
      desc "list", "List configuration settings"
      CONFIG_FILE_NAME = ".agentic.yml"
      USER_CONFIG_PATH = File.join(Dir.home, CONFIG_FILE_NAME)
      PROJECT_CONFIG_PATH = File.join(Dir.pwd, CONFIG_FILE_NAME)

      desc "list", "List configuration settings"
      def list
        user_config = load_config(USER_CONFIG_PATH)
        project_config = load_config(PROJECT_CONFIG_PATH)

        # Format user config
        user_config_str = "User configuration (#{USER_CONFIG_PATH}):\n"
        user_config_str += format_config(user_config)

        # Format project config
        project_config_str = "Project configuration (#{PROJECT_CONFIG_PATH}):\n"
        project_config_str += format_config(project_config)

        # Format active config
        active_config_str = "Active configuration:\n"
        active_config_str += format_config(active_config)

        # Format environment variables
        env_vars_str = "Environment variables:\n"
        token_status = ENV["OPENAI_ACCESS_TOKEN"] ?
                      UI.colorize("[SET]", :green) :
                      UI.colorize("[NOT SET]", :red)
        env_vars_str += "  OPENAI_ACCESS_TOKEN: #{token_status}"

        # Display in a box
        config_info = [
          user_config_str,
          "",
          project_config_str,
          "",
          active_config_str,
          "",
          env_vars_str
        ].join("\n")

        puts UI.box("Configuration", config_info, padding: [1, 2, 1, 2], style: {border: {fg: :blue}})
      end

      desc "get KEY", "Get a configuration setting"
      def get(key)
        config = active_config
        value = config[key]

        if value
          value_str = case value
          when true then UI.colorize("true", :green)
          when false then UI.colorize("false", :red)
          when String then "\"#{value}\""
          else value.to_s
          end

          puts UI.box(
            "Configuration Value",
            "#{UI.colorize(key, :blue)}: #{value_str}",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :green}}
          )
        else
          puts UI.box(
            "Error",
            "Key '#{UI.colorize(key, :yellow)}' not found in configuration",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :red}}
          )
          exit 1
        end
      end

      desc "set KEY=VALUE", "Set a configuration setting"
      option :global, type: :boolean, aliases: "-g",
        desc: "Set in global user config instead of project config"
      def set(key_value)
        key, value = key_value.split("=", 2)

        unless value
          puts "Error: Invalid format. Use KEY=VALUE"
          exit 1
        end

        path = options[:global] ? USER_CONFIG_PATH : PROJECT_CONFIG_PATH
        config = load_config(path) || {}

        # Convert string values to appropriate types
        value = case value.downcase
        when "true" then true
        when "false" then false
        when /^\d+$/ then value.to_i
        when /^\d+\.\d+$/ then value.to_f
        else value
        end

        config[key] = value
        save_config(path, config)

        puts UI.box(
          "Configuration Updated",
          "Set #{UI.colorize(key, :blue)} to #{UI.colorize(value.to_s, :green)} in #{path}",
          padding: [1, 2, 1, 2],
          style: {border: {fg: :green}}
        )
      end

      desc "init", "Initialize configuration"
      option :global, type: :boolean, aliases: "-g",
        desc: "Initialize global user config instead of project config"
      def init
        path = options[:global] ? USER_CONFIG_PATH : PROJECT_CONFIG_PATH

        if File.exist?(path)
          puts UI.box(
            "Configuration Exists",
            "Configuration already exists at #{UI.colorize(path, :blue)}",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :yellow}}
          )
          return
        end

        config = {
          "model" => "gpt-4o-mini",
          "log_level" => "info"
          # Add other default configuration options here
        }

        save_config(path, config)

        # Format the config for display
        config_str = format_config(config)

        puts UI.box(
          "Configuration Initialized",
          "Created configuration at #{UI.colorize(path, :blue)}\n\n#{config_str}",
          padding: [1, 2, 1, 2],
          style: {border: {fg: :green}}
        )
      end

      private

      def load_config(path)
        return unless File.exist?(path)

        begin
          YAML.load_file(path)
        rescue => e
          puts "Error loading configuration from #{path}: #{e.message}"
          nil
        end
      end

      def save_config(path, config)
        # Create directory if it doesn't exist
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)

        File.write(path, YAML.dump(config))
      end

      def active_config
        # Combine user and project configs, with project taking precedence
        user_config = load_config(USER_CONFIG_PATH) || {}
        project_config = load_config(PROJECT_CONFIG_PATH) || {}

        user_config.merge(project_config)
      end

      def format_config(config)
        if config.nil? || config.empty?
          "  #{UI.colorize("[empty]", :yellow)}\n"
        else
          config.map do |key, value|
            value_str = case value
            when true then UI.colorize("true", :green)
            when false then UI.colorize("false", :red)
            when String then "\"#{value}\""
            else value.to_s
            end

            "  #{UI.colorize(key, :blue)}: #{value_str}"
          end.join("\n") + "\n"
        end
      end
    end

    desc "config", "Configure Agentic settings"
    subcommand "config", ConfigCommands

    desc "capabilities", "Manage capability registry"
    subcommand "capabilities", Capabilities

    desc "portal", "Manage human intervention portal"
    subcommand "portal", HumanInterventionCommands

    private

    # Asks the user if they want to adjust the plan
    # @return [Boolean] true if user wants to adjust, false otherwise
    def ask_user_for_plan_adjustment
      puts UI.colorize("Would you like to adjust this plan? (y/n)", :cyan)
      response = $stdin.gets&.chomp&.downcase
      response == "y" || response == "yes"
    end

    # Determines if we should ask the user about executing the plan
    # @return [Boolean] true if we should ask, false otherwise
    def should_ask_for_execution?
      !options[:quiet] && !options[:execute] && !options[:no_interactive]
    end

    # Asks the user if they want to execute the plan
    # @return [Boolean] true if user wants to execute, false otherwise
    def ask_user_for_execution
      puts
      puts UI.colorize("Would you like to execute this plan now? (y/n)", :cyan)
      response = $stdin.gets&.chomp&.downcase
      response == "y" || response == "yes"
    end

    # Executes a plan immediately (from plan command)
    # @param execution_plan [ExecutionPlan] The execution plan to execute
    def execute_plan_immediately(execution_plan)
      # Create workspace if path provided
      workspace = create_workspace_if_specified

      # Convert ExecutionPlan to tasks, carrying the declared graph along
      execute_tasks(build_task_graph(execution_plan.tasks, workspace: workspace))
    end

    # Builds executable tasks from plan definitions and resolves the graph
    # they declare against the tasks just built. Plan-local ids ("t1")
    # never reach the orchestrator: it keys on Task#id, so every edge is
    # handed over as the Task it points at. Flat plans come back with no
    # edges and run exactly as they did before graph fields existed.
    # @param definitions [Array<TaskDefinition>] The planned tasks
    # @param workspace [Workspace, nil] Shared workspace for file-generating tasks
    # @param inputs [Array<Hash>] Per-task input, positionally aligned with definitions
    # @return [Array<Array(Task, Array<Task>, Hash{String => Task})>] One
    #   [task, dependencies, needs] triple per definition, in plan order
    # @raise [Thor::Error] If the graph cannot be scheduled (dangling ids, cycles)
    def build_task_graph(definitions, workspace: nil, inputs: [])
      ExecutionPlan.new(definitions, nil).validate!

      by_id = {}
      built = definitions.each_with_index.map do |task_def, index|
        task = Task.new(
          description: task_def.description,
          agent_spec: task_def.agent,
          input: inputs[index] || {},
          workspace: workspace
        )
        by_id[task_def.id] = task if task_def.id
        [task_def, task]
      end

      built.map do |task_def, task|
        dependencies = task_def.depends_on.map { |id| by_id.fetch(id) }
        needs = task_def.needs.transform_values { |id| by_id.fetch(id) }
        [task, dependencies, needs, task_def.on_failure.to_sym]
      end
    rescue ExecutionPlan::InvalidPlanError => e
      raise Thor::Error, "Plan cannot be executed: #{e.message}"
    end

    # Shared execution logic for both execute command and immediate execution
    # @param graph [Array<Array(Task, Array<Task>, Hash{String => Task}, Symbol)>]
    #   The tasks to execute with their resolved edges (see #build_task_graph)
    def execute_tasks(graph)
      say UI.colorize("Executing plan...", :green) unless options[:quiet]

      # Setup observability adapters for CLI execution
      setup_observability_adapters

      # Determine output format from file extension if provided
      output_format = determine_output_format(options[:file])

      # Create an execution observer for real-time feedback
      observer = ExecutionObserver.new(options.merge(output_format: output_format, holistic_display: true))

      # Setup the PlanOrchestrator with the observer's lifecycle hooks
      orchestrator = PlanOrchestrator.new(
        concurrency_limit: options[:max_concurrency] || 10,
        lifecycle_hooks: observer.lifecycle_hooks
      )

      # Add tasks to the orchestrator with their declared edges, so
      # dependents wait for (and can read) what they depend on
      graph.each do |task, dependencies, needs, on_failure|
        orchestrator.add_task(task, dependencies, needs: needs.empty? ? nil : needs, on_failure: on_failure)
      end

      # Show the total number of tasks (and edges, when the plan has any)
      unless options[:quiet]
        edges = graph.sum { |_, dependencies, needs| (dependencies | needs.values).size }
        puts UI.colorize("Total tasks: #{graph.size}", :blue)
        puts UI.colorize("Dependencies: #{edges}", :blue) if edges.positive?
        puts
      end

      # Configure LLM for agent execution
      llm_config = LlmConfig.new
      llm_config.model = options[:model] if options[:model]

      # Setup signal handler for graceful cancellation
      setup_cancellation_handler(orchestrator, observer)

      # Execute the plan
      begin
        result = orchestrator.execute_plan(DefaultAgentProvider.new(llm_config))

        # Always save result to file
        save_result_to_file(result, options, observer)
      rescue Interrupt
        # Handle Ctrl+C gracefully - signal handler will take care of cleanup
        # This rescue is here just in case the signal doesn't propagate properly
        puts "\n#{UI.colorize("⚠", :yellow)} Execution interrupted"
        exit(130)
      end
    end

    # Adjusts the plan based on user input
    # @param execution_plan [ExecutionPlan] The original execution plan
    # @param config [LlmConfig] The LLM configuration
    # @return [ExecutionPlan] The adjusted execution plan
    def adjust_plan_with_user_input(execution_plan, config)
      puts UI.colorize("What adjustments would you like to make to the plan?", :cyan)
      puts UI.colorize("(Describe what you'd like to add, remove, or modify)", :dark)

      user_input = $stdin.gets&.chomp || ""

      return execution_plan if user_input.strip.empty?

      # Use LLM to adjust the plan based on user input
      adjusted_plan = UI.with_spinner("Adjusting plan based on your feedback") do
        adjust_plan_via_llm(execution_plan, user_input, config)
      end

      # Show the adjusted plan
      puts UI.colorize("\nAdjusted Plan:", :green)
      puts format_plan(adjusted_plan)
      puts

      adjusted_plan
    end

    # Uses LLM to adjust the plan based on user feedback
    # @param execution_plan [ExecutionPlan] The original execution plan
    # @param user_feedback [String] The user's feedback for adjustments
    # @param config [LlmConfig] The LLM configuration
    # @return [ExecutionPlan] The adjusted execution plan
    def adjust_plan_via_llm(execution_plan, user_feedback, config)
      system_message = "You are an expert project planner. Your task is to adjust an existing execution plan based on user feedback."

      current_plan = {
        tasks: execution_plan.tasks.map do |task|
          {
            description: task.description,
            agent: {
              name: task.agent.name,
              description: task.agent.description,
              instructions: task.agent.instructions
            }
          }
        end,
        expected_answer: {
          format: execution_plan.expected_answer.format,
          sections: execution_plan.expected_answer.sections,
          length: execution_plan.expected_answer.length
        }
      }

      user_message = <<~MSG
        Current Plan:
        #{JSON.pretty_generate(current_plan)}

        User Feedback:
        #{user_feedback}

        Please adjust the plan based on the user's feedback. Maintain the same structure but modify tasks as requested.
      MSG

      schema = StructuredOutputs::Schema.new("adjusted_plan") do |s|
        s.array :tasks, items: {
          type: "object",
          properties: {
            description: {type: "string"},
            agent: {
              type: "object",
              properties: {
                name: {type: "string"},
                description: {type: "string"},
                instructions: {type: "string"}
              },
              required: %w[name description instructions]
            }
          },
          required: %w[description agent]
        }
        s.object :expected_answer do |o|
          o.string :format
          o.array :sections, items: {type: "string"}
          o.string :length
        end
      end

      messages = [
        {role: "system", content: system_message},
        {role: "user", content: user_message}
      ]

      llm_client = Agentic.client(config)
      response = llm_client.complete(messages, output_schema: schema)

      if response.successful?
        tasks = response.content["tasks"].map do |task_data|
          TaskDefinition.new(
            description: task_data["description"],
            agent: AgentSpecification.new(
              name: task_data["agent"]["name"],
              description: task_data["agent"]["description"],
              instructions: task_data["agent"]["instructions"]
            )
          )
        end

        expected_answer = ExpectedAnswerFormat.new(
          format: response.content["expected_answer"]["format"],
          sections: response.content["expected_answer"]["sections"],
          length: response.content["expected_answer"]["length"]
        )

        ExecutionPlan.new(tasks, expected_answer)
      else
        Agentic.logger.error("Failed to adjust plan: #{response.error&.message || response.refusal}")
        execution_plan # Return original plan if adjustment fails
      end
    end

    # Configures logging based on command options
    def configure_logging
      if options[:verbose]
        Agentic.logger.level = :debug
        Agentic.logger.formatter = proc do |severity, datetime, progname, msg|
          color = case severity
          when "DEBUG" then :blue
          when "INFO" then :green
          when "WARN" then :yellow
          when "ERROR" then :red
          when "FATAL" then :red
          else :white
          end

          timestamp = UI.colorize(datetime.strftime("%Y-%m-%d %H:%M:%S"), :dark)
          severity_colored = UI.colorize(severity.ljust(5), color)

          "[#{timestamp}] #{severity_colored} : #{msg}\n"
        end
      elsif options[:quiet]
        Agentic.logger.level = :warn
      else
        Agentic.logger.level = :info
      end
    end

    # Checks for API token and raises error if not configured
    def check_api_token!
      unless Agentic.configuration.access_token || Agentic.configuration.api_base_url
        error_box = UI.box(
          "Configuration Error",
          "No OpenAI API token configured.\n\n" \
          "You can set it using one of these methods:\n" \
          "- Environment variable: OPENAI_ACCESS_TOKEN\n" \
          "- Configuration file: .agentic.yml\n" \
          "- Run: agentic config set api_token=your_token",
          style: {border: {fg: :red}},
          padding: [1, 2, 1, 2]
        )

        raise Thor::Error, error_box
      end
    end

    # Outputs plan based on format options
    def output_plan(execution_plan, options)
      # Determine the save file path if --save is used
      save_path = nil
      output_format = options[:output]

      if options[:save]
        if options[:save] == "save" # Default value when --save is used without argument
          timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
          # Default to JSON when saving without explicit format for better structure
          if output_format == "text"
            output_format = "json"
            save_path = "plan-#{timestamp}.json"
          else
            extension = (output_format == "yaml") ? "yml" : output_format
            save_path = "plan-#{timestamp}.#{extension}"
          end
        else
          save_path = options[:save]
          # When saving to a file, prefer structured format over text for better usability
          if output_format == "text"
            output_format = "json"
          end
        end
      end

      output = case output_format
      when "json"
        JSON.pretty_generate(execution_plan.to_h)
      when "yaml"
        YAML.dump(execution_plan.to_h)
      else # text
        format_plan(execution_plan)
      end

      if save_path
        File.write(save_path, output)
        say UI.colorize("Plan saved to #{save_path}", :green) unless options[:quiet]
      else
        puts output unless options[:quiet]
      end
    end

    # Formats a plan for display
    # @param execution_plan [ExecutionPlan] The execution plan
    # @return [String] The formatted plan
    def format_plan(execution_plan)
      output = []
      output << UI.colorize("═" * 80, :blue)
      output << UI.colorize(" EXECUTION PLAN", :blue)
      output << UI.colorize("═" * 80, :blue)
      output << ""

      output << UI.colorize("Tasks:", :green)
      execution_plan.tasks.each_with_index do |task, index|
        # Wrap long descriptions to prevent formatting issues
        description = if task.description.length > 70
          "#{task.description[0..67]}..."
        else
          task.description
        end

        output << "  #{UI.colorize("#{index + 1}.", :blue)} #{description}"
        output << "     #{UI.colorize("Agent:", :dark)} #{UI.colorize(task.agent.name, :magenta)}"
        output << ""
      end

      output << UI.colorize("Expected Answer:", :green)
      output << "  #{UI.colorize("Format:", :dark)} #{UI.colorize(execution_plan.expected_answer.format, :yellow)}"

      # Handle long section lists safely
      if execution_plan.expected_answer.sections.empty?
        sections_display = UI.colorize("(none specified)", :dark)
      elsif execution_plan.expected_answer.sections.length > 3
        first_three = execution_plan.expected_answer.sections[0..2]
        remaining = execution_plan.expected_answer.sections.length - 3
        sections_display = "#{first_three.join(", ")} #{UI.colorize("(+#{remaining} more)", :dark)}"
      else
        sections_display = execution_plan.expected_answer.sections.join(", ")
      end

      output << "  #{UI.colorize("Sections:", :dark)} #{sections_display}"
      output << "  #{UI.colorize("Length:", :dark)} #{UI.colorize(execution_plan.expected_answer.length, :yellow)}"
      output << ""
      output << UI.colorize("═" * 80, :blue)

      output.join("\n")
    end

    # Loads plan data from file or stdin based on options
    def load_plan_data
      if options[:plan]
        JSON.parse(File.read(options[:plan]))
      elsif options[:from_stdin]
        stdin_content = $stdin.read
        $stdin.close unless $stdin.closed?
        JSON.parse(stdin_content)
      end
    end

    # Initializes task instances from plan data, resolving any dependency
    # graph the file declares. Plan files without graph fields (anything
    # written before ids existed, or by hand) load as flat plans.
    # @param plan_data [Hash] Parsed plan JSON
    # @return [Array<Array(Task, Array<Task>, Hash{String => Task})>] See #build_task_graph
    def initialize_tasks(plan_data)
      # Create workspace if path provided
      workspace = create_workspace_if_specified

      task_data = Array(plan_data["tasks"])
      definitions = task_data.map { |data| TaskDefinition.from_hash(data) }
      inputs = task_data.map { |data| data["input"] || {} }

      build_task_graph(definitions, workspace: workspace, inputs: inputs)
    end

    # Outputs execution result based on format options
    def output_result(result, options)
      output = case options[:output]
      when "json"
        JSON.pretty_generate(result.to_h)
      when "yaml"
        YAML.dump(result.to_h)
      else # text
        format_execution_result(result)
      end

      puts output unless options[:quiet]
    end

    # Formats execution result as text
    def format_execution_result(result)
      status_text = UI.status_text(result.status.to_s, result.status)
      execution_time = UI.format_duration(result.execution_time)

      output = "Execution Result:\n"
      output += "Status: #{status_text}\n"
      output += "Execution Time: #{execution_time}\n\n"

      output += "Tasks:\n"
      result.tasks.each do |task_id, task_data|
        task_result = result.task_result(task_id)
        status = task_result ? task_result.status : :pending

        status_indicator = UI.task_status_indicator(status)
        description = task_data[:description]

        output += "  #{status_indicator} #{description}\n"
      end

      # Create a box for the result
      UI.box(
        "Execution Summary",
        output,
        padding: [1, 2, 1, 2],
        style: {border: {fg: result.successful? ? :green : :yellow}}
      )
    end

    # Saves execution result to file if requested
    def save_result_to_file(result, options, observer = nil)
      # Determine the save file path - always save to a file
      save_path = if options[:file]
        # User specified a file path
        options[:file]
      else
        # Default filename with timestamp
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        "result-#{timestamp}.json"
      end

      # Determine content format
      output_format = determine_output_format(save_path)

      # Generate content based on format
      content = if output_format == :json || !observer
        # Save as JSON (default behavior)
        JSON.pretty_generate(result.to_h)
      else
        # Use observer to generate format-specific content
        observer.generate_file_content(result, output_format)
      end

      # Save the content
      File.write(save_path, content)

      # Note: The execution observer already displays the save path in its summary,
      # so we don't need a duplicate message here
    end

    # Determines output format from file extension
    # @param file_path [String, nil] The file path
    # @return [Symbol] The detected format (:json, :markdown, :html, :text)
    def determine_output_format(file_path)
      return :text unless file_path

      extension = File.extname(file_path).downcase
      case extension
      when ".json"
        :json
      when ".md", ".markdown"
        :markdown
      when ".html", ".htm"
        :html
      when ".txt"
        :text
      when ".yaml", ".yml"
        :yaml
      else
        :text # Default fallback
      end
    end

    # Sets up signal handler for graceful cancellation
    # @param orchestrator [PlanOrchestrator] The plan orchestrator to cancel
    # @param observer [ExecutionObserver] The observer to notify of cancellation
    def setup_cancellation_handler(orchestrator, observer)
      Signal.trap("INT") do
        puts "\n#{UI.colorize("⚠", :yellow)} Cancellation requested..."

        # Notify observer of cancellation (sets flag)
        observer.handle_cancellation if observer.respond_to?(:handle_cancellation)

        # Cancel the plan execution
        orchestrator.cancel_plan

        # Show cancellation message
        puts UI.box(
          "Execution Cancelled",
          "Plan execution was cancelled by user request.\nPartial results may be available.",
          padding: [1, 2, 1, 2],
          style: {border: {fg: :yellow}}
        )

        exit(130) # Standard exit code for SIGINT
      end
    end

    # Setup observability adapters for CLI execution
    def setup_observability_adapters
      return if @observability_setup_attempted

      @observability_setup_attempted = true

      # Configure observability adapters based on CLI options
      cli_options = {
        quiet: options[:quiet],
        verbose: options[:verbose],
        color: !options[:no_color],
        enable_file_logging: !options[:no_file_logging],
        log_path: options[:log_path]
      }.compact

      # For execution mode, disable console adapter to prevent debug timestamps
      # The ProgressTracker provides clean output instead
      config = Observability::AdapterFactory.default_cli_config(cli_options)
      config[:console][:enabled] = false  # Disable console adapter for clean execution output

      # Configure adapters with console disabled
      Agentic.observability_engine.configure_adapters(config)

      unless options[:quiet]
        if Agentic.observability_engine.find_adapters(:file).any?
          file_adapter = Agentic.observability_engine.find_adapters(:file).first
          say UI.colorize("📁 Logging to: #{file_adapter.status[:log_path]}", :blue)
        end
      end
    end

    # Plans with dynamic progress tracking to show the user what's happening
    # @param goal [String] The goal to plan for
    # @param config [LlmConfig] The LLM configuration
    # @return [ExecutionPlan] The generated execution plan
    def plan_with_progress_tracking(goal, config)
      # Create simple, robust streaming observer
      observer = Streaming::StreamingPlanObserver.new(options)

      # Set up cancellation handler for planning
      setup_planning_cancellation_handler(observer)

      observer.planning_started(goal)

      begin
        # Create planner with observer
        planner = TaskPlanner.new(goal, config, observer: observer)

        # Execute the planning process with observer callbacks
        execution_plan = planner.plan

        observer.planning_completed(execution_plan)
        execution_plan
      rescue Interrupt
        observer.planning_cancelled
        raise
      rescue => error
        observer.planning_failed(error.message)
        raise error
      end
    end

    # Sets up signal handler for graceful cancellation during planning
    # @param observer [Streaming::StreamingPlanObserver] The observer to notify
    def setup_planning_cancellation_handler(observer)
      Signal.trap("INT") do
        puts "\n#{UI.colorize("⚠", :yellow)} Cancellation requested during planning..."

        # Notify observer of cancellation
        observer.planning_cancelled

        exit(130) # Standard exit code for SIGINT
      end
    end

    # Creates a workspace if --workspace option is specified
    # @return [Workspace, nil] The workspace instance or nil if not specified
    def create_workspace_if_specified
      return nil unless options[:workspace]

      workspace_path = options[:workspace]

      # Notify user of workspace creation
      unless options[:quiet]
        say UI.colorize("📁 Using workspace: #{workspace_path}", :blue)
      end

      # Create workspace (persistent by default for CLI usage)
      Workspace.new(workspace_path, persistent: true)
    end
  end
end
