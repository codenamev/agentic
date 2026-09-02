# frozen_string_literal: true

require "spec_helper"

# Simple agent provider for testing
class TestAgentProvider
  def get_agent_for_task(task)
    MockAgent.new
  end
end

# Re-use MockAgent from task_integration_spec.rb
class MockAgent
  attr_reader :id, :prompt_history

  def initialize(id = "mock-agent-123")
    @id = id
    @prompt_history = []
    @should_fail = false
  end

  def execute(prompt)
    @prompt_history << prompt

    if @should_fail
      raise StandardError, "Mock agent execution failed"
    end

    {"result" => "Mock agent response"}
  end

  def set_failure_mode(should_fail)
    @should_fail = should_fail
  end
end

RSpec.describe Agentic::PlanOrchestrator do
  let(:plan_id) { "test-plan-id" }
  let(:orchestrator) { described_class.new(plan_id: plan_id) }

  describe "#initialize" do
    it "sets the plan id and default attributes" do
      expect(orchestrator.plan_id).to eq(plan_id)
      expect(orchestrator.tasks).to be_empty
      expect(orchestrator.execution_state[:pending]).to be_empty
      expect(orchestrator.results).to be_empty
    end

    it "generates a plan id when not provided" do
      custom_orchestrator = described_class.new
      expect(custom_orchestrator.plan_id).not_to be_nil
    end
  end

  describe "#add_task" do
    let(:task) do
      Agentic::Task.new(
        description: "Test task",
        agent_spec: {"instructions" => "You are a test agent"},
        input: {"test_key" => "test_value"}
      )
    end

    let(:dependency_task) do
      Agentic::Task.new(
        description: "Dependency task",
        agent_spec: {"instructions" => "You are a test agent"},
        input: {"test_key" => "dependency"}
      )
    end

    it "adds a task to the orchestrator" do
      orchestrator.add_task(task)
      expect(orchestrator.tasks[task.id]).to eq(task)
      expect(orchestrator.execution_state[:pending]).to include(task.id)
    end

    it "stores task dependencies" do
      orchestrator.add_task(dependency_task)
      orchestrator.add_task(task, [dependency_task.id])

      # Check task is added with dependency
      expect(orchestrator.tasks[task.id]).to eq(task)
      expect(orchestrator.send(:all_dependencies_met?, task.id)).to be false

      # Complete dependency and verify it's now met
      orchestrator.execution_state[:pending].delete(dependency_task.id)
      orchestrator.execution_state[:completed].add(dependency_task.id)
      expect(orchestrator.send(:all_dependencies_met?, task.id)).to be true
    end
  end

  describe "#execute_plan" do
    let(:agent_provider) { TestAgentProvider.new }
    let(:task_a) do
      Agentic::Task.new(
        description: "Task A",
        agent_spec: {"instructions" => "You are a test agent"},
        input: {"name" => "A"}
      )
    end

    let(:task_b) do
      Agentic::Task.new(
        description: "Task B",
        agent_spec: {"instructions" => "You are a test agent"},
        input: {"name" => "B"}
      )
    end

    let(:task_c) do
      Agentic::Task.new(
        description: "Task C",
        agent_spec: {"instructions" => "You are a test agent"},
        input: {"name" => "C"}
      )
    end

    it "executes tasks with no dependencies" do
      orchestrator.add_task(task_a)
      result = orchestrator.execute_plan(agent_provider)

      expect(result).to be_a(Agentic::PlanExecutionResult)
      expect(result.status).to eq(:completed)
      expect(result.task_result(task_a.id).status).to eq(:completed)
      expect(orchestrator.execution_state[:completed]).to include(task_a.id)
    end

    it "executes tasks in dependency order" do
      # Set up task dependencies: A -> B -> C
      orchestrator.add_task(task_a)
      orchestrator.add_task(task_b, [task_a.id])
      orchestrator.add_task(task_c, [task_b.id])

      result = orchestrator.execute_plan(agent_provider)

      expect(result.status).to eq(:completed)
      expect(result.task_result(task_a.id).status).to eq(:completed)
      expect(result.task_result(task_b.id).status).to eq(:completed)
      expect(result.task_result(task_c.id).status).to eq(:completed)
    end

    it "joins an existing reactor instead of nesting a new event loop" do
      orchestrator.add_task(task_a)
      orchestrator.add_task(task_b, [task_a.id])

      result = nil
      Async do
        result = orchestrator.execute_plan(agent_provider)
      end.wait

      expect(result).to be_a(Agentic::PlanExecutionResult)
      expect(result.status).to eq(:completed)
      expect(result.task_result(task_b.id).status).to eq(:completed)
    end

    it "handles task failures" do
      failing_agent_provider = TestAgentProvider.new
      agent = MockAgent.new
      agent.set_failure_mode(true)
      allow(failing_agent_provider).to receive(:get_agent_for_task).and_return(agent)

      orchestrator.add_task(task_a)
      result = orchestrator.execute_plan(failing_agent_provider)

      expect(result.status).to eq(:partial_failure)
      expect(result.task_result(task_a.id).status).to eq(:failed)
      expect(orchestrator.execution_state[:failed]).to include(task_a.id)
    end

    it "handles mixed success and failure" do
      mixed_agent_provider = TestAgentProvider.new
      success_agent = MockAgent.new
      failure_agent = MockAgent.new
      failure_agent.set_failure_mode(true)

      # Task A succeeds, Task B fails
      allow(mixed_agent_provider).to receive(:get_agent_for_task) do |task|
        (task.id == task_a.id) ? success_agent : failure_agent
      end

      orchestrator.add_task(task_a)
      orchestrator.add_task(task_b)
      result = orchestrator.execute_plan(mixed_agent_provider)

      expect(result.status).to eq(:partial_failure)
      expect(result.task_result(task_a.id).status).to eq(:completed)
      expect(result.task_result(task_b.id).status).to eq(:failed)
      expect(orchestrator.execution_state[:completed]).to include(task_a.id)
      expect(orchestrator.execution_state[:failed]).to include(task_b.id)
    end

    it "doesn't execute dependent tasks when dependencies fail" do
      # Set up task dependencies: A -> B
      orchestrator.add_task(task_a)
      orchestrator.add_task(task_b, [task_a.id])

      # Make task A fail
      failing_agent_provider = TestAgentProvider.new
      agent = MockAgent.new
      agent.set_failure_mode(true)
      allow(failing_agent_provider).to receive(:get_agent_for_task).and_return(agent)

      result = orchestrator.execute_plan(failing_agent_provider)

      expect(result.status).to eq(:partial_failure)
      expect(result.task_result(task_a.id).status).to eq(:failed)
      expect(result.task_result(task_b.id)).to be_nil
      expect(orchestrator.execution_state[:pending]).to include(task_b.id)
    end

    context "when the plan can never finish" do
      it "raises on a dependency that names no task in the plan" do
        orchestrator.add_task(task_a)
        orchestrator.add_task(task_b, ["#{task_a.id}x"])

        expect {
          orchestrator.execute_plan(agent_provider)
        }.to raise_error(ArgumentError, /Task B depends on unknown task\(s\) #{Regexp.escape(task_a.id)}x \(did you mean #{Regexp.escape(task_a.id)}\?\)/)
      end

      it "names every task with unknown dependencies, not just the first" do
        orchestrator.add_task(task_a, ["ghost-1"])
        orchestrator.add_task(task_b, ["ghost-2"])

        expect {
          orchestrator.execute_plan(agent_provider)
        }.to raise_error(ArgumentError, /Task A depends on unknown task\(s\) ghost-1; Task B depends on unknown task\(s\) ghost-2/)
      end

      it "raises on a dependency cycle, naming the unrunnable tasks" do
        orchestrator.add_task(task_a, [task_b])
        orchestrator.add_task(task_b, [task_a])
        orchestrator.add_task(task_c, [task_b])

        expect {
          orchestrator.execute_plan(agent_provider)
        }.to raise_error(ArgumentError, /dependency cycle leaves task\(s\) unrunnable: Task A, Task B, Task C/)
      end

      it "raises on a task that depends on itself" do
        orchestrator.add_task(task_a, [task_a])

        expect {
          orchestrator.execute_plan(agent_provider)
        }.to raise_error(ArgumentError, /dependency cycle leaves task\(s\) unrunnable: Task A/)
      end

      it "still allows dependencies declared before their task is added" do
        orchestrator.add_task(task_b, [task_a])
        orchestrator.add_task(task_a)

        result = orchestrator.execute_plan(agent_provider)

        expect(result.status).to eq(:completed)
        expect(orchestrator.execution_state[:completed]).to include(task_a.id, task_b.id)
      end

      it "still allows needs:-declared dependencies before their task is added" do
        orchestrator.add_task(task_b, needs: {prior: task_a})
        orchestrator.add_task(task_a)

        result = orchestrator.execute_plan(agent_provider)

        expect(result.status).to eq(:completed)
        expect(orchestrator.execution_state[:completed]).to include(task_a.id, task_b.id)
      end

      it "still runs the remainder of a plan pruned with cancel_task" do
        # A cycle whose member was canceled before execution is inert,
        # not a structural error: the survivor strands (as with any
        # failed dependency) and unrelated tasks run to completion
        orchestrator.add_task(task_a, [task_b])
        orchestrator.add_task(task_b, [task_a])
        orchestrator.add_task(task_c)
        orchestrator.cancel_task(task_a.id)

        result = orchestrator.execute_plan(agent_provider)

        expect(result.status).to eq(:canceled)
        expect(orchestrator.execution_state[:completed]).to include(task_c.id)
        expect(orchestrator.execution_state[:pending]).to include(task_b.id)
      end
    end
  end

  describe "private methods" do
    let(:agent_provider) { TestAgentProvider.new }

    describe "#overall_status" do
      it "returns :completed when all tasks are complete" do
        task = Agentic::Task.new(
          description: "Test task",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        orchestrator.add_task(task)
        orchestrator.execution_state[:pending].delete(task.id)
        orchestrator.execution_state[:completed].add(task.id)

        expect(orchestrator.send(:overall_status)).to eq(:completed)
      end

      it "returns :in_progress when tasks are still pending or in progress" do
        task = Agentic::Task.new(
          description: "Test task",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        orchestrator.add_task(task)
        expect(orchestrator.send(:overall_status)).to eq(:in_progress)

        orchestrator.execution_state[:pending].delete(task.id)
        orchestrator.execution_state[:in_progress].add(task.id)
        expect(orchestrator.send(:overall_status)).to eq(:in_progress)
      end

      it "returns :partial_failure when some tasks have failed" do
        task = Agentic::Task.new(
          description: "Test task",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        orchestrator.add_task(task)
        orchestrator.execution_state[:pending].delete(task.id)
        orchestrator.execution_state[:failed].add(task.id)

        expect(orchestrator.send(:overall_status)).to eq(:partial_failure)
      end
    end

    describe "#all_dependencies_met?" do
      it "returns true when all dependencies are completed" do
        task_a = Agentic::Task.new(
          description: "Task A",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        task_b = Agentic::Task.new(
          description: "Task B",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        # B depends on A
        orchestrator.add_task(task_a)
        orchestrator.add_task(task_b, [task_a.id])

        # A is not completed yet
        expect(orchestrator.send(:all_dependencies_met?, task_b.id)).to be false

        # Complete A
        orchestrator.execution_state[:pending].delete(task_a.id)
        orchestrator.execution_state[:completed].add(task_a.id)

        expect(orchestrator.send(:all_dependencies_met?, task_b.id)).to be true
      end

      it "returns true for tasks with no dependencies" do
        task = Agentic::Task.new(
          description: "Test task",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        orchestrator.add_task(task)
        expect(orchestrator.send(:all_dependencies_met?, task.id)).to be true
      end
    end

    describe "#find_eligible_tasks" do
      it "returns tasks with no dependencies" do
        task_a = Agentic::Task.new(
          description: "Task A",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        task_b = Agentic::Task.new(
          description: "Task B",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        task_c = Agentic::Task.new(
          description: "Task C",
          agent_spec: {"instructions" => "You are a test agent"}
        )

        # A has no dependencies, B depends on A, C depends on B
        orchestrator.add_task(task_a)
        orchestrator.add_task(task_b, [task_a.id])
        orchestrator.add_task(task_c, [task_b.id])

        eligible_tasks = orchestrator.send(:find_eligible_tasks)
        expect(eligible_tasks).to eq([task_a.id])
        expect(eligible_tasks).not_to include(task_b.id)
        expect(eligible_tasks).not_to include(task_c.id)
      end
    end
  end
end
