# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::CapabilitySpecification do
  def spec(name: "summarization", version: "1.0.0")
    described_class.new(name: name, description: "Summarizes text", version: version)
  end

  describe "#compatible_with?" do
    it "is true for an exact version match" do
      expect(spec.compatible_with?(spec)).to be true
    end

    it "is true when this minor version is higher within the same major" do
      expect(spec(version: "1.2.0").compatible_with?(spec(version: "1.0.0"))).to be true
    end

    it "is true across patch versions within the same minor" do
      expect(spec(version: "1.0.3").compatible_with?(spec(version: "1.0.0"))).to be true
    end

    it "is false when this minor version is lower than the other" do
      expect(spec(version: "1.0.0").compatible_with?(spec(version: "1.2.0"))).to be false
    end

    it "is false across major versions in either direction" do
      expect(spec(version: "2.0.0").compatible_with?(spec(version: "1.0.0"))).to be false
      expect(spec(version: "1.0.0").compatible_with?(spec(version: "2.0.0"))).to be false
    end

    it "is false for a different capability name" do
      expect(spec(name: "translation").compatible_with?(spec)).to be false
    end

    it "is false for a non-specification" do
      expect(spec.compatible_with?("1.0.0")).to be false
    end

    it "requires an exact match when a version does not parse" do
      expect(spec(version: "1.0.0").compatible_with?(spec(version: "latest"))).to be false
      expect(spec(version: "latest").compatible_with?(spec(version: "latest"))).to be true
    end
  end
end
