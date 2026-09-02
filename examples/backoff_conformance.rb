# frozen_string_literal: true

# Backoff Conformance: every strategy x jitter combination, a thousand
# draws each through an injected seeded RNG, checked against the
# documented bounds. Retry timing is a contract like any other - and
# now that rng: is injectable, the contract is testable without
# stubbing a single method.
#
#   bundle exec ruby examples/backoff_conformance.rb [seed]
#
# Runs offline and deterministically. Exit 1 on any bound violation.

require_relative "../lib/agentic"

seed = (ARGV.first || 20260707).to_i
DRAWS = 1_000
BASE = 1.0
RETRY_COUNT = 3

# The documented bounds for each (strategy, jitter) combination
def expected_bounds(strategy, jitter, retry_count)
  nominal = case strategy
  when :constant then BASE
  when :linear then retry_count * BASE
  when :exponential then BASE * (2**(retry_count - 1))
  end

  case jitter
  when false then [nominal, nominal]
  when true then [nominal * 0.75, nominal * 1.25]
  when :full then [0.0, nominal]
  end
end

failures = []
puts "BACKOFF CONFORMANCE (seed #{seed}, #{DRAWS} draws per combination)"
puts
puts "  strategy      jitter   expected               observed               verdict"

%i[constant linear exponential].each do |strategy|
  [false, true, :full].each do |jitter|
    rng = Random.new(seed)
    orchestrator = Agentic::PlanOrchestrator.new(retry_policy: {
      backoff_strategy: strategy,
      backoff_constant: BASE,
      backoff_base: BASE,
      backoff_jitter: jitter,
      rng: rng
    })

    observed = []
    orchestrator.define_singleton_method(:sleep) { |delay| observed << delay }

    task = Agentic::Task.new(description: "t", agent_spec: {"name" => "t", "instructions" => "t"})
    task.retry_count = RETRY_COUNT
    DRAWS.times { orchestrator.apply_retry_backoff(task: task) }

    low, high = expected_bounds(strategy, jitter, RETRY_COUNT)
    epsilon = 1e-9
    in_bounds = observed.all? { |d| d.between?(low - epsilon, high + epsilon) }
    spans = jitter == false || (observed.max - observed.min) > (high - low) * 0.8

    verdict = if !in_bounds
      failures << [strategy, jitter, :bounds]
      "OUT OF BOUNDS (#{observed.min.round(3)}..#{observed.max.round(3)})"
    elsif !spans
      failures << [strategy, jitter, :coverage]
      "poor coverage"
    else
      "conforms"
    end

    puts format("  %-13s %-8s [%6.3f, %6.3f]      [%6.3f, %6.3f]      %s",
      strategy, jitter.inspect, low, high, observed.min, observed.max, verdict)
  end
end

puts
if failures.empty?
  puts "  every combination stayed inside its documented envelope AND"
  puts "  explored at least 80% of it. the timing contract holds."
else
  puts "  CONTRACT VIOLATIONS: #{failures.inspect}"
  exit 1
end
