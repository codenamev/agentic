# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::Task do
  let(:description) { "Test task description" }
  let(:agent_spec) { {"instructions" => "You are a test agent"} }
  let(:input) { {"test_key" => "test_value"} }
  let(:task) { described_class.new(description: description, agent_spec: agent_spec, input: input) }

  describe "#initialize" do
    it "sets the basic attributes" do
      expect(task.id).not_to be_nil
      expect(task.description).to eq(description)
      expect(task.agent_spec).to be_a(Agentic::AgentSpecification)
      expect(task.agent_spec.instructions).to eq("You are a test agent")
      expect(task.input).to eq(input)
      expect(task.status).to eq(:pending)
      expect(task.output).to be_nil
      expect(task.failure).to be_nil
    end
  end

  describe "#perform" do
    let(:agent) { double("Agent") }
    let(:output) { {"result" => "test_result"} }

    context "when execution succeeds" do
      before do
        allow(agent).to receive(:execute).and_return(output)
      end

      it "updates the task status to completed" do
        task.perform(agent)
        expect(task.status).to eq(:completed)
      end

      it "sets the output" do
        task.perform(agent)
        expect(task.output).to eq(output)
      end

      it "returns a successful TaskResult" do
        result = task.perform(agent)
        expect(result).to be_a(Agentic::TaskResult)
        expect(result.successful?).to be true
        expect(result.output).to eq(output)
      end

      it "leaves stats nil for an agent that reports none" do
        expect(task.perform(agent).stats).to be_nil
      end

      it "attaches the agent's last_stats to the result" do
        stats = Agentic::GenerationStats.new(id: "gen-1", prompt_tokens: 3, completion_tokens: 4, total_tokens: 7)
        allow(agent).to receive(:last_stats).and_return(stats)

        expect(task.perform(agent).stats).to be(stats)
      end

      it "notifies observers of status changes" do
        observer = double("Observer")
        allow(observer).to receive(:update)

        task.add_observer(observer)

        expect(observer).to receive(:update).with(:status_change, task, :pending, :in_progress)
        expect(observer).to receive(:update).with(:status_change, task, :in_progress, :completed)

        task.perform(agent)
      end
    end

    context "when execution fails" do
      let(:error) { StandardError.new("Test error") }

      before do
        allow(error).to receive(:backtrace).and_return(["line1", "line2"])
        allow(agent).to receive(:execute).and_raise(error)
        allow(agent).to receive(:id).and_return("agent-123")
        allow(Agentic.logger).to receive(:error)
      end

      it "updates the task status to failed" do
        task.perform(agent)
        expect(task.status).to eq(:failed)
      end

      it "sets the failure" do
        task.perform(agent)
        expect(task.failure).to be_a(Agentic::TaskFailure)
        expect(task.failure.message).to eq("Test error")
        expect(task.failure.type).to eq("StandardError")
      end

      it "returns a failed TaskResult" do
        result = task.perform(agent)
        expect(result).to be_a(Agentic::TaskResult)
        expect(result.failed?).to be true
        expect(result.failure).to be_a(Agentic::TaskFailure)
      end

      it "logs the error" do
        expect(Agentic.logger).to receive(:error).with("Task execution failed: Test error")
        task.perform(agent)
      end

      it "notifies observers of status changes and failure" do
        observer = double("Observer")
        allow(observer).to receive(:update)

        task.add_observer(observer)

        expect(observer).to receive(:update).with(:status_change, task, :pending, :in_progress)
        expect(observer).to receive(:update).with(:status_change, task, :in_progress, :failed)
        expect(observer).to receive(:update).with(:failure_occurred, task, kind_of(Agentic::TaskFailure))

        task.perform(agent)
      end
    end
  end

  describe "#retry" do
    let(:agent) { double("Agent") }
    let(:output) { {"result" => "test_result"} }

    context "when task is in failed state" do
      before do
        allow(agent).to receive(:execute).and_return(output)
        task.instance_variable_set(:@status, :failed)
      end

      it "updates the task status to retrying then completed" do
        observer = double("Observer")
        allow(observer).to receive(:update)

        task.add_observer(observer)

        expect(observer).to receive(:update).with(:status_change, task, :failed, :retrying)
        expect(observer).to receive(:update).with(:status_change, task, :retrying, :in_progress)
        expect(observer).to receive(:update).with(:status_change, task, :in_progress, :completed)

        task.retry(agent)
        expect(task.status).to eq(:completed)
      end

      it "returns a successful TaskResult" do
        result = task.retry(agent)
        expect(result).to be_a(Agentic::TaskResult)
        expect(result.successful?).to be true
      end
    end

    context "when task is not in failed state" do
      it "raises an error" do
        expect { task.retry(agent) }.to raise_error("Cannot retry a task that is not in a failed state")
      end
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      hash = task.to_h
      expect(hash).to be_a(Hash)
      expect(hash[:id]).to eq(task.id)
      expect(hash[:description]).to eq(task.description)
      expect(hash[:agent_spec]).to be_a(Hash)
      expect(hash[:agent_spec]["instructions"]).to eq("You are a test agent")
      expect(hash[:input]).to eq(task.input)
      expect(hash[:status]).to eq(task.status)
    end

    context "when task has failed" do
      before do
        failure = Agentic::TaskFailure.new(
          message: "Test failure",
          type: "TestError"
        )
        task.instance_variable_set(:@failure, failure)
      end

      it "includes failure information" do
        hash = task.to_h
        expect(hash[:failure]).to be_a(Hash)
        expect(hash[:failure][:message]).to eq("Test failure")
        expect(hash[:failure][:type]).to eq("TestError")
      end
    end
  end

  describe "#build_prompt" do
    it "formats the prompt correctly" do
      prompt = task.send(:build_prompt)
      expect(prompt).to include("[System Instructions]")
      expect(prompt).to include("You are a test agent")
      expect(prompt).to include("[Task Description]")
      expect(prompt).to include("Test task description")
      expect(prompt).to include("[Input Parameters]")
      expect(prompt).to include("test_key")
      expect(prompt).to include("test_value")
      expect(prompt).to include("[Output Requirements]")
    end

    context "when task has no output schema" do
      it "includes generic JSON output requirements" do
        prompt = task.send(:build_prompt)
        expect(prompt).to include("Provide your response as valid JSON only")
        expect(prompt).to include("Do not wrap the JSON in markdown code blocks")
      end
    end

    context "when task has an output schema" do
      before do
        task.output_schema_name = :default
      end

      it "includes structured output requirements" do
        prompt = task.send(:build_prompt)
        expect(prompt).to include("Provide your response as a structured JSON object")
        expect(prompt).to include("follows the specified schema")
        expect(prompt).to include("Do not include any markdown formatting")
      end
    end
  end

  describe "structured output functionality" do
    describe "#output_schema_name" do
      it "can be set during initialization" do
        task_with_schema = described_class.new(
          description: description,
          agent_spec: agent_spec,
          input: input,
          output_schema_name: :default
        )
        expect(task_with_schema.output_schema_name).to eq(:default)
      end

      it "can be set after initialization" do
        task.output_schema_name = :analysis
        expect(task.output_schema_name).to eq(:analysis)
      end
    end

    describe "#output_schema" do
      context "when no schema name is set" do
        it "returns nil" do
          expect(task.output_schema).to be_nil
        end
      end

      context "when a valid schema name is set" do
        before do
          task.output_schema_name = :default
        end

        it "returns the corresponding schema" do
          schema = task.output_schema
          expect(schema).to be_a(Agentic::StructuredOutputs::Schema)
          expect(schema.to_hash[:name]).to eq("task_output")
        end
      end

      context "when an invalid schema name is set" do
        before do
          task.output_schema_name = :non_existent
        end

        it "returns nil" do
          expect(task.output_schema).to be_nil
        end
      end
    end

    describe "#has_output_schema?" do
      context "when no schema name is set" do
        it "returns false" do
          expect(task.has_output_schema?).to be false
        end
      end

      context "when a valid schema name is set" do
        before do
          task.output_schema_name = :default
        end

        it "returns true" do
          expect(task.has_output_schema?).to be true
        end
      end

      context "when an invalid schema name is set" do
        before do
          task.output_schema_name = :non_existent
        end

        it "returns false" do
          expect(task.has_output_schema?).to be false
        end
      end
    end

    describe "#set_output_schema" do
      it "sets the output schema name" do
        task.set_output_schema(:analysis)
        expect(task.output_schema_name).to eq(:analysis)
      end
    end

    describe "#perform with structured output" do
      let(:agent) { double("Agent") }
      let(:schema) { Agentic::TaskOutputSchemas.default_task_schema }
      let(:structured_output) do
        {
          "status" => "completed",
          "result" => {
            "summary" => "Task completed successfully"
          },
          "steps" => ["step1", "step2"]
        }
      end

      before do
        task.output_schema_name = :default
      end

      context "when agent supports structured output" do
        before do
          allow(agent).to receive(:execute_with_schema).with(anything, schema).and_return(structured_output)
        end

        it "calls execute_with_schema instead of execute" do
          expect(agent).to receive(:execute_with_schema).with(anything, schema)
          expect(agent).not_to receive(:execute)

          task.perform(agent)
        end

        it "sets the structured output" do
          task.perform(agent)
          expect(task.output).to eq(structured_output)
        end

        it "returns a successful TaskResult" do
          result = task.perform(agent)
          expect(result).to be_a(Agentic::TaskResult)
          expect(result.successful?).to be true
          expect(result.output).to eq(structured_output)
        end
      end

      context "when agent does not support structured output" do
        before do
          allow(agent).to receive(:execute_with_schema).and_raise(StandardError, "Structured output not supported")
        end

        it "handles the error and creates a TaskResult with failure" do
          result = task.perform(agent)
          expect(result).to be_a(Agentic::TaskResult)
          expect(result.successful?).to be false
          expect(task.status).to eq(:failed)
          expect(task.failure).to be_a(Agentic::TaskFailure)
          expect(task.failure.message).to include("Structured output not supported")
        end
      end
    end
  end
end
