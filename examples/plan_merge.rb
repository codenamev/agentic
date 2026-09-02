# frozen_string_literal: true

# The Plan Merge: base, ours, theirs - a three-way merge of plan wire
# formats. Independent changes combine; the same edge rewired two
# different ways is a CONFLICT, reported in topology vocabulary, not
# JSON-line vocabulary. Round 7 gave plans diff; this gives them merge.
#
#   bundle exec ruby examples/plan_merge.rb
#
# Runs offline; two teammates edit the same pipeline.

require_relative "../lib/agentic"

# The wire format from plan_roundtrip: tasks + labeled edges
BASE = {
  "tasks" => ["fetch", "parse", "rank", "publish"],
  "edges" => [
    {"from" => "fetch", "to" => "parse", "label" => nil},
    {"from" => "parse", "to" => "rank", "label" => "entries"},
    {"from" => "rank", "to" => "publish", "label" => nil}
  ]
}.freeze

# Ours: adds dedupe between parse and rank
OURS = {
  "tasks" => ["fetch", "parse", "dedupe", "rank", "publish"],
  "edges" => [
    {"from" => "fetch", "to" => "parse", "label" => nil},
    {"from" => "parse", "to" => "dedupe", "label" => "entries"},
    {"from" => "dedupe", "to" => "rank", "label" => "candidates"},
    {"from" => "rank", "to" => "publish", "label" => nil}
  ]
}.freeze

# Theirs: adds moderation between parse and rank (same seam!)
# and independently adds an audit leaf off publish
THEIRS = {
  "tasks" => ["fetch", "parse", "moderate", "rank", "publish", "audit"],
  "edges" => [
    {"from" => "fetch", "to" => "parse", "label" => nil},
    {"from" => "parse", "to" => "moderate", "label" => "entries"},
    {"from" => "moderate", "to" => "rank", "label" => "safe_entries"},
    {"from" => "rank", "to" => "publish", "label" => nil},
    {"from" => "publish", "to" => "audit", "label" => nil}
  ]
}.freeze

def edge_map(wire)
  wire["edges"].to_h { |e| [[e["from"], e["to"]], e["label"]] }
end

def merge(base, ours, theirs)
  base_edges = edge_map(base)
  our_edges = edge_map(ours)
  their_edges = edge_map(theirs)

  conflicts = []
  merged_tasks = (base["tasks"] | ours["tasks"] | theirs["tasks"])

  # An edge's fate in each branch: kept, removed, or added
  all_keys = (base_edges.keys | our_edges.keys | their_edges.keys)
  merged_edges = all_keys.filter_map do |key|
    in_base = base_edges.key?(key)
    in_ours = our_edges.key?(key)
    in_theirs = their_edges.key?(key)

    if in_base && !in_ours && !in_theirs
      # Both branches removed this edge - but did they replace it the
      # same way? If both rewired the same seam differently, conflict.
      our_replacement = our_edges.keys.find { |k| k[0] == key[0] && !base_edges.key?(k) }
      their_replacement = their_edges.keys.find { |k| k[0] == key[0] && !base_edges.key?(k) }
      if our_replacement && their_replacement && our_replacement != their_replacement
        conflicts << {seam: key, ours: our_replacement, theirs: their_replacement}
      end
      nil
    elsif in_base && in_ours && in_theirs
      [key, base_edges[key]] # unchanged everywhere
    elsif !in_base
      [key, our_edges[key] || their_edges[key]] # added by one branch
    else
      [key, (in_ours ? our_edges[key] : their_edges[key])] # kept by one, removed by other -> keep? no: removed wins
    end
  end

  [{"tasks" => merged_tasks, "edges" => merged_edges.map { |(from, to), label|
    {"from" => from, "to" => to, "label" => label}
  }}, conflicts]
end

merged, conflicts = merge(BASE, OURS, THEIRS)

puts "PLAN MERGE (base + ours + theirs)"
puts
puts "  cleanly merged:"
puts "    tasks: #{merged["tasks"].join(", ")}"
(merged["edges"] - BASE["edges"]).each do |e|
  puts "    + #{e["from"]} -> #{e["to"]}#{" (#{e["label"]})" if e["label"]}"
end
puts
if conflicts.any?
  puts "  CONFLICTS (both branches rewired the same seam):"
  conflicts.each do |c|
    puts "    seam #{c[:seam][0]} -> #{c[:seam][1]}:"
    puts "      ours:   #{c[:seam][0]} -> #{c[:ours][1]} -> ..."
    puts "      theirs: #{c[:seam][0]} -> #{c[:theirs][1]} -> ..."
  end
  puts
  puts "  resolution is a DESIGN decision - should dedupe run before"
  puts "  moderation, after it, or fused? no textual merge can answer"
  puts "  that, which is why the conflict is reported in topology terms:"
  puts "  the humans must decide the order of the new stages."
end
