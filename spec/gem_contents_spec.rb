# frozen_string_literal: true

require "rubygems"

# Pack-contents check: the gem must only ship runtime files. The published
# 0.2.0 carried .claude/settings.local.json and session transcripts because
# the gemspec used a denylist over `git ls-files`. This pins the allowlist so
# that regression fails CI instead of landing on rubygems.
RSpec.describe "agentic.gemspec contents" do
  let(:allowed_prefixes) { %w[lib/ exe/ sig/] }
  let(:allowed_files) { %w[LICENSE.txt README.md CHANGELOG.md] }

  let(:gemspec) { Gem::Specification.load(File.expand_path("../agentic.gemspec", __dir__)) }

  it "ships only runtime files" do
    stray = gemspec.files.reject do |f|
      allowed_prefixes.any? { |prefix| f.start_with?(prefix) } || allowed_files.include?(f)
    end
    expect(stray).to be_empty, "gem would ship non-runtime files:\n  #{stray.join("\n  ")}"
  end

  it "ships the library and the executable" do
    expect(gemspec.files).to include("lib/agentic.rb", "lib/agentic/version.rb")
    expect(gemspec.executables).to include("agentic")
  end

  it "never ships session transcripts, local settings or planning docs" do
    expect(gemspec.files.grep(%r{\A(\.claude|\.claude-sessions|\.architecture|docs|examples|reports|plugins|benchmark)/})).to be_empty
    expect(gemspec.files.grep(/\.local\.json\z|\.jsonl\z/)).to be_empty
    expect(gemspec.files.grep(/\.md\z/).reject { |f| f.start_with?("lib/") } - allowed_files).to be_empty
  end
end
