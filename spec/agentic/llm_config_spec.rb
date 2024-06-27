require "spec_helper"

RSpec.describe Agentic::LlmConfig do
  describe "#initialize" do
    it "sets default values for attributes" do
      config = described_class.new
      expect(config.model).to eq "gpt-4o"
    end

    it "allows setting model in initializer" do
      config = described_class.new(model: "custom-model")
      expect(config.model).to eq "custom-model"
    end
  end

  describe "attr_accessors" do
    let(:config) { described_class.new }

    it "allows reading and writing model" do
      config.model = "new-model"
      expect(config.model).to eq "new-model"
    end
  end
end
