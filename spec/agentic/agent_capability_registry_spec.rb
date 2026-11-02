# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::AgentCapabilityRegistry do
  let(:registry) { described_class.instance }
  let(:capability) do
    Agentic::CapabilitySpecification.new(
      name: "text_generation",
      description: "Generates text",
      version: "1.0.0",
      inputs: {prompt: {type: "string", required: true}},
      outputs: {response: {type: "string"}}
    )
  end
  let(:provider) do
    Agentic::CapabilityProvider.new(
      capability: capability,
      implementation: ->(inputs) { {response: inputs[:prompt]} }
    )
  end

  before do
    registry.clear
    registry.register(capability, provider)
  end

  describe "#find" do
    it "matches on named comparators" do
      expect(registry.find(name: "text_generation", min_version: "0.9.0")).to eq([capability])
      expect(registry.find(has_input: "prompt")).to eq([capability])
      expect(registry.find(has_output: :missing)).to be_empty
    end

    it "matches on the specification's data attributes as bare keys" do
      expect(registry.find(description: "Generates text")).to eq([capability])
      expect(registry.find("description" => "Something else")).to be_empty
    end

    it "does not dispatch unknown keys as method calls" do
      as_hash = capability.to_h
      expect(capability).not_to receive(:to_h)

      expect(registry.find(to_h: as_hash)).to be_empty
      expect(registry.find(object_id: capability.object_id)).to be_empty
    end

    it "treats a key that names a method needing arguments as a non-match instead of raising" do
      expect { registry.find(compatible_with?: true) }.not_to raise_error
      expect(registry.find(compatible_with?: true)).to be_empty
    end
  end
end
