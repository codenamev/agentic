# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  add_filter "/vendor/"
  # Current full-suite coverage is ~74.7%; keep the gate at the floor so it
  # blocks regressions, and ratchet it upward as coverage improves
  minimum_coverage 74

  add_group "Core", "lib/agentic/*.rb"
  add_group "CLI", "lib/agentic/cli/"
  add_group "Verification", "lib/agentic/verification/"
  add_group "Observability", "lib/agentic/observability/"
  add_group "Learning", "lib/agentic/learning/"
  add_group "Extensions", "lib/agentic/extension/"
  add_group "UI", "lib/agentic/ui/"
  add_group "Errors", "lib/agentic/errors/"
end

require "agentic"

require "vcr"

# Give the test environment a credential so fail-fast configuration
# validation passes without a real key; VCR intercepts all HTTP anyway
Agentic.configure do |config|
  config.access_token ||= "test-token"
end

# Load test factories
Dir[File.join(__dir__, "factories", "*.rb")].each { |f| require f }

VCR.configure do |config|
  config.cassette_library_dir = "spec/vcr_cassettes"
  config.hook_into :webmock
  config.filter_sensitive_data("<OPENAI_ACCESS_TOKEN>") { Agentic.configuration.access_token }
  # Fail loudly when a spec makes an unrecorded HTTP request instead of
  # silently hitting the real network (slow, flaky, and spends API credits)
  config.allow_http_connections_when_no_cassette = false
end

RSpec.configure do |config|
  # Include test factories
  config.include VerificationFactories
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Filter out slow integration tests by default
  config.filter_run_excluding :slow unless ENV["RUN_SLOW_TESTS"]

  # A stray Kernel#exit (e.g. Thor aborting on a missing required option)
  # would otherwise abort the entire run mid-suite while still printing a
  # normal-looking summary; surface it as a regular example failure instead
  config.around(:each) do |example|
    example.run
  rescue SystemExit => e
    raise "Spec attempted to exit the process (status #{e.status})"
  end

  # VCR configuration
  config.around(:each, :vcr) do |example|
    name = example.metadata[:cassette_name] || example.full_description.downcase.gsub(/\W+/, "_")
    VCR.use_cassette(name) { example.call }
  end

  # Focus on specific tests
  config.filter_run_when_matching :focus
  config.run_all_when_everything_filtered = true

  # Show slowest examples
  config.profile_examples = 10
end
