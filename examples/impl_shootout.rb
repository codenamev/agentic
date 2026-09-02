# frozen_string_literal: true

# The Implementation Shootout: two candidates for the same capability,
# one eval set, and a verdict computed instead of vibed. v1 is a fast
# regex; v2 is a slower keyword-weight model. The scoreboard reports
# quality AND latency, because "which is better" has two axes and
# every README that hides one is selling something.
#
#   bundle exec ruby examples/impl_shootout.rb
#
# Runs offline; the verdict includes the price of the quality.

require_relative "../lib/agentic"

SPEC = Agentic::CapabilitySpecification.new(
  name: "route_ticket", description: "Route a ticket to a queue", version: "?",
  inputs: {text: {type: "string", required: true}},
  outputs: {queue: {type: "string", required: true, enum: %w[billing bug account general]}}
)

# Candidate 1: the regex that shipped in an afternoon
V1 = lambda do |i|
  queue = case i[:text].downcase
  when /refund|charge|invoice/ then "billing"
  when /crash|error|broken/ then "bug"
  when /password|login|email/ then "account"
  else "general"
  end
  sleep(0.002)
  {queue: queue}
end

# Candidate 2: stem weights, summed as evidence - slower, subtler
WEIGHTS = {
  "billing" => {"refund" => 3, "charge" => 2, "invoice" => 3, "paid" => 2, "money" => 1},
  "bug" => {"crash" => 3, "error" => 2, "broken" => 2, "lost" => 1, "fail" => 2},
  "account" => {"password" => 3, "login" => 3, "email" => 2, "lock" => 2}
}.freeze
V2 = lambda do |i|
  words = i[:text].downcase.scan(/[a-z]+/)
  scores = WEIGHTS.transform_values { |stems|
    stems.sum { |stem, weight| (words.any? { |w| w.start_with?(stem) }) ? weight : 0 }
  }
  best, score = scores.max_by { |_, s| s }
  sleep(0.01)
  {queue: (score > 0) ? best : "general"}
end

EVALS = [
  {text: "I was charged twice, I want a refund", queue: "billing"},
  {text: "App crashes when I open settings", queue: "bug"},
  {text: "Can't login, password reset email never arrives", queue: "account"},
  {text: "I paid but my invoice shows money owed", queue: "billing"},
  {text: "The export fails and I lost my work", queue: "bug"},
  {text: "My account is locked after the update", queue: "account"},
  {text: "How do I change my plan?", queue: "general"},
  # The decider: one bug word, five points of account evidence
  {text: "Password reset email shows an error page", queue: "account"}
].freeze

def run_candidate(impl)
  EVALS.map do |eval_case|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output = impl.call(text: eval_case[:text])
    {
      correct: output[:queue] == eval_case[:queue],
      got: output[:queue],
      latency: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    }
  end
end

results = {"v1 regex" => run_candidate(V1), "v2 weights" => run_candidate(V2)}

puts "IMPLEMENTATION SHOOTOUT: #{SPEC.name} (#{EVALS.size} eval cases)"
puts
puts "  case (expected)                                v1 regex     v2 weights"
EVALS.each_with_index do |eval_case, index|
  marks = results.values.map { |r|
    r[index][:correct] ? "pass" : "FAIL(#{r[index][:got]})"
  }
  puts format("  %-46s %-12s %s", "#{eval_case[:text][0, 36]}... (#{eval_case[:queue]})", *marks)
end

puts
puts "  scoreboard:"
results.each do |name, rows|
  accuracy = rows.count { |r| r[:correct] } / EVALS.size.to_f
  p50 = rows.map { |r| r[:latency] }.sort[rows.size / 2]
  puts format("    %-12s accuracy %3d%%   p50 %.1fms", name, (accuracy * 100).round, p50 * 1000)
end

v1_acc = results["v1 regex"].count { |r| r[:correct] }
v2_acc = results["v2 weights"].count { |r| r[:correct] }
puts
puts "  verdict: v2 wins #{v2_acc}/#{EVALS.size} to #{v1_acc}/#{EVALS.size} - and costs 5x the latency."
puts "  the deciding cases share a shape: 'password reset email shows an"
puts "  error page' has one bug word and five points of account evidence."
puts "  first-match regex answers by clause order - an accident of code"
puts "  layout - while weights answer by total evidence. whether that is"
puts "  worth 8ms per ticket is YOUR call; the shootout's job is to put"
puts "  both axes on one table so the tradeoff is chosen, not discovered."
puts "  and a perfect v2 score means the EVAL SET stopped discriminating,"
puts "  not that v2 is done - add cases until your best candidate fails."
