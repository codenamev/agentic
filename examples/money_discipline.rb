# frozen_string_literal: true

# Money Discipline: every money bug in production is the same three
# bugs - floats for currency, arithmetic before validation, and
# rounding decided at the last minute by whoever's line of code got
# there first. This runs an invoicing plan twice: once the way demos
# do it (floats), once the way ledgers demand (integer cents, a Money
# value object, rounding policy declared at the boundary) - and lets
# a penny audit judge them both.
#
#   bundle exec ruby examples/money_discipline.rb
#
# Runs offline; the discrepancy is real IEEE 754, not contrivance.

require_relative "../lib/agentic"

Agentic.logger.level = :fatal

LINE_ITEMS = [
  {desc: "api calls", unit_price: 0.1, qty: 3},
  {desc: "storage", unit_price: 29.99, qty: 3},
  {desc: "seats", unit_price: 19.99, qty: 7}
].freeze
TAX_RATE = 0.0825

# --- the demo version: floats all the way down ----------------------------------
def float_invoice(items)
  subtotal = items.sum { |i| i[:unit_price] * i[:qty] }
  tax = subtotal * TAX_RATE
  {subtotal: subtotal, tax: tax, total: subtotal + tax}
end

# --- the ledger version: integer cents + one rounding policy --------------------
# Money is a value object: cents inside, arithmetic closed, rounding
# NAMED (banker's here) and applied exactly where policy says
Money = Struct.new(:cents) do
  def +(other) = Money.new(cents + other.cents)

  def *(other) = Money.new((cents * other).round(half: :even))

  def to_s = format("$%d.%02d", cents / 100, cents % 100)
end

def cents(dollars) = Money.new((dollars * 100).round)

CONTRACT = Agentic::CapabilitySpecification.new(
  name: "invoice", description: "Price an invoice", version: "1.0.0",
  inputs: {items: {type: "array", required: true, non_empty: true}},
  outputs: {
    subtotal_cents: {type: "integer", required: true, min: 0},
    tax_cents: {type: "integer", required: true, min: 0},
    total_cents: {type: "integer", required: true, min: 0}
  },
  rules: {
    adds_up: {message: "total must equal subtotal + tax, to the penny",
              fields: [:subtotal_cents, :tax_cents, :total_cents],
              check: ->(o) { o[:total_cents] == o[:subtotal_cents] + o[:tax_cents] }}
  }
)

def ledger_invoice(items)
  subtotal = items.map { |i| cents(i[:unit_price]) * i[:qty] }.sum(Money.new(0))
  tax = subtotal * TAX_RATE
  {subtotal_cents: subtotal.cents, tax_cents: tax.cents, total_cents: (subtotal + tax).cents}
end

# Run both as plan tasks; validate only the ledger (floats can't even
# SIGN the contract - integer cents is a type, and types are promises)
orchestrator = Agentic::PlanOrchestrator.new
float_task = Agentic::Task.new(description: "float invoice", agent_spec: {"name" => "f", "instructions" => "w"}, payload: LINE_ITEMS)
ledger_task = Agentic::Task.new(description: "ledger invoice", agent_spec: {"name" => "l", "instructions" => "w"}, payload: LINE_ITEMS)
orchestrator.add_task(float_task, agent: ->(t) { float_invoice(t.payload) })
orchestrator.add_task(ledger_task, agent: ->(t) { ledger_invoice(t.payload) })
result = orchestrator.execute_plan

floats = result.task_result(float_task.id).output
ledger = result.task_result(ledger_task.id).output

puts "MONEY DISCIPLINE (same invoice, two arithmetics)"
puts
puts "               float version                ledger version"
puts format("  %-12s %-28.14f %s", "subtotal", floats[:subtotal], Money.new(ledger[:subtotal_cents]))
puts format("  %-12s %-28.14f %s", "tax", floats[:tax], Money.new(ledger[:tax_cents]))
puts format("  %-12s %-28.14f %s", "total", floats[:total], Money.new(ledger[:total_cents]))
puts

Agentic::CapabilityValidator.new(CONTRACT).validate_outputs!(ledger)
puts "  the ledger version signed its contract: integer cents, all"
puts "  non-negative, and the adds_up rule verified to the penny."
puts
float_cents = (floats[:total] * 100).round
puts "  now read the float column like an accountant: the subtotal ends"
puts format("  in ...%s, because 0.1 x 3 is not 0.3 in binary - IEEE 754", format("%.14f", floats[:subtotal])[-6..])
puts "  is already paying out interest. today it rounds to the"
puts "  right penny (#{float_cents}); at some other quantity or rate it won't,"
puts "  and the discrepancy will surface in a reconciliation report"
puts "  eleven months from now, assigned to whoever touched the code"
puts "  last. the discipline is three sentences: money is integer"
puts "  cents (a TYPE the contract can enforce - \"integer\" isn't"
puts "  pedantry, it's a tripwire); rounding is a NAMED policy applied"
puts "  at declared points (banker's, at multiplication), not an"
puts "  accident of printf; and the books must balance BY RULE"
puts "  (adds_up), not by hope. take my money - but count it in cents."
