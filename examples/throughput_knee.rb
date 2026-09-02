# frozen_string_literal: true

# The Throughput Knee: sweep one limiter's ceiling from 1 to 8 against
# an upstream that quietly serializes above 4, and measure TWO clocks -
# service time (inside the upstream) and total time (including the wait
# for a slot). The knee is where they diverge: past it, you're not
# going faster, you're just queueing somewhere you can't see.
#
#   bundle exec ruby examples/throughput_knee.rb
#
# Runs offline; the upstream's true parallelism is 4.

require_relative "../lib/agentic"
require "async"

TRUE_PARALLELISM = 4
SERVICE_TIME = 0.02
JOBS = 24

# The upstream: work beyond its parallelism doesn't fail, it queues -
# invisibly, on the server's side of the wire
server_in_flight = 0
upstream = lambda do
  server_in_flight += 1
  queued = [server_in_flight - TRUE_PARALLELISM, 0].max
  sleep(SERVICE_TIME * (1 + queued))
  server_in_flight -= 1
end

limiter = Agentic::RateLimit.new(1)
rows = []

Sync do
  (1..8).each do |ceiling|
    limiter.resize(ceiling)
    batch_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    service_times = []
    total_times = []

    JOBS.times.map {
      Async do
        submitted = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        limiter.acquire do
          admitted = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          upstream.call
          finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          service_times << finished - admitted
          total_times << finished - submitted
        end
      end
    }.each(&:wait)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - batch_started
    rows << {
      ceiling: ceiling,
      throughput: JOBS / elapsed,
      service_p50: service_times.sort[service_times.size / 2],
      total_p50: total_times.sort[total_times.size / 2]
    }
  end
end

puts "THROUGHPUT KNEE (#{JOBS} jobs per ceiling; upstream parallelism undisclosed)"
puts
puts "  ceiling   jobs/sec     service p50    total p50      "
rows.each do |row|
  bar = "#" * (row[:throughput] / 10).round
  puts format("  %-9d %8.1f     %8.1fms     %8.1fms   %s",
    row[:ceiling], row[:throughput], row[:service_p50] * 1000, row[:total_p50] * 1000, bar)
end

# The knee: the last ceiling where throughput still grew meaningfully
knee = rows.each_cons(2).find { |a, b| b[:throughput] < a[:throughput] * 1.08 }&.first || rows.last
puts
puts "  the knee is at ceiling #{knee[:ceiling]}. below it, more lanes bought more"
puts "  jobs/sec. above it, throughput didn't plateau - it FELL, because"
puts "  overload slows everyone, not just the excess. and SERVICE time rose:"
puts "  the upstream only runs #{TRUE_PARALLELISM} at once, so lanes 5-8 didn't add"
puts "  parallelism, they just moved the queue from your limiter (where"
puts "  total p50 measures it) onto the server (where service p50 hides"
puts "  it, and where you usually can't see it at all). watch both clocks:"
puts "  when raising your ceiling raises the SERVER's latency, you've"
puts "  found their ceiling, and the polite move is to stop pushing."
