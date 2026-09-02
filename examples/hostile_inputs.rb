# frozen_string_literal: true

# Hostile Inputs: a parser's real spec is what it does with input
# nobody intended. The journal's replay parses a file that - by the
# journal's own reason for existing - may end mid-write. In round 12
# this probe caught the torn tail denying ALL recovery; the round-13
# release made replay tolerant-by-default (salvage whole lines,
# REPORT damage) with a strict mode for auditors. This probe is now
# the acceptance test that keeps it that way.
#
#   bundle exec ruby examples/hostile_inputs.rb
#
# Runs offline; exits 1 if any hostile file draws blood again.

require_relative "../lib/agentic"
require "tmpdir"
require "json"

GOOD = %({"event":"task_succeeded","task_id":"t1","description":"t1","duration":0.1,"output":"ok"})

def replay_verdict(lines)
  path = File.join(Dir.tmpdir, "agentic_hostile.jsonl")
  File.write(path, lines.join("\n"))
  state = Agentic::ExecutionJournal.replay(path: path)
  [:recovered, state.completed_task_ids.size, state.damage]
rescue => e
  [:crashed, e.class.to_s, []]
end

PROBES = {
  "clean file (control)" => [GOOD, GOOD.sub("t1", "t2")],
  "torn tail (crash mid-write)" => [GOOD, %({"event":"task_succ)],
  "binary garbage line" => [GOOD, "\x00\x01\xFFnot json at all"],
  "empty + whitespace lines" => [GOOD, "", "   ", GOOD.sub("t1", "t2")],
  "8MB single line" => [GOOD, %({"event":"task_succeeded","task_id":"big","description":"big","duration":0.1,"output":"#{"x" * 8_000_000}"})],
  "valid JSON, wrong shape" => [GOOD, %({"event":"task_succeeded","task_id":42,"duration":"fast"})],
  "unknown event type" => [GOOD, %({"event":"solar_flare","task_id":"t9"})],
  "duplicate success lines" => [GOOD, GOOD]
}.freeze

puts "HOSTILE INPUTS (#{PROBES.size} probes against ExecutionJournal.replay)"
puts
blood = []
PROBES.each do |name, lines|
  verdict, detail, damage = replay_verdict(lines)
  ok = verdict == :recovered
  blood << name unless ok
  report = damage.map { |d| "line #{d[:line]}: #{d[:reason]}" }.join(", ")
  puts format("  %-30s %s", name,
    if ok
      "recovered (#{detail} salvaged#{"; damage reported: #{report}" if damage.any?})"
    else
      "CRASHED: #{detail}"
    end)
end

# The auditor's door: strict mode must still refuse damage, loudly
puts
strict_path = File.join(Dir.tmpdir, "agentic_hostile_strict.jsonl")
File.write(strict_path, [GOOD, %({"event":"task_succ)].join("\n"))
begin
  Agentic::ExecutionJournal.replay(path: strict_path, mode: :strict)
  blood << "strict mode accepted damage"
  puts "  strict mode: ACCEPTED a torn line - auditors are flying blind"
rescue Agentic::Errors::JournalDamagedError => e
  puts "  strict mode: refused, in uniform - #{e.class.name.split("::").last}: #{e.message}"
end

puts
if blood.empty?
  puts "  every hostile file was survived, every whole line salvaged, and"
  puts "  every wound REPORTED - state.damage names the line and the"
  puts "  reason, so recovery tools can say \"resumed 47 tasks; 1 torn"
  puts "  line at the tail\" instead of either crashing or lying. and the"
  puts "  same file offers two doors: tolerant for recovery (salvage"
  puts "  maximally, report honestly), strict for audits (refuse damage,"
  puts "  in the journal's own error class, with the line number). one"
  puts "  format, two reader postures, both legitimate - that was the"
  puts "  round-12 ask, verbatim, and this probe keeps it delivered."
else
  puts "  BLOOD: #{blood.join("; ")} - the tail is no longer tolerated."
end
exit(blood.empty? ? 0 : 1)
