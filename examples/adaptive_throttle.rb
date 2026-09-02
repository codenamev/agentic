# frozen_string_literal: true

# The Adaptive Throttle: nobody TELLS you an upstream's capacity - you
# discover it. An AIMD controller (TCP's algorithm) probes upward one
# lane at a time and halves on congestion, converging on the capacity
# the provider never documented. Watch the target find the truth.
#
#   bundle exec ruby examples/adaptive_throttle.rb
#
# Runs offline; the upstream secretly handles 3 concurrent calls well.

require_relative "../lib/agentic"
require "async"

SECRET_CAPACITY = 3
BASE_LATENCY = 0.02
BATCHES = 12
BATCH_SIZE = 6

# The upstream: fast until you exceed its capacity, then it degrades
in_flight = 0
upstream = lambda do
  in_flight += 1
  overload = [in_flight - SECRET_CAPACITY, 0].max
  sleep(BASE_LATENCY * (1 + overload * 1.5))
  in_flight -= 1
end

# AIMD: additive increase, multiplicative decrease - steering ONE live
# limiter via resize, the same object the clients would share
target = 1
limiter = Agentic::RateLimit.new(target)
history = []
congestion_threshold = BASE_LATENCY * 1.6

puts "ADAPTIVE THROTTLE (upstream capacity: undisclosed; AIMD will find it)"
puts
puts "  batch   target   p50                                 action"

Sync do
  BATCHES.times do |batch|
    limiter.resize(target)
    latencies = []

    BATCH_SIZE.times.map {
      Async do
        limiter.acquire do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          upstream.call
          latencies << Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
      end
    }.each(&:wait)

    p50 = latencies.sort[latencies.size / 2]
    congested = p50 > congestion_threshold
    history << target

    action = if congested
      new_target = [target / 2, 1].max
      verdict = "congested -> halve to #{new_target}"
      target = new_target
      verdict
    else
      target += 1
      "healthy -> probe up to #{target}"
    end

    puts format("  %-7d %-8d %6.1fms   %-24s %s",
      batch + 1, history.last, p50 * 1000, "#" * (history.last * 3), action)
  end
end

puts
settled = history.last(6)
puts format("  the controller oscillates around %.1f lanes - the upstream's", settled.sum.to_f / settled.size)
puts "  secret capacity is #{SECRET_CAPACITY}. AIMD never saw that constant; it derived"
puts "  it from latency alone, and it will re-derive it when the upstream"
puts "  changes. static concurrency limits are a guess frozen at deploy"
puts "  time; adaptive ones are a measurement that never stops. and the"
puts "  controller steers ONE live RateLimit via resize - every client"
puts "  sharing that limiter inherits each correction, mid-flight."
