# frozen_string_literal: true

# Rule Shapes: the same policy - "express shipments need a customs
# code" - written three ways: a lambda, a structured check, and a
# relation. Then four consumers try to use each shape: the validator,
# the message deriver, the fixture generator, and the schema export.
# Representation isn't style; it's a decision about who else gets to
# understand you.
#
#   bundle exec ruby examples/rule_shapes.rb
#
# Runs offline; the table is the argument.

require_relative "../lib/agentic"

INPUTS = {
  express: {type: "boolean"},
  customs_code: {type: "string"}
}.freeze

SHAPES = {
  "lambda" => {
    "express needs customs" => ->(i) { !i[:express] || !i[:customs_code].nil? }
  },
  "structured check" => {
    customs: {message: "express shipments need a customs code",
              fields: [:express, :customs_code],
              check: ->(i) { !i[:express] || !i[:customs_code].nil? }}
  },
  "relation" => {
    customs: {relation: :requires, fields: [:express, :customs_code]}
  }
}.freeze

def spec_with(rules)
  Agentic::CapabilitySpecification.new(
    name: "ship", description: "Ship it", version: "1.0.0", inputs: INPUTS, rules: rules
  )
end

# Consumer 1: can the validator enforce it?
def enforces?(spec)
  Agentic::CapabilityValidator.new(spec).validate_inputs!(express: true)
  false
rescue Agentic::Errors::ValidationError
  true
end

# Consumer 2: does a violation point at its fields, with a real message?
def explains?(spec)
  Agentic::CapabilityValidator.new(spec).validate_inputs!(express: true)
  false
rescue Agentic::Errors::ValidationError => e
  violation = e.rule_violations.first
  violation[:fields].any? && !violation[:message].match?(/\A(rule_)?\d*\z/)
end

# Consumer 3: can a generator SATISFY it without running it blind?
# (Only a declared predicate can be satisfied constructively)
def generatable?(rules)
  rules.values.all? { |d| !d.respond_to?(:call) && d[:relation] }
end

# Consumer 4: does it reach the JSON Schema export as a real keyword?
def projects?(spec)
  schema = spec.to_json_schema
  !(schema["dependencies"] || schema["allOf"]).nil?
end

puts "RULE SHAPES: one policy, three representations, four consumers"
puts
puts "  shape                  enforced   explains   generatable  projects"
SHAPES.each do |name, rules|
  spec = spec_with(rules)
  puts format("  %-22s %-10s %-10s %-12s %s",
    name,
    enforces?(spec) ? "yes" : "NO",
    explains?(spec) ? "yes" : "no",
    generatable?(rules) ? "yes" : "no",
    projects?(spec) ? "yes" : "no")
end

puts
puts "  all three shapes enforce - if enforcement were the whole job,"
puts "  they'd be interchangeable and you'd pick by taste. but the"
puts "  lambda answers ONE message (call) so it has ONE consumer; the"
puts "  structured check adds fields: and message:, so violations can"
puts "  explain themselves; and the relation makes the predicate itself"
puts "  data, so tools that never RUN it - the generator, the schema"
puts "  export, round 10's diff - can still read it. choose the"
puts "  representation by counting who must understand it: code keeps"
puts "  secrets, data makes friends. save lambdas for policies that"
puts "  are genuinely secrets."
