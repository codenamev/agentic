# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe "Portal deprecation (ADR-023 Phase 2)" do
  around do |example|
    previous = Warning[:deprecated]
    Warning[:deprecated] = true
    Agentic::HumanIntervention::Portal.reset_deprecation_warning!
    Agentic::CLI::HumanInterventionCommands.reset_deprecation_warning!
    example.run
  ensure
    Warning[:deprecated] = previous
    Agentic::HumanIntervention::Portal.reset_deprecation_warning!
    Agentic::CLI::HumanInterventionCommands.reset_deprecation_warning!
  end

  describe Agentic::HumanIntervention::Portal do
    it "emits a :deprecated warning pointing at the resume path and #101" do
      allow(Warning).to receive(:warn)
      expect(Warning).to receive(:warn)
        .with(a_string_including("Portal is deprecated", "agentic pending", "--resume --answer", "issues/101"),
          category: :deprecated)

      portal = described_class.new
      portal.shutdown!
    end

    it "warns once per process, not once per instance" do
      allow(Warning).to receive(:warn)
      expect(described_class.warn_deprecated_once).to be(true)
      expect(described_class.warn_deprecated_once).to be(false)
    end

    it "stays silent when deprecation warnings are off" do
      Warning[:deprecated] = false
      expect { described_class.warn_deprecated_once }.not_to output.to_stderr
    end
  end

  describe Agentic::CLI::HumanInterventionCommands do
    it "prints the CLI notice to the given io once per process" do
      io = StringIO.new
      expect(described_class.warn_deprecated_once(io)).to be(true)
      expect(described_class.warn_deprecated_once(io)).to be(false)
      expect(io.string.lines.size).to eq(1)
      expect(io.string).to include("`agentic portal` is deprecated", "agentic pending", "--resume --answer")
    end

    it "prints the notice even when Warning[:deprecated] is off" do
      Warning[:deprecated] = false
      io = StringIO.new
      described_class.warn_deprecated_once(io)
      expect(io.string).to include("deprecated")
    end
  end
end
