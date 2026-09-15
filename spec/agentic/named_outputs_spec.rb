# frozen_string_literal: true

require "spec_helper"
RSpec.describe Agentic::NamedOutputs, "tolerated failures" do
  let(:failure) { Agentic::TaskFailure.new(message: "boom", type: "StandardError", retryable: false) }

  it "records a named dependency's failure without an output" do
    outputs = described_class.new
    outputs.record_failure(:findings, failure)

    expect(outputs.succeeded?(:findings)).to be(false)
    expect(outputs.failure_of("findings")).to eq(failure)
    expect(outputs[:findings]).to be_nil
    expect(outputs.key?(:findings)).to be(false)
  end

  it "reports success for a name with an output and no failure" do
    outputs = described_class.new
    outputs[:findings] = {"ok" => true}

    expect(outputs.succeeded?(:findings)).to be(true)
    expect(outputs.failure_of(:findings)).to be_nil
  end
end
