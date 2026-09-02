# frozen_string_literal: true

# The Require Cost Report: `require` is a purchase - memory, objects,
# and boot time, paid again by every process you fork and every
# worker you scale. This measures what the gem and each major
# dependency cost AT REQUIRE TIME, each in a clean subprocess so
# nobody's cost gets billed to a neighbor's account.
#
#   bundle exec ruby examples/require_cost.rb
#
# Runs offline; each row is an isolated child process.

require "open3"
require "rbconfig"

RUBY = RbConfig.ruby
LIB = File.expand_path("../lib", __dir__)

# Measure inside a pristine child: RSS and allocated objects, before
# and after the require - so each row is that require's WHOLE bill,
# transitive dependencies included
PROBE = <<~'RUBY'
  def rss_kb = File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
  target, touch = ARGV
  objects_before = GC.stat(:total_allocated_objects)
  rss_before = rss_kb
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  require target
  eval(touch) if touch && !touch.empty? # standard:disable Security/Eval
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  puts [rss_kb - rss_before, GC.stat(:total_allocated_objects) - objects_before, ms.round(1)].join(",")
RUBY

def cost_of(target, touch = "")
  out, status = Open3.capture2(RUBY, "-I", LIB, "-e", PROBE, target, touch)
  raise "probe failed for #{target}" unless status.success?

  rss_kb, objects, ms = out.strip.split(",")
  {rss_mb: rss_kb.to_f / 1024, objects: objects.to_i, ms: ms.to_f}
end

TARGETS = {
  "json (stdlib)" => ["json"],
  "zeitwerk" => ["zeitwerk"],
  "async" => ["async"],
  "dry-schema" => ["dry/schema"],
  "agentic (require only)" => ["agentic"],
  "agentic + first real touch" => ["agentic",
    "Agentic::PlanOrchestrator.new; Agentic::CapabilityValidator"]
}.freeze

puts "REQUIRE COST REPORT (each row measured in a pristine child process)"
puts
puts "  require                             RSS        objects       time"
rows = TARGETS.transform_values { |target, touch| cost_of(target, touch || "") }
rows.each do |name, cost|
  puts format("  %-28s %8.1fMB %14d %8.0fms  %s",
    name, cost[:rss_mb], cost[:objects], cost[:ms], "#" * (cost[:rss_mb] * 2).round)
end

bare = rows["agentic (require only)"]
touched = rows["agentic + first real touch"]

puts
puts "  the bill, read like a Heroku support ticket - and it's a plot"
puts format("  twist: `require \"agentic\"` costs %.1fMB / %dms, nearly FREE,", bare[:rss_mb], bare[:ms])
puts "  because Zeitwerk (the round-1 cleanup) defers every constant."
puts format("  the first real touch is where the bill lands: %.1fMB and %dms,", touched[:rss_mb], touched[:ms])
puts "  as async and dry-schema come in through the autoloader. deferred"
puts "  is not free - it's a bill that arrives during your first"
puts "  request instead of your boot, which is either exactly what you"
puts "  want (CLI tools, tiny scripts pay only for what they touch) or"
puts "  exactly what you don't (a web worker's first request eats the"
puts "  latency). the moves this report funds: eager_load in servers +"
puts "  preload_app (pay once, share copy-on-write), stay lazy in CLIs,"
puts "  and run this script in CI so a new dependency's bill arrives in"
puts "  the PR that adds it - not in the invoice at month's end."
