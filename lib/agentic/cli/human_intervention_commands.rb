# frozen_string_literal: true

require "thor"
require "json"
require "yaml"

module Agentic
  class CLI
    # Human Intervention Portal CLI commands
    #
    # Provides comprehensive command-line interface for human oversight including:
    # - Request management and viewing
    # - Interactive approval processes
    # - User role management
    # - Real-time monitoring and statistics
    # - Portal administration
    #
    # Design Goals:
    # 1. Seamless integration with existing Thor CLI architecture
    # 2. Intuitive workflow for human reviewers
    # 3. Rich formatting and status visualization
    # 4. Comprehensive audit trail and logging
    # 5. Role-based access control enforcement
    class HumanInterventionCommands < Thor
      class_option :format, type: :string, enum: %w[table json yaml text], default: "table",
        desc: "Output format for data display"
      class_option :verbose, type: :boolean, aliases: "-v",
        desc: "Enable verbose output with detailed information"

      def initialize(*args)
        super
        @portal = ensure_portal_initialized
      end

      desc "list [STATUS]", "List intervention requests"
      long_desc <<-LONGDESC
        Lists intervention requests with optional status filtering.

        Available statuses: pending, in_review, approved, rejected, escalated, timeout, cancelled

        Examples:
          $ agentic portal list                    # Show all requests
          $ agentic portal list pending            # Show only pending requests
          $ agentic portal list --format=json     # JSON output format
      LONGDESC
      option :assignee, type: :string, aliases: "-a",
        desc: "Filter by assigned user"
      option :type, type: :string, aliases: "-t",
        desc: "Filter by intervention type"
      option :priority, type: :numeric, aliases: "-p",
        desc: "Filter by priority level (1-5)"
      option :limit, type: :numeric, aliases: "-l", default: 50,
        desc: "Maximum number of requests to show"
      def list(status = nil)
        requests = @portal.list_requests(
          status: status&.to_sym,
          assigned_to: options[:assignee],
          type: options[:type]&.to_sym,
          priority: options[:priority],
          limit: options[:limit]
        )

        if requests.empty?
          display_empty_state(status)
          return
        end

        case options[:format]
        when "json"
          puts JSON.pretty_generate(requests.map(&:to_h))
        when "yaml"
          puts YAML.dump(requests.map(&:to_h))
        when "text"
          display_requests_text(requests)
        else # table
          display_requests_table(requests)
        end

        display_summary_info(requests) unless options[:format] == "json" || options[:format] == "yaml"
      end

      desc "show ID", "Show detailed information about an intervention request"
      long_desc <<-LONGDESC
        Displays comprehensive information about a specific intervention request including:
        - Request details and context
        - Assignment and status history
        - Audit trail with timestamps
        - Available response options

        Example:
          $ agentic portal show abc123-def456-789
      LONGDESC
      def show(request_id)
        request = @portal.get_request(request_id)

        unless request
          display_error("Request '#{request_id}' not found")
          exit 1
        end

        case options[:format]
        when "json"
          puts JSON.pretty_generate(request.to_h)
        when "yaml"
          puts YAML.dump(request.to_h)
        else
          display_request_details(request)
        end
      end

      desc "respond ID", "Respond to an intervention request"
      long_desc <<-LONGDESC
        Provides interactive interface for responding to intervention requests.
        
        The command will prompt for:
        - Decision (approve/reject)
        - Comment explaining the decision
        - Additional response data if applicable

        Example:
          $ agentic portal respond abc123-def456-789
      LONGDESC
      option :decision, type: :string, enum: %w[approve reject], aliases: "-d",
        desc: "Auto-approve or reject without interactive prompt"
      option :comment, type: :string, aliases: "-c",
        desc: "Response comment"
      option :user, type: :string, aliases: "-u",
        desc: "Responding user (defaults to system user)"
      def respond(request_id)
        request = @portal.get_request(request_id)

        unless request
          display_error("Request '#{request_id}' not found")
          exit 1
        end

        unless request.actionable?
          display_warning("Request is not actionable (status: #{request.status}, expired: #{request.expired?})")
          return
        end

        # Get or prompt for decision
        decision = options[:decision]&.to_sym
        unless decision
          display_request_summary(request)
          decision = prompt_for_decision
          return if decision.nil? # User cancelled
        end

        # Get or prompt for comment
        comment = options[:comment]
        comment ||= prompt_for_comment if decision

        # Get responding user
        user = options[:user] || current_user || "cli_user"

        # Submit response
        begin
          response = @portal.respond_to_request(
            request_id,
            decision: decision,
            user: user,
            comment: comment
          )

          display_response_success(request, response)
        rescue => e
          display_error("Failed to submit response: #{e.message}")
          exit 1
        end
      end

      desc "assign ID USER", "Assign an intervention request to a user"
      long_desc <<-LONGDESC
        Assigns an intervention request to a specific user for review.
        
        Example:
          $ agentic portal assign abc123-def456-789 reviewer@company.com
      LONGDESC
      option :assigned_by, type: :string,
        desc: "User making the assignment (defaults to current user)"
      def assign(request_id, user)
        request = @portal.get_request(request_id)

        unless request
          display_error("Request '#{request_id}' not found")
          exit 1
        end

        assigned_by = options[:assigned_by] || current_user || "cli_user"

        begin
          @portal.assign_request(request_id, user: user, assigned_by: assigned_by)

          puts UI.box(
            "Assignment Complete",
            "Request #{UI.colorize(request_id[0..7], :blue)} has been assigned to #{UI.colorize(user, :green)}",
            padding: [1, 2, 1, 2],
            style: {border: {fg: :green}}
          )
        rescue => e
          display_error("Failed to assign request: #{e.message}")
          exit 1
        end
      end

      desc "stats", "Display portal statistics and health information"
      long_desc <<-LONGDESC
        Shows comprehensive portal statistics including:
        - Request volume and status distribution
        - Response time metrics
        - User activity and workload
        - System health indicators

        Example:
          $ agentic portal stats --verbose
      LONGDESC
      def stats
        stats = @portal.stats
        health = @portal.health_check

        case options[:format]
        when "json"
          puts JSON.pretty_generate({statistics: stats, health: health})
        when "yaml"
          puts YAML.dump({statistics: stats, health: health})
        else
          display_stats_dashboard(stats, health)
        end
      end

      desc "users", "Manage portal users and roles"
      long_desc <<-LONGDESC
        User management subcommands for role-based access control.
        
        Examples:
          $ agentic portal users list
          $ agentic portal users add reviewer@company.com --role=reviewer
          $ agentic portal users show reviewer@company.com
      LONGDESC
      option :role, type: :string, enum: %w[viewer reviewer approver admin],
        desc: "User role for access control"
      option :metadata, type: :hash,
        desc: "Additional user metadata (key:value pairs)"
      def users(action = "list", username = nil)
        case action
        when "list"
          display_users_list
        when "add"
          add_user(username, options[:role], options[:metadata] || {})
        when "show"
          show_user(username)
        when "remove"
          remove_user(username)
        else
          display_error("Unknown user action: #{action}")
          puts "Available actions: list, add, show, remove"
          exit 1
        end
      end

      desc "monitor", "Start real-time monitoring of portal activity"
      long_desc <<-LONGDESC
        Starts real-time monitoring interface showing:
        - New intervention requests as they arrive
        - Status changes and responses
        - System health metrics
        - Alert notifications

        Example:
          $ agentic portal monitor
      LONGDESC
      option :refresh, type: :numeric, default: 5,
        desc: "Refresh interval in seconds"
      option :alerts_only, type: :boolean,
        desc: "Show only alert conditions"
      def monitor
        puts UI.colorize("🔍 Starting portal monitoring (refresh every #{options[:refresh]}s)", :blue)
        puts UI.colorize("Press Ctrl+C to stop", :dark)
        puts

        setup_signal_handler

        loop do
          display_monitoring_dashboard
          sleep(options[:refresh])
        rescue Interrupt
          puts "\n#{UI.colorize("Monitoring stopped", :yellow)}"
          break
        rescue => e
          puts UI.colorize("Monitor error: #{e.message}", :red)
          sleep(options[:refresh])
        end
      end

      desc "health", "Check portal health and system status"
      long_desc <<-LONGDESC
        Performs comprehensive health check of the portal system including:
        - Request processing capacity
        - Response time performance
        - Memory and resource usage
        - External dependency status

        Example:
          $ agentic portal health
      LONGDESC
      def health
        health_status = @portal.health_check

        case options[:format]
        when "json"
          puts JSON.pretty_generate(health_status)
        when "yaml"
          puts YAML.dump(health_status)
        else
          display_health_dashboard(health_status)
        end

        # Exit with appropriate code based on health status
        exit_code = case health_status[:status]
        when :healthy then 0
        when :warning then 1
        when :critical then 2
        else 3
        end

        exit exit_code
      end

      private

      # Initialize portal instance
      def ensure_portal_initialized
        # In a real implementation, this would load configuration and initialize the portal
        # For now, create a basic instance with default configuration
        Agentic::HumanIntervention::Portal.new
      end

      # Display empty state when no requests are found
      def display_empty_state(status)
        message = if status
          "No intervention requests found with status '#{status}'"
        else
          "No intervention requests found"
        end

        puts UI.box(
          "Intervention Requests",
          "#{message}\n\n" \
          "Requests will appear here when agents need human oversight for:\n" \
          "- Ethical review and validation\n" \
          "- Domain expertise consultation\n" \
          "- Novel situation handling\n" \
          "- Resource authorization",
          padding: [1, 2, 1, 2],
          style: {border: {fg: :blue}}
        )
      end

      # Display requests in table format
      def display_requests_table(requests)
        puts UI.colorize("Intervention Requests", :blue)
        puts "─" * 120

        printf "%-12s %-10s %-8s %-20s %-15s %-25s %s\n",
          "ID", "STATUS", "PRIORITY", "TYPE", "REQUESTER", "TITLE", "CREATED"

        puts "─" * 120

        requests.each do |request|
          status_color = status_color_for(request.status)
          priority_indicator = priority_indicator_for(request.priority)

          printf "%-12s %-10s %-8s %-20s %-15s %-25s %s\n",
            request.id[0..10],
            UI.colorize(request.status.to_s.upcase, status_color),
            priority_indicator,
            request.type.to_s.tr("_", " ").capitalize,
            request.requester[0..13],
            truncate(request.title, 23),
            format_timestamp(request.created_at)
        end

        puts "─" * 120
      end

      # Display requests in text format
      def display_requests_text(requests)
        requests.each_with_index do |request, index|
          puts if index > 0

          status_color = status_color_for(request.status)

          puts "#{UI.colorize("Request:", :blue)} #{request.id}"
          puts "#{UI.colorize("Status:", :dark)} #{UI.colorize(request.status.to_s.capitalize, status_color)}"
          puts "#{UI.colorize("Priority:", :dark)} #{priority_indicator_for(request.priority)} (#{request.priority})"
          puts "#{UI.colorize("Type:", :dark)} #{request.type.to_s.tr("_", " ").capitalize}"
          puts "#{UI.colorize("Title:", :dark)} #{request.title}"
          puts "#{UI.colorize("Requester:", :dark)} #{request.requester}"
          puts "#{UI.colorize("Created:", :dark)} #{format_timestamp(request.created_at)}"
          puts "#{UI.colorize("Assigned to:", :dark)} #{request.assigned_to || "Unassigned"}" if request.assigned_to
        end
      end

      # Display detailed information about a single request
      def display_request_details(request)
        status_color = status_color_for(request.status)

        content = []

        # Basic information
        content << "#{UI.colorize("ID:", :blue)} #{request.id}"
        content << "#{UI.colorize("Status:", :blue)} #{UI.colorize(request.status.to_s.capitalize, status_color)}"
        content << "#{UI.colorize("Priority:", :blue)} #{priority_indicator_for(request.priority)} (#{request.priority})"
        content << "#{UI.colorize("Type:", :blue)} #{request.type.to_s.tr("_", " ").capitalize}"
        content << ""

        # Request details
        content << "#{UI.colorize("Title:", :green)} #{request.title}"
        content << UI.colorize("Description:", :green).to_s
        content << indent_text(request.description, 2)
        content << ""

        # Metadata
        content << "#{UI.colorize("Requester:", :dark)} #{request.requester}"
        content << "#{UI.colorize("Created:", :dark)} #{format_timestamp(request.created_at)}"
        content << "#{UI.colorize("Updated:", :dark)} #{format_timestamp(request.updated_at)}"
        content << "#{UI.colorize("Expires:", :dark)} #{format_timestamp(request.expires_at)}"
        content << "#{UI.colorize("Assigned to:", :dark)} #{request.assigned_to || "Unassigned"}"

        # Status indicators
        status_indicators = []
        status_indicators << UI.colorize("EXPIRED", :red) if request.expired?
        status_indicators << UI.colorize("ACTIONABLE", :green) if request.actionable?
        content << "#{UI.colorize("Flags:", :dark)} #{status_indicators.join(", ")}" unless status_indicators.empty?

        # Context and options if available
        unless request.context.empty?
          content << ""
          content << UI.colorize("Context:", :magenta).to_s
          request.context.each do |key, value|
            content << "  #{key}: #{value}"
          end
        end

        unless request.options.empty?
          content << ""
          content << UI.colorize("Options:", :magenta).to_s
          request.options.each_with_index do |option, index|
            content << "  #{index + 1}. #{option}"
          end
        end

        # Audit trail
        unless request.audit_trail.empty?
          content << ""
          content << UI.colorize("Audit Trail:", :yellow).to_s
          request.audit_trail.each do |entry|
            timestamp = Time.parse(entry[:timestamp]).strftime("%Y-%m-%d %H:%M:%S")
            action = entry[:action].to_s.tr("_", " ").capitalize
            content << "  #{timestamp} - #{action}"

            if entry[:details] && !entry[:details].empty?
              entry[:details].each do |key, value|
                content << "    #{key}: #{value}"
              end
            end
          end
        end

        puts UI.box(
          "Intervention Request Details",
          content.join("\n"),
          padding: [1, 2, 1, 2],
          style: {border: {fg: :blue}}
        )
      end

      # Display a summary of the request for response prompts
      def display_request_summary(request)
        puts UI.box(
          "Intervention Request",
          "#{UI.colorize("Title:", :blue)} #{request.title}\n\n" \
          "#{UI.colorize("Description:", :blue)}\n#{indent_text(request.description, 2)}\n\n" \
          "#{UI.colorize("Type:", :blue)} #{request.type.to_s.tr("_", " ").capitalize}\n" \
          "#{UI.colorize("Priority:", :blue)} #{priority_indicator_for(request.priority)} (#{request.priority})\n" \
          "#{UI.colorize("Requester:", :blue)} #{request.requester}",
          padding: [1, 2, 1, 2],
          style: {border: {fg: :yellow}}
        )
      end

      # Prompt user for approve/reject decision
      def prompt_for_decision
        puts UI.colorize("\nPlease choose your response:", :cyan)
        puts "1. #{UI.colorize("Approve", :green)} - Grant approval for this request"
        puts "2. #{UI.colorize("Reject", :red)} - Deny approval for this request"
        puts "3. #{UI.colorize("Cancel", :yellow)} - Exit without responding"

        loop do
          print UI.colorize("Enter your choice (1/2/3): ", :cyan)
          choice = $stdin.gets&.chomp

          case choice
          when "1", "approve", "a"
            return :approved
          when "2", "reject", "r"
            return :rejected
          when "3", "cancel", "c", ""
            puts UI.colorize("Response cancelled", :yellow)
            return nil
          else
            puts UI.colorize("Invalid choice. Please enter 1, 2, or 3.", :red)
          end
        end
      end

      # Prompt user for response comment
      def prompt_for_comment
        puts UI.colorize("\nOptional: Provide a comment explaining your decision", :cyan)
        puts UI.colorize("(Press Enter to skip or type your comment)", :dark)
        print UI.colorize("Comment: ", :cyan)

        comment = $stdin.gets&.chomp
        comment.empty? ? nil : comment
      end

      # Display successful response submission
      def display_response_success(request, response)
        decision_text = response.approved? ?
          UI.colorize("APPROVED", :green) :
          UI.colorize("REJECTED", :red)

        content = []
        content << "Response submitted successfully!"
        content << ""
        content << "#{UI.colorize("Request:", :blue)} #{request.title}"
        content << "#{UI.colorize("Decision:", :blue)} #{decision_text}"
        content << "#{UI.colorize("User:", :blue)} #{response.user}"
        content << "#{UI.colorize("Timestamp:", :blue)} #{format_timestamp(response.timestamp)}"

        if response.comment
          content << "#{UI.colorize("Comment:", :blue)} #{response.comment}"
        end

        puts UI.box(
          "Response Submitted",
          content.join("\n"),
          padding: [1, 2, 1, 2],
          style: {border: {fg: :green}}
        )
      end

      # Display summary information about requests
      def display_summary_info(requests)
        total = requests.size
        status_counts = requests.group_by(&:status).transform_values(&:size)
        priority_counts = requests.group_by(&:priority).transform_values(&:size)

        puts
        puts UI.colorize("Summary:", :blue)
        puts "  Total requests: #{total}"

        if status_counts.any?
          status_summary = status_counts.map { |status, count| "#{status}: #{count}" }.join(", ")
          puts "  Status breakdown: #{status_summary}"
        end

        if priority_counts.any?
          priority_summary = priority_counts.map { |priority, count| "priority #{priority}: #{count}" }.join(", ")
          puts "  Priority breakdown: #{priority_summary}"
        end
      end

      # Display statistics dashboard
      def display_stats_dashboard(stats, health)
        content = []

        # Request statistics
        content << UI.colorize("Request Statistics:", :green).to_s
        content << "  Total requests: #{stats[:total_requests]}"
        content << "  Active requests: #{stats[:active_requests]}"
        content << "  Pending requests: #{stats[:pending_requests]}"
        content << "  Approved: #{stats[:approved]}"
        content << "  Rejected: #{stats[:rejected]}"
        content << "  Expired: #{stats[:expired_requests]}"
        content << ""

        # Performance metrics
        content << UI.colorize("Performance Metrics:", :green).to_s
        content << "  Average response time: #{format_duration(stats[:average_response_time])}"
        content << "  Total responses: #{stats[:total_responses]}"
        content << "  Registered users: #{stats[:registered_users]}"
        content << ""

        # Health status
        health_color = case health[:status]
        when :healthy then :green
        when :warning then :yellow
        when :critical, :overloaded, :degraded, :slow then :red
        else :blue
        end

        content << UI.colorize("System Health:", :green).to_s
        content << "  Status: #{UI.colorize(health[:status].to_s.capitalize, health_color)}"

        puts UI.box(
          "Portal Statistics",
          content.join("\n"),
          padding: [1, 2, 1, 2],
          style: {border: {fg: :blue}}
        )
      end

      # Display health dashboard
      def display_health_dashboard(health_status)
        status_color = case health_status[:status]
        when :healthy then :green
        when :warning then :yellow
        else :red
        end

        content = []
        content << "#{UI.colorize("Overall Status:", :blue)} #{UI.colorize(health_status[:status].to_s.capitalize, status_color)}"
        content << ""
        content << UI.colorize("Metrics:", :blue).to_s
        content << "  Active requests: #{health_status[:active_requests]}"
        content << "  Pending requests: #{health_status[:pending_requests]}"
        content << "  Expired requests: #{health_status[:expired_requests]}"
        content << "  Average response time: #{format_duration(health_status[:average_response_time])}"
        content << "  Registered users: #{health_status[:registered_users]}"

        puts UI.box(
          "Portal Health Check",
          content.join("\n"),
          padding: [1, 2, 1, 2],
          style: {border: {fg: status_color}}
        )
      end

      # Display monitoring dashboard
      def display_monitoring_dashboard
        system("clear") unless ENV["NO_CLEAR"]

        puts UI.colorize("🔍 Human Intervention Portal Monitor", :blue)
        puts UI.colorize("─" * 60, :dark)
        puts

        # Get current stats and health
        stats = @portal.stats
        health = @portal.health_check

        # Recent requests (last 10)
        recent_requests = @portal.list_requests(limit: 10)

        puts UI.colorize("Recent Activity:", :green)
        if recent_requests.empty?
          puts "  No recent activity"
        else
          recent_requests.first(5).each do |request|
            status_color = status_color_for(request.status)
            age = time_ago(request.created_at)
            puts "  #{UI.colorize(request.status.to_s.upcase.ljust(10), status_color)} #{truncate(request.title, 30)} (#{age})"
          end
        end
        puts

        # Quick stats
        puts UI.colorize("Current Status:", :green)
        puts "  Health: #{UI.colorize(health[:status].to_s.capitalize, (health[:status] == :healthy) ? :green : :red)}"
        puts "  Active: #{stats[:active_requests]}  Pending: #{stats[:pending_requests]}  Users: #{stats[:registered_users]}"
        puts "  Avg Response: #{format_duration(stats[:average_response_time])}"
        puts

        puts UI.colorize("Last updated: #{Time.now.strftime("%H:%M:%S")}", :dark)
      end

      # Helper methods

      def status_color_for(status)
        case status
        when :pending then :yellow
        when :in_review then :blue
        when :approved then :green
        when :rejected then :red
        when :escalated then :magenta
        when :timeout then :red
        when :cancelled then :dark
        else :white
        end
      end

      def priority_indicator_for(priority)
        case priority
        when 5 then UI.colorize("🔥", :red)    # Emergency
        when 4 then UI.colorize("❗", :red)    # Critical
        when 3 then UI.colorize("⚠️", :yellow)  # High
        when 2 then UI.colorize("📋", :blue)   # Normal
        when 1 then UI.colorize("📝", :dark)   # Low
        else UI.colorize("❓", :white)
        end
      end

      def format_timestamp(time)
        return "N/A" unless time
        time.strftime("%Y-%m-%d %H:%M")
      end

      def format_duration(seconds)
        return "0s" unless seconds && seconds > 0

        if seconds < 60
          "#{seconds.round(1)}s"
        elsif seconds < 3600
          "#{(seconds / 60).round(1)}m"
        else
          hours = seconds / 3600
          minutes = (seconds % 3600) / 60
          "#{hours.round(1)}h #{minutes.round}m"
        end
      end

      def time_ago(time)
        return "unknown" unless time

        diff = Time.now - time

        case diff
        when 0..60
          "#{diff.round}s ago"
        when 60..3600
          "#{(diff / 60).round}m ago"
        when 3600..86400
          "#{(diff / 3600).round}h ago"
        else
          "#{(diff / 86400).round}d ago"
        end
      end

      def truncate(text, length)
        return text unless text
        (text.length > length) ? "#{text[0..length - 4]}..." : text
      end

      def indent_text(text, spaces)
        prefix = " " * spaces
        text.split("\n").map { |line| "#{prefix}#{line}" }.join("\n")
      end

      def current_user
        ENV["USER"] || ENV["USERNAME"] || "unknown"
      end

      def setup_signal_handler
        Signal.trap("INT") do
          puts "\n#{UI.colorize("Monitoring stopped by user", :yellow)}"
          exit(0)
        end
      end

      def display_error(message)
        puts UI.box(
          "Error",
          message,
          padding: [1, 2, 1, 2],
          style: {border: {fg: :red}}
        )
      end

      def display_warning(message)
        puts UI.box(
          "Warning",
          message,
          padding: [1, 2, 1, 2],
          style: {border: {fg: :yellow}}
        )
      end

      # User management methods (placeholder implementations)
      def display_users_list
        puts UI.colorize("User management not yet implemented", :yellow)
      end

      def add_user(username, role, metadata)
        puts UI.colorize("User management not yet implemented", :yellow)
      end

      def show_user(username)
        puts UI.colorize("User management not yet implemented", :yellow)
      end

      def remove_user(username)
        puts UI.colorize("User management not yet implemented", :yellow)
      end
    end
  end
end
