# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::PlanOrchestrator, "configuration" do
  let(:task) do
    Agentic::Task.new(
      description: "Test task",
      agent_spec: {"instructions" => "You are a test agent"},
      input: {"test" => true}
    )
  end

  let(:failure) do
    Agentic::TaskFailure.new(
      message: "Test error",
      type: "TimeoutError",
      context: {agent_id: "test-agent"}
    )
  end

  describe "retry policy" do
    it "uses default retry policy when none is provided" do
      orchestrator = described_class.new

      # Verify default values
      expect(orchestrator.retry_policy[:max_retries]).to eq(3)
      expect(orchestrator.retry_policy[:retryable_errors]).to include("TimeoutError")
      expect(orchestrator.retry_policy[:backoff_strategy]).to eq(:constant)
    end

    it "allows customizing retry policy" do
      custom_policy = {
        max_retries: 5,
        retryable_errors: ["CustomError", "NetworkError"],
        backoff_strategy: :exponential,
        backoff_base: 2
      }

      orchestrator = described_class.new(retry_policy: custom_policy)

      # Verify custom values
      expect(orchestrator.retry_policy[:max_retries]).to eq(5)
      expect(orchestrator.retry_policy[:retryable_errors]).to eq(["CustomError", "NetworkError"])
      expect(orchestrator.retry_policy[:backoff_strategy]).to eq(:exponential)
      expect(orchestrator.retry_policy[:backoff_base]).to eq(2)

      # Verify defaults are still present for options not specified
      # (jitter defaults ON so fleets don't retry in lockstep)
      expect(orchestrator.retry_policy[:backoff_jitter]).to be true
    end

    it "merges custom policy with defaults" do
      custom_policy = {
        retryable_errors: ["CustomError"]
      }

      orchestrator = described_class.new(retry_policy: custom_policy)

      # Verify custom value
      expect(orchestrator.retry_policy[:retryable_errors]).to eq(["CustomError"])

      # Verify other defaults are maintained
      expect(orchestrator.retry_policy[:max_retries]).to eq(3)
      expect(orchestrator.retry_policy[:backoff_strategy]).to eq(:constant)
    end
  end

  describe "failure handling policy" do
    it "correctly identifies retryable vs non-retryable failures" do
      # Test orchestrator with custom policy
      orchestrator = described_class.new(retry_policy: {
        retryable_errors: ["RetryableError"]
      })

      # Create test task
      task.retry_count = 0

      # Retryable failure
      retryable_failure = Agentic::TaskFailure.new(
        message: "A retryable error",
        type: "RetryableError"
      )

      # Non-retryable failure
      non_retryable_failure = Agentic::TaskFailure.new(
        message: "A non-retryable error",
        type: "OtherError"
      )

      # Run private method through instance_exec to test behavior
      is_retryable = orchestrator.instance_exec(task, retryable_failure) do |task, failure|
        retry?(task: task, failure: failure)
      end

      is_non_retryable = orchestrator.instance_exec(task, non_retryable_failure) do |task, failure|
        retry?(task: task, failure: failure)
      end

      expect(is_retryable).to be true
      expect(is_non_retryable).to be false
    end

    it "respects max_retries setting" do
      orchestrator = described_class.new(retry_policy: {max_retries: 2})

      # Test with retry count at limit
      task.retry_count = 2

      # Run private method through instance_exec
      should_retry = orchestrator.instance_exec(task, failure) do |task, failure|
        retry?(task: task, failure: failure)
      end

      expect(should_retry).to be false
    end

    it "identifies errors requiring human intervention" do
      orchestrator = described_class.new

      auth_failure = Agentic::TaskFailure.new(
        message: "Authentication failed",
        type: "AuthenticationError"
      )

      other_failure = Agentic::TaskFailure.new(
        message: "Some other error",
        type: "OtherError"
      )

      # Run private method through instance_exec
      needs_intervention = orchestrator.instance_exec(auth_failure) do |failure|
        requires_intervention?(failure: failure)
      end

      doesnt_need_intervention = orchestrator.instance_exec(other_failure) do |failure|
        requires_intervention?(failure: failure)
      end

      expect(needs_intervention).to be true
      expect(doesnt_need_intervention).to be false
    end

    it "pauses for the namespaced provider auth error a real 401 produces" do
      failure = Agentic::TaskFailure.from_exception(Agentic::Errors::LlmAuthenticationError.new("401"))

      expect(described_class.new.send(:requires_intervention?, failure: failure)).to be true
    end
  end
end
