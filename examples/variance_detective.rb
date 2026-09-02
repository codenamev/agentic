# frozen_string_literal: true

# The Variance Detective: ten journaled runs of the same plan, then a
# hunt for the task whose p90/p50 ratio betrays it. Averages hide
# flakiness; percentile spreads name it. Uses duration_percentile
# (new this round) over the journal's accumulated samples.
#
#   bundle exec ruby examples/variance_detective.rb [seed]
#
# Runs offline; one task is scripted-flaky, the others honest.

require_relative "../lib/agentic"
require "tmpdir"

seed = (ARGV.first || 20260707).to_i
rng = Random.new(seed)

JOURNAL = File.join(Dir.tmpdir, "agentic_variance.journal.jsonl")
File.delete(JOURNAL) if File.exist?(JOURNAL)
journal = Agentic::ExecutionJournal.new(path: JOURNAL)

# Steady tasks jitter a little; the flaky one occasionally stalls
PROFILE = {
  "fetch:profile" => ->(rng) { 0.020 + rng.rand * 0.004 },
  "fetch:permissions" => ->(rng) { 0.015 + rng.rand * 0.003 },
  "render:dashboard" => ->(rng) { 0.030 + rng.rand * 0.005 },
  "fetch:recommendations" => ->(rng) {
    (rng.rand < 0.3) ? 0.080 + rng.rand * 0.02 : 0.018 + rng.rand * 0.004
  }
}.freeze

RUNS = 20
RUNS.times do
  orchestrator = Agentic::PlanOrchestrator.new(
    concurrency_limit: 4, lifecycle_hooks: journal.lifecycle_hooks
  )
  PROFILE.each do |name, latency|
    orchestrator.add_task(Agentic::Task.new(
      description: name, agent_spec: {"name" => name, "instructions" => "serve"},
      payload: latency
    ), agent: ->(t) { sleep(t.payload.call(rng)) || :ok })
  end
  orchestrator.execute_plan
end

# --- the investigation --------------------------------------------------------
state = Agentic::ExecutionJournal.replay(path: JOURNAL)

puts "VARIANCE DETECTIVE (#{RUNS} journaled runs, seed #{seed})"
puts
puts "  task                         p50     p90   worst   p90/p50"

suspects = []
PROFILE.each_key do |name|
  p50 = state.duration_percentile(name, 50)
  p90 = state.duration_percentile(name, 90)
  worst = state.duration_percentile(name, 100)
  ratio = p90 / p50
  flaky = ratio > 2.0
  suspects << name if flaky
  puts format("  %-24s %5.0fms %5.0fms %5.0fms %8.1fx  %s",
    name, p50 * 1000, p90 * 1000, worst * 1000, ratio, flaky ? "<- SUSPECT" : "")
end

puts
if suspects.any?
  puts "  verdict: #{suspects.join(", ")} runs fine at the median and"
  puts "  terribly at the tail - the signature of flakiness (cold caches,"
  puts "  lock contention, a retried upstream). an AVERAGE would have"
  puts "  reported ~#{(state.duration_percentile(suspects.first, 50) * 1000 * 1.4).round}ms and told you nothing was wrong."
else
  puts "  no suspects. suspiciously well-behaved - check the seed."
end
