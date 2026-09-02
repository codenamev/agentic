# frozen_string_literal: true

# The Contract Overhead Bench: "should we validate every call?" is a
# performance question, so answer it with a measurement instead of a
# vibe. Benchmarks the validator across contract sizes and rule
# counts, then prices it against the thing it protects - because
# overhead is a fraction, and everyone keeps quoting the numerator.
#
#   bundle exec ruby examples/contract_overhead.rb
#
# Runs offline; times are real, the LLM latency is the industry's.

require_relative "../lib/agentic"

ITERATIONS = 2_000
LLM_CALL_MS = 800.0 # a conservative round-trip for a real model call

def bench(iterations)
  # Warm up, then measure - the first call pays dry-schema compilation
  yield
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / iterations * 1000
end

def spec_with(keys:, relations:)
  inputs = keys.times.to_h { |i| [:"field_#{i}", {type: "number", required: true, min: 0, max: 1_000}] }
  rules = relations.times.to_h { |i|
    [:"rule_#{i}", {relation: :sum_lte, fields: [:"field_#{i}", :"field_#{(i + 1) % keys}"], limit: 2_000}]
  }
  Agentic::CapabilitySpecification.new(
    name: "bench", description: "bench", version: "1.0.0", inputs: inputs, rules: rules
  )
end

puts "CONTRACT OVERHEAD BENCH (#{ITERATIONS} validations per row)"
puts
puts "  contract                   per call     share of an #{LLM_CALL_MS.to_i}ms LLM call"

rows = [
  ["3 keys, no rules", spec_with(keys: 3, relations: 0), {field_0: 1, field_1: 2, field_2: 3}],
  ["10 keys, no rules", spec_with(keys: 10, relations: 0), 10.times.to_h { |i| [:"field_#{i}", i] }],
  ["10 keys, 5 relations", spec_with(keys: 10, relations: 5), 10.times.to_h { |i| [:"field_#{i}", i] }],
  ["30 keys, 15 relations", spec_with(keys: 30, relations: 15), 30.times.to_h { |i| [:"field_#{i}", i] }]
]

results = rows.map do |label, spec, payload|
  validator = Agentic::CapabilityValidator.new(spec)
  ms = bench(ITERATIONS) { validator.validate_inputs!(payload) }
  share = ms / LLM_CALL_MS * 100
  puts format("  %-26s %8.4fms   %.4f%%  %s", label, ms, share, "#" * [(share * 2000).round, 40].min)
  [label, ms]
end

# The failure path costs too - measure a rejection (exception + message building)
reject_spec = spec_with(keys: 10, relations: 5)
reject_validator = Agentic::CapabilityValidator.new(reject_spec)
bad_payload = 10.times.to_h { |i| [:"field_#{i}", 1_900] } # breaks every sum_lte
reject_ms = bench(500) {
  begin
    reject_validator.validate_inputs!(bad_payload)
  rescue Agentic::Errors::ValidationError
    nil
  end
}
puts format("  %-26s %8.4fms   (the expensive path: exception + %d rule reports)", "rejection, 5 rules broken", reject_ms, 5)

puts
fastest, cheapest = results.first
biggest, priciest = results.last
puts "  the whole table rounds to zero: the biggest contract here"
puts format("  (%s) costs %.4fms per call - %.5f%% of the LLM", biggest.downcase, priciest, priciest / LLM_CALL_MS * 100)
puts format("  round-trip it guards. even rejection, the slow path, is %.2fms.", reject_ms)
puts "  \"we skip validation for performance\" saves the price of a"
puts format("  rounding error (%s: %.4fms) to risk shipping a malformed", fastest.downcase, cheapest)
puts "  prompt to an #{LLM_CALL_MS.to_i}ms call that BILLS you for the mistake."
puts "  validate both doors. the meter says you can afford it."
