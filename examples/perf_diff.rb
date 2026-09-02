# frozen_string_literal: true

# The Perf Diff: run the plan before and after a change, diff per-task
# durations, and flag regressions - with the one qualifier that decides
# whether anyone should care: is the regressed task ON the critical
# path? Off-path regressions are trivia; on-path regressions are the
# release note nobody wrote.
#
#   bundle exec ruby examples/perf_diff.rb
#
# Runs offline; the "change" speeds one task up and quietly breaks
# another, as changes do.

require_relative "../lib/agentic"

BASELINE = {
  "fetch:prices" => {sleep: 0.10, deps: []},
  "fetch:inventory" => {sleep: 0.06, deps: []},
  "reprice:catalog" => {sleep: 0.08, deps: ["fetch:prices", "fetch:inventory"]},
  "index:search" => {sleep: 0.05, deps: ["reprice:catalog"]},
  "warm:cache" => {sleep: 0.04, deps: ["reprice:catalog"]}
}.freeze

# The optimization sped up repricing... and the same PR made
# fetch:prices slower. Ship it? Let's find out.
AFTER_THE_PR = BASELINE.merge(
  "reprice:catalog" => BASELINE["reprice:catalog"].merge(sleep: 0.03),
  "fetch:prices" => BASELINE["fetch:prices"].merge(sleep: 0.16)
).freeze

def measure(work)
  durations = {}
  orchestrator = Agentic::PlanOrchestrator.new(
    concurrency_limit: 4,
    lifecycle_hooks: {
      after_task_success: ->(task_id:, task:, result:, duration:) { durations[task.description] = duration }
    }
  )
  tasks = {}
  work.each do |name, spec|
    tasks[name] = Agentic::Task.new(description: name,
      agent_spec: {"name" => name, "instructions" => "work"}, payload: spec[:sleep])
    orchestrator.add_task(tasks[name], spec[:deps].map { |d| tasks.fetch(d) },
      agent: ->(t) { sleep(t.payload) || :ok })
  end
  result = orchestrator.execute_plan
  [durations, result.execution_time, orchestrator.graph]
end

def critical_path_names(graph, durations)
  names = graph[:tasks].transform_values(&:description)
  memo = {}
  walk = lambda do |task_id|
    memo[task_id] ||= begin
      best = graph[:dependencies][task_id].map { |d| walk.call(d) }.max_by { |p| p[:cost] } || {cost: 0.0, path: []}
      {cost: best[:cost] + durations[names[task_id]], path: best[:path] + [names[task_id]]}
    end
  end
  graph[:order].map { |id| walk.call(id) }.max_by { |p| p[:cost] }[:path]
end

NOISE_MS = 15

before, wall_before, = measure(BASELINE)
after, wall_after, graph = measure(AFTER_THE_PR)
path_after = critical_path_names(graph, after)

puts "PERF DIFF (noise floor #{NOISE_MS}ms)"
puts
puts "  task                  before     after     delta  "
regressions = []
BASELINE.each_key do |name|
  delta_ms = (after[name] - before[name]) * 1000
  marker =
    if delta_ms.abs < NOISE_MS then ""
    elsif delta_ms.negative? then "faster"
    else
      on_path = path_after.include?(name)
      regressions << {name: name, on_path: on_path}
      on_path ? "SLOWER + ON CRITICAL PATH" : "slower (off-path)"
    end
  puts format("  %-18s %7dms %7dms %+8dms  %s",
    name, before[name] * 1000, after[name] * 1000, delta_ms, marker)
end

puts
puts format("  wall clock: %dms -> %dms (%+dms)",
  wall_before * 1000, wall_after * 1000, (wall_after - wall_before) * 1000)
puts
blocking = regressions.select { |r| r[:on_path] }
if blocking.any?
  puts "  VERDICT: don't ship. #{blocking.map { |r| r[:name] }.join(", ")} regressed"
  puts "  on the critical path - the repricing win is real and the users"
  puts "  will never feel it, because the wall clock got worse anyway."
  exit 1
else
  puts "  VERDICT: ship it."
end
