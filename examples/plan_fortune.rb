# frozen_string_literal: true

# The Plan Fortune Teller: reads your graph's palm - depth, fan-in,
# roots, breadth - and tells its fortune. Every fortune is a real
# structural fact wearing a mystic's robe; the entertainment is a
# delivery mechanism for the diagnosis.
#
#   bundle exec ruby examples/plan_fortune.rb
#
# Runs offline. The stars are graph[:stats].

require_relative "../lib/agentic"

def step(name)
  Agentic::Task.new(description: name, agent_spec: {"name" => name, "instructions" => "toil"})
end

# A seeker arrives with their plan
orchestrator = Agentic::PlanOrchestrator.new
gather = 4.times.map { |i| step("gather-#{i}") }
sift = step("sift")
weigh = step("weigh")
judge = step("judge")
scribe = step("scribe")

gather.each { |t| orchestrator.add_task(t) }
orchestrator.add_task(sift, gather)
orchestrator.add_task(weigh, [sift])
orchestrator.add_task(judge, [weigh])
orchestrator.add_task(scribe, [judge])

# --- the reading --------------------------------------------------------------
graph = orchestrator.graph
stats = graph[:stats]
roots = graph[:dependencies].count { |_, deps| deps.empty? }
leaves = graph[:dependencies].keys.count { |id| graph[:edges].none? { |e| e[:from] == id } }
tasks = graph[:tasks].size

fortunes = []

fortunes << if roots >= 4
  "You begin in many places at once, child of parallelism - " \
  "your mornings are wide (#{roots} roots)."
else
  "You begin cautiously (#{roots} root#{"s" unless roots == 1}) - " \
  "the fates smile on those who fan out."
end

fortunes << if stats[:max_fan_in] >= 4
  "Beware: all rivers flow through one gate (fan-in #{stats[:max_fan_in]}). " \
  "When that gate falters, all waters still."
else
  "Your joinings are modest (fan-in #{stats[:max_fan_in]}) - no single " \
  "gate holds your fate."
end

fortunes << if stats[:max_depth] > tasks / 2
  "I see a long road, #{stats[:max_depth]} stations deep, in a caravan of " \
  "only #{tasks}. More than half your journey walks single file - " \
  "latency stalks you, and the critical path knows your name."
else
  "Your road is short for your numbers (depth #{stats[:max_depth]} of " \
  "#{tasks}) - swiftness favors you."
end

fortunes << if leaves == 1
  "All ends in a single scroll (1 leaf). Tidy. The ancestors approve of " \
  "plans that know what they produce."
else
  "Your plan ends in #{leaves} places - be sure someone reads them all."
end

puts "THE PLAN FORTUNE TELLER"
puts
puts "  the seeker presents a plan of #{tasks} tasks..."
puts "  the teller studies graph[:stats] (the palm never lies):"
puts
fortunes.each { |fortune| puts "  * #{fortune}" }
puts
puts "  cross my palm with a refactor and return: the fortune about the"
puts "  long road is a real diagnosis - see refactor_receipts.rb for"
puts "  the cure, and three_shapes.rb to choose your next incarnation."
