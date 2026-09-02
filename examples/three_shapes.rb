# frozen_string_literal: true

# Three Shapes: the same six units of work arranged three ways - a
# chain, a star, and staged joins - then measured and critiqued. Design
# is choosing a shape ON PURPOSE, and purpose needs numbers.
#
#   bundle exec ruby examples/three_shapes.rb
#
# Runs offline; each unit of work is 40ms of simulated IO.

require_relative "../lib/agentic"

UNIT = 0.04
NAMES = %w[gather_a gather_b gather_c gather_d combine finish].freeze

def build(shape)
  orchestrator = Agentic::PlanOrchestrator.new(concurrency_limit: 4)
  tasks = NAMES.to_h do |name|
    [name, Agentic::Task.new(description: name, agent_spec: {"name" => name, "instructions" => "work"})]
  end

  deps = case shape
  when :chain # one long line: simple to read, nothing overlaps
    NAMES.each_cons(2).to_h { |a, b| [b, [a]] }
  when :star # everything at once, one god join
    {"combine" => %w[gather_a gather_b gather_c gather_d], "finish" => ["combine"]}
  when :staged # balanced: pairs join, then join the joins
    {"gather_c" => [], "gather_d" => [],
     "combine" => %w[gather_a gather_b],
     "finish" => %w[combine gather_c gather_d]}
  end

  NAMES.each do |name|
    orchestrator.add_task(tasks[name], (deps[name] || []).map { |d| tasks.fetch(d) },
      agent: ->(_t) { sleep(UNIT) || :ok })
  end
  orchestrator
end

# Structural facts, read straight off the graph
def shape_facts(graph)
  dependencies = graph[:dependencies]
  depth = {}
  measure = ->(id) { depth[id] ||= 1 + (dependencies[id].map { |d| measure.call(d) }.max || 0) }
  {
    max_fan_in: dependencies.values.map(&:size).max,
    depth: dependencies.keys.map { |id| measure.call(id) }.max
  }
end

puts "THREE SHAPES: six tasks x #{(UNIT * 1000).round}ms, concurrency 4"
puts
puts "  shape    wall       depth    max fan-in the trade"

TRADES = {
  chain: "trivially debuggable; pays full serial price",
  star: "fastest; one join owns every failure mode",
  staged: "nearly as fast; each join has one reason to wait"
}.freeze

%i[chain star staged].each do |shape|
  orchestrator = build(shape)
  facts = shape_facts(orchestrator.graph)
  result = orchestrator.execute_plan
  puts format("  %-8s %4dms     %-8d %-9d %s",
    shape, result.execution_time * 1000, facts[:depth], facts[:max_fan_in], TRADES[shape])
end

puts
puts "none of these is wrong. the chain is right when the work is truly"
puts "sequential; the star when the join is trivial; the staged shape when"
puts "the join has judgment in it. what's wrong is not knowing which one"
puts "you built - and now the graph will tell you, in two numbers."
