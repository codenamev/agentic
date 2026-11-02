# frozen_string_literal: true

module Agentic
  # Performance optimization framework for the Agentic system
  #
  # Provides comprehensive performance enhancement including:
  # - Intelligent multi-level caching with TTL and invalidation
  # - Connection and object pooling
  # - Performance monitoring and alerting
  # - Automatic optimization based on usage patterns
  # - Resource-aware scaling and tuning
  #
  # @example Basic usage
  #   # Initialize performance optimization
  #   Agentic::Performance.initialize!
  #
  #   # Use optimized operations
  #   result = Agentic::Performance.optimize('expensive_computation') do
  #     perform_expensive_computation
  #   end
  #
  # @example LLM optimization
  #   optimized_response = Agentic::Performance.optimize_llm_request(client, messages)
  #
  # @example Cache management
  #   Agentic::Performance.cache.set('key', 'value', category: :llm_responses)
  #   value = Agentic::Performance.cache.get('key')
  module Performance
    class << self
      attr_reader :optimizer, :cache_manager

      # Initialize the performance optimization system
      # @param config [Hash] Configuration options
      def initialize!(config = {})
        @optimizer = Optimizer.new(config)
        @cache_manager = @optimizer.cache_manager
        @initialized = true
      end

      # Check if performance system is initialized
      # @return [Boolean] True if initialized
      def initialized?
        @initialized ||= false
      end

      # Ensure performance system is initialized
      def ensure_initialized!
        initialize! unless initialized?
      end

      # Quick access to cache manager
      # @return [CacheManager] The cache manager instance
      def cache
        ensure_initialized!
        @cache_manager
      end

      # Optimize operation execution with caching and monitoring
      # @param key [String] Cache key
      # @param category [Symbol] Cache category
      # @param ttl [Integer, nil] Cache TTL
      # @param tags [Array<String>] Cache tags
      # @param block [Proc] Block to optimize
      # @return [Object] Result of execution
      def optimize(key, category: :default, ttl: nil, tags: [], &block)
        ensure_initialized!
        @optimizer.optimize(key, category: category, ttl: ttl, tags: tags, &block)
      end

      # Optimize LLM client requests
      # @param client [LlmClient] LLM client
      # @param messages [Array] Messages
      # @param options [Hash] Request options
      # @return [LlmResponse] Optimized LLM response
      def optimize_llm_request(client, messages, **options)
        ensure_initialized!
        @optimizer.optimize_llm_request(client, messages, **options)
      end

      # Optimize task execution
      # @param task [Task] Task to execute
      # @param agent [Agent] Agent to execute task
      # @return [TaskResult] Task result
      def optimize_task_execution(task, agent)
        ensure_initialized!
        @optimizer.optimize_task_execution(task, agent)
      end

      # Get performance status and metrics
      # @return [Hash] Performance status
      def status
        ensure_initialized!
        @optimizer.performance_status
      end

      # Get optimization recommendations
      # @return [Array<String>] Performance recommendations
      def recommendations
        ensure_initialized!
        @optimizer.recommendations
      end

      # Configure optimization strategy
      # @param strategy [Symbol] Optimization strategy
      def set_strategy(strategy)
        ensure_initialized!
        @optimizer.set_strategy(strategy)
      end

      # Configure specific optimizations
      # @param optimizations [Hash] Optimization settings
      def configure(**optimizations)
        ensure_initialized!
        @optimizer.configure_optimizations(**optimizations)
      end

      # Clear all caches
      def clear_caches
        ensure_initialized!
        @optimizer.clear_caches
      end

      # Trigger manual optimization
      def optimize_now!
        ensure_initialized!
        @optimizer.optimize_now!
      end

      # Performance monitoring methods
      def memory_usage
        ensure_initialized!
        @optimizer.memory_usage
      end

      def cache_efficiency
        ensure_initialized!
        @optimizer.cache_efficiency
      end

      # Advanced caching operations

      # Cache LLM response with intelligent categorization
      # @param key [String] Cache key
      # @param response [Object] LLM response
      # @param ttl [Integer, nil] TTL override
      def cache_llm_response(key, response, ttl: nil)
        cache&.set(key, response, category: :llm_responses, ttl: ttl)
      end

      # Cache agent configuration
      # @param agent_name [String] Agent name
      # @param config [Hash] Agent configuration
      def cache_agent_config(agent_name, config)
        cache&.set("agent_config:#{agent_name}", config, category: :agent_configs)
      end

      # Cache task result
      # @param task_id [String] Task ID
      # @param result [TaskResult] Task result
      def cache_task_result(task_id, result)
        cache&.set("task_result:#{task_id}", result, category: :task_results)
      end

      # Cache verification result
      # @param content_hash [String] Hash of content being verified
      # @param result [VerificationResult] Verification result
      def cache_verification_result(content_hash, result)
        cache&.set("verification:#{content_hash}", result, category: :verification_results)
      end

      # Invalidation helpers

      # Invalidate all LLM caches
      def invalidate_llm_cache
        cache&.invalidate_by_categories(:llm_responses)
      end

      # Invalidate agent configuration caches
      def invalidate_agent_configs
        cache&.invalidate_by_categories(:agent_configs)
      end

      # Invalidate task result caches
      def invalidate_task_results
        cache&.invalidate_by_categories(:task_results)
      end

      # Invalidate by custom tags
      # @param tags [Array<String>] Tags to invalidate
      def invalidate_by_tags(*tags)
        cache&.invalidate_by_tags(*tags)
      end

      # Cache warming utilities

      # Warm LLM response cache with common queries
      # @param common_queries [Array<Hash>] Common LLM queries
      def warm_llm_cache(common_queries)
        return unless cache

        common_queries.each do |query|
          key = "llm:#{query[:messages].hash}:#{query[:model]}"
          next if cache.get(key, category: :llm_responses)

          # This would typically be done asynchronously
          Thread.new do
          # Simulate warming - in practice, this would make actual LLM calls
          # response = llm_client.complete(query[:messages], model: query[:model])
          # cache.set(key, response, category: :llm_responses)
          rescue => e
            puts "Cache warming error: #{e.message}" if $DEBUG
          end
        end
      end

      # Warm agent configuration cache
      # @param agent_names [Array<String>] Agent names to warm
      def warm_agent_configs(agent_names)
        return unless cache

        agent_names.each do |name|
          key = "agent_config:#{name}"
          next if cache.get(key, category: :agent_configs)

          # Load agent configuration from store
          Thread.new do
          # config = agent_store.load_config(name)
          # cache.set(key, config, category: :agent_configs) if config
          rescue => e
            puts "Agent config warming error: #{e.message}" if $DEBUG
          end
        end
      end

      # Development and debugging helpers

      # Get cache statistics for debugging
      # @return [Hash] Detailed cache statistics
      def debug_cache_stats
        ensure_initialized!
        {
          cache_manager: cache&.stats,
          optimizer: @optimizer.performance_status,
          recommendations: recommendations
        }
      end

      # Benchmark operation with and without caching
      # @param key [String] Cache key
      # @param iterations [Integer] Number of iterations
      # @param block [Proc] Block to benchmark
      # @return [Hash] Benchmark results
      def benchmark(key, iterations: 10, &block)
        ensure_initialized!

        # Clear cache for fair comparison
        cache&.delete(key)

        # Benchmark without cache
        uncached_times = []
        iterations.times do
          start_time = Time.now
          block.call
          uncached_times << Time.now - start_time
        end

        # Benchmark with cache
        cached_times = []
        iterations.times do
          start_time = Time.now
          optimize(key, &block)
          cached_times << Time.now - start_time
        end

        {
          uncached: {
            times: uncached_times,
            average: uncached_times.sum / uncached_times.size,
            min: uncached_times.min,
            max: uncached_times.max
          },
          cached: {
            times: cached_times,
            average: cached_times.sum / cached_times.size,
            min: cached_times.min,
            max: cached_times.max
          },
          improvement: {
            speedup: uncached_times.sum / cached_times.sum,
            avg_improvement: (uncached_times.sum / uncached_times.size) / (cached_times.sum / cached_times.size)
          }
        }
      end

      # Configuration presets for different environments

      # Development environment configuration
      def configure_for_development
        configure(
          strategy: Optimizer::Strategy::CONSERVATIVE,
          cache_enabled: true,
          pooling_enabled: false,
          monitoring_enabled: true,
          auto_tuning_enabled: false
        )
      end

      # Production environment configuration
      def configure_for_production
        configure(
          strategy: Optimizer::Strategy::BALANCED,
          cache_enabled: true,
          pooling_enabled: true,
          monitoring_enabled: true,
          auto_tuning_enabled: true
        )
      end

      # High-performance environment configuration
      def configure_for_high_performance
        configure(
          strategy: Optimizer::Strategy::AGGRESSIVE,
          cache_enabled: true,
          pooling_enabled: true,
          monitoring_enabled: true,
          auto_tuning_enabled: true
        )
      end

      # Reset performance system (mainly for testing)
      def reset!
        @optimizer = nil
        @cache_manager = nil
        @initialized = false
      end
    end
  end
end
