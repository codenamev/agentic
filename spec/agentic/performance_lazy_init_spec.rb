# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Agentic::Performance, "initialization" do
  # The background threads an optimizer owns, found by reference rather
  # than by name (threads name themselves asynchronously)
  def threads_owned_by(optimizer)
    return [] unless optimizer

    caches = optimizer.cache_manager&.instance_variable_get(:@caches)&.values || []
    [optimizer.instance_variable_get(:@optimization_thread), *caches.map { |c| c.instance_variable_get(:@cleanup_thread) }].compact
  end

  around do |example|
    saved = %i[@optimizer @cache_manager @initialized].to_h { |ivar| [ivar, described_class.instance_variable_get(ivar)] }
    described_class.reset!
    example.run
  ensure
    # reset! drops references but never stops threads: stop the ones this
    # example's optimizer started, and nothing else
    threads_owned_by(described_class.instance_variable_get(:@optimizer)).each(&:kill)
    saved&.each { |ivar, value| described_class.instance_variable_set(ivar, value) }
  end

  around do |example|
    original = ENV["AGENTIC_ENV"]
    ENV["AGENTIC_ENV"] = "development"
    example.run
  ensure
    ENV["AGENTIC_ENV"] = original
  end

  it "is not initialized by Agentic.initialize_agent_assembly" do
    assembly_ivars = %i[@agent_capability_registry @agent_store @agent_assembly_engine]
    saved = assembly_ivars.to_h { |ivar| [ivar, Agentic.instance_variable_get(ivar)] }
    assembly_ivars.each { |ivar| Agentic.instance_variable_set(ivar, nil) }

    Dir.mktmpdir do |dir|
      allow(Agentic.configuration).to receive(:agent_store_path).and_return(dir)
      allow(Agentic::Performance::Optimizer).to receive(:new).and_call_original

      Agentic.initialize_agent_assembly

      expect(described_class.initialized?).to be(false)
      expect(Agentic::Performance::Optimizer).not_to have_received(:new)
    end
  ensure
    saved.each { |ivar, value| Agentic.instance_variable_set(ivar, value) }
  end

  it "builds with the environment preset on first access" do
    expect(described_class.optimizer.config).to include(
      strategy: Agentic::Performance::Optimizer::Strategy::CONSERVATIVE,
      auto_tuning_enabled: false
    )
    expect(described_class.cache_manager).not_to be_nil
    expect(described_class.optimizer).not_to be_auto_tuning_running
  end

  it "honors auto_tuning_enabled: false when configured before first use" do
    optimizer = described_class.configure_for_development

    expect(optimizer).to equal(described_class.optimizer)
    expect(optimizer.config[:auto_tuning_enabled]).to be(false)
    expect(optimizer).not_to be_auto_tuning_running
  end

  it "still starts auto-tuning when a preset enables it" do
    expect(described_class.configure_for_production).to be_auto_tuning_running
  end

  it "merges a pre-first-use configure onto the environment preset" do
    described_class.configure(monitoring_enabled: false)

    expect(described_class.optimizer.config).to include(
      strategy: Agentic::Performance::Optimizer::Strategy::CONSERVATIVE,
      auto_tuning_enabled: false,
      monitoring_enabled: false
    )
  end

  it "merges into the existing optimizer after first use" do
    optimizer = described_class.optimizer

    expect(described_class.configure(monitoring_enabled: false)).to equal(optimizer)
    expect(optimizer.config[:monitoring_enabled]).to be(false)
  end

  it "builds exactly one optimizer under concurrent first use" do
    ENV["AGENTIC_ENV"] = "production" # auto-tuning on: each optimizer built starts a thread

    allow(Agentic::Performance::Optimizer).to receive(:new).and_wrap_original do |original, *args|
      sleep 0.01 # widen the race window
      original.call(*args)
    end

    8.times.map { Thread.new { described_class.cache } }.each(&:join)

    expect(Agentic::Performance::Optimizer).to have_received(:new).once
    expect(described_class.optimizer).to be_auto_tuning_running
  end
end
