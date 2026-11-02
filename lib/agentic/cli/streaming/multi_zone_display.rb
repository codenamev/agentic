# frozen_string_literal: true

require "tty-box"
require "tty-cursor"
require "tty-screen"

module Agentic
  class CLI < Thor
    module Streaming
      # Coordinates multiple display zones for rich real-time progress tracking
      class MultiZoneDisplay
        attr_reader :streaming_zone, :progress_zone, :is_active

        def initialize(options = {})
          @options = options
          @cursor = TTY::Cursor
          @is_active = false
          @zones_initialized = false

          # Detect terminal capabilities
          @screen_height = begin
            TTY::Screen.height
          rescue
            24
          end
          @screen_width = begin
            TTY::Screen.width
          rescue
            80
          end

          # Zone heights (leave room for input/output)
          @streaming_zone_height = 4
          @progress_zone_height = [@screen_height - 12, 6].max
          @summary_zone_height = 3

          # Initialize zones
          @streaming_zone = StreamingZone.new(options)
          @progress_zone = ProgressZone.new(options)

          # Track zone positions
          @zone_positions = {}
          @original_cursor_position = nil
        end

        # Initializes the multi-zone display layout
        def initialize_layout
          return if @options[:quiet] || @zones_initialized

          @original_cursor_position = save_cursor_position
          setup_zones
          @zones_initialized = true
          @is_active = true
        end

        # Starts streaming in the streaming zone
        # @param initial_message [String] Initial message to display
        def start_streaming(initial_message = "🚀 Initializing response generation...")
          initialize_layout unless @zones_initialized
          @streaming_zone.start(initial_message)
        end

        # Updates streaming progress with new token
        # @param token [String] New token received
        # @param intelligent_message [String] Context-aware progress message
        # @param estimated_total [Integer, nil] Estimated total tokens
        def update_streaming_progress(token, intelligent_message, estimated_total = nil)
          @streaming_zone.update_token_progress(token, intelligent_message, estimated_total)
        end

        # Completes streaming successfully
        # @param final_message [String] Final completion message
        def complete_streaming(final_message = "Response generation completed")
          @streaming_zone.complete(final_message)
        end

        # Fails streaming with error
        # @param error_message [String] Error message
        def fail_streaming(error_message = "Response generation failed")
          @streaming_zone.fail(error_message)
        end

        # Creates a progress section
        # @param section_id [String] Unique section identifier
        # @param title [String] Section title
        # @param description [String] Section description
        def create_progress_section(section_id, title, description)
          initialize_layout unless @zones_initialized
          @progress_zone.create_section(section_id, title, description)
        end

        # Starts a process in the progress zone
        # @param section_id [String] Section identifier
        # @param process_id [String] Process identifier
        # @param description [String] Process description
        # @param metadata [Hash] Additional metadata
        def start_progress_process(section_id, process_id, description, metadata = {})
          @progress_zone.start_process(section_id, process_id, description, metadata)
        end

        # Updates a progress process
        # @param process_id [String] Process identifier
        # @param progress_message [String] Current progress message
        def update_progress_process(process_id, progress_message)
          @progress_zone.update_process(process_id, progress_message)
        end

        # Completes a progress process
        # @param process_id [String] Process identifier
        # @param result_message [String] Result message
        # @param duration [Float] Process duration
        def complete_progress_process(process_id, result_message, duration)
          @progress_zone.complete_process(process_id, result_message, duration)
        end

        # Fails a progress process
        # @param process_id [String] Process identifier
        # @param error_message [String] Error message
        # @param duration [Float] Process duration
        def fail_progress_process(process_id, error_message, duration)
          @progress_zone.fail_process(process_id, error_message, duration)
        end

        # Shows a final summary with execution results
        # @param status [Symbol] Overall execution status
        # @param execution_time [Float] Total execution time
        # @param results_summary [String] Summary of results
        def show_final_summary(status, execution_time, results_summary)
          return if @options[:quiet]

          # Position cursor for summary
          move_to_summary_zone

          # Create summary box
          summary_content = build_summary_content(status, execution_time, results_summary)
          summary_box = create_summary_box(status, summary_content)

          puts summary_box
        end

        # Cleans up the display and restores normal terminal state
        def cleanup
          return unless @is_active

          begin
            @streaming_zone.stop if @streaming_zone.is_active
          rescue
            nil
          end
          begin
            @progress_zone.clear
          rescue
            nil
          end

          # Restore cursor to bottom of display
          move_cursor_to_bottom

          @is_active = false
          @zones_initialized = false
        end

        # Handles cancellation gracefully
        def handle_cancellation
          return unless @is_active

          @streaming_zone.stop

          # Show cancellation message in summary area
          move_to_summary_zone
          puts create_cancellation_box

          cleanup
        end

        # Gets current display statistics
        # @return [Hash] Current statistics from all zones
        def stats
          {
            streaming: @streaming_zone.stats,
            progress: @progress_zone.progress_summary,
            layout: {
              screen_height: @screen_height,
              screen_width: @screen_width,
              zones_initialized: @zones_initialized,
              is_active: @is_active
            }
          }
        end

        private

        # Sets up the initial zone layout
        def setup_zones
          puts @cursor.hide

          # Print zone headers with boxes
          puts create_zone_header("🔄 Real-time Generation", @streaming_zone_height)
          @zone_positions[:streaming] = current_line_number

          puts create_zone_header("📊 Section Progress", @progress_zone_height)
          @zone_positions[:progress] = current_line_number

          # Reserve space for summary zone
          puts create_zone_header("📈 Summary", @summary_zone_height)
          @zone_positions[:summary] = current_line_number

          # Move cursor back to streaming zone for initial content
          move_to_streaming_zone
        end

        # Creates a zone header box
        # @param title [String] Zone title
        # @param height [Integer] Zone height
        # @return [String] Formatted zone header
        def create_zone_header(title, height)
          return "#{title}:\n" if @options[:no_color]

          TTY::Box.frame(
            title,
            width: [@screen_width - 4, 60].min,
            height: height,
            style: {
              border: {
                fg: :blue
              }
            }
          )
        end

        # Builds content for the final summary
        # @param status [Symbol] Execution status
        # @param execution_time [Float] Total execution time
        # @param results_summary [String] Results summary
        # @return [String] Summary content
        def build_summary_content(status, execution_time, results_summary)
          streaming_stats = @streaming_zone.stats
          progress_stats = @progress_zone.progress_summary

          content = []
          content << "Status: #{format_status(status)}"
          content << "Total Time: #{format_duration(execution_time)}"
          content << ""
          content << "Generation: #{streaming_stats[:token_count]} tokens at #{streaming_stats[:rate].round(1)}/sec"
          content << "Sections: #{progress_stats[:total_sections]} total, #{progress_stats[:active_sections]} active"
          content << ""
          content << results_summary

          content.join("\n")
        end

        # Creates the final summary box
        # @param status [Symbol] Execution status
        # @param content [String] Summary content
        # @return [String] Formatted summary box
        def create_summary_box(status, content)
          return "Execution Complete:\n#{content}" if @options[:no_color]

          border_color = case status
          when :completed then :green
          when :partial_failure then :yellow
          else :red
          end

          TTY::Box.frame(
            "Execution Complete",
            content,
            width: [@screen_width - 4, 60].min,
            style: {
              border: {
                fg: border_color
              }
            }
          )
        end

        # Creates a cancellation notification box
        # @return [String] Formatted cancellation box
        def create_cancellation_box
          content = "Plan execution was cancelled by user request.\nPartial results may be available."

          return "Execution Cancelled:\n#{content}" if @options[:no_color]

          TTY::Box.frame(
            "Execution Cancelled",
            content,
            width: [@screen_width - 4, 60].min,
            style: {
              border: {
                fg: :yellow
              }
            }
          )
        end

        # Zone navigation methods
        def move_to_streaming_zone
          nil if @options[:quiet]
          # Implementation depends on tracking cursor positions
          # For now, simplified approach
        end

        def move_to_progress_zone
          nil if @options[:quiet]
          # Implementation depends on tracking cursor positions
        end

        def move_to_summary_zone
          return if @options[:quiet]
          # Move to summary area at bottom
          puts "\n"
        end

        def move_cursor_to_bottom
          return if @options[:quiet]
          puts @cursor.show
          puts "\n"
        end

        # Utility methods
        def save_cursor_position
          # Save current cursor position for restoration
          # This is a placeholder - actual implementation may vary by terminal
          [0, 0]
        end

        def current_line_number
          # Get current line number in terminal
          # This is a placeholder for actual implementation
          0
        end

        def format_status(status)
          case status
          when :completed then colorize_text("✓ Completed", :green)
          when :partial_failure then colorize_text("⚠ Partial Success", :yellow)
          when :failed then colorize_text("✗ Failed", :red)
          else colorize_text(status.to_s, :blue)
          end
        end

        def format_duration(seconds)
          if seconds < 1
            "#{(seconds * 1000).round}ms"
          elsif seconds < 60
            "#{seconds.round(1)}s"
          else
            "#{(seconds / 60).round(1)}m"
          end
        end

        def colorize_text(text, color)
          @options[:no_color] ? text : UI.colorize(text, color)
        end
      end
    end
  end
end
