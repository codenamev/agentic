# frozen_string_literal: true

require "set"
require "json"
require "async"

module Agentic
  # Unified observability engine for all event coordination
  #
  # Simplified architecture that consolidates local observers and adapters
  # into a single, clean interface.
  #
  # @example Basic usage
  #   engine = ObservabilityEngine.new
  #   engine.add_local_observer(observer)
  #   engine.notify(:task_started, {task_id: "123"})
  #
  # @example Global usage
  #   Agentic.observability_engine.notify(:agent_build_completed, agent_data)
  class ObservabilityEngine
    attr_reader :local_observers, :filters, :stats, :file_observer, :adapters, :event_dispatcher

    def initialize(enable_advanced_dispatching: false, dispatcher_config: {})
      # Legacy observers (for backward compatibility)
      @local_observers = []
      @filters = []
      @observer_mutex = Mutex.new
      @file_observer = nil
      @file_observer_mutex = Mutex.new

      # New adapter-based system
      @adapters = []
      @adapters_mutex = Mutex.new

      # v0.3.0 Advanced EventDispatcher (optional)
      @enable_advanced_dispatching = enable_advanced_dispatching
      @event_dispatcher = enable_advanced_dispatching ? Observability::EventDispatcher.new(dispatcher_config) : nil

      @stats = {
        events_processed: 0,
        local_notifications: 0,
        file_notifications: 0,
        adapter_notifications: 0,
        last_event_at: nil,
        dispatcher_stats: @event_dispatcher&.statistics || {}
      }
    end

    # Add a local observer for in-process event handling
    # @param observer [Object] Object that responds to #handle_event(event_data)
    def add_local_observer(observer)
      @observer_mutex.synchronize do
        @local_observers << observer unless @local_observers.include?(observer)
      end
    end

    # Remove a local observer
    # @param observer [Object] Observer to remove
    def remove_local_observer(observer)
      @observer_mutex.synchronize do
        @local_observers.delete(observer)
      end
    end

    # Clear all local observers
    def clear_local_observers
      @observer_mutex.synchronize do
        @local_observers.clear
      end
    end

    # Add an event filter
    # @param block [Proc] Filter that receives EventData and returns boolean
    def add_filter(&block)
      @filters << block if block
    end

    # Clear all filters
    def clear_filters
      @filters.clear
    end

    # Main event notification method - unified interface for all events
    # @param event_type [Symbol] Type of event
    # @param data [Hash] Event data
    # @param metadata [Hash] Additional metadata
    # @param source [String] Optional source identifier
    # @param correlation_context [Hash] v0.3.0 correlation context for advanced dispatching
    # @param event_context [Observability::EventContext] v0.3.0 hierarchical event context
    def notify(event_type, data: {}, metadata: {}, source: nil, correlation_context: {}, event_context: nil)
      @stats[:events_processed] += 1
      @stats[:last_event_at] = Time.now

      # v0.3.0 Advanced Dispatching Path
      if @enable_advanced_dispatching && @event_dispatcher
        @event_dispatcher.dispatch(
          event_type,
          data,
          source: source,
          correlation_context: correlation_context.merge(metadata),
          event_context: event_context
        )
        @stats[:dispatcher_stats] = @event_dispatcher.statistics
        return
      end

      # Legacy Path (backward compatibility)
      # Create standardized event
      event = Observability::EventData.new(
        type: event_type,
        data: data,
        metadata: metadata,
        source: source
      )

      # Apply filters
      return unless @filters.all? { |filter| filter.call(event) }

      # Notify local observers (synchronous)
      notify_local_observers(event)

      # Notify adapters (asynchronous)
      notify_adapters(event)

      Agentic.logger.debug("Event processed: #{event_type}")
    end

    # Check if any observers are configured
    # @return [Boolean] True if there are any observers
    def active?
      !@local_observers.empty? || !@adapters.empty?
    end

    # Get comprehensive statistics
    # @return [Hash] Statistics about event processing
    def statistics
      adapters_status = all_adapters.map(&:status)

      @stats.merge({
        local_observers: @local_observers.size,
        filters: @filters.size,
        adapters_count: @adapters.size,
        adapters: adapters_status
      })
    end

    # ==================== ADAPTER-BASED METHODS ====================

    # Add an adapter to the observability engine
    # @param adapter [BaseAdapter] The adapter to add
    def add_adapter(adapter)
      @adapters_mutex.synchronize do
        @adapters << adapter unless @adapters.include?(adapter)
      end
      Agentic.logger&.debug("Added #{adapter.adapter_type} adapter")
    end

    # Remove an adapter from the observability engine
    # @param adapter [BaseAdapter] The adapter to remove
    def remove_adapter(adapter)
      @adapters_mutex.synchronize do
        @adapters.delete(adapter)
      end
      Agentic.logger&.debug("Removed #{adapter.adapter_type} adapter")
    end

    # Remove all adapters
    def clear_adapters
      @adapters_mutex.synchronize do
        @adapters.each(&:shutdown)
        @adapters.clear
      end
    end

    # Get all adapters
    # @return [Array<BaseAdapter>] Current adapters
    def all_adapters
      @adapters_mutex.synchronize do
        @adapters.dup
      end
    end

    # Find adapters by type
    # @param type [String, Symbol] The adapter type to find
    # @return [Array<BaseAdapter>] Adapters of the specified type
    def find_adapters(type)
      all_adapters.select { |adapter| adapter.adapter_type == type.to_s }
    end

    # Configure adapters from hash configuration
    # @param config [Hash] Configuration hash for adapters
    def configure_adapters(config)
      # Clear existing adapters
      clear_adapters

      # Create new adapters from configuration
      new_adapters = Observability::AdapterFactory.create_from_config(config)
      new_adapters.each { |adapter| add_adapter(adapter) }

      Agentic.logger&.info("Configured #{new_adapters.size} adapters")
    end

    # Enable default adapters for CLI usage
    # @param options [Hash] CLI options for configuration
    def enable_default_cli_adapters(options = {})
      config = Observability::AdapterFactory.default_cli_config(options)
      configure_adapters(config)
    end

    # === v0.3.0 ADVANCED DISPATCHING METHODS ===

    # Enable advanced event dispatching with routing and filtering
    # @param config [Hash] EventDispatcher configuration options
    def enable_advanced_dispatching(config = {})
      @enable_advanced_dispatching = true
      @event_dispatcher = Observability::EventDispatcher.new(config)

      # Integrate existing observers with new dispatcher
      @local_observers.each do |observer|
        @event_dispatcher.add_observer(observer)
      end

      Agentic.logger&.info("Enabled advanced event dispatching")
    end

    # Disable advanced dispatching (fallback to legacy system)
    def disable_advanced_dispatching
      @enable_advanced_dispatching = false
      @event_dispatcher&.stop_processing
      @event_dispatcher = nil
      Agentic.logger&.info("Disabled advanced event dispatching")
    end

    # Configure event routing rules (requires advanced dispatching)
    # @param rules [Array<Hash>] Array of routing rule configurations
    def configure_event_routing(rules)
      return unless @event_dispatcher

      rules.each { |rule| @event_dispatcher.add_routing_rule(**rule) }
      Agentic.logger&.debug("Configured #{rules.size} routing rules")
    end

    # Add event filters for advanced dispatching
    # @param filters [Hash] Hash of filter_name => filter_block pairs
    def configure_event_filters(filters)
      return unless @event_dispatcher

      filters.each { |name, filter| @event_dispatcher.add_filter(name, &filter) }
      Agentic.logger&.debug("Configured #{filters.size} event filters")
    end

    # Add event transformers for advanced dispatching
    # @param transformers [Hash] Hash of transformer_name => transformer_block pairs
    def configure_event_transformers(transformers)
      return unless @event_dispatcher

      transformers.each { |name, transformer| @event_dispatcher.add_transformer(name, &transformer) }
      Agentic.logger&.debug("Configured #{transformers.size} event transformers")
    end

    # Check if advanced dispatching is enabled
    # @return [Boolean]
    def advanced_dispatching_enabled?
      @enable_advanced_dispatching && !@event_dispatcher.nil?
    end

    # Get recent events from file adapters
    # @param limit [Integer] Maximum number of events to return
    # @return [Array<Hash>] Recent events
    def recent_events(limit: 50)
      file_adapters = find_adapters(:file)
      return [] if file_adapters.empty?

      # Use the first file adapter
      file_adapters.first.recent_events(limit: limit)
    end

    # Get events since a specific timestamp from file adapters
    # @param since [Time, String] Timestamp to filter from
    # @return [Array<Hash>] Events since timestamp
    def events_since(since)
      file_adapters = find_adapters(:file)
      return [] if file_adapters.empty?

      # Use the first file adapter
      file_adapters.first.events_since(since)
    end

    # Graceful shutdown
    def shutdown
      Agentic.logger.info("Shutting down ObservabilityEngine")

      clear_local_observers
      clear_filters
      clear_adapters

      Agentic.logger.debug("ObservabilityEngine shutdown complete")
    end

    private

    def notify_local_observers(event)
      observers_copy = nil
      @observer_mutex.synchronize do
        observers_copy = @local_observers.dup
      end

      observers_copy.each do |observer|
        if observer.respond_to?(:handle_event)
          observer.handle_event(event)
        elsif observer.respond_to?(:update)
          # Legacy compatibility
          # Pass self as source when event.source is nil
          observer.update(event.type, event.source || self, event.to_h)
        end
        @stats[:local_notifications] += 1
      rescue => error
        Agentic.logger.warn("Local observer error: #{error.message}")
      end
    end

    def notify_adapters(event)
      adapters_copy = nil
      @adapters_mutex.synchronize do
        adapters_copy = @adapters.dup
      end

      return if adapters_copy.empty?

      # Notify each adapter asynchronously to prevent blocking
      adapters_copy.each do |adapter|
        next unless adapter.enabled?

        Async(annotation: "ObservabilityEngine#notify_adapter") do
          adapter.handle_event(event)
          @stats[:adapter_notifications] += 1
        rescue => error
          Agentic.logger.warn("Adapter error (#{adapter.adapter_type}): #{error.message}")
        end
      end
    end
  end
end
