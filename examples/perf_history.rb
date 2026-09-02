# frozen_string_literal: true

# Perf History: last release's run left a journal; this release's run
# is compared against it. No synthetic baseline, no same-process
# rerun - the baseline is what production actually did, keyed by task
# description, straight from ExecutionJournal durations.
#
#   bundle exec ruby examples/perf_history.rb
#
# Runs offline; "last release" is journaled first, then "this release"
# runs against its recorded history.

require_relative "../lib/agentic"
require "tmpdir"

BASELINE_JOURNAL = File.join(Dir.tmpdir, "agentic_perf_history.jsonl")
File.delete(BASELINE_JOURNAL) if File.exist?(BASELINE_JOURNAL)

RELEASE_1 = {
  "resize:images" => 0.06,
  "transcode:audio" => 0.11,
  "generate:captions" => 0.08,
  "package:episode" => 0.05
}.freeze

# This release: captions got slower (new model), packaging got faster
RELEASE_2 = RELEASE_1.merge(
  "generate:captions" => 0.14,
  "package:episode" => 0.02
).freeze

def run_release(work, journal: nil, collect: nil)
  hooks = {}
  hooks = journal.lifecycle_hooks if journal
  if collect
    hooks = (journal ? journal.lifecycle_hooks : {}).merge(
      after_task_success: ->(task_id:, task:, result:, duration:) { collect[task.description] = duration }
    )
  end

  orchestrator = Agentic::PlanOrchestrator.new(concurrency_limit: 4, lifecycle_hooks: hooks)
  previous = nil
  work.each do |name, latency|
    task = Agentic::Task.new(description: name,
      agent_spec: {"name" => name, "instructions" => "work"}, payload: latency)
    orchestrator.add_task(task, previous ? [previous] : [], agent: ->(t) { sleep(t.payload) || :ok })
    previous = task
  end
  orchestrator.execute_plan
end

# --- release 1 ships; its journal IS the baseline ----------------------------
run_release(RELEASE_1, journal: Agentic::ExecutionJournal.new(path: BASELINE_JOURNAL))
baseline = Agentic::ExecutionJournal.replay(path: BASELINE_JOURNAL).durations

# --- release 2 runs; the journal from last time judges it --------------------
current = {}
run_release(RELEASE_2, collect: current)

NOISE_MS = 15

puts "PERF HISTORY (baseline: #{BASELINE_JOURNAL.split("/").last}, noise floor #{NOISE_MS}ms)"
puts
puts "  task                 last release   this one     delta"
regressions = []
current.each do |name, duration|
  recorded = baseline[name]
  next unless recorded

  delta_ms = (duration - recorded) * 1000
  verdict =
    if delta_ms.abs < NOISE_MS then ""
    elsif delta_ms.negative? then "faster"
    else
      regressions << name
      "REGRESSED"
    end
  puts format("  %-20s %9.0fms %9.0fms %+8.0fms  %s",
    name, recorded * 1000, duration * 1000, delta_ms, verdict)
end

puts
if regressions.any?
  puts "  #{regressions.join(", ")} regressed against the journal of the"
  puts "  last shipped release. the baseline wasn't a benchmark rig - it"
  puts "  was what actually ran, fsynced as it happened."
  exit 1
else
  puts "  no regressions against recorded history. ship."
end
