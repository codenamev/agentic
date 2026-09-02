# frozen_string_literal: true

# The API Surface Census: your public API is not what you documented -
# it's every public method a user CAN call, because that's what semver
# binds you to. This census counts the whole surface, then
# cross-references 100 example programs to split it into the API
# people actually use and the accidental API nobody asked for but
# everyone can break themselves against.
#
#   bundle exec ruby examples/api_surface.rb
#
# Runs offline; the examples directory is the usage corpus.

require_relative "../lib/agentic"

Agentic.logger.level = :fatal

# Load everything so the census sees the whole surface
Zeitwerk::Registry.loaders.each(&:eager_load) if defined?(Zeitwerk::Registry)

CORE = [
  Agentic::PlanOrchestrator, Agentic::Task, Agentic::ExecutionJournal,
  Agentic::RateLimit, Agentic::CapabilitySpecification, Agentic::CapabilityValidator,
  Agentic::CapabilityProvider, Agentic::TaskFailure, Agentic::TaskResult,
  Agentic::PlanExecutionResult, Agentic::RelationRules
].freeze

corpus = Dir[File.join(__dir__, "*.rb")].reject { |f| f.end_with?("api_surface.rb") }
  .map { |f| File.read(f, encoding: "UTF-8") }.join("\n")

puts "API SURFACE CENSUS (#{CORE.size} core classes vs #{Dir[File.join(__dir__, "*.rb")].size - 1} example programs)"
puts
puts "  class                      surface   exercised   accidental (public, unused by any example)"

total_surface = 0
total_exercised = 0
accidental_all = []
CORE.each do |klass|
  # Owner-checked: only methods this class itself defines count as ITS
  # surface - inherited Object/Psych noise is someone else's ledger
  methods = (klass.public_instance_methods(false) +
    klass.singleton_class.public_instance_methods(false).select { |m|
      klass.singleton_class.instance_method(m).owner == klass.singleton_class
    }).uniq.reject { |m| m.to_s.start_with?("_") }
  used, unused = methods.partition { |m| corpus.match?(/\.#{Regexp.escape(m.to_s.chomp("?").chomp("!"))}\b/) || corpus.include?(".#{m}") }
  total_surface += methods.size
  total_exercised += used.size
  accidental_all.concat(unused.map { |m| "#{klass.name.split("::").last}##{m}" })
  puts format("  %-26s %-9d %-11d %s",
    klass.name.split("::").last, methods.size, used.size, unused.take(3).join(", "))
end

puts
puts format("  total public surface: %d methods; %d (%.0f%%) exercised by the corpus.",
  total_surface, total_exercised, total_exercised * 100.0 / total_surface)
puts
puts "  reading the census like a steward: the exercised set is your REAL"
puts "  API - 100 programs voted with their call sites, and every one of"
puts "  those methods now carries a semver promise whether the docs say"
puts "  so or not. the accidental set (#{accidental_all.size} methods) is surface you're"
puts "  paying interest on without collecting rent: each is a thing a"
puts "  user could couple to tomorrow, constraining refactors forever."
puts "  the move isn't deletion - it's DECLARATION: mark them @api"
puts "  private (or make them private) while nobody depends on them,"
puts "  because the day after somebody does, they're yours for a major"
puts "  version. public-by-default is a loan; the census is the bill."
