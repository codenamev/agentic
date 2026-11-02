# frozen_string_literal: true

require "rubygems"

# Every `require` under lib/ must resolve to something a consumer gets from
# `gem install agentic`: Ruby's own library, or a gem the gemspec declares as
# a runtime dependency. The dev bundle hides the gap (rgl sat in the Gemfile,
# base64 rode in on another gem's dependency), so CI stayed green while
# `require "agentic"; Agentic::ArtifactGraph` raised LoadError for consumers.
# Default gems that Ruby has promoted, or announced it will promote, to
# bundled gems count as needing a declaration: that is how logger and cgi are
# already handled.
RSpec.describe "lib/ requires" do
  let(:gemspec) { Gem::Specification.load(File.expand_path("../agentic.gemspec", __dir__)) }
  let(:declared) { gemspec.runtime_dependencies.map(&:name) }
  let(:lib_dir) { File.expand_path("../lib", __dir__) }

  # Gem::BUNDLED_GEMS::SINCE is Ruby's own table (3.3+). The literal list is
  # 4.0's table, so CI on an older interpreter applies the same verdicts.
  let(:bundled) do
    announced = defined?(Gem::BUNDLED_GEMS::SINCE) ? Gem::BUNDLED_GEMS::SINCE.keys : []
    known = %w[abbrev base64 benchmark bigdecimal csv drb fiddle getoptlong irb logger mutex_m nkf observer
      ostruct pstore racc rdoc reline resolv-replace rinda syslog tsort win32ole]
    (announced + known).uniq
  end

  # [require path, lib-relative file] for every require of something outside the gem
  let(:requires) do
    Dir[File.join(lib_dir, "**", "*.rb")].sort.flat_map do |file|
      File.foreach(file).filter_map do |line|
        path = line[/\A\s*require\s+["']([^"']+)["']/, 1]
        [path, file.delete_prefix("#{lib_dir}/")] if path && !path.start_with?("agentic")
      end
    end
  end

  # A file in the stdlib directories, or a feature the interpreter provides
  # without one (Set is built in on Ruby 4.0, so "set.rb" sits bare in
  # $LOADED_FEATURES next to "enumerator.so").
  def shipped_with_ruby?(path)
    return true if $LOADED_FEATURES.include?("#{path}.rb") || $LOADED_FEATURES.include?("#{path}.so")

    %w[rubylibdir archdir].any? do |dir|
      ["rb", RbConfig::CONFIG["DLEXT"]].any? { |ext| File.exist?(File.join(RbConfig::CONFIG[dir], "#{path}.#{ext}")) }
    end
  end

  it "sees the requires it guards" do
    expect(requires.map(&:first)).to include("json", "zeitwerk", "tsort", "concurrent")
  end

  it "only requires Ruby's library or declared runtime dependencies" do
    undeclared = requires.uniq.filter_map do |path, file|
      owner = Gem::Specification.find_by_path(path)
      name = owner ? owner.name : path.split("/").first
      next if declared.include?(name)
      next if (owner&.default_gem? || shipped_with_ruby?(path)) && !bundled.include?(name)

      "#{file}: require \"#{path}\" (#{name})"
    end

    expect(undeclared).to be_empty, "requires nothing declares as a runtime dependency:\n  #{undeclared.uniq.join("\n  ")}"
  end
end
