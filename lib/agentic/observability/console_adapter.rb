# frozen_string_literal: true

module Agentic
  module Observability
    # Console adapter for outputting events to STDOUT/STDERR
    # Provides formatted, human-readable output for CLI usage
    class ConsoleAdapter < BaseAdapter
      # Color codes for different event types
      COLORS = {
        task_started: :blue,
        task_completed: :green,
        task_failed: :red,
        agent_build_started: :cyan,
        agent_build_completed: :cyan,
        plan_started: :yellow,
        plan_completed: :green,
        plan_failed: :red,
        error: :red,
        warning: :yellow,
        info: :blue,
        debug: :gray
      }.freeze

      # Default format for events
      DEFAULT_FORMAT = "[%{timestamp}] %{type}: %{message}"

      def initialize(config = {})
        super
        @format = config[:format] || DEFAULT_FORMAT
        @color_enabled = config.fetch(:color, true)
        @timestamp_format = config[:timestamp_format] || "%H:%M:%S"
        @output_stream = config[:output_stream] || $stdout
        @verbose = config.fetch(:verbose, false)
      end

      # Handle event by outputting formatted message to console
      # @param event_data [EventData] The event to output
      def handle_event(event_data)
        with_error_handling(event_data) do
          output = format_event(event_data)
          @output_stream.puts(output)
          @output_stream.flush
        end
      end

      # Get extended status including console-specific information
      # @return [Hash] Status with console adapter details
      def status
        super.merge({
          format: @format,
          color_enabled: @color_enabled,
          timestamp_format: @timestamp_format,
          verbose: @verbose
        })
      end

      private

      def format_event(event_data)
        timestamp = format_timestamp(event_data.timestamp)
        message = extract_message(event_data)
        type = event_data.type.to_s

        formatted = @format % {
          timestamp: timestamp,
          type: type,
          message: message,
          source: event_data.source || "unknown"
        }

        apply_color(formatted, event_data.type)
      end

      def format_timestamp(timestamp_str)
        time = timestamp_str.is_a?(String) ? Time.parse(timestamp_str) : timestamp_str
        time.strftime(@timestamp_format)
      rescue ArgumentError
        timestamp_str.to_s
      end

      def extract_message(event_data)
        data = event_data.data

        # Try common message fields
        return data[:message] if data[:message]
        return data[:description] if data[:description]
        return data["message"] if data["message"]
        return data["description"] if data["description"]

        # For specific event types, create meaningful messages
        case event_data.type
        when :task_started
          "Task started: #{data[:task_description] || data[:task_id] || "Unknown task"}"
        when :task_completed
          duration = data[:duration] ? " (#{data[:duration]}s)" : ""
          "Task completed: #{data[:task_description] || data[:task_id] || "Unknown task"}#{duration}"
        when :task_failed
          error = data[:error] ? " - #{data[:error]}" : ""
          "Task failed: #{data[:task_description] || data[:task_id] || "Unknown task"}#{error}"
        when :agent_build_started
          "Building agent: #{data[:agent_name] || "Unknown agent"}"
        when :agent_build_completed
          "Agent built: #{data[:agent_name] || "Unknown agent"}"
        when :plan_started
          "Plan started: #{data[:goal] || "Unknown goal"}"
        when :plan_completed
          task_count = data[:task_count] ? " (#{data[:task_count]} tasks)" : ""
          "Plan completed: #{data[:goal] || "Unknown goal"}#{task_count}"
        when :plan_failed
          error = data[:error] ? " - #{data[:error]}" : ""
          "Plan failed: #{data[:goal] || "Unknown goal"}#{error}"
        else
          # Fallback: show data in verbose mode, otherwise just type
          if @verbose && data.any?
            data.inspect
          else
            event_data.type.to_s.humanize
          end
        end
      end

      def apply_color(text, event_type)
        return text unless @color_enabled

        color = COLORS[event_type] || :default
        colorize(text, color)
      end

      def colorize(text, color)
        case color
        when :red
          "\e[31m#{text}\e[0m"
        when :green
          "\e[32m#{text}\e[0m"
        when :yellow
          "\e[33m#{text}\e[0m"
        when :blue
          "\e[34m#{text}\e[0m"
        when :cyan
          "\e[36m#{text}\e[0m"
        when :gray
          "\e[37m#{text}\e[0m"
        else
          text
        end
      end
    end
  end
end

# Add string humanize method if not available
class String
  unless method_defined?(:humanize)
    def humanize
      tr("_", " ").gsub(/\b\w/) { |match| match.upcase }
    end
  end
end
