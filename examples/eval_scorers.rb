# frozen_string_literal: true

# Eval Scorers: the same eval set scored four ways - exact match,
# keyword containment, numeric tolerance, and a judge rubric. Exact
# scoring drowns one real failure in wording noise; the right scorer
# per field reports exactly the failure that matters. The harness
# shape never changes - only the scorer column does.
#
#   bundle exec ruby examples/eval_scorers.rb
#
# Runs offline; exits 1 because one capability blind spot is real.

require_relative "../lib/agentic"

SEVERITY = {
  "damaged item" => 0.9,
  "refund requested" => 0.8,
  "account email update" => 0.2
}.freeze

spec = Agentic::CapabilitySpecification.new(
  name: "summarize_ticket", description: "Summarize a support ticket", version: "1.0.0",
  inputs: {text: {type: "string", required: true}},
  outputs: {
    summary: {type: "string", required: true},
    priority: {type: "number", required: true, min: 0, max: 1}
  }
)
Agentic.register_capability(spec, Agentic::CapabilityProvider.new(capability: spec, implementation: ->(i) {
  text = i[:text].downcase
  fragments = []
  fragments << "damaged item" if text.match?(/broken|damaged/)
  fragments << "refund requested" if text.match?(/refund|money back/)
  fragments << "account email update" if text.match?(/email/)
  # the blind spot: no rule for crashes - those tickets read as general inquiries
  summary = fragments.empty? ? "general inquiry" : "customer reports #{fragments.join(", ")}"
  {summary: summary, priority: fragments.map { |f| SEVERITY[f] }.max || 0.3}
}))

# --- the scorer seam: (expected, actual) -> score in 0.0..1.0 ------------------
SCORERS = {
  exact: ->(expected, actual) { (expected == actual) ? 1.0 : 0.0 },
  contains: ->(keywords, actual) { keywords.count { |k| actual.to_s.downcase.include?(k) }.fdiv(keywords.size) },
  tolerance: ->(spec, actual) { ((spec[:value] - actual).abs <= spec[:within]) ? 1.0 : 0.0 },
  judge: ->(rubric, actual) { rubric.call(actual) }
}.freeze
PASS_AT = 0.99 # judge scorers may grade partially; everything else is 0-or-1

NAMES_A_PROBLEM = ->(summary) { summary.include?("general inquiry") ? 0.0 : 0.6 }
NAMES_AN_ACTION = ->(summary) { summary.match?(/request|update/) ? 0.4 : 0.0 }
RUBRIC = ->(summary) { NAMES_A_PROBLEM.call(summary) + NAMES_AN_ACTION.call(summary) }

CASES = [
  {ticket: "My package arrived broken and I want my money back",
   checks: [
     {field: :summary, scorer: :exact, expected: "Damaged item; refund requested"},
     {field: :summary, scorer: :contains, expected: %w[damaged refund]},
     {field: :priority, scorer: :tolerance, expected: {value: 0.9, within: 0.15}},
     {field: :summary, scorer: :judge, expected: RUBRIC}
   ]},
  {ticket: "How do I change my email address?",
   checks: [
     {field: :summary, scorer: :exact, expected: "customer reports account email update"},
     {field: :summary, scorer: :contains, expected: %w[email]},
     {field: :priority, scorer: :tolerance, expected: {value: 0.2, within: 0.1}}
   ]},
  {ticket: "The app crashes every time I open settings and I lost work",
   checks: [
     {field: :summary, scorer: :exact, expected: "Crash in settings; data loss"},
     {field: :summary, scorer: :contains, expected: %w[crash settings]},
     {field: :priority, scorer: :tolerance, expected: {value: 0.95, within: 0.1}},
     {field: :summary, scorer: :judge, expected: RUBRIC}
   ]}
].freeze

provider = Agentic::AgentCapabilityRegistry.instance.get_provider("summarize_ticket")
results = CASES.flat_map.with_index(1) do |kase, number|
  output = provider.execute(text: kase[:ticket])
  kase[:checks].map do |check|
    score = SCORERS.fetch(check[:scorer]).call(check[:expected], output[check[:field]])
    {case: number, scorer: check[:scorer], field: check[:field], score: score, pass: score >= PASS_AT}
  end
end

puts "EVAL SCORERS: one eval set, four ways to say \"good enough\""
puts
CASES.each_with_index do |kase, index|
  puts "  case #{index + 1}: #{kase[:ticket].inspect}"
  results.select { |r| r[:case] == index + 1 }.each do |r|
    puts format("    %-10s on %-9s %s  (%.2f)", r[:scorer], r[:field], r[:pass] ? "PASS" : "FAIL", r[:score])
  end
  puts
end

by_scorer = results.group_by { |r| r[:scorer] }
puts "  scoreboard:"
by_scorer.each do |scorer, rows|
  puts format("    %-10s %d/%d pass", scorer, rows.count { |r| r[:pass] }, rows.size)
end

exact_fails = by_scorer[:exact].count { |r| !r[:pass] }
real_fails = results.reject { |r| r[:scorer] == :exact }.reject { |r| r[:pass] }.map { |r| r[:case] }.uniq
puts
puts "  exact flagged #{exact_fails}/3 cases, but most of that is wording noise."
puts "  the field-appropriate scorers flagged only case #{real_fails.join(", ")} - the crash"
puts "  ticket - and that failure is REAL: the capability has no rule for"
puts "  crashes, so a data-loss ticket scores priority 0.3. same harness,"
puts "  same cases; the scorer column is what makes a failure mean something."

exit(real_fails.any? ? 1 : 0)
