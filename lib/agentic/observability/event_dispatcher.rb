# frozen_string_literal: true

require "async"
require "async/queue"

module Agentic
  module Observability
    # EventDispatcher provides intelligent event routing, filtering, and transformation
    # between event sources and observers. It implements performance optimization
    # through priority queues, buffering, and asynchronous processing.
    #
    # Design Goals:
    # 1. Support agent orchestration patterns with hierarchical event routing
    # 2. Enable sophisticated filtering based on correlation context
    # 3. Optimize performance through intelligent batching and priority handling
    # 4. Maintain non-blocking event processing for high throughput
    #
    # Architect Team Guidance:
    # - Jamie Chen (Domain Expert): Agent hierarchy and workflow stage routing
    # - Jordan Lee (Performance Specialist): Priority queues and batching optimization
    class EventDispatcher
      # Event priority levels for routing optimization
      PRIORITY_CRITICAL = 0   # System errors, security events
      PRIORITY_HIGH = 1       # Task failures, agent errors
      PRIORITY_NORMAL = 2     # Task progress, state changes
      PRIORITY_LOW = 3        # Informational events, metrics

      # Default configuration
      DEFAULT_CONFIG = {
        max_buffer_size: 1000,
        batch_size: 50,
        batch_timeout: 0.1, # seconds
        enable_priority_routing: true,
        enable_correlation_filtering: true,
        enable_performance_metrics: true,
        enable_pipeline_integration: true, # v0.3.0 EventPipeline integration
        pipeline_config: {}                # Configuration for integrated EventPipeline
      }.freeze

      attr_reader :config, :statistics

      def initialize(config = {})
        @config = DEFAULT_CONFIG.merge(config)
        @routing_rules = []
        @filters = []
        @transformers = []
        @observers = []
        @priority_queues = create_priority_queues
        @event_buffer = []
        @statistics = {
          events_processed: 0,
          events_filtered: 0,
          events_batched: 0,
          average_processing_time: 0.0,
          buffer_utilization: 0.0,
          pipeline_stats: {}
        }
        @mutex = Mutex.new
        @processing = false
        @start_time = Time.now

        # v0.3.0 EventPipeline Integration
        @event_pipeline = nil
        initialize_pipeline if @config[:enable_pipeline_integration]
      end

      # Add a routing rule for intelligent event distribution
      # @param rule [Hash] Routing rule configuration
      # @option rule [Symbol, Array<Symbol>] :event_types Event types to match
      # @option rule [Symbol, Array<Symbol>] :sources Source types to match
      # @option rule [Proc] :condition Custom condition block
      # @option rule [Symbol] :priority Priority level for matched events
      # @option rule [Array] :observers Specific observers for matched events
      def add_routing_rule(**rule)
        validate_routing_rule!(rule)
        @routing_rules << rule
        Agentic.logger.debug("Added routing rule: #{rule.keys}")
      end

      # Add an event filter
      # @param name [Symbol] Filter identifier
      # @param block [Proc] Filter block that receives event and returns boolean
      def add_filter(name, &block)
        return unless block

        @filters << {name: name, filter: block}
        Agentic.logger.debug("Added event filter: #{name}")
      end

      # Add an event transformer
      # @param name [Symbol] Transformer identifier
      # @param block [Proc] Transformer block that receives and modifies event
      def add_transformer(name, &block)
        return unless block

        @transformers << {name: name, transformer: block}
        Agentic.logger.debug("Added event transformer: #{name}")
      end

      # Register an observer for event notifications
      # @param observer [Object] Observer that responds to #update
      # @param priority [Integer] Observer priority (lower = higher priority)
      def add_observer(observer, priority: PRIORITY_NORMAL)
        @mutex.synchronize do
          @observers << {observer: observer, priority: priority}
          @observers.sort_by! { |obs| obs[:priority] }
        end
      end

      # Remove an observer
      # @param observer [Object] Observer to remove
      def remove_observer(observer)
        @mutex.synchronize do
          @observers.reject! { |obs| obs[:observer] == observer }
        end
      end

      # Dispatch event through the routing and filtering pipeline
      # @param event_type [Symbol] Type of event
      # @param data [Hash] Event data
      # @param source [Object] Event source
      # @param correlation_context [Hash] Correlation context for filtering
      # @param event_context [EventContext] v0.3.0 EventContext for hierarchical correlation
      # @param priority [Integer] Event priority override
      def dispatch(event_type, data = {}, source: nil, correlation_context: {}, event_context: nil, priority: nil)
        start_time = Time.now.to_f

        # Create enriched event with hierarchical context
        event = create_event(event_type, data, source, correlation_context, event_context)

        # Apply routing rules to determine priority and target observers
        routing_result = apply_routing_rules(event)
        event_priority = priority || routing_result[:priority] || determine_priority(event_type)
        target_observers = routing_result[:observers] || @observers

        # Apply filters
        return if filtered_out?(event)

        # Apply transformers
        event = apply_transformers(event)

        # Route to appropriate processing based on priority
        if @config[:enable_priority_routing]
          route_by_priority(event, event_priority, target_observers)
        else
          process_immediately(event, target_observers)
        end

        # Update statistics
        update_statistics(Time.now.to_f - start_time)
      end

      # Start asynchronous event processing
      def start_processing
        return if @processing

        @processing = true

        # Start EventPipeline if integrated
        @event_pipeline&.start

        Async do |task|
          @config[:enable_priority_routing] ? process_priority_queues(task) : nil
          process_event_buffer(task) if @config[:batch_size] > 1
        end
      end

      # Stop event processing
      def stop_processing
        @processing = false

        # Stop EventPipeline if integrated
        @event_pipeline&.stop
      end

      # Get current buffer utilization
      # @return [Float] Buffer utilization percentage (0.0 to 1.0)
      def buffer_utilization
        @event_buffer.size.to_f / @config[:max_buffer_size]
      end

      # Clear all routing rules, filters, and transformers
      def clear_configuration
        @routing_rules.clear
        @filters.clear
        @transformers.clear
        Agentic.logger.debug("Cleared event dispatcher configuration")
      end

      private

      # Create priority queues for different event priorities
      def create_priority_queues
        return {} unless @config[:enable_priority_routing]

        {
          PRIORITY_CRITICAL => Async::Queue.new,
          PRIORITY_HIGH => Async::Queue.new,
          PRIORITY_NORMAL => Async::Queue.new,
          PRIORITY_LOW => Async::Queue.new
        }
      end

      # Create enriched event with metadata and hierarchical context
      def create_event(event_type, data, source, correlation_context, event_context = nil)
        # Merge correlation context with EventContext information
        enriched_correlation_context = correlation_context.dup

        if event_context
          enriched_correlation_context.merge!({
            context_id: event_context.context_id,
            correlation_id: event_context.correlation_id,
            context_type: event_context.context_type,
            context_name: event_context.name,
            hierarchy_path: event_context.hierarchy_path,
            context_state: event_context.state,
            context_depth: event_context.depth,
            parent_context_id: event_context.parent_context&.context_id
          })
        end

        {
          type: event_type,
          data: data,
          source: source,
          source_class: source&.class&.name,
          correlation_context: enriched_correlation_context,
          event_context: event_context,
          timestamp: Time.now.to_f,
          dispatcher_metadata: {
            buffer_size: @event_buffer.size,
            processing_time: nil,
            context_enriched: !event_context.nil?
          }
        }
      end

      # Apply routing rules to determine event handling
      def apply_routing_rules(event)
        result = {priority: nil, observers: nil}

        @routing_rules.each do |rule|
          next unless matches_routing_rule?(event, rule)

          result[:priority] = rule[:priority] if rule[:priority]
          result[:observers] = rule[:observers] if rule[:observers]
          break if rule[:exclusive] # Stop at first exclusive match
        end

        result
      end

      # Check if event matches a routing rule
      def matches_routing_rule?(event, rule)
        # Check event types
        if rule[:event_types]
          types = Array(rule[:event_types])
          return false unless types.include?(event[:type])
        end

        # Check source types
        if rule[:sources]
          sources = Array(rule[:sources])
          return false unless sources.include?(event[:source_class]&.to_sym)
        end

        # Check custom condition
        if rule[:condition]
          return false unless rule[:condition].call(event)
        end

        true
      end

      # Determine default priority based on event type
      def determine_priority(event_type)
        case event_type.to_s
        when /security/, /breach/
          PRIORITY_CRITICAL
        when /task_failed/, /agent_error/, /verification_failed/, /_failed\z/
          PRIORITY_HIGH
        when /error/, /failure/
          PRIORITY_CRITICAL
        when /task_/, /agent_/, /plan_/
          PRIORITY_NORMAL
        else
          PRIORITY_LOW
        end
      end

      # Check if event should be filtered out
      def filtered_out?(event)
        @filters.any? do |filter_config|
          !filter_config[:filter].call(event)
        rescue => e
          Agentic.logger.warn("Filter #{filter_config[:name]} error: #{e.message}")
          false # Don't filter on error
        end.tap do |filtered|
          @statistics[:events_filtered] += 1 if filtered
        end
      end

      # Apply all transformers to event
      def apply_transformers(event)
        @transformers.reduce(event) do |current_event, transformer_config|
          transformer_config[:transformer].call(current_event) || current_event
        rescue => e
          Agentic.logger.warn("Transformer #{transformer_config[:name]} error: #{e.message}")
          current_event
        end
      end

      # Route event based on priority
      def route_by_priority(event, priority, observers)
        # Asynchronous batching (the EventPipeline or priority queues) only applies
        # once #start_processing has been invoked to drain them. Until then, deliver
        # events synchronously so they are never silently buffered without a consumer.
        unless @processing
          process_immediately(event, observers)
          return
        end

        # v0.3.0 Pipeline Integration: Route through EventPipeline for batched processing
        if @event_pipeline && @config[:enable_pipeline_integration]
          route_through_pipeline(event, priority, observers)
        elsif @priority_queues[priority]
          @priority_queues[priority].enqueue({event: event, observers: observers})
        else
          process_immediately(event, observers)
        end
      end

      # Process event immediately (synchronous)
      def process_immediately(event, observers)
        notify_observers(event, observers)
      end

      # Process priority queues asynchronously
      def process_priority_queues(task)
        @priority_queues.each do |priority, queue|
          task.async do
            while @processing
              event_package = queue.dequeue
              notify_observers(event_package[:event], event_package[:observers])
            end
          end
        end
      end

      # Process event buffer for batching
      def process_event_buffer(task)
        task.async do
          while @processing
            sleep(@config[:batch_timeout])
            process_buffered_events if @event_buffer.size >= @config[:batch_size]
          end
        end
      end

      # Process accumulated events in buffer
      def process_buffered_events
        events_to_process = nil

        @mutex.synchronize do
          events_to_process = @event_buffer.slice!(0, @config[:batch_size])
        end

        return if events_to_process.empty?

        events_to_process.each do |event_package|
          notify_observers(event_package[:event], event_package[:observers])
        end

        @statistics[:events_batched] += events_to_process.size
      end

      # Notify observers about event
      def notify_observers(event, observers)
        observers.each do |observer_config|
          observer = observer_config[:observer]

          begin
            if observer.respond_to?(:update)
              observer.update(event[:type], event[:source], event)
            elsif observer.respond_to?(:call)
              observer.call(event)
            end
          rescue => e
            Agentic.logger.warn("Observer notification error: #{e.message}")
          end
        end
      end

      # Update processing statistics
      def update_statistics(processing_time)
        @statistics[:events_processed] += 1

        # Update average processing time (exponential moving average)
        alpha = 0.1 # Smoothing factor
        @statistics[:average_processing_time] =
          (alpha * processing_time) + ((1 - alpha) * @statistics[:average_processing_time])

        @statistics[:buffer_utilization] = buffer_utilization
      end

      # Validate routing rule configuration
      def validate_routing_rule!(rule)
        required_keys = [:event_types, :sources, :condition]
        unless required_keys.any? { |key| rule.key?(key) }
          raise ArgumentError, "Routing rule must specify at least one of: #{required_keys.join(", ")}"
        end

        if rule[:priority] && !rule[:priority].is_a?(Integer)
          raise ArgumentError, "Priority must be an integer"
        end

        if rule[:observers] && !rule[:observers].is_a?(Array)
          raise ArgumentError, "Observers must be an array"
        end
      end

      # === v0.3.0 EVENTPIPELINE INTEGRATION ===

      # Initialize EventPipeline for advanced batching
      def initialize_pipeline
        pipeline_config = DEFAULT_CONFIG[:pipeline_config].merge(@config[:pipeline_config] || {})

        # Configure pipeline for optimal dispatcher integration
        pipeline_config = pipeline_config.merge({
          batch_size_max: @config[:batch_size],
          batch_timeout: @config[:batch_timeout],
          enable_backpressure: true,
          enable_adaptive_batching: true,
          enable_performance_monitoring: @config[:enable_performance_metrics]
        })

        @event_pipeline = EventPipeline.new(pipeline_config)

        # Add dispatcher as a pipeline processor
        @event_pipeline.add_processor(self, stage: EventPipeline::STAGE_PROCESSING, priority: 1)

        Agentic.logger&.debug("EventPipeline integration initialized")
      end

      # Route event through EventPipeline for batched processing
      def route_through_pipeline(event, priority, observers)
        # Add dispatcher-specific metadata for pipeline processing
        event[:dispatcher_metadata] = (event[:dispatcher_metadata] || {}).merge({
          routing_priority: priority,
          target_observers: observers,
          routed_at: Time.now.to_f
        })

        # Convert priority to pipeline priority
        pipeline_priority = case priority
        when PRIORITY_CRITICAL then :high
        when PRIORITY_HIGH then :high
        when PRIORITY_NORMAL then :normal
        when PRIORITY_LOW then :low
        else :normal
        end

        # Ingest into pipeline for batched processing
        success = @event_pipeline.ingest_event(event, priority: pipeline_priority)

        unless success
          # Fallback to immediate processing if pipeline rejects (backpressure)
          process_immediately(event, observers)
        end
      end

      # Process batches from EventPipeline (implements EventPipeline processor interface)
      def process_batch(batch, priority: :normal)
        start_time = Time.now.to_f

        # Group events by target observers for efficient processing
        events_by_observers = batch.group_by do |event|
          event[:dispatcher_metadata][:target_observers] || @observers
        end

        # Process each group
        events_by_observers.each do |observers, events|
          events.each { |event| notify_observers(event, observers) }
        end

        # Update statistics
        processing_time = Time.now.to_f - start_time
        @statistics[:events_batched] += batch.size
        update_statistics(processing_time)
      end

      # Get EventPipeline status (if enabled)
      def pipeline_status
        return nil unless @event_pipeline

        @event_pipeline.status
      end

      # Enable/disable pipeline integration at runtime
      def enable_pipeline_integration(pipeline_config = {})
        return if @event_pipeline # Already enabled

        @config[:enable_pipeline_integration] = true
        @config[:pipeline_config] = pipeline_config

        initialize_pipeline
        @event_pipeline.start if @processing

        Agentic.logger&.info("EventPipeline integration enabled")
      end

      def disable_pipeline_integration
        return unless @event_pipeline

        @event_pipeline.stop if @event_pipeline.status[:running]
        @event_pipeline = nil
        @config[:enable_pipeline_integration] = false

        Agentic.logger&.info("EventPipeline integration disabled")
      end
    end
  end
end
