# frozen_string_literal: true

require "open3"

# Loader contract check. lib/agentic.rb makes Zeitwerk the single code loader
# and tells files not to require_relative their siblings. Zeitwerk tolerates
# a managed file being required directly, so a stray require never crashes;
# it only hand-maintains a load-order edge the loader already owns, which is
# how the rule came back 57 lines strong with no red build. The first example
# tests the promise behind the rule, the second tests the rule.
RSpec.describe "Zeitwerk loader" do
  let(:lib_dir) { File.expand_path("../lib", __dir__) }

  # A fresh interpreter, so no constant is already loaded by spec_helper and
  # nothing in this process's state can hide a file that only loads because
  # another file was required first. force: true also walks lib/agentic/cli,
  # which the loader excludes from normal eager loading.
  it "eager-loads every constant under lib/agentic/ in a fresh process" do
    script = <<~RUBY
      require "agentic"
      loader = Zeitwerk::Registry.loaders.find { |l| l.tag == "agentic" }
      abort "no Zeitwerk loader tagged agentic (did the gem name change?)" unless loader
      loader.eager_load(force: true)
      print Agentic::CLI.name
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, "-W0", "-I", lib_dir, "-e", script)

    expect(status).to be_success, "eager load failed:\n#{err}"
    expect(out).to eq("Agentic::CLI")
  end

  it "manages every file under lib/agentic/ without require_relative" do
    offenders = Dir[File.join(lib_dir, "agentic", "**", "*.rb")].sort.flat_map do |file|
      File.foreach(file).with_index(1).filter_map do |line, number|
        "#{file.delete_prefix("#{lib_dir}/")}:#{number}: #{line.strip}" if line.match?(/\A\s*require_relative\b/)
      end
    end

    expect(offenders).to be_empty,
      "require_relative between loader-managed files (reference the constant instead):\n  #{offenders.join("\n  ")}"
  end
end
