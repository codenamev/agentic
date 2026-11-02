# frozen_string_literal: true

module Agentic
  class CLI < Thor
    module Streaming
      # Enhanced progress tracker that coordinates all streaming display components
      class EnhancedProgressTracker
        attr_reader :multi_zone_display, :sections, :active_processes

        def initialize(options = {})
          @options = options
          @multi_zone_display = MultiZoneDisplay.new(options)
          @sections = {}
          @active_processes = {}
          @is_streaming = false
          @start_time = Time.now
        end

        # Starts the enhanced progress tracking
        def start
          @multi_zone_display.initialize_layout
          @start_time = Time.now
        end

        # Creates a section for progress tracking
        # @param section_id [String] Unique section identifier
        # @param title [String] Section title
        # @param description [String] Section description
        def create_section(section_id, title, description)
          @sections[section_id] = {
            title: title,
            description: description,
            created_at: Time.now
          }

          @multi_zone_display.create_progress_section(section_id, title, description)
        end

        # Starts a process within a section
        # @param section_id [String] Section identifier
        # @param process_id [String] Process identifier
        # @param description [String] Process description
        # @param metadata [Hash] Additional metadata
        def start_process(section_id, process_id, description, metadata = {})
          @active_processes[process_id] = {
            section_id: section_id,
            description: description,
            start_time: Time.now,
            metadata: metadata
          }

          @multi_zone_display.start_progress_process(section_id, process_id, description, metadata)
        end

        # Updates a process with new progress
        # @param process_id [String] Process identifier
        # @param progress_message [String] Current progress message
        def update_process(process_id, progress_message)
          if @active_processes[process_id]
            @active_processes[process_id][:last_update] = Time.now
            @active_processes[process_id][:progress_message] = progress_message
          end

          @multi_zone_display.update_progress_process(process_id, progress_message)
        end

        # Completes a process successfully
        # @param process_id [String] Process identifier
        # @param result_message [String] Result message (can be raw output)
        # @param duration [Float] Process duration
        def complete_process(process_id, result_message, duration)
          # Format the result message intelligently
          formatted_result = format_result_text(result_message)

          @multi_zone_display.complete_progress_process(process_id, formatted_result, duration)
          @active_processes.delete(process_id)
        end

        # Fails a process
        # @param process_id [String] Process identifier
        # @param error_message [String] Error message
        # @param duration [Float] Process duration
        def fail_process(process_id, error_message, duration)
          @multi_zone_display.fail_progress_process(process_id, error_message, duration)
          @active_processes.delete(process_id)
        end

        # Starts streaming mode with token-level progress
        # @param initial_message [String] Initial streaming message
        def start_streaming(initial_message = "🚀 Initializing response generation...")
          @is_streaming = true
          @multi_zone_display.start_streaming(initial_message)
        end

        # Updates streaming progress with new token
        # @param token [String] New token received
        # @param intelligent_message [String] Context-aware progress message
        # @param estimated_total [Integer, nil] Estimated total tokens
        def update_streaming_progress(token, intelligent_message, estimated_total = nil)
          return unless @is_streaming
          @multi_zone_display.update_streaming_progress(token, intelligent_message, estimated_total)
        end

        # Completes streaming successfully
        # @param final_message [String] Final completion message
        def complete_streaming(final_message = "Response generation completed")
          @is_streaming = false
          @multi_zone_display.complete_streaming(final_message)
        end

        # Fails streaming
        # @param error_message [String] Error message
        def fail_streaming(error_message = "Response generation failed")
          @is_streaming = false
          @multi_zone_display.fail_streaming(error_message)
        end

        # Shows final summary and cleans up display
        # @param status [Symbol] Overall execution status
        # @param results [Hash] Execution results
        # @param tasks [Hash] Task information
        def show_final_summary(status, results, tasks)
          execution_time = Time.now - @start_time
          results_summary = generate_results_summary(results, tasks)

          @multi_zone_display.show_final_summary(status, execution_time, results_summary)
          @multi_zone_display.cleanup
        end

        # Handles cancellation gracefully
        def handle_cancellation
          @is_streaming = false
          @multi_zone_display.handle_cancellation
        end

        # Gets comprehensive progress statistics
        # @return [Hash] Complete progress statistics
        def stats
          base_stats = @multi_zone_display.stats
          base_stats.merge({
            sections: @sections,
            active_processes: @active_processes,
            total_execution_time: Time.now - @start_time,
            is_streaming: @is_streaming
          })
        end

        # Legacy compatibility methods for existing code

        # Legacy method: display_summary (now handled by final summary)
        def display_summary
          # This is now handled by show_final_summary
          # Keeping for backwards compatibility
        end

        # Legacy method: display_complete_section
        def display_complete_section(section_id)
          # Section completion is now handled automatically
          # Keeping for backwards compatibility
        end

        # Legacy method: section_status_symbol
        def section_status_symbol(section)
          case section[:status]
          when :pending then "⏳"
          when :in_progress then "🔄"
          when :completed then "✅"
          when :partial_failure then "⚠️"
          when :failed then "❌"
          else "?"
          end
        end

        private

        # Intelligently formats result text for display
        # @param result_output [String, Object] Raw result output
        # @return [String] Formatted result message
        def format_result_text(result_output)
          return "completed" if result_output.nil? || result_output.to_s.strip.empty?

          result_text = result_output.to_s.strip

          # Try to parse as JSON for better formatting
          if result_text.start_with?("{", "[")
            begin
              parsed = JSON.parse(result_text)
              return format_json_result(parsed)
            rescue JSON::ParserError
              # Fall through to text handling
            end
          end

          # For plain text, create a concise summary
          if result_text.length > 100
            "#{result_text[0..60]}... (#{result_text.length} chars)"
          else
            result_text
          end
        end

        # Formats JSON results with semantic understanding
        # @param parsed_json [Hash, Array] Parsed JSON data
        # @return [String] Semantic description of the result
        def format_json_result(parsed_json)
          case parsed_json
          when Hash
            if parsed_json.key?("interview_questions") && parsed_json["interview_questions"].is_a?(Array)
              count = parsed_json["interview_questions"].length
              "Interview questions prepared: #{count} questions"
            elsif parsed_json.key?("report") || parsed_json.key?("Report")
              "Report compiled with structured content"
            elsif parsed_json.key?("research") || parsed_json.keys.any? { |k| k.to_s.downcase.include?("background") }
              "Background research completed"
            elsif parsed_json.key?("questions") && parsed_json["questions"].is_a?(Array)
              count = parsed_json["questions"].length
              "Questions formulated: #{count} items"
            else
              key_count = parsed_json.keys.length
              "Structured data generated: #{key_count} sections"
            end
          when Array
            "List compiled: #{parsed_json.length} items"
          else
            "Data generated successfully"
          end
        end

        # Generates a summary of execution results
        # @param results [Hash] Execution results
        # @param tasks [Hash] Task information
        # @return [String] Results summary
        def generate_results_summary(results, tasks)
          return "No results available" unless results && !results.empty?

          successful_results = results.values.select(&:successful?)
          failed_results = results.values.reject(&:successful?)

          summary_lines = []
          summary_lines << "Results: #{successful_results.length} successful, #{failed_results.length} failed"

          if successful_results.any?
            # Show a preview of successful results
            preview = successful_results.first(2).map.with_index do |result, index|
              task_id = result.respond_to?(:task_id) ? result.task_id : "task_#{index + 1}"
              task_info = tasks&.[](task_id) || {}
              description = task_info[:description] || "Task #{index + 1}"

              formatted_result = format_result_text(result.output)
              "• #{truncate_text(description, 30)}: #{formatted_result}"
            end

            summary_lines.concat(preview)

            if successful_results.length > 2
              summary_lines << "• ... and #{successful_results.length - 2} more"
            end
          end

          summary_lines.join("\n")
        end

        # Truncates text to specified length
        # @param text [String] Text to truncate
        # @param max_length [Integer] Maximum length
        # @return [String] Truncated text
        def truncate_text(text, max_length)
          return text if text.length <= max_length
          "#{text[0..max_length - 4]}..."
        end
      end
    end
  end
end
