# frozen_string_literal: true

module Agentic
  class CLI < Thor
    # Observer that provides real-time feedback during plan execution
    class ExecutionObserver
      # Initialize a new execution observer
      # @param options [Hash] CLI options
      def initialize(options = {})
        @options = options
        @output_format = options[:output_format] || :text
        @start_time = Time.now
        @completed_tasks = 0
        @failed_tasks = 0
        @total_tasks = 0
        @cancellation_requested = false

        # Create the progress tracker for line-by-line updates
        @progress_tracker = ProgressTracker.new(options)

        # Legacy state for compatibility (minimal usage)
        @task_states = {}
        @built_agents = {}
        @assembly_details = {}

        # Observability integration - connect to global engine
        @observability_engine = Agentic.observability_engine

        # Subscribe to agent assembly events
        @observability_engine.add_local_observer(self)
      end

      # Builds lifecycle hooks for the plan orchestrator
      # @return [Hash] The lifecycle hooks
      def lifecycle_hooks
        {
          before_agent_build: method(:before_agent_build),
          after_agent_build: method(:after_agent_build),
          before_task_execution: method(:before_task_execution),
          after_task_success: method(:after_task_success),
          after_task_failure: method(:after_task_failure),
          plan_completed: method(:plan_completed)
        }
      end

      # Called before an agent is built for a task
      # @param task_id [String] The ID of the task
      # @param task [Task] The task needing an agent
      def before_agent_build(task_id:, task:)
        # Notify observability engine
        @observability_engine.notify(:agent_build_started, data: {
          task_id: task_id,
          task_description: task.description,
          agent_spec: task.agent_spec.to_h
        }, source: "cli_execution_observer")

        return if @options[:quiet]
        return if @cancellation_requested # Don't start new agents if cancellation requested

        # Create agent building section if it doesn't exist
        @progress_tracker.create_section("agent_building", "Agent Assembly", "Building specialized agents for tasks")

        # Start the agent building process
        process_description = "Building agent for: #{truncate_description(task.description)}"
        @progress_tracker.start_process("agent_building", "agent_#{task_id}", process_description, {
          task_id: task_id,
          agent_spec: task.agent_spec.to_h
        })

        # Track for legacy compatibility
        @task_states[task_id] = {
          status: :building_agent,
          description: task.description,
          start_time: Time.now,
          task: task
        }
      end

      # Called after an agent is built for a task
      # @param task_id [String] The ID of the task
      # @param task [Task] The task that got an agent
      # @param agent [Agent] The built agent
      # @param build_duration [Float] The time taken to build the agent
      def after_agent_build(task_id:, task:, agent:, build_duration:)
        # Notify observability engine
        @observability_engine.notify(:agent_build_completed, data: {
          task_id: task_id,
          task_description: task.description,
          agent_role: agent.role,
          agent_purpose: agent.purpose,
          build_duration: build_duration
        }, source: "cli_execution_observer")

        return if @options[:quiet]

        # Complete the agent building process
        if @cancellation_requested
          @progress_tracker.fail_process("agent_#{task_id}", "Agent building cancelled", build_duration)
        else
          result_message = "#{agent.role} agent ready"
          @progress_tracker.complete_process("agent_#{task_id}", result_message, build_duration)
        end

        # Track built agents for legacy compatibility
        @built_agents[task_id] = {
          role: agent.role,
          build_duration: build_duration,
          task_description: task.description
        }

        # Update task state for legacy compatibility
        @task_states[task_id]&.merge!({
          status: @cancellation_requested ? :canceled : :agent_ready,
          agent_duration: build_duration,
          agent_role: agent.role
        })
      end

      # Called before a task is executed
      # @param task_id [String] The ID of the task
      # @param task [Task] The task to execute
      def before_task_execution(task_id:, task:)
        # Notify observability engine
        @observability_engine.notify(:task_started, data: {
          task_id: task_id,
          task_description: task.description,
          agent_spec: task.agent_spec.to_h,
          input: task.input
        }, source: "cli_execution_observer")

        return if @options[:quiet]
        return if @cancellation_requested # Don't start new tasks if cancellation requested

        @total_tasks += 1 unless @task_states.key?(task_id)

        # Create task execution section if it doesn't exist
        @progress_tracker.create_section("task_execution", "Task Execution", "Running tasks with assembled agents")

        # Start the task execution process
        process_description = truncate_description(task.description)
        @progress_tracker.start_process("task_execution", "task_#{task_id}", process_description, {
          task_id: task_id,
          agent_spec: task.agent_spec.to_h,
          input: task.input
        })

        # Update task state for legacy compatibility
        if @task_states[task_id]
          # Preserve existing data (like agent info) and update status
          @task_states[task_id].merge!({
            status: :in_progress,
            execution_start_time: Time.now
          })
        else
          # Create new state if it doesn't exist
          @task_states[task_id] = {
            status: :in_progress,
            description: task.description,
            start_time: Time.now,
            task: task
          }
        end
      end

      # Called after a task is successfully executed
      # @param task_id [String] The ID of the task
      # @param task [Task] The task that was executed
      # @param result [TaskResult] The result of the task
      # @param duration [Float] The duration of the task execution
      def after_task_success(task_id:, task:, result:, duration:)
        # Notify observability engine
        @observability_engine.notify(:task_completed, data: {
          task_id: task_id,
          task_description: task.description,
          status: :completed,
          duration: duration,
          output: result.output
        }, source: "cli_execution_observer")

        return if @options[:quiet]

        @completed_tasks += 1

        # Complete the task execution process
        if @cancellation_requested
          @progress_tracker.fail_process("task_#{task_id}", "Task cancelled", duration)
        else
          # Pass raw result output to ProgressTracker for smart formatting
          @progress_tracker.complete_process("task_#{task_id}", result.output, duration)
        end

        # Update task state for legacy compatibility
        @task_states[task_id]&.merge!({
          status: @cancellation_requested ? :canceled : :completed,
          duration: duration,
          output: result.output
        })
      end

      # Called after a task fails
      # @param task_id [String] The ID of the task
      # @param task [Task] The task that failed
      # @param failure [TaskFailure] The failure details
      # @param duration [Float] The duration of the task execution
      def after_task_failure(task_id:, task:, failure:, duration:)
        # Notify observability engine
        @observability_engine.notify(:task_failed, data: {
          task_id: task_id,
          task_description: task.description,
          status: :failed,
          duration: duration,
          error_message: failure.message,
          error_type: failure.type
        }, source: "cli_execution_observer")

        return if @options[:quiet]

        @failed_tasks += 1

        # Fail the task execution process
        error_message = truncate_description(failure.message, 60)
        @progress_tracker.fail_process("task_#{task_id}", error_message, duration)

        # Update task state for legacy compatibility
        @task_states[task_id]&.merge!({
          status: @cancellation_requested ? :canceled : :failed,
          duration: duration,
          error: failure.message
        })
      end

      # Called when the plan execution is completed
      # @param plan_id [String] The ID of the plan
      # @param status [Symbol] The status of the plan execution
      # @param execution_time [Float] The execution time in seconds
      # @param tasks [Hash] The tasks that were executed
      # @param results [Hash] The results of the task executions
      def plan_completed(plan_id:, status:, execution_time:, tasks:, results:)
        # Notify observability engine
        @observability_engine.notify(:plan_completed, data: {
          plan_id: plan_id,
          status: status,
          execution_time: execution_time,
          total_tasks: tasks.size,
          completed_tasks: @completed_tasks,
          failed_tasks: @failed_tasks
        }, source: "cli_execution_observer")

        return if @options[:quiet]

        # Always save to file now - determine the output path
        save_path = determine_save_path(@options[:file])
        absolute_path = File.expand_path(save_path)

        # Show consolidated final summary (includes progress summary and results)
        show_consolidated_summary(status, execution_time, absolute_path, results, tasks)
      end

      # Generates file content for saving based on the specified format
      # @param result [PlanExecutionResult] The plan execution result
      # @param format [Symbol] The target format
      # @return [String] The formatted content
      def generate_file_content(result, format)
        if format == :json
          JSON.pretty_generate(result.to_h)
        else
          # Use LLM to generate format-specific content
          generate_formatted_output(
            result.results.values.select(&:successful?),
            result.tasks,
            format
          )
        end
      end

      # Shows the initial summary panel with progress information
      # @param status [Symbol] The execution status
      # @param execution_time [Float] The execution time in seconds
      # @param absolute_path [String] The output file path
      def show_initial_summary(status, execution_time, absolute_path)
        total_time = UI.format_duration(execution_time)

        result_color = case status
        when :completed
          :green
        when :partial_failure
          :yellow
        else
          :red
        end

        # Build initial summary content
        summary_content = [
          "Status: #{UI.status_text(status, status)}",
          "Tasks: #{@total_tasks} total, " \
          "#{UI.colorize(@completed_tasks.to_s, :green)} completed, " \
          "#{UI.colorize(@failed_tasks.to_s, :red)} failed",
          "Time: #{total_time}",
          "",
          "Output: #{UI.colorize(absolute_path, :blue)}",
          "",
          "Generating output preview..."
        ]

        summary = UI.box(
          "Execution Summary",
          summary_content.join("\n"),
          style: {border: {fg: result_color}}
        )

        puts "\n#{summary}" if !summary.empty?

        # Track summary state
        @summary_lines = summary.lines.count + 1 # +1 for the newline before
        @summary_rendered = true
      end

      # Shows a consolidated final summary combining progress and results
      # @param status [Symbol] The execution status
      # @param execution_time [Float] The execution time in seconds
      # @param absolute_path [String] The output file path
      # @param results [Hash] The task execution results
      # @param tasks [Hash] The task data
      def show_consolidated_summary(status, execution_time, absolute_path, results, tasks)
        total_time = format_duration(execution_time)

        result_color = case status
        when :completed
          :green
        when :partial_failure
          :yellow
        else
          :red
        end

        # Generate progress summary
        progress_lines = []
        @progress_tracker.sections.each do |section_id, section|
          total = section[:process_count]
          completed = section[:completed_count]
          failed = section[:failed_count]

          progress_lines << if failed > 0
            "#{@progress_tracker.section_status_symbol(section)} #{section[:title]}: #{completed}/#{total} completed, #{failed} failed"
          else
            "#{@progress_tracker.section_status_symbol(section)} #{section[:title]}: #{completed}/#{total} completed"
          end
        end

        # Generate result preview
        preview = generate_output_preview(results, tasks)

        # Build consolidated summary content
        summary_content = [
          "Status: #{status_text(status)}",
          "Time: #{total_time}",
          "",
          "Progress:",
          *progress_lines.map { |line| "  #{line}" },
          "",
          "Results:",
          preview,
          "",
          "Output saved to: #{colorize_text(absolute_path, :blue)}"
        ]

        summary = create_box(
          "Execution Complete",
          summary_content.join("\n"),
          result_color
        )

        puts "\n#{summary}"
      end

      # Updates the summary panel with a specific message
      # @param status [Symbol] The execution status
      # @param execution_time [Float] The execution time in seconds
      # @param absolute_path [String] The output file path
      # @param message [String] The message to display
      def update_summary_with_message(status, execution_time, absolute_path, message)
        total_time = UI.format_duration(execution_time)

        result_color = case status
        when :completed
          :green
        when :partial_failure
          :yellow
        else
          :red
        end

        # Build summary content with the custom message
        summary_content = [
          "Status: #{UI.status_text(status, status)}",
          "Tasks: #{@total_tasks} total, " \
          "#{UI.colorize(@completed_tasks.to_s, :green)} completed, " \
          "#{UI.colorize(@failed_tasks.to_s, :red)} failed",
          "Time: #{total_time}",
          "",
          "Output: #{UI.colorize(absolute_path, :blue)}",
          "",
          message
        ]

        summary = UI.box(
          "Execution Summary",
          summary_content.join("\n"),
          style: {border: {fg: result_color}}
        )

        # Clear previous summary if it was rendered
        if @summary_rendered && @summary_lines > 0
          UI.clear_and_reposition(@summary_lines)
        end

        puts "\n#{summary}" if !summary.empty

        # Update tracking
        @summary_lines = summary.lines.count + 1 # +1 for the newline before
        @summary_rendered = true
      end

      # Handles cancellation by setting a flag (safe to call from signal context)
      def handle_cancellation
        @cancellation_requested = true
      end

      # Handle events from the observability engine
      # @param event [Observability::EventData] The event data
      def handle_event(event)
        return if @options[:quiet]
        return unless event.source == "agent_assembly_engine"

        # Display assembly steps in real-time with indentation
        indent = "  "
        case event.type
        when :agent_assembly_searching_store
          puts "#{indent}#{colorize_text("→", :blue)} Searching for existing agent..."
        when :agent_assembly_found_existing
          agent_role = event.data[:agent_role]
          puts "#{indent}#{colorize_text("✓", :green)} Found existing #{colorize_text(agent_role, :cyan)} agent"
        when :agent_assembly_no_existing
          puts "#{indent}#{colorize_text("→", :blue)} No existing agent found, assembling new..."
        when :agent_assembly_analyzing_requirements
          puts "#{indent}#{colorize_text("→", :blue)} Analyzing task requirements..."
        when :agent_assembly_requirements_analyzed
          count = event.data[:count]
          requirements = event.data[:requirements]
          @assembly_details[event.data[:task_id]] ||= {}
          @assembly_details[event.data[:task_id]][:requirements] = requirements
          req_display = requirements.first(3).join(", ")
          req_display += ", ..." if requirements.size > 3
          puts "#{indent}#{colorize_text("✓", :green)} Found #{colorize_text(count, :cyan)} required capabilities: #{req_display}"
        when :agent_assembly_selecting_capabilities
          puts "#{indent}#{colorize_text("→", :blue)} Selecting capabilities..."
        when :agent_assembly_capabilities_selected
          count = event.data[:count]
          capabilities = event.data[:capabilities]
          @assembly_details[event.data[:task_id]] ||= {}
          @assembly_details[event.data[:task_id]][:capabilities] = capabilities
          cap_display = capabilities.first(3).join(", ")
          cap_display += ", ..." if capabilities.size > 3
          puts "#{indent}#{colorize_text("✓", :green)} Selected #{colorize_text(count, :cyan)} capabilities: #{cap_display}"
        when :agent_assembly_building_agent
          puts "#{indent}#{colorize_text("→", :blue)} Constructing agent..."
        when :agent_assembly_agent_built
          agent_role = event.data[:agent_role]
          puts "#{indent}#{colorize_text("✓", :green)} #{colorize_text(agent_role, :cyan)} agent constructed"
        when :agent_assembly_storing_agent
          agent_role = event.data[:agent_role]
          puts "#{indent}#{colorize_text("→", :blue)} Storing #{agent_role} agent for reuse..."
        end
      rescue => e
        Agentic.logger.debug("Error handling agent assembly event: #{e.message}")
      end

      private

      # Determines the save path for output file
      # @param file_option [String] The file option from CLI
      # @return [String] The resolved file path
      def determine_save_path(file_option)
        if file_option
          # User specified a file path
          file_option
        else
          # Default filename with timestamp
          timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
          "result-#{timestamp}.json"
        end
      end

      # Generates a preview of the output (first 2-3 lines)
      # @param results [Hash] The task results
      # @param tasks [Hash] The task data
      # @return [String] Preview text
      def generate_output_preview(results, tasks)
        # Create semantic descriptions instead of raw output
        result_objects = results.values
        successful_results = result_objects.select(&:successful?)

        if successful_results.empty?
          return "  No successful task outputs"
        end

        # Generate semantic descriptions for each result
        descriptions = successful_results.map.with_index do |result, index|
          task_id = result.respond_to?(:task_id) ? result.task_id : "task_#{index + 1}"
          task_info = tasks[task_id] || {}
          description = task_info[:description] || "Task #{index + 1}"

          # Create meaningful summary from result
          summary = summarize_result(result.output, description)
          "• #{summary}"
        end

        # Take first 3 descriptions
        preview_lines = descriptions.first(3)
        if descriptions.length > 3
          preview_lines << "• ... (#{descriptions.length - 3} more)"
        end

        preview_lines.map { |line| "  #{line}" }.join("\n")
      end

      # Summarizes a result in a human-readable way
      # @param output [Object] The task output
      # @param description [String] The task description
      # @return [String] Human-readable summary
      def summarize_result(output, description)
        return truncate_description(description) + " completed" if output.nil? || output.to_s.strip.empty?

        # If output looks like JSON, extract meaningful information
        if output.is_a?(String) && output.strip.start_with?("{")
          begin
            parsed = JSON.parse(output)
            if parsed.is_a?(Hash)
              # Look for common patterns
              if parsed.key?("interview_questions") && parsed["interview_questions"].is_a?(Array)
                count = parsed["interview_questions"].length
                return "Interview questions prepared: #{count} questions covering key topics"
              elsif parsed.key?("report") || parsed.key?("Report")
                return "Report compiled: Structured guide with talking points and research"
              elsif parsed.key?("research") || parsed.keys.any? { |k| k.to_s.downcase.include?("background") }
                return "Background research completed: Key information gathered"
              elsif parsed.key?("questions") && parsed["questions"].is_a?(Array)
                count = parsed["questions"].length
                return "Questions formulated: #{count} interview questions prepared"
              else
                # Generic handling for other structured data
                key_count = parsed.keys.length
                return "#{truncate_description(description)} completed: #{key_count} data sections generated"
              end
            end
          rescue JSON::ParserError
            # Fall through to simple text handling
          end
        end

        # For simple text results
        if description.downcase.include?("research")
          "Research completed: Background information gathered"
        elsif description.downcase.include?("question")
          "Questions prepared: Interview questions formulated"
        elsif description.downcase.include?("report")
          "Report completed: Information organized and structured"
        elsif description.downcase.include?("review") || description.downcase.include?("finalize")
          "Review completed: Final report verified and ready"
        else
          "#{truncate_description(description, 40)} completed"
        end
      end

      # Truncates a description to a specified length
      # @param description [String] The description to truncate
      # @param max_length [Integer] Maximum length (default: 80)
      # @return [String] Truncated description
      def truncate_description(description, max_length = 80)
        return description if description.length <= max_length
        "#{description[0..max_length - 4]}..."
      end

      # Formats a task result for display
      # @param output [Object] The task output
      # @return [String] Formatted result message
      def format_task_result(output)
        return "completed" if output.nil? || output.to_s.strip.empty?

        output_text = output.to_s.strip
        return truncate_description(output_text, 60) if output_text.length > 60
        output_text
      end

      # Formats duration in a human-readable way
      # @param seconds [Float] Duration in seconds
      # @return [String] Formatted duration
      def format_duration(seconds)
        if seconds < 1
          "#{(seconds * 1000).round}ms"
        elsif seconds < 60
          "#{seconds.round(1)}s"
        else
          "#{(seconds / 60).round(1)}m"
        end
      end

      # Colorizes text unless no_color is set
      # @param text [String] Text to colorize
      # @param color [Symbol] Color to apply
      # @return [String] Colorized or plain text
      def colorize_text(text, color)
        @options[:no_color] ? text : UI.colorize(text, color)
      end

      # Creates a status text with appropriate color
      # @param status [Symbol] The status
      # @return [String] Colored status text
      def status_text(status)
        case status
        when :completed
          colorize_text("✓ Completed", :green)
        when :partial_failure
          colorize_text("⚠ Partial Success", :yellow)
        when :failed
          colorize_text("✗ Failed", :red)
        else
          colorize_text(status.to_s, :blue)
        end
      end

      # Creates a box for display
      # @param title [String] Box title
      # @param content [String] Box content
      # @param border_color [Symbol] Border color
      # @return [String] Formatted box
      def create_box(title, content, border_color)
        return "#{title}:\n#{content}" if @options[:no_color]

        UI.box(title, content, style: {border: {fg: border_color}})
      end

      # Formats consolidated output from all task results
      # @param results [Hash] Hash of task_id => TaskExecutionResult
      # @param tasks [Hash] Hash of task_id => Task data
      # @return [String] Formatted output
      def format_consolidated_output(results, tasks)
        # Convert hash values to array and filter successful results
        result_objects = results.values
        successful_results = result_objects.select(&:successful?)

        if successful_results.empty?
          colorize_text("No successful task outputs", :yellow)
        elsif @output_format == :text
          # Simple text format (existing behavior)
          outputs = successful_results.map.with_index do |result, index|
            output = result.output.to_s.strip
            if output.empty?
              "#{index + 1}. (no output)"
            else
              "#{index + 1}. #{output}"
            end
          end
          outputs.join("\n")
        else
          # Use LLM to generate format-specific output
          generate_formatted_output(successful_results, tasks, @output_format)
        end
      end

      # Generates format-specific output using LLM
      # @param successful_results [Array<TaskExecutionResult>] The successful task results
      # @param tasks [Hash] Hash of task_id => Task data
      # @param format [Symbol] The target format (:markdown, :html, :json, :yaml)
      # @return [String] Formatted output
      def generate_formatted_output(successful_results, tasks, format)
        return simple_format_fallback(successful_results) if successful_results.empty?

        # Prepare task data for LLM
        task_summaries = successful_results.map.with_index do |result, index|
          task_id = result.respond_to?(:task_id) ? result.task_id : "task_#{index + 1}"
          task_info = tasks[task_id] || {}

          {
            index: index + 1,
            description: task_info[:description] || "Task #{index + 1}",
            output: result.output.to_s.strip
          }
        end

        # Generate format-specific prompt
        prompt = build_formatting_prompt(task_summaries, format)

        # Use LLM to generate formatted output
        begin
          llm_config = Agentic::LlmConfig.new
          llm_client = Agentic::LlmClient.new(llm_config)

          response = llm_client.complete([
            {role: "user", content: prompt}
          ])

          if response.successful?
            response.content
          else
            simple_format_fallback(successful_results)
          end
        rescue => e
          Agentic.logger.warn("Failed to generate formatted output: #{e.message}")
          simple_format_fallback(successful_results)
        end
      end

      # Builds a prompt for LLM to format the output
      # @param task_summaries [Array<Hash>] Array of task summary data
      # @param format [Symbol] The target format
      # @return [String] The formatting prompt
      def build_formatting_prompt(task_summaries, format)
        case format
        when :markdown
          build_markdown_prompt(task_summaries)
        when :html
          build_html_prompt(task_summaries)
        when :json
          build_json_prompt(task_summaries)
        when :yaml
          build_yaml_prompt(task_summaries)
        else
          build_generic_prompt(task_summaries, format)
        end
      end

      # Builds markdown formatting prompt
      def build_markdown_prompt(task_summaries)
        task_data = task_summaries.map do |task|
          "#{task[:index]}. **#{task[:description]}**\n   Result: #{task[:output]}"
        end.join("\n\n")

        <<~PROMPT
          Please format the following task execution results as a clean, professional Markdown document:

          #{task_data}

          Requirements:
          - Use appropriate headings and structure
          - Make it readable and well-organized
          - Include a summary section
          - Use proper Markdown formatting
          - Keep the content concise but informative
        PROMPT
      end

      # Builds HTML formatting prompt
      def build_html_prompt(task_summaries)
        task_data = task_summaries.map do |task|
          "#{task[:index]}. #{task[:description]} → #{task[:output]}"
        end.join("\n")

        <<~PROMPT
          Please format the following task execution results as clean HTML:

          #{task_data}

          Requirements:
          - Use semantic HTML elements
          - Include basic styling for readability
          - Structure with headings and lists
          - Make it professional and clean
          - Include a summary section
        PROMPT
      end

      # Builds JSON formatting prompt
      def build_json_prompt(task_summaries)
        <<~PROMPT
          Please format the following task execution results as a well-structured JSON document:

          #{task_summaries.map { |t| "#{t[:index]}. #{t[:description]} → #{t[:output]}" }.join("\n")}

          Requirements:
          - Create a structured JSON with summary, tasks array, and metadata
          - Include task descriptions, outputs, and indices
          - Make it easy to parse programmatically
          - Add relevant metadata like timestamp, total tasks, etc.
        PROMPT
      end

      # Builds YAML formatting prompt
      def build_yaml_prompt(task_summaries)
        <<~PROMPT
          Please format the following task execution results as clean YAML:

          #{task_summaries.map { |t| "#{t[:index]}. #{t[:description]} → #{t[:output]}" }.join("\n")}

          Requirements:
          - Use proper YAML structure with summary and tasks
          - Include task descriptions and outputs
          - Make it readable and well-organized
          - Add metadata section
        PROMPT
      end

      # Builds generic formatting prompt
      def build_generic_prompt(task_summaries, format)
        task_data = task_summaries.map do |task|
          "#{task[:index]}. #{task[:description]} → #{task[:output]}"
        end.join("\n")

        <<~PROMPT
          Please format the following task execution results in #{format} format:

          #{task_data}

          Make it well-structured, professional, and appropriate for the #{format} format.
        PROMPT
      end

      # Simple fallback formatting when LLM is unavailable
      def simple_format_fallback(successful_results)
        outputs = successful_results.map.with_index do |result, index|
          output = result.output.to_s.strip
          if output.empty?
            "#{index + 1}. (no output)"
          else
            "#{index + 1}. #{output}"
          end
        end
        outputs.join("\n")
      end
    end
  end
end
