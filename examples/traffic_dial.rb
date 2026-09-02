# frozen_string_literal: true

# The Traffic Dial: a canary rollout as one knob. New code starts at
# one lane of traffic; every healthy stage turns the dial up, and the
# moment the latency budget burns, the dial turns itself back down.
# No feature flags service, no rollout platform - a RateLimit, resized.
#
#   bundle exec ruby examples/traffic_dial.rb
#
# Runs offline; v2 hides a regression that only appears above 3 lanes.

require_relative "../lib/agentic"
require "async"

FULL_CAPACITY = 10
SLO = 0.035 # p50 budget per request, seconds
STAGES = [1, 3, 6, 10].freeze
REQUESTS_PER_STAGE = 12

# v2 of the worker: fine at low concurrency, degrades above 3 in
# flight - the classic regression a staging box never has enough
# traffic to show you
v2_in_flight = 0
v2 = lambda do
  v2_in_flight += 1
  overload = [v2_in_flight - 3, 0].max
  sleep(0.02 * (1 + overload))
  v2_in_flight -= 1
end

dial = Agentic::RateLimit.new(STAGES.first)
history = []
burns = Hash.new(0)

puts "TRAFFIC DIAL: rolling out v2, #{FULL_CAPACITY} lanes of traffic total"
puts
puts "  stage    lanes    p50        verdict"

Sync do
  stage_index = 0
  8.times do
    lanes = STAGES[stage_index]
    dial.resize(lanes)
    latencies = []

    REQUESTS_PER_STAGE.times.map {
      Async do
        dial.acquire do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          v2.call
          latencies << Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
      end
    }.each(&:wait)

    p50 = latencies.sort[latencies.size / 2]
    healthy = p50 <= SLO
    hold = false
    verdict = if healthy && lanes == FULL_CAPACITY
      "SLO holds at full traffic - rollout complete"
    elsif healthy && burns[STAGES[stage_index + 1]] >= 2
      hold = true
      "holding at #{lanes} - stage #{STAGES[stage_index + 1]} burned twice; page the author, not the dial"
    elsif healthy
      stage_index += 1
      "healthy - dial up to #{STAGES[stage_index]}"
    else
      burns[lanes] += 1
      stage_index = [stage_index - 1, 0].max
      "SLO burned - dial BACK to #{STAGES[stage_index]}"
    end

    history << {lanes: lanes, p50: p50, healthy: healthy}
    puts format("  %-8d %-8d %6.1fms   %s", history.size, lanes, p50 * 1000, verdict)

    break if hold || (healthy && lanes == FULL_CAPACITY)
  end
end

puts
ceiling_found = history.select { |h| h[:healthy] }.map { |h| h[:lanes] }.max
puts "  the dial settled at #{ceiling_found} lanes, tried #{STAGES[STAGES.index(ceiling_found) + 1]} twice, and stopped -"
puts "  v2 has a regression that only shows above 3 in flight, which is"
puts "  exactly the kind of bug staging never catches and production"
puts "  always does. the rollout didn't need a platform team: one"
puts "  RateLimit, resized on evidence, IS the deployment strategy."
puts "  ship the fix, turn the dial again tomorrow."
