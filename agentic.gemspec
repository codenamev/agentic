# frozen_string_literal: true

require_relative "lib/agentic/version"

Gem::Specification.new do |spec|
  spec.name = "agentic"
  spec.version = Agentic::VERSION
  spec.authors = ["Valentino Stoll"]
  spec.email = ["v@codenamev.com"]

  spec.summary = "An AI Agent builder and orchestrator"
  spec.description = "Easily build, manage, deploy, and run self-contained purpose-driven AI Agents."
  spec.homepage = "https://github.com/codenamev/agentic"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/codenamev/agentic"
  spec.metadata["changelog_uri"] = "https://github.com/codenamev/agentic/tree/main/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "dry-schema"
  spec.add_dependency "ruby-openai"
  spec.add_dependency "zeitwerk"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
