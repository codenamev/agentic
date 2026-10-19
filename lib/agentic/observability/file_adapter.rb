# frozen_string_literal: true

module Agentic
  module Observability
    # File adapter for logging events to local files
    # Wraps FileObserver to provide adapter interface
    class FileAdapter < BaseAdapter
      # Default configuration
      DEFAULT_CONFIG = {
        log_path: File.join(Dir.home, ".agentic", "observability", "events.jsonl"),
        max_file_size: 10 * 1024 * 1024, # 10MB
        max_files: 5
      }.freeze

      def initialize(config = {})
        # Merge with defaults
        config = DEFAULT_CONFIG.merge(config)
        super
      end

      # Handle event by writing to file via FileObserver
      # @param event_data [EventData] The event to log
      def handle_event(event_data)
        with_error_handling(event_data) do
          @file_observer.handle_event(event_data)
        end
      end

      # Get recent events from file
      # @param limit [Integer] Maximum number of events to return
      # @return [Array<Hash>] Recent events
      def recent_events(limit: 50)
        return [] unless @file_observer
        @file_observer.recent_events(limit: limit)
      end

      # Get events since a specific timestamp
      # @param since [Time, String] Timestamp to filter from
      # @return [Array<Hash>] Events since timestamp
      def events_since(since)
        return [] unless @file_observer
        @file_observer.events_since(since)
      end

      # Get file observer statistics
      # @return [Hash] File observer statistics
      def file_statistics
        return {} unless @file_observer
        @file_observer.statistics
      end

      # Get extended status including file-specific information
      # @return [Hash] Status with file adapter details
      def status
        base_status = super
        file_stats = file_statistics

        base_status.merge({
          log_path: @config[:log_path],
          file_size: file_stats[:file_size] || 0,
          total_events: file_stats[:total_events] || 0,
          first_event_at: file_stats[:first_event_at],
          last_event_at: file_stats[:last_event_at],
          rotation_needed: should_rotate?
        })
      end

      # Check if file rotation is needed
      # @return [Boolean] True if rotation is needed
      def should_rotate?
        return false unless @file_observer
        @file_observer.should_rotate?
      end

      # Manually trigger file rotation
      def rotate_file!
        return unless @file_observer
        @file_observer.rotate_file!
      end

      # Get the observability directory path
      # @return [String] Directory path
      def observability_dir
        return nil unless @file_observer
        @file_observer.observability_dir
      end

      # Graceful shutdown
      def shutdown
        super
        # FileObserver doesn't need explicit shutdown, but we can log
        if @file_observer
          final_stats = @file_observer.statistics
          Agentic.logger&.info("File adapter shutdown: #{final_stats[:total_events]} events logged")
        end
      end

      protected

      def setup
        log_path = @config[:log_path]
        max_file_size = @config[:max_file_size]
        max_files = @config[:max_files]

        @file_observer = FileObserver.new(
          log_path: log_path,
          max_file_size: max_file_size,
          max_files: max_files
        )

        Agentic.logger&.debug("File adapter initialized: #{log_path}")
      rescue => error
        # Re-raise with more context
        raise "Failed to initialize file adapter: #{error.message}"
      end

      def on_enable
        Agentic.logger&.info("File adapter enabled: #{@config[:log_path]}")
      end

      def on_disable
        Agentic.logger&.info("File adapter disabled: #{@config[:log_path]}")
      end

      # Override error handling to provide file-specific context
      def handle_error(error, event_data)
        message = "File adapter error (#{@config[:log_path]}): #{error.message}"
        if Agentic.logger
          Agentic.logger.error(message)
          Agentic.logger.debug("Event: #{event_data.type}, Error: #{error.backtrace&.first}")
        else
          warn message
        end
      end
    end
  end
end
