# frozen_string_literal: true

# The Circuit Breaker: when an upstream is down, the cheapest request
# is the one you don't send. The breaker trips after 3 consecutive
# retryable failures (or ONE non-retryable - no auth error deserves a
# second strike), fast-fails while open, and probes with a single
# request before closing again. Every skipped call is money.
#
#   bundle exec ruby examples/circuit_breaker.rb
#
# Runs offline; act one is a 503 outage, act two a revoked key.

require_relative "../lib/agentic"
require "tmpdir"

Agentic.logger.level = :fatal

# A breaker is a tiny state machine: closed -> open -> half_open -> closed
class Breaker
  TRIP_AFTER = 3
  COOLDOWN_TICKS = 4

  attr_reader :state, :skipped

  def initialize
    @state = :closed
    @strikes = 0
    @cooldown = 0
    @skipped = 0
  end

  def allow?
    case @state
    when :closed then true
    when :open
      @cooldown -= 1
      if @cooldown <= 0
        @state = :half_open
        true # the probe
      else
        @skipped += 1
        false
      end
    when :half_open then true
    end
  end

  def record_success
    @state = :closed
    @strikes = 0
  end

  # The framework's nil convention (TaskFailure#hopeless?): only an
  # EXPLICIT false verdict trips instantly. An error that expressed no
  # opinion gets a strike - suspicion, not a death sentence.
  def record_failure(verdict)
    hopeless = verdict == false
    @strikes += hopeless ? TRIP_AFTER : 1
    return unless @strikes >= TRIP_AFTER || @state == :half_open

    @state = :open
    @strikes = 0
    @cooldown = COOLDOWN_TICKS
  end
end

def run_scenario(name, ticks, journal_path, &upstream)
  File.delete(journal_path) if File.exist?(journal_path)
  journal = Agentic::ExecutionJournal.new(path: journal_path)
  breaker = Breaker.new

  puts "  #{name}"
  puts "    tick   breaker     what happened"

  ticks.times do |tick|
    unless breaker.allow?
      puts format("    %-6d %-11s call SKIPPED - not sent, not billed, not waited on", tick, breaker.state)
      next
    end

    probe = breaker.state == :half_open
    orchestrator = Agentic::PlanOrchestrator.new(
      lifecycle_hooks: journal.lifecycle_hooks,
      retry_policy: {max_retries: 0, retryable_errors: []}
    )
    orchestrator.add_task(Agentic::Task.new(
      description: "call:#{tick}", agent_spec: {"name" => "caller", "instructions" => "call"}
    ), agent: ->(_t) { upstream.call(tick) })
    result = orchestrator.execute_plan

    if result.successful?
      breaker.record_success
      puts format("    %-6d %-11s %s", tick, breaker.state, probe ? "probe SUCCEEDED - breaker closes" : "ok")
    else
      # The journal's write-time verdict feeds the breaker - the error
      # already testified whether retrying could ever help
      verdict = Agentic::ExecutionJournal.replay(path: journal_path).events
        .reverse.find { |e| e[:event] == "task_failed" }[:retryable]
      breaker.record_failure(verdict)
      puts format("    %-6d %-11s failed (retryable: %s)%s", tick, breaker.state, verdict,
        (breaker.state == :open) ? " - breaker TRIPS" : "")
    end
  end
  puts
  [Agentic::ExecutionJournal.replay(path: journal_path), breaker]
end

puts "CIRCUIT BREAKER (trip after #{Breaker::TRIP_AFTER} strikes, cooldown #{Breaker::COOLDOWN_TICKS} ticks)"
puts

# Act one: a transient outage - three strikes, trip, skip, probe, recover
OUTAGE = (4..9)
state, breaker = run_scenario("act one: 503s from tick 4 to 9", 16,
  File.join(Dir.tmpdir, "agentic_breaker_1.jsonl")) do |tick|
  raise Agentic::Errors::LlmServerError, "503 (tick #{tick})" if OUTAGE.cover?(tick)

  "ok"
end

# Act two: a revoked key - ONE strike, because the error testified
# that no retry can ever help
state2, breaker2 = run_scenario("act two: key revoked at tick 2", 8,
  File.join(Dir.tmpdir, "agentic_breaker_2.jsonl")) do |tick|
  raise Agentic::Errors::LlmAuthenticationError, "401 key revoked" if tick >= 2

  "ok"
end

felt = state.events.count { |e| e[:event] == "task_failed" }
puts "  act one's outage lasted #{OUTAGE.size} ticks but only #{felt} calls felt it: the"
puts "  breaker ate the middle as #{breaker.skipped} skips (nothing sent, nothing billed,"
puts "  no timeout waited out) and spent one probe discovering the recovery."
puts "  act two never reached three strikes - the 401's journaled verdict"
puts "  (retryable: false) tripped the breaker on FIRST contact, and the"
puts "  probe kept finding the same wall (#{state2.events.count { |e| e[:event] == "task_failed" }} real calls, #{breaker2.skipped} skipped)."
puts "  strike counts are for errors that might pass; testimony that the"
puts "  error can never pass deserves an instant trip."
