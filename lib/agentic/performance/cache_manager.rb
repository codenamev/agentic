# frozen_string_literal: true

module Agentic
  module Performance
    # Cache manager for coordinating multiple cache instances and strategies
    #
    # Provides intelligent caching coordination with:
    # - Multi-level caching (L1 memory, L2 Redis, etc.)
    # - Cache warming and preloading strategies
    # - Dependency-based invalidation
    # - Performance monitoring and optimization
    # - Plugin-based cache backends
    class CacheManager
      # Cache levels for multi-level caching
      CACHE_LEVELS = {
        l1: {max_size: 500, max_memory: 50 * 1024 * 1024, default_ttl: 300},      # 5 min, 50MB
        l2: {max_size: 2000, max_memory: 200 * 1024 * 1024, default_ttl: 1800},  # 30 min, 200MB
        l3: {max_size: 10000, max_memory: 1024 * 1024 * 1024, default_ttl: 3600} # 1 hour, 1GB
      }.freeze

      # Cache categories for different data types
      CACHE_CATEGORIES = {
        llm_responses: {default_ttl: 3600, tags: ["llm"], level: :l2},
        agent_configs: {default_ttl: 1800, tags: ["config"], level: :l1},
        task_results: {default_ttl: 7200, tags: ["task"], level: :l2},
        verification_results: {default_ttl: 1800, tags: ["verification"], level: :l1},
        capability_metadata: {default_ttl: 3600, tags: ["capability"], level: :l1},
        execution_plans: {default_ttl: 1800, tags: ["plan"], level: :l2},
        observability_data: {default_ttl: 300, tags: ["observability"], level: :l3}
      }.freeze

      attr_reader :caches, :statistics

      def initialize(config = {})
        @config = config
        @caches = {}
        @statistics = {
          total_requests: 0,
          cache_hits: 0,
          cache_misses: 0,
          invalidations: 0,
          warming_operations: 0
        }
        @mutex = Mutex.new

        initialize_cache_levels
        setup_cache_categories
      end

      # Get value with intelligent cache level selection
      # @param key [String] Cache key
      # @param category [Symbol] Cache category
      # @return [Object, nil] Cached value
      def get(key, category: :default)
        @statistics[:total_requests] += 1

        category_config = CACHE_CATEGORIES[category] || {}
        preferred_level = category_config[:level] || :l1

        # Try preferred level first, then fallback to other levels
        cache_levels = [preferred_level] + (CACHE_LEVELS.keys - [preferred_level])

        cache_levels.each do |level|
          cache = @caches[level]
          next unless cache

          value = cache.get(key)
          if value
            @statistics[:cache_hits] += 1

            # Promote to higher cache levels for frequently accessed data
            promote_to_higher_levels(key, value, level, category)

            return value
          end
        end

        @statistics[:cache_misses] += 1
        nil
      end

      # Set value with intelligent cache level and TTL selection
      # @param key [String] Cache key
      # @param value [Object] Value to cache
      # @param category [Symbol] Cache category
      # @param ttl [Integer, nil] Time-to-live override
      # @param tags [Array<String>] Additional tags
      # @return [Boolean] Success status
      def set(key, value, category: :default, ttl: nil, tags: [])
        category_config = CACHE_CATEGORIES[category] || {}
        preferred_level = category_config[:level] || :l1
        final_ttl = ttl || category_config[:default_ttl]
        final_tags = (Array(tags) + Array(category_config[:tags]) + [category.to_s]).uniq

        cache = @caches[preferred_level]
        return false unless cache

        cache.set(key, value, ttl: final_ttl, tags: final_tags)
      end

      # Fetch with fallback computation
      # @param key [String] Cache key
      # @param category [Symbol] Cache category
      # @param ttl [Integer, nil] Time-to-live override
      # @param tags [Array<String>] Additional tags
      # @param block [Proc] Computation block
      # @return [Object] Cached or computed value
      def fetch(key, category: :default, ttl: nil, tags: [], &block)
        value = get(key, category: category)
        return value unless value.nil?

        return nil unless block

        computed_value = block.call
        set(key, computed_value, category: category, ttl: ttl, tags: tags)
        computed_value
      end

      # Delete from all cache levels
      # @param key [String] Cache key
      # @return [Integer] Number of caches that had the key
      def delete(key)
        deleted_count = 0
        @caches.each_value do |cache|
          deleted_count += 1 if cache.delete(key)
        end
        deleted_count
      end

      # Invalidate by tags across all cache levels
      # @param tags [Array<String>] Tags to invalidate
      # @return [Hash] Invalidation count by cache level
      def invalidate_by_tags(*tags)
        @statistics[:invalidations] += 1

        results = {}
        @caches.each do |level, cache|
          results[level] = cache.invalidate_by_tags(tags)
        end
        results
      end

      # Invalidate by category
      # @param categories [Array<Symbol>] Categories to invalidate
      # @return [Hash] Invalidation count by cache level
      def invalidate_by_categories(*categories)
        tags = categories.flat_map { |cat| [cat.to_s] + Array(CACHE_CATEGORIES[cat][:tags]) }.uniq
        invalidate_by_tags(tags)
      end

      # Warm cache with precomputed data
      # @param data [Hash] Key-value pairs to warm
      # @param category [Symbol] Cache category
      # @param ttl [Integer, nil] Time-to-live override
      def warm_cache(data, category: :default, ttl: nil)
        @statistics[:warming_operations] += 1

        data.each do |key, value|
          set(key, value, category: category, ttl: ttl)
        end
      end

      # Intelligent cache warming based on usage patterns
      # @param keys [Array<String>] Keys to consider for warming
      # @param category [Symbol] Cache category
      # @param block [Proc] Block to compute values
      def intelligent_warming(keys, category: :default, &block)
        return unless block

        @statistics[:warming_operations] += 1

        # Prioritize keys based on historical access patterns
        prioritized_keys = prioritize_keys_for_warming(keys, category)

        # Warm up to 50% of cache capacity to avoid eviction
        max_warm_count = (@caches[:l1]&.config&.dig(:max_size) || 100) / 2

        prioritized_keys.first(max_warm_count).each do |key|
          next if get(key, category: category) # Skip if already cached

          begin
            value = block.call(key)
            set(key, value, category: category) if value
          rescue => e
            # Log error but continue warming other keys
            puts "Cache warming error for key '#{key}': #{e.message}" if $DEBUG
          end
        end
      end

      # Get comprehensive statistics
      # @return [Hash] Cache statistics
      def stats
        cache_stats = {}
        total_memory = 0
        total_entries = 0

        @caches.each do |level, cache|
          stats = cache.stats
          cache_stats[level] = stats
          total_memory += stats[:memory_usage]
          total_entries += stats[:entry_count]
        end

        overall_hit_rate = (@statistics[:total_requests] > 0) ?
          @statistics[:cache_hits].to_f / @statistics[:total_requests] : 0.0

        @statistics.merge({
          cache_levels: cache_stats,
          total_memory_usage: total_memory,
          total_entries: total_entries,
          overall_hit_rate: overall_hit_rate
        })
      end

      # Clear all caches
      def clear_all
        @caches.each_value(&:clear)
      end

      # Health check for all cache levels
      # @return [Hash] Health status by level
      def health_check
        health = {}

        @caches.each do |level, cache|
          stats = cache.stats
          health[level] = {
            status: determine_cache_health(stats),
            memory_utilization: stats[:memory_usage].to_f / stats[:memory_limit],
            capacity_utilization: stats[:entry_count].to_f / stats[:size_limit],
            hit_rate: stats[:hit_rate]
          }
        end

        health
      end

      # Optimize cache configuration based on usage patterns
      def optimize_configuration
        @caches.each do |level, cache|
          stats = cache.stats

          # Suggest configuration optimizations
          if stats[:hit_rate] < 0.5 && stats[:entry_count] < stats[:size_limit] * 0.1
            puts "Consider reducing cache size for level #{level}" if $DEBUG
          elsif stats[:memory_usage] > stats[:memory_limit] * 0.9
            puts "Consider increasing memory limit for level #{level}" if $DEBUG
          elsif stats[:hit_rate] > 0.9 && stats[:entry_count] > stats[:size_limit] * 0.8
            puts "Consider increasing cache size for level #{level}" if $DEBUG
          end
        end
      end

      # Background maintenance operations
      def perform_maintenance
        @caches.each_value do |cache|
          # Cleanup expired entries
          cache.cleanup_expired

          # Trigger eviction if memory usage is high
          if cache.stats[:memory_usage] > cache.config[:max_memory] * 0.85
            # Force eviction by temporarily reducing cache size
            original_size = cache.config[:max_size]
            cache.config[:max_size] = (original_size * 0.8).to_i
            # Eviction happens automatically on next write
            cache.config[:max_size] = original_size
          end
        end
      end

      private

      # Initialize cache levels with appropriate configurations
      def initialize_cache_levels
        CACHE_LEVELS.each do |level, config|
          merged_config = config.merge(@config[level] || {})
          @caches[level] = Cache.new(merged_config)
        end
      end

      # Setup category-specific cache configurations
      def setup_cache_categories
        # Pre-warm frequently used categories if needed
        # This could be extended to load from configuration or historical data
      end

      # Promote frequently accessed data to higher cache levels
      def promote_to_higher_levels(key, value, current_level, category)
        return if current_level == :l1 # Already at highest level

        # Simple promotion logic: if accessed from L2/L3, promote to L1
        if current_level != :l1
          @caches[:l1]&.set(key, value,
            ttl: CACHE_CATEGORIES[category][:default_ttl],
            tags: CACHE_CATEGORIES[category][:tags])
        end
      end

      # Prioritize keys for cache warming based on heuristics
      def prioritize_keys_for_warming(keys, category)
        # Simple heuristic: prioritize shorter keys (often more frequently accessed)
        # In a real implementation, this could use historical access data
        keys.sort_by { |key| [key.length, key] }
      end

      # Determine cache health based on statistics
      def determine_cache_health(stats)
        if stats[:hit_rate] > 0.8 && stats[:memory_usage] < stats[:memory_limit] * 0.9
          :healthy
        elsif stats[:hit_rate] > 0.5 && stats[:memory_usage] < stats[:memory_limit] * 0.95
          :warning
        else
          :critical
        end
      end
    end
  end
end
