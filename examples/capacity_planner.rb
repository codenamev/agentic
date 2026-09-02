# frozen_string_literal: true

# The Capacity Planner: "how many workers do we need?" is not a
# feeling, it's Little's Law - L = lambda x W. The journal already
# holds W (task durations, as percentiles across runs); give the
# planner your target arrival rate and it computes the lanes, then
# checks the answer against every limit you've configured - because
# the binding constraint is usually not the one in the meeting.
#
#   bundle exec ruby examples/capacity_planner.rb
#
# Runs offline; history is seeded into a journal first.

require_relative "../lib/agentic"
require "tmpdir"

Agentic.logger.level = :fatal

# --- build history: 30 journaled runs of the pipeline ---------------------------
JOURNAL = File.join(Dir.tmpdir, "agentic_capacity.journal.jsonl")
File.delete(JOURNAL) if File.exist?(JOURNAL)
journal = Agentic::ExecutionJournal.new(path: JOURNAL)
rng = Random.new(1123)

30.times do
  {"fetch:ticket" => 0.08, "classify" => 0.35, "draft:reply" => 0.9}.each do |name, base|
    # log-normal-ish: mostly base, occasionally 2-3x - like real latency
    duration = base * (0.8 + rng.rand(0.4)) * ((rng.rand < 0.12) ? (2 + rng.rand) : 1)
    journal.record(:task_succeeded, task_id: name, description: name, duration: duration.round(4), output: nil)
  end
end

state = Agentic::ExecutionJournal.replay(path: JOURNAL)

TARGET_PER_MINUTE = 120 # tickets per minute at peak
CONFIGURED = {
  "orchestrator concurrency_limit" => 8,
  "provider quota (windowed)" => "90/min",
  "connection pool ceiling" => 12
}.freeze

puts "CAPACITY PLANNER (target: #{TARGET_PER_MINUTE} tickets/min at peak)"
puts
puts "  task             p50        p95        lanes needed (p50/p95) "

lambda_per_sec = TARGET_PER_MINUTE / 60.0
total_p95_lanes = 0
state.duration_samples.keys.each do |task|
  p50 = state.duration_percentile(task, 50)
  p95 = state.duration_percentile(task, 95)
  # Little's Law: concurrent-in-service L = arrival rate x service time
  lanes_p50 = (lambda_per_sec * p50).ceil
  lanes_p95 = (lambda_per_sec * p95).ceil
  total_p95_lanes += lanes_p95
  puts format("  %-16s %6.0fms   %6.0fms   %2d / %-2d %s",
    task, p50 * 1000, p95 * 1000, lanes_p50, lanes_p95, "#" * lanes_p95)
end

puts
puts "  plan for p95, not p50: capacity sized to the median is capacity"
puts "  that queues every time latency has a bad day, and latency has a"
puts "  bad day 1 run in 8 in this journal. total lanes at p95: #{total_p95_lanes}."
puts

# --- check the plan against every configured limit -------------------------------
puts "  the plan vs. what's actually configured:"
puts "    limit                                have     verdict at #{TARGET_PER_MINUTE}/min"
verdicts = {
  "orchestrator concurrency_limit" => (total_p95_lanes <= 8) ? "holds" : "BINDS FIRST - raise to #{total_p95_lanes}",
  "provider quota (windowed)" => (TARGET_PER_MINUTE <= 90) ? "holds" : "BINDS - 90/min < #{TARGET_PER_MINUTE}/min arrivals, queues grow without bound",
  "connection pool ceiling" => (total_p95_lanes <= 12) ? "holds" : "BINDS - #{total_p95_lanes} lanes want connections"
}
CONFIGURED.each do |name, have|
  puts format("    %-36s %-8s %s", name, have, verdicts[name])
end

puts
puts "  the meeting was about to argue concurrency_limit; the math says"
puts "  the provider QUOTA binds first - 90/min against 120/min arrivals"
puts "  isn't a slowdown, it's an unbounded queue (utilization > 1 has"
puts "  no steady state). fix the quota; the #{total_p95_lanes} lanes and the pool"
puts "  already hold. Little's Law plus a journal is a capacity plan;"
puts "  a dashboard plus a feeling is a postmortem."
