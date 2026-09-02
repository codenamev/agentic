# frozen_string_literal: true

# The Onboarding Trail: a codebase is a place people live, and new
# teammates don't need a map of every pipe - they need a TOUR: which
# room to enter first, and why each room makes sense given the ones
# you've seen. This computes the tour from the code itself: scan who
# mentions whom, then order the rooms so no stop assumes a concept
# you haven't met yet.
#
#   bundle exec ruby examples/onboarding_trail.rb
#
# Runs offline; the trail is derived, not curated (mostly).

require_relative "../lib/agentic"

LIB = File.expand_path("../lib/agentic", __dir__)

# What each room is FOR - the one sentence a tour guide adds that a
# dependency graph can't
ROOM_NOTES = {
  "task_failure" => "how this house talks about things going wrong (failure as data)",
  "task_result" => "the envelope every outcome arrives in",
  "task" => "the unit of work: lifecycle, payloads, needs",
  "rate_limit" => "the shared front door: ceilings, windows, resize",
  "execution_journal" => "the house's memory: fsynced, replayable, per-shard",
  "relation_rules" => "predicates as data - rules tools can read",
  "capability_specification" => "contracts: declared inputs, outputs, rules",
  "capability_validator" => "the barricade that enforces the contracts",
  "plan_orchestrator" => "the living room where everything meets: scheduling, hooks, the graph"
}.freeze

# Who mentions whom, from the source itself
files = ROOM_NOTES.keys.to_h do |name|
  source = File.read(File.join(LIB, "#{name}.rb"), encoding: "UTF-8")
  constants = source.scan(/\b(?:Agentic::)?([A-Z][A-Za-z]+)\b/).flatten.uniq
  mentioned = ROOM_NOTES.keys.select { |other|
    other != name && constants.include?(other.split("_").map(&:capitalize).join)
  }
  [name, {mentions: mentioned, lines: source.lines.size}]
end

# The trail: repeatedly visit the room with the fewest unmet mentions
trail = []
until trail.size == files.size
  next_room = files.keys.reject { |f| trail.include?(f) }
    .min_by { |f| [(files[f][:mentions] - trail).size, files[f][:lines]] }
  trail << next_room
end

puts "THE ONBOARDING TRAIL (computed from who-mentions-whom)"
puts
puts "  day one, in order - no room assumes one you haven't seen:"
puts
trail.each_with_index do |room, index|
  unmet = files[room][:mentions] - trail[0..index]
  puts format("  %d. %-26s %4d lines   %s", index + 1, room, files[room][:lines], ROOM_NOTES[room])
  puts "     (mentions #{files[room][:mentions].join(", ")})" if files[room][:mentions].any?
  puts "     WARNING: tour visits this before #{unmet.join(", ")}" if unmet.any?
end

puts
puts "  why a trail instead of a map: a map answers \"where is\" and"
puts "  nobody's first question is where - it's \"what should I read"
puts "  FIRST so the rest makes sense?\" the ordering came from the"
puts "  code (fewest unmet concepts next), and the one-line room notes"
puts "  came from a human, which is the correct split: structure is"
puts "  derivable, PURPOSE isn't. notice the trail starts with failure -"
puts "  this house talks about failure before it talks about work, and"
puts "  a new teammate who learns that on day one has learned the"
puts "  house's values, not just its layout. codebases are places"
puts "  people live; give the new roommate a tour, not a blueprint."
