# frozen_string_literal: true

module Agentic
  module Performance
    # Performance optimization framework with caching, pooling, and monitoring
    #
    # Provides comprehensive performance optimization including:
    # - Intelligent caching strategies
    # - Connection and object pooling
    # - Performance monitoring and alerting
    # - Automatic scaling and tuning
    # - Resource usage optimization
    #
    # Design Goals:
    # 1. Transparent performance enhancement with minimal code changes
    # 2. Automatic optimization based on usage patterns
    # 3. Comprehensive monitoring and alerting
    # 4. Pluggable optimization strategies
    # 5. Resource-aware scaling and throttling
    class Optimizer
      # Optimization strategies
      module Strategy
        CONSERVATIVE = :conservative  # Minimal optimization, stability focused
        BALANCED = :balanced         # Balance between performance and stability
        AGGRESSIVE = :aggressive     # Maximum performance, higher resource usage
        CUSTOM = :custom            # User-defined optimization rules
      end

      # Performance metrics
      class Metrics
        attr_reader :data

        def initialize
          @data = {
            response_times: [],
            memory_usage: [],
            cache_hit_rates: [],
            error_rates: [],
            throughput: [],
            resource_utilization: {}
          }
          @mutex = Mutex.new
        end

        def record_response_time(duration)
          @mutex.synchronize do
            @data[:response_times] << {time: Time.now, duration: duration}
            # Keep only last 1000 measurements
            @data[:response_times] = @data[:response_times].last(1000)
          end
        end

        def record_memory_usage(bytes)
          @mutex.synchronize do
            @data[:memory_usage] << {time: Time.now, bytes: bytes}
            @data[:memory_usage] = @data[:memory_usage].last(1000)
          end
        end

        def record_cache_hit_rate(rate)
          @mutex.synchronize do
            @data[:cache_hit_rates] << {time: Time.now, rate: rate}
            @data[:cache_hit_rates] = @data[:cache_hit_rates].last(1000)
          end
        end

        def record_error(error_type)
          @mutex.synchronize do
            @data[:error_rates] << {time: Time.now, error_type: error_type}
            @data[:error_rates] = @data[:error_rates].last(1000)
          end
        end

        def record_throughput(requests_per_second)
          @mutex.synchronize do
            @data[:throughput] << {time: Time.now, rps: requests_per_second}
            @data[:throughput] = @data[:throughput].last(1000)
          end
        end

        def average_response_time(window_seconds = 300)
          cutoff = Time.now - window_seconds
          recent_times = @data[:response_times].select { |entry| entry[:time] >= cutoff }

          return 0.0 if recent_times.empty?

          recent_times.sum { |entry| entry[:duration] } / recent_times.size.to_f
        end

        def current_memory_usage
          @data[:memory_usage].last&.dig(:bytes) || 0
        end

        def current_cache_hit_rate
          @data[:cache_hit_rates].last&.dig(:rate) || 0.0
        end

        def error_rate(window_seconds = 300)
          cutoff = Time.now - window_seconds
          recent_errors = @data[:error_rates].select { |entry| entry[:time] >= cutoff }

          recent_errors.size / window_seconds.to_f
        end

        def summary(window_seconds = 300)
          {
            avg_response_time: average_response_time(window_seconds),
            current_memory: current_memory_usage,
            cache_hit_rate: current_cache_hit_rate,
            error_rate: error_rate(window_seconds),
            data_points: {
              response_times: @data[:response_times].size,
              memory_samples: @data[:memory_usage].size,
              cache_samples: @data[:cache_hit_rates].size,
              error_samples: @data[:error_rates].size
            }
          }
        end
      end

      # Optimization configuration
      DEFAULT_CONFIG = {
        strategy: Strategy::BALANCED,
        cache_enabled: true,
        pooling_enabled: true,
        monitoring_enabled: true,
        auto_tuning_enabled: true,
        metrics_window_seconds: 300,
        optimization_interval: 60,
        cache_config: {},
        pool_config: {},
        thresholds: {
          response_time_warning: 1.0,
          response_time_critical: 5.0,
          memory_warning: 500 * 1024 * 1024,  # 500MB
          memory_critical: 1024 * 1024 * 1024, # 1GB
          cache_hit_rate_warning: 0.7,
          error_rate_warning: 0.01 # 1% error rate
        }
      }.freeze

      attr_reader :config, :metrics, :cache_manager

      def initialize(config = {})
        @config = DEFAULT_CONFIG.merge(config)
        @metrics = Metrics.new
        @cache_manager = CacheManager.new(@config[:cache_config]) if @config[:cache_enabled]
        @optimization_thread = nil
        @mutex = Mutex.new

        start_optimization_thread if @config[:auto_tuning_enabled]
      end

      # Optimize method execution with caching and monitoring
      # @param key [String] Cache key for the operation
      # @param category [Symbol] Cache category
      # @param ttl [Integer, nil] Cache TTL override
      # @param tags [Array<String>] Cache tags
      # @param block [Proc] Block to execute and optimize
      # @return [Object] Result of the block execution
      def optimize(key, category: :default, ttl: nil, tags: [], &block)
        return block.call unless block

        start_time = Time.now

        begin
          result = if @cache_manager && cacheable_operation?(category)
            @cache_manager.fetch(key, category: category, ttl: ttl, tags: tags, &block)
          else
            block.call
          end

          # Record successful execution
          duration = Time.now - start_time
          @metrics.record_response_time(duration)
          record_memory_usage

          result
        rescue => error
          # Record error for monitoring
          @metrics.record_error(error.class.name)
          duration = Time.now - start_time
          @metrics.record_response_time(duration)

          raise error
        end
      end

      # Optimize LLM client requests with caching and retry logic
      # @param client [LlmClient] LLM client instance
      # @param messages [Array] LLM messages
      # @param options [Hash] LLM options
      # @return [Object] LLM response
      def optimize_llm_request(client, messages, **options)
        # Create cache key based on messages and critical options
        cache_key = generate_llm_cache_key(messages, options)

        optimize(cache_key, category: :llm_responses, ttl: 3600) do
          client.complete(messages, **options)
        end
      end

      # Optimize task execution with performance monitoring
      # @param task [Task] Task instance
      # @param agent [Agent] Agent instance
      # @return [TaskResult] Task execution result
      def optimize_task_execution(task, agent)
        cache_key = "task:#{task.id}:#{agent.class.name}"

        optimize(cache_key, category: :task_results, ttl: 1800) do
          task.perform(agent)
        end
      end

      # Get current performance status
      # @return [Hash] Performance metrics and status
      def performance_status
        cache_stats = @cache_manager&.stats || {}
        metrics_summary = @metrics.summary(@config[:metrics_window_seconds])

        {
          strategy: @config[:strategy],
          cache_enabled: @config[:cache_enabled],
          metrics: metrics_summary,
          cache: cache_stats,
          health_status: determine_health_status(metrics_summary),
          optimizations_applied: current_optimizations,
          recommendations: generate_recommendations(metrics_summary, cache_stats)
        }
      end

      # Manual optimization trigger
      def optimize_now!
        perform_optimization_cycle
      end

      # Clear all caches
      def clear_caches
        @cache_manager&.clear_all
      end

      # Get optimization recommendations
      # @return [Array<String>] List of recommendations
      def recommendations
        metrics_summary = @metrics.summary(@config[:metrics_window_seconds])
        cache_stats = @cache_manager&.stats || {}
        generate_recommendations(metrics_summary, cache_stats)
      end

      # Configure optimization strategy
      # @param strategy [Symbol] New optimization strategy
      def set_strategy(strategy)
        @config[:strategy] = strategy
        apply_strategy_configuration(strategy)
      end

      # Enable/disable specific optimizations
      # @param optimizations [Hash] Optimization flags
      def configure_optimizations(**optimizations)
        @config.merge!(optimizations)

        if optimizations[:cache_enabled] == false
          @cache_manager = nil
        elsif optimizations[:cache_enabled] == true && @cache_manager.nil?
          @cache_manager = CacheManager.new(@config[:cache_config])
        end
      end

      # Performance monitoring methods
      def memory_usage
        GC.stat[:heap_allocated_pages] * GC::INTERNAL_CONSTANTS[:HEAP_PAGE_SIZE]
      end

      def cpu_usage
        # Simplified CPU usage estimation
        # In production, this could integrate with system monitoring tools
        Process.times.utime + Process.times.stime
      end

      def cache_efficiency
        return 0.0 unless @cache_manager

        stats = @cache_manager.stats
        stats[:overall_hit_rate] || 0.0
      end

      private

      # Check if operation should be cached
      def cacheable_operation?(category)
        return false unless @cache_manager

        # Define cacheable categories based on strategy
        case @config[:strategy]
        when Strategy::CONSERVATIVE
          [:agent_configs, :capability_metadata].include?(category)
        when Strategy::BALANCED
          [:llm_responses, :agent_configs, :verification_results, :capability_metadata].include?(category)
        when Strategy::AGGRESSIVE
          true # Cache everything
        else
          @config[:cacheable_categories]&.include?(category) || false
        end
      end

      # Generate cache key for LLM requests
      def generate_llm_cache_key(messages, options)
        # Include critical options that affect response
        key_data = {
          messages: messages,
          model: options[:model],
          temperature: options[:temperature],
          max_tokens: options[:max_tokens]
        }

        # Create deterministic hash
        Digest::SHA256.hexdigest(key_data.to_json)
      end

      # Record current memory usage
      def record_memory_usage
        @metrics.record_memory_usage(memory_usage) if @config[:monitoring_enabled]
      end

      # Start automatic optimization thread
      def start_optimization_thread
        @optimization_thread = Thread.new do
          Thread.current.name = "performance-optimizer"
          loop do
            sleep(@config[:optimization_interval])
            perform_optimization_cycle
          rescue => e
            puts "Optimization error: #{e.message}" if $DEBUG
          end
        end
      end

      # Perform optimization cycle
      def perform_optimization_cycle
        return unless @config[:auto_tuning_enabled]

        @mutex.synchronize do
          metrics_summary = @metrics.summary(@config[:metrics_window_seconds])
          cache_stats = @cache_manager&.stats || {}

          # Update cache hit rates in metrics
          if cache_stats[:overall_hit_rate]
            @metrics.record_cache_hit_rate(cache_stats[:overall_hit_rate])
          end

          # Apply automatic optimizations based on metrics
          apply_automatic_optimizations(metrics_summary, cache_stats)

          # Trigger cache maintenance
          @cache_manager&.perform_maintenance
        end
      end

      # Apply strategy-specific configuration
      def apply_strategy_configuration(strategy)
        case strategy
        when Strategy::CONSERVATIVE
          @config[:cache_config][:max_memory] = 50 * 1024 * 1024  # 50MB
          @config[:thresholds][:response_time_warning] = 2.0
        when Strategy::BALANCED
          @config[:cache_config][:max_memory] = 200 * 1024 * 1024 # 200MB
          @config[:thresholds][:response_time_warning] = 1.0
        when Strategy::AGGRESSIVE
          @config[:cache_config][:max_memory] = 500 * 1024 * 1024 # 500MB
          @config[:thresholds][:response_time_warning] = 0.5
        end

        # Recreate cache manager with new config
        if @cache_manager
          @cache_manager = CacheManager.new(@config[:cache_config])
        end
      end

      # Apply automatic optimizations based on current metrics
      def apply_automatic_optimizations(metrics_summary, cache_stats)
        # Adjust cache sizes based on hit rates
        if cache_stats[:overall_hit_rate] && cache_stats[:overall_hit_rate] < 0.5
          # Low hit rate - consider warming cache or adjusting TTLs
          warm_frequently_accessed_data
        end

        # Adjust based on response times
        if metrics_summary[:avg_response_time] > @config[:thresholds][:response_time_warning]
          # High response times - increase cache aggressiveness
          increase_cache_aggressiveness
        end

        # Memory-based optimizations
        if metrics_summary[:current_memory] > @config[:thresholds][:memory_warning]
          # High memory usage - trigger eviction
          @cache_manager&.perform_maintenance
        end
      end

      # Warm frequently accessed data
      def warm_frequently_accessed_data
        # Implementation would depend on access pattern tracking
        # For now, this is a placeholder
      end

      # Increase cache aggressiveness
      def increase_cache_aggressiveness
        # Increase TTLs for better caching
        # Implementation would adjust cache configurations
      end

      # Determine overall health status
      def determine_health_status(metrics_summary)
        issues = []

        if metrics_summary[:avg_response_time] > @config[:thresholds][:response_time_critical]
          issues << :critical_response_time
        elsif metrics_summary[:avg_response_time] > @config[:thresholds][:response_time_warning]
          issues << :warning_response_time
        end

        if metrics_summary[:current_memory] > @config[:thresholds][:memory_critical]
          issues << :critical_memory
        elsif metrics_summary[:current_memory] > @config[:thresholds][:memory_warning]
          issues << :warning_memory
        end

        if metrics_summary[:cache_hit_rate] < @config[:thresholds][:cache_hit_rate_warning]
          issues << :low_cache_hit_rate
        end

        if metrics_summary[:error_rate] > @config[:thresholds][:error_rate_warning]
          issues << :high_error_rate
        end

        case issues.size
        when 0
          :healthy
        when 1..2
          :warning
        else
          :critical
        end
      end

      # Get currently applied optimizations
      def current_optimizations
        optimizations = []
        optimizations << "caching" if @config[:cache_enabled]
        optimizations << "pooling" if @config[:pooling_enabled]
        optimizations << "monitoring" if @config[:monitoring_enabled]
        optimizations << "auto_tuning" if @config[:auto_tuning_enabled]
        optimizations
      end

      # Generate performance recommendations
      def generate_recommendations(metrics_summary, cache_stats)
        recommendations = []

        if metrics_summary[:avg_response_time] > @config[:thresholds][:response_time_warning]
          recommendations << "Consider increasing cache TTL or preloading frequently accessed data"
        end

        if metrics_summary[:cache_hit_rate] < 0.7
          recommendations << "Cache hit rate is low - review caching strategy or warm cache"
        end

        if metrics_summary[:current_memory] > @config[:thresholds][:memory_warning]
          recommendations << "Memory usage is high - consider reducing cache sizes or enabling compression"
        end

        if cache_stats[:total_entries] && cache_stats[:total_entries] < 100
          recommendations << "Cache utilization is low - consider increasing cache sizes"
        end

        recommendations << "System is performing well" if recommendations.empty?

        recommendations
      end
    end
  end
end
