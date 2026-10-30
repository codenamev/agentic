# frozen_string_literal: true

require "json"
require "fileutils"
require "time" # Time#iso8601 - do not depend on another file loading it first

module Agentic
  # Durable, append-only journal of plan execution.
  #
  # Wires into PlanOrchestrator's lifecycle hooks and writes one JSON line
  # per event - locked, flushed, and fsynced - so a crashed or killed
  # process leaves a complete record of every task that started, finished,
  # or failed, and of what each success cost to obtain. LLM calls are the
  # expensive part of a plan; the journal is what lets you not pay for
  # them twice.
  #
  # @example Journal a plan and resume after a crash
  #   journal = Agentic::ExecutionJournal.new(path: "orders.journal.jsonl")
  #   orchestrator = Agentic::PlanOrchestrator.new(lifecycle_hooks: journal.lifecycle_hooks)
  #   # ... process dies mid-plan, rerun:
  #   state = Agentic::ExecutionJournal.replay(path: "orders.journal.jsonl")
  #   state.completed_task_ids # => tasks you already paid for
  #   state.outputs["task-1"]  # => their outputs, ready to reuse
  class ExecutionJournal
    # Replayed journal state: everything a resuming process needs to know
    ReplayedState = Struct.new(
      :plan_id, :status, :completed_task_ids, :failed_task_ids, :outputs, :failures, :events, :descriptions, :durations, :duration_samples, :damage,
      :tokens,
      keyword_init: true
    ) do
      # Token usage summed over every task_succeeded line that carried it.
      # nil when no line did (older journals, or runs that never reached an
      # LLM) - unknown is not zero, so it is never reported as zero.
      # @return [Integer, nil] Total tokens across recorded tasks
      def total_tokens
        totals = tokens.values.map { |t| t[:total_tokens] }.compact
        totals.empty? ? nil : totals.sum
      end

      # Whether any lines were torn, mis-encoded, or shape-broken.
      # Tolerant replay salvages around damage and reports it here;
      # a recovery tool should check this and say so out loud.
      # @return [Boolean]
      def damaged?
        !damage.empty?
      end

      # Task durations keyed by description - the natural baseline source
      # for performance regression tooling
      # @return [Hash{String=>Float}] Description => seconds (latest wins)
      def durations_by_description
        durations
      end

      # A percentile over a task's recorded durations, for baselines that
      # resist single-run noise (a journal may hold many runs)
      # @param description [String] The task's description
      # @param percentile [Numeric] 0-100
      # @param last [Integer, nil] Consider only the most recent N samples
      # @return [Float, nil] The percentile duration, or nil if unrecorded
      def duration_percentile(description, percentile, last: nil)
        samples = duration_samples[description]
        return nil if samples.nil? || samples.empty?

        samples = samples.last(last) if last
        sorted = samples.sort
        rank = (percentile / 100.0) * (sorted.size - 1)
        lower = sorted[rank.floor]
        upper = sorted[rank.ceil]
        lower + (upper - lower) * (rank - rank.floor)
      end

      # @param key [String] A task id or a task description (descriptions
      #   act as idempotency keys across runs, since ids are per-run)
      # @return [Boolean] True if the journal records a success for the task
      def completed?(key)
        completed_task_ids.include?(key) || completed_descriptions.include?(key)
      end

      # Descriptions of every task the journal proves completed - the
      # resume set for a rerun, where task ids are freshly generated
      # @return [Array<String>]
      def completed_descriptions
        completed_task_ids.filter_map { |task_id| descriptions[task_id] }
      end
    end

    # @return [String] Absolute path of the journal file
    attr_reader :path

    # @return [Integer] Events per fsync (1 = every event is durable
    #   before record returns)
    attr_reader :fsync_every

    # @param path [String] Where to write the journal (created on first event)
    # @param fsync_every [Integer] Group-commit knob. 1 (the default) is
    #   the strong promise: a crash cannot unwrite what record returned
    #   from. n > 1 amortizes the fsync across n events for ~n-fold write
    #   throughput - AND a crash may lose up to n-1 acknowledged events.
    #   That is a different durability contract, not a faster same one;
    #   choose it only where your recovery story tolerates the gap.
    def initialize(path:, fsync_every: 1)
      unless fsync_every.is_a?(Integer) && fsync_every >= 1
        raise ArgumentError, "fsync_every must be a positive Integer, got #{fsync_every.inspect}"
      end

      @path = File.expand_path(path)
      @fsync_every = fsync_every
      @writes = 0
      @mutex = Mutex.new
      FileUtils.mkdir_p(File.dirname(@path))
    end

    # Lifecycle hooks for PlanOrchestrator, optionally chaining existing hooks
    # @param hooks [Hash] Hooks to invoke after journaling (e.g. a CLI observer's)
    # @return [Hash] Hooks that journal each event, then delegate
    def lifecycle_hooks(hooks = {})
      {
        before_task_execution: chain(hooks[:before_task_execution]) do |task_id:, task:|
          record(:task_started, task_id: task_id, description: task.description)
        end,
        after_task_success: chain(hooks[:after_task_success]) do |task_id:, task:, result:, duration:|
          record(:task_succeeded, task_id: task_id, description: task.description, duration: duration, output: result.output,
            **token_fields(result))
        end,
        after_task_failure: chain(hooks[:after_task_failure]) do |task_id:, task:, failure:, duration:|
          record(:task_failed, task_id: task_id, description: task.description, duration: duration,
            error: failure.message, error_type: failure.type,
            retryable: failure.respond_to?(:retryable?) ? failure.retryable? : nil)
        end,
        plan_completed: chain(hooks[:plan_completed]) do |plan_id:, status:, execution_time:, tasks:, results:|
          record(:plan_completed, plan_id: plan_id, status: status, execution_time: execution_time)
        end
      }
    end

    # Appends an event to the journal - locked, flushed, and fsynced
    #
    # @note Concurrency contract: thread-safe (a Mutex serializes
    #   writers in-process) AND cross-process safe (flock serializes
    #   writers across processes). Pinned by the concurrency contract
    #   spec and the threads/process drills.
    # @param event [Symbol, String] The event name
    # @param payload [Hash] Event data (must be JSON-serializable)
    # @return [void]
    def record(event, payload = {})
      line = JSON.generate({event: event, at: Time.now.utc.iso8601(3)}.merge(payload))

      @mutex.synchronize do
        File.open(@path, "a") do |file|
          file.flock(File::LOCK_EX)
          file.puts(line)
          file.flush
          file.fsync if ((@writes += 1) % @fsync_every).zero?
        end
      end
    end

    # Forces durability of everything written so far - call before
    # relying on a group-committed journal (e.g. at plan completion)
    # @return [void]
    def sync
      @mutex.synchronize do
        File.open(@path, "a") { |file| file.fsync } if File.exist?(@path)
      end
    end

    # Replays a journal file into resumable state.
    #
    # The default mode is :tolerant, because the file being replayed
    # is - by this class's reason for existing - a file that may end
    # mid-write: every whole line is salvaged, and torn, mis-encoded,
    # or shape-broken lines are recorded on state.damage instead of
    # raising. Recovery tools must never be the second thing that
    # fails. Audit tools that WANT to fail on damage pass
    # mode: :strict and get a JournalDamagedError naming the line.
    #
    # @param path [String] The journal file to replay
    # @param mode [Symbol] :tolerant (salvage + report) or :strict (raise)
    # @return [ReplayedState] What completed, what failed, and what it produced
    # @raise [Errors::JournalDamagedError] In :strict mode, on the first damaged line
    def self.replay(path:, mode: :tolerant)
      state = ReplayedState.new(
        plan_id: nil,
        status: nil,
        completed_task_ids: [],
        failed_task_ids: [],
        outputs: {},
        failures: {},
        events: [],
        descriptions: {},
        durations: {},
        duration_samples: Hash.new { |h, k| h[k] = [] },
        damage: [],
        tokens: {}
      )

      return state unless File.exist?(path)

      line_number = 0
      File.foreach(path) do |line|
        line_number += 1
        entry = begin
          stripped = line.scrub("�").strip
          next if stripped.empty?

          JSON.parse(stripped, symbolize_names: true)
        rescue JSON::ParserError, EncodingError => e
          if mode == :strict
            raise Errors::JournalDamagedError.new("unparseable journal line: #{e.message[0, 60]}", line_number: line_number)
          end
          state.damage << {line: line_number, reason: e.class.name}
          next
        end

        if %w[task_succeeded task_failed task_started].include?(entry[:event]) && !entry[:task_id].is_a?(String)
          if mode == :strict
            raise Errors::JournalDamagedError.new("#{entry[:event]} line missing a String task_id", line_number: line_number)
          end
          state.damage << {line: line_number, reason: "missing task_id"}
          next
        end

        state.events << entry
        if entry[:task_id] && entry[:description]
          state.descriptions[entry[:task_id]] = entry[:description]
        end

        case entry[:event]
        when "task_succeeded"
          task_id = entry[:task_id]
          state.completed_task_ids << task_id unless state.completed_task_ids.include?(task_id)
          state.failed_task_ids.delete(task_id)
          state.failures.delete(task_id)
          state.outputs[task_id] = entry[:output]
          state.tokens[task_id] = entry.slice(:prompt_tokens, :completion_tokens, :total_tokens) if entry.key?(:total_tokens)
          if entry[:description] && entry[:duration]
            state.durations[entry[:description]] = entry[:duration]
            state.duration_samples[entry[:description]] << entry[:duration]
          end
        when "task_failed"
          task_id = entry[:task_id]
          unless state.completed_task_ids.include?(task_id)
            state.failed_task_ids << task_id unless state.failed_task_ids.include?(task_id)
            state.failures[task_id] = {message: entry[:error], type: entry[:error_type], retryable: entry[:retryable]}
          end
        when "plan_completed"
          state.plan_id = entry[:plan_id]
          state.status = entry[:status]&.to_sym
        end
      end

      state
    end

    private

    # Token usage fields for a task_succeeded line. Absent (not zero) when
    # the result carries no stats, so a replay can tell "unknown" from "free".
    # @param result [TaskResult] The task's result
    # @return [Hash] prompt/completion/total token counts, or empty
    def token_fields(result)
      stats = result.respond_to?(:stats) ? result.stats : nil
      return {} unless stats

      {prompt_tokens: stats.prompt_tokens, completion_tokens: stats.completion_tokens, total_tokens: stats.total_tokens}
    end

    # Wraps a journaling block so an existing hook still runs afterwards
    def chain(existing, &journal_block)
      return journal_block unless existing

      ->(**kwargs) {
        journal_block.call(**kwargs)
        existing.call(**kwargs)
      }
    end
  end
end
