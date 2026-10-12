# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::TaskResult do
  let(:task_id) { "test-task-id" }
  let(:output) { {"result" => "test_result"} }
  let(:failure) { Agentic::TaskFailure.new(message: "Test failure", type: "TestError") }

  describe "#initialize" do
    context "with success result" do
      let(:result) { described_class.new(task_id: task_id, success: true, output: output) }

      it "sets the attributes correctly" do
        expect(result.task_id).to eq(task_id)
        expect(result.success).to be true
        expect(result.output).to eq(output)
        expect(result.failure).to be_nil
      end
    end

    context "with stats" do
      let(:stats) { Agentic::GenerationStats.new(id: "gen-1", prompt_tokens: 10, completion_tokens: 5, total_tokens: 15) }

      it "carries the token usage and serializes it" do
        result = described_class.new(task_id: task_id, success: true, output: output, stats: stats)
        expect(result.stats).to be(stats)
        expect(result.to_h[:stats]).to eq(id: "gen-1", prompt_tokens: 10, completion_tokens: 5, total_tokens: 15)
      end

      it "defaults to nil so unknown usage is never reported as zero" do
        result = described_class.new(task_id: task_id, success: true, output: output)
        expect(result.stats).to be_nil
        expect(result.to_h[:stats]).to be_nil
      end
    end

    context "with failure result" do
      let(:result) { described_class.new(task_id: task_id, success: false, failure: failure) }

      it "sets the attributes correctly" do
        expect(result.task_id).to eq(task_id)
        expect(result.success).to be false
        expect(result.output).to be_nil
        expect(result.failure).to eq(failure)
      end
    end
  end

  describe "#successful?" do
    it "returns true when success is true" do
      result = described_class.new(task_id: task_id, success: true)
      expect(result.successful?).to be true
    end

    it "returns false when success is false" do
      result = described_class.new(task_id: task_id, success: false)
      expect(result.successful?).to be false
    end
  end

  describe "#failed?" do
    it "returns false when success is true" do
      result = described_class.new(task_id: task_id, success: true)
      expect(result.failed?).to be false
    end

    it "returns true when success is false" do
      result = described_class.new(task_id: task_id, success: false)
      expect(result.failed?).to be true
    end
  end

  describe "#to_h" do
    it "returns a hash representation for success result" do
      result = described_class.new(task_id: task_id, success: true, output: output)
      hash = result.to_h

      expect(hash).to be_a(Hash)
      expect(hash[:task_id]).to eq(task_id)
      expect(hash[:success]).to be true
      expect(hash[:output]).to eq(output)
      expect(hash[:failure]).to be_nil
    end

    it "returns a hash representation for failure result" do
      result = described_class.new(task_id: task_id, success: false, failure: failure)
      hash = result.to_h

      expect(hash).to be_a(Hash)
      expect(hash[:task_id]).to eq(task_id)
      expect(hash[:success]).to be false
      expect(hash[:output]).to be_nil
      expect(hash[:failure]).to be_a(Hash)
      expect(hash[:failure][:message]).to eq("Test failure")
    end
  end
end
