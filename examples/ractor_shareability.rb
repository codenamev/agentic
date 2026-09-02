# frozen_string_literal: true

# The Ractor Shareability Audit: `freeze` is a promise about one
# object; Ractor.shareable? is a promise about everything it can
# reach. The graph API says "frozen snapshot" - this audit asks the
# stricter question: which framework values could cross a Ractor
# boundary TODAY, which need make_shareable's deep freeze, and which
# can never go because they hold live machinery?
#
#   bundle exec ruby examples/ractor_shareability.rb
#
# Runs offline; verdicts come from Ractor itself, not from reading code.

require_relative "../lib/agentic"

Agentic.logger.level = :fatal
Warning[:experimental] = false # Ractor is experimental; the audit knows

def task_named(name)
  Agentic::Task.new(description: name, agent_spec: {"name" => name, "instructions" => "w"})
end

orchestrator = Agentic::PlanOrchestrator.new
a = task_named("a")
b = task_named("b")
orchestrator.add_task(a)
orchestrator.add_task(b, [a])

spec = Agentic::CapabilitySpecification.new(
  name: "quote", description: "q", version: "1.0.0",
  inputs: {mode: {type: "string", required: true, enum: %w[air sea]}},
  rules: {gate: {relation: :requires, fields: [:mode]}}
)

SUBJECTS = {
  "graph snapshot" => orchestrator.graph,
  "graph[:order]" => orchestrator.graph[:order],
  "graph[:stats]" => orchestrator.graph[:stats],
  "to_json_schema output" => spec.to_json_schema,
  "a Task object" => a,
  "TaskResult.success" => Agentic::TaskResult.new(task_id: "t", success: true, output: "x"),
  "a RateLimit" => Agentic::RateLimit.new(2)
}.freeze

# One verdict per subject, on a COPY wherever possible - an auditor
# that deep-freezes the system under audit is contaminating its own
# evidence (the first draft of this file did exactly that)
def verdict(value)
  frozen = value.frozen?
  return [frozen, true, "(already crosses)"] if Ractor.shareable?(value)

  copy = begin
    Marshal.load(Marshal.dump(value))
  rescue TypeError
    nil # holds procs, mutexes, IO - unmarshalable machinery
  end

  after = if copy
    begin
      Ractor.make_shareable(copy)
      "a deep-frozen copy crosses"
    rescue Ractor::Error, TypeError => e
      "refused: #{e.class.name.split("::").last}"
    end
  else
    begin
      Ractor.make_shareable(value)
      "deep-frozen IN PLACE (mutates the original!)"
    rescue Ractor::Error, TypeError
      "REFUSED: holds live machinery"
    end
  end
  [frozen, false, after]
end

puts "THE RACTOR SHAREABILITY AUDIT (frozen is not the same promise)"
puts
puts "  value                    frozen?  shareable?  after make_shareable"
SUBJECTS.each do |name, value|
  frozen, shareable, after = verdict(value)
  puts format("  %-24s %-8s %-11s %s", name, frozen, shareable, after)
end

# --- the payoff: ship a shareable value to a real Ractor -------------------------
schema = Ractor.make_shareable(spec.to_json_schema)
answer = Ractor.new(schema) { |s| "checked #{s["properties"].size} properties in another Ractor" }.take

puts
puts "  proof of travel: #{answer}"
puts
puts "  the audit's grammar lesson: graph[:order] and graph[:stats] are"
puts "  data all the way down and cross as-is. the full snapshot is"
puts "  'frozen' but REACHES unfrozen Task objects - a top-floor promise"
puts "  on a building with unlocked doors below; a deep-frozen COPY"
puts "  crosses fine, and copies are what you should send anyway. the"
puts "  RateLimit is the honest REFUSAL: it holds a real Mutex, and no"
puts "  amount of freezing turns a lock into a value - it's a machine,"
puts "  not a fact. that's the Ractor pattern in one line: send facts,"
puts "  keep machines. and note the auditor's own first-draft sin,"
puts "  preserved in the comment above: it deep-froze the system under"
puts "  audit and contaminated row after row - Ractor.shareable? is"
puts "  ruby's strictest freeze referee, and referees must not tamper"
puts "  with the evidence."
