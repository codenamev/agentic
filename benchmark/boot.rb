# frozen_string_literal: true

# Boot-time benchmark: what does it cost to require this gem?
#
#   bundle exec ruby benchmark/boot.rb
#
# Each scenario runs in a fresh subprocess so measurements don't
# contaminate each other. Wall time, object allocations, and the number
# of loaded files tell three different stories:
# - wall time is what your app's boot feels like
# - allocations approximate the parse/define work done
# - $LOADED_FEATURES is how much of the world you dragged in

require "rbconfig"

LIB = File.expand_path("../lib", __dir__)

SCENARIOS = {
  "baseline (empty ruby)" => "",
  "require \"agentic\"" => 'require "agentic"',
  "... + Agentic::CLI (thor, tty-*)" => 'require "agentic"; Agentic::CLI',
  "... + agent assembly init" => 'require "agentic"; Agentic.logger.level = :error; Agentic.initialize_agent_assembly'
}.freeze

def measure(label, code)
  script = <<~RUBY
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    allocated_before = GC.stat(:total_allocated_objects)
    #{code}
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
    allocated = GC.stat(:total_allocated_objects) - allocated_before
    puts format("%-36s %9.1f ms %12d objects %6d features",
      #{label.inspect}, elapsed_ms, allocated, $LOADED_FEATURES.size)
  RUBY
  system(RbConfig.ruby, "-I", LIB, "-e", script) || abort("scenario failed: #{label}")
end

puts "scenario                                     wall          allocations    loaded files"
puts "-" * 88
SCENARIOS.each { |label, code| measure(label, code) }
