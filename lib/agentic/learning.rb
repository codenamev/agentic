# frozen_string_literal: true

module Agentic
  # The Learning module provides components for capturing execution history,
  # recognizing patterns, and optimizing strategies based on feedback and metrics.
  #
  # @example Using the Learning System components
  #   # Initialize components
  #   history_store = Agentic::Learning::ExecutionHistoryStore.new(storage_path: "history")
  #   recognizer = Agentic::Learning::PatternRecognizer.new(history_store: history_store)
  #   optimizer = Agentic::Learning::StrategyOptimizer.new(
  #     pattern_recognizer: recognizer,
  #     history_store: history_store
  #   )
  #
  #   # Record execution data
  #   history_store.record_execution(
  #     task_id: "task-123",
  #     agent_type: "research_agent",
  #     duration_ms: 1500,
  #     success: true,
  #     metrics: { tokens_used: 2000 }
  #   )
  #
  #   # Analyze patterns
  #   patterns = recognizer.analyze_agent_performance("research_agent")
  #
  #   # Optimize strategies
  #   improved_prompt = optimizer.optimize_prompt_template(
  #     "Please research the topic: {topic}",
  #     "research_agent"
  #   )
  module Learning
    # Factory method to create a complete learning system
    #
    # @param options [Hash] Configuration options for all components
    # @option options [Logger] :logger Custom logger (defaults to Agentic.logger)
    # @option options [String] :storage_path Path for storing execution history
    # @option options [Boolean] :auto_optimize Whether to auto-apply optimizations
    # @option options [Symbol] :optimization_strategy Strategy (:conservative, :balanced, :aggressive)
    # @option options [LlmClient] :llm_client Optional LLM client for optimizations
    # @return [Hash] Hash containing all initialized learning system components
    def self.create(options = {})
      history_store = ExecutionHistoryStore.new(
        logger: options[:logger],
        storage_path: options[:storage_path],
        anonymize: options.fetch(:anonymize, true)
      )

      pattern_recognizer = PatternRecognizer.new(
        logger: options[:logger],
        history_store: history_store,
        min_sample_size: options[:min_sample_size] || 10
      )

      strategy_optimizer = StrategyOptimizer.new(
        logger: options[:logger],
        pattern_recognizer: pattern_recognizer,
        history_store: history_store,
        llm_client: options[:llm_client],
        auto_apply_optimizations: options.fetch(:auto_optimize, false)
      )

      {
        history_store: history_store,
        pattern_recognizer: pattern_recognizer,
        strategy_optimizer: strategy_optimizer
      }
    end

    # Lifecycle hooks that feed a learning system from plan execution,
    # in the same shape ExecutionJournal uses: pass them to
    # PlanOrchestrator.new(lifecycle_hooks:), optionally chaining hooks
    # you already have.
    #
    # (This replaces the never-functional register_with_orchestrator,
    # which called an #on API the orchestrator never had - hooks are a
    # construction-time seam, so the learning system meets the
    # orchestrator there.)
    #
    # @param learning_system [Hash] Components from Learning.create
    # @param hooks [Hash] Existing hooks to invoke after recording
    # @return [Hash] Lifecycle hooks for PlanOrchestrator.new
    def self.lifecycle_hooks(learning_system, hooks = {})
      store = learning_system.fetch(:history_store)
      record = lambda do |task_id:, task:, duration:, success:, metrics: {}|
        store.record_execution(
          task_id: task_id,
          agent_type: task.agent_spec.is_a?(Hash) ? task.agent_spec["name"] : task.agent_spec&.name,
          duration_ms: (duration * 1000).round,
          success: success,
          metrics: metrics,
          context: {task_description: task.description}
        )
      end

      {
        after_task_success: lambda do |task_id:, task:, result:, duration:|
          stats = result.respond_to?(:stats) ? result.stats : nil
          # String keys: PatternRecognizer reads metrics["tokens_used"], and
          # that is also the shape a JSON-reloaded record has.
          metrics = stats ? {"tokens_used" => stats.total_tokens, "prompt_tokens" => stats.prompt_tokens, "completion_tokens" => stats.completion_tokens} : {}
          record.call(task_id: task_id, task: task, duration: duration, success: true, metrics: metrics)
          hooks[:after_task_success]&.call(task_id: task_id, task: task, result: result, duration: duration)
        end,
        after_task_failure: lambda do |task_id:, task:, failure:, duration:|
          record.call(task_id: task_id, task: task, duration: duration, success: false,
            metrics: {failure_type: failure.type})
          hooks[:after_task_failure]&.call(task_id: task_id, task: task, failure: failure, duration: duration)
        end
      }
    end
  end
end
