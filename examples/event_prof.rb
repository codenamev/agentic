# frozen_string_literal: true

# EventProf for Plans: TestProf taught test suites to answer "where
# does the time GO?" by group, not by file. Same question for plans:
# tag every task by its kind (llm:, db:, render:), collect durations
# from the lifecycle hooks, and report task-seconds by tag - plus the
# number nobody computes: how much of that time ran in parallel, and
# how much of the wall clock one tag owns hostage.
#
#   bundle exec ruby examples/event_prof.rb
#
# Runs offline; durations are scripted, accounting is real.

require_relative "../lib/agentic"

Agentic.logger.level = :fatal

WORK = {
  "db:fetch_users" => 0.03, "db:fetch_orders" => 0.04, "db:fetch_stock" => 0.03,
  "llm:summarize" => 0.22, "llm:classify" => 0.18, "llm:draft" => 0.25,
  "render:header" => 0.01, "render:body" => 0.02, "render:pdf" => 0.05
}.freeze

samples = []
hooks = {
  after_task_success: ->(task_id:, task:, result:, duration:) {
    samples << [task.description, duration]
  }
}

orchestrator = Agentic::PlanOrchestrator.new(concurrency_limit: 3, lifecycle_hooks: hooks)
tasks = WORK.to_h { |name, cost| [name, Agentic::Task.new(description: name, agent_spec: {"name" => name, "instructions" => "w"})] }

# db feeds llm feeds render - three stages, three lanes
db, llm, render = %w[db llm render].map { |prefix| tasks.select { |n, _| n.start_with?(prefix) }.values }
db.each { |t| orchestrator.add_task(t, agent: ->(task) { sleep(WORK[task.description]) }) }
llm.each { |t| orchestrator.add_task(t, db, agent: ->(task) { sleep(WORK[task.description]) }) }
render.each { |t| orchestrator.add_task(t, llm, agent: ->(task) { sleep(WORK[task.description]) }) }

wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
orchestrator.execute_plan
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_start

# --- the profile ----------------------------------------------------------------
by_tag = samples.group_by { |name, _| name[/\A\w+/] }
  .transform_values { |rows| {seconds: rows.sum { |_, d| d }, count: rows.size, worst: rows.max_by { |_, d| d }} }
task_seconds = samples.sum { |_, d| d }

puts "EVENT PROF (task-seconds by tag; wall clock #{(wall * 1000).round}ms, 3 lanes)"
puts
puts "  tag      seconds    share    tasks    worst offender"
by_tag.sort_by { |_, v| -v[:seconds] }.each do |tag, stats|
  share = stats[:seconds] / task_seconds * 100
  puts format("  %-8s %6.0fms   %5.1f%%   %-8d %s (%.0fms)  %s",
    tag, stats[:seconds] * 1000, share, stats[:count],
    stats[:worst][0], stats[:worst][1] * 1000, "#" * (share / 3).round)
end

parallelism = task_seconds / wall
puts
puts format("  task-seconds: %.0fms across %.0fms of wall = %.1fx effective parallelism", task_seconds * 1000, wall * 1000, parallelism)
puts
llm_share = by_tag["llm"][:seconds] / task_seconds * 100
puts "  the TestProf move is reading the SHARE column before touching any"
puts format("  code: llm owns %.0f%% of all task-seconds, so a 20%% win there is", llm_share)
puts "  worth more than deleting the entire render stage - optimizing"
puts "  db: or render: is polishing doorknobs on a burning building."
puts format("  and the parallelism line is the second lesson: %.1fx on 3 lanes", parallelism)
puts "  means the stage barriers are eating part of the overlap -"
puts "  llm tasks can't start until ALL db tasks finish. profile by"
puts "  group, fix the biggest group, re-profile. boring, effective,"
puts "  and the hooks made it fifteen lines."
