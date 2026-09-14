# frozen_string_literal: true

RSpec.describe Agentic::Observability::EventDispatcher do
  let(:dispatcher) { described_class.new }
  let(:mock_observer) { double("MockObserver") }

  before do
    allow(mock_observer).to receive(:update)
  end

  describe "initialization" do
    it "creates dispatcher with default configuration" do
      expect(dispatcher.config).to include(
        max_buffer_size: 1000,
        batch_size: 50,
        enable_priority_routing: true
      )
    end

    it "allows configuration override" do
      custom_dispatcher = described_class.new(max_buffer_size: 500, batch_size: 25)
      expect(custom_dispatcher.config[:max_buffer_size]).to eq(500)
      expect(custom_dispatcher.config[:batch_size]).to eq(25)
    end

    it "initializes empty statistics" do
      expect(dispatcher.statistics[:events_processed]).to eq(0)
      expect(dispatcher.statistics[:events_filtered]).to eq(0)
    end
  end

  describe "observer management" do
    it "adds observers with priority" do
      dispatcher.add_observer(mock_observer, priority: 1)

      dispatcher.dispatch(:test_event, {message: "test"})

      expect(mock_observer).to have_received(:update)
    end

    it "removes observers" do
      dispatcher.add_observer(mock_observer)
      dispatcher.remove_observer(mock_observer)

      dispatcher.dispatch(:test_event, {message: "test"})

      expect(mock_observer).not_to have_received(:update)
    end

    it "prioritizes observers by priority level" do
      high_priority_observer = double("HighPriorityObserver")
      low_priority_observer = double("LowPriorityObserver")

      allow(high_priority_observer).to receive(:update)
      allow(low_priority_observer).to receive(:update)

      dispatcher.add_observer(low_priority_observer, priority: 3)
      dispatcher.add_observer(high_priority_observer, priority: 1)

      dispatcher.dispatch(:priority_test, {})

      expect(high_priority_observer).to have_received(:update)
      expect(low_priority_observer).to have_received(:update)
    end
  end

  describe "event dispatching" do
    before do
      dispatcher.add_observer(mock_observer)
    end

    it "dispatches basic events" do
      dispatcher.dispatch(:task_started, {task_id: "123"}, source: "test_source")

      expect(mock_observer).to have_received(:update).with(
        :task_started,
        "test_source",
        hash_including(
          type: :task_started,
          data: {task_id: "123"},
          source: "test_source"
        )
      )
    end

    it "enriches events with metadata" do
      dispatcher.dispatch(:enriched_event, {data: "test"})

      expect(mock_observer).to have_received(:update) do |type, source, event|
        expect(event).to include(:timestamp, :dispatcher_metadata, :source_class)
        expect(event[:dispatcher_metadata]).to include(:buffer_size)
      end
    end

    it "handles correlation context" do
      correlation_context = {correlation_id: "abc-123", workflow_id: "workflow-456"}

      dispatcher.dispatch(:correlated_event, {}, correlation_context: correlation_context)

      expect(mock_observer).to have_received(:update) do |type, source, event|
        expect(event[:correlation_context]).to eq(correlation_context)
      end
    end
  end

  describe "routing rules" do
    let(:task_observer) { double("TaskObserver") }
    let(:error_observer) { double("ErrorObserver") }

    before do
      allow(task_observer).to receive(:update)
      allow(error_observer).to receive(:update)

      dispatcher.add_observer(mock_observer) # Default observer
    end

    it "routes events by type" do
      dispatcher.add_routing_rule(
        event_types: [:task_started, :task_completed],
        observers: [{observer: task_observer, priority: 1}],
        priority: described_class::PRIORITY_HIGH
      )

      dispatcher.dispatch(:task_started, {})

      expect(task_observer).to have_received(:update)
    end

    it "routes events by source type" do
      dispatcher.add_routing_rule(
        sources: [:String],
        observers: [{observer: error_observer, priority: 0}]
      )

      dispatcher.dispatch(:test_event, {}, source: "string_source")

      expect(error_observer).to have_received(:update)
    end

    it "routes events by custom condition" do
      dispatcher.add_routing_rule(
        condition: ->(event) { event[:data][:severity] == "critical" },
        observers: [{observer: error_observer, priority: 0}],
        priority: described_class::PRIORITY_CRITICAL
      )

      dispatcher.dispatch(:custom_event, {severity: "critical"})

      expect(error_observer).to have_received(:update)
    end

    it "validates routing rules" do
      expect {
        dispatcher.add_routing_rule(priority: "invalid")
      }.to raise_error(ArgumentError, /must specify at least one/)

      expect {
        dispatcher.add_routing_rule(event_types: [:test], priority: "not_integer")
      }.to raise_error(ArgumentError, /Priority must be an integer/)
    end
  end

  describe "filtering" do
    before do
      dispatcher.add_observer(mock_observer)
    end

    it "filters events based on custom conditions" do
      dispatcher.add_filter(:test_filter) do |event|
        event[:data][:should_process] == true
      end

      # This event should be filtered out
      dispatcher.dispatch(:filtered_event, {should_process: false})
      expect(mock_observer).not_to have_received(:update)

      # This event should pass through
      dispatcher.dispatch(:passed_event, {should_process: true})
      expect(mock_observer).to have_received(:update)
    end

    it "updates filter statistics" do
      dispatcher.add_filter(:blocking_filter) { |event| false }

      dispatcher.dispatch(:blocked_event, {})

      expect(dispatcher.statistics[:events_filtered]).to eq(1)
    end

    it "handles filter errors gracefully" do
      dispatcher.add_filter(:error_filter) do |event|
        raise StandardError, "Filter error"
      end

      expect {
        dispatcher.dispatch(:error_test, {})
      }.not_to raise_error

      expect(mock_observer).to have_received(:update) # Event should still pass through
    end
  end

  describe "transformers" do
    before do
      dispatcher.add_observer(mock_observer)
    end

    it "transforms event data" do
      dispatcher.add_transformer(:enricher) do |event|
        event[:data][:enriched] = true
        event[:data][:processed_at] = Time.now.to_f
        event
      end

      dispatcher.dispatch(:transform_test, {original: "data"})

      expect(mock_observer).to have_received(:update) do |type, source, event|
        expect(event[:data][:enriched]).to be true
        expect(event[:data][:processed_at]).to be_a(Float)
        expect(event[:data][:original]).to eq("data")
      end
    end

    it "handles transformer errors gracefully" do
      dispatcher.add_transformer(:error_transformer) do |event|
        raise StandardError, "Transformer error"
      end

      expect {
        dispatcher.dispatch(:error_transform, {data: "test"})
      }.not_to raise_error

      expect(mock_observer).to have_received(:update)
    end
  end

  describe "priority handling" do
    it "determines priority based on event type" do
      test_cases = [
        [:security_breach, described_class::PRIORITY_CRITICAL],
        [:task_error, described_class::PRIORITY_CRITICAL],
        [:task_failed, described_class::PRIORITY_HIGH],
        [:agent_error, described_class::PRIORITY_HIGH],
        [:task_started, described_class::PRIORITY_NORMAL],
        [:metrics_update, described_class::PRIORITY_LOW]
      ]

      test_cases.each do |event_type, expected_priority|
        priority = dispatcher.send(:determine_priority, event_type)
        expect(priority).to eq(expected_priority),
          "Event #{event_type} should have priority #{expected_priority}, got #{priority}"
      end
    end
  end

  describe "performance optimization" do
    it "tracks processing statistics" do
      dispatcher.add_observer(mock_observer)

      5.times { |i| dispatcher.dispatch(:perf_test, {iteration: i}) }

      stats = dispatcher.statistics
      expect(stats[:events_processed]).to eq(5)
      expect(stats[:average_processing_time]).to be >= 0
    end

    it "calculates buffer utilization" do
      initial_utilization = dispatcher.buffer_utilization
      expect(initial_utilization).to eq(0.0)

      # Buffer utilization is calculated as buffer_size / max_buffer_size
      # Since we're not using batching in this test, buffer should remain empty
      expect(dispatcher.buffer_utilization).to be_between(0.0, 1.0)
    end

    it "handles observer notification errors gracefully" do
      broken_observer = double("BrokenObserver")
      allow(broken_observer).to receive(:update).and_raise("Observer error")

      dispatcher.add_observer(broken_observer)
      dispatcher.add_observer(mock_observer)

      expect {
        dispatcher.dispatch(:error_test, {})
      }.not_to raise_error

      # Good observer should still receive the event
      expect(mock_observer).to have_received(:update)
    end
  end

  describe "configuration management" do
    it "clears all configuration" do
      dispatcher.add_routing_rule(event_types: [:test])
      dispatcher.add_filter(:test_filter) { true }
      dispatcher.add_transformer(:test_transformer) { |e| e }

      dispatcher.clear_configuration

      # After clearing, basic dispatch should still work
      dispatcher.add_observer(mock_observer)
      dispatcher.dispatch(:clear_test, {})

      expect(mock_observer).to have_received(:update)
    end
  end

  describe "Domain Expert requirements (agent orchestration)" do
    it "supports agent hierarchy routing" do
      parent_agent_observer = double("ParentAgentObserver")
      child_agent_observer = double("ChildAgentObserver")

      allow(parent_agent_observer).to receive(:update)
      allow(child_agent_observer).to receive(:update)

      # Route events based on agent hierarchy in correlation context
      dispatcher.add_routing_rule(
        condition: ->(event) { event[:correlation_context][:agent_level] == "parent" },
        observers: [{observer: parent_agent_observer, priority: 1}]
      )

      dispatcher.add_routing_rule(
        condition: ->(event) { event[:correlation_context][:agent_level] == "child" },
        observers: [{observer: child_agent_observer, priority: 2}]
      )

      # Test parent agent event
      dispatcher.dispatch(
        :agent_decision,
        {decision: "delegate_task"},
        correlation_context: {agent_level: "parent", agent_id: "parent-123"}
      )

      # Test child agent event
      dispatcher.dispatch(
        :agent_execution,
        {action: "execute_subtask"},
        correlation_context: {agent_level: "child", parent_id: "parent-123"}
      )

      expect(parent_agent_observer).to have_received(:update)
      expect(child_agent_observer).to have_received(:update)
    end

    it "supports workflow stage filtering" do
      planning_observer = double("PlanningObserver")
      execution_observer = double("ExecutionObserver")

      allow(planning_observer).to receive(:update)
      allow(execution_observer).to receive(:update)

      dispatcher.add_filter(:planning_stage) do |event|
        event[:correlation_context][:workflow_stage] == "planning"
      end

      dispatcher.add_observer(planning_observer)

      # This should pass the filter
      dispatcher.dispatch(
        :task_analysis,
        {complexity: "high"},
        correlation_context: {workflow_stage: "planning"}
      )

      # This should be filtered out
      dispatcher.dispatch(
        :task_execution,
        {progress: 50},
        correlation_context: {workflow_stage: "execution"}
      )

      expect(planning_observer).to have_received(:update).once
    end
  end

  describe "Performance Specialist requirements" do
    it "processes events without blocking" do
      slow_observer = double("SlowObserver")
      fast_observer = double("FastObserver")

      allow(slow_observer).to receive(:update) do
        sleep(0.01) # Simulate slow observer
      end
      allow(fast_observer).to receive(:update)

      dispatcher.add_observer(slow_observer)
      dispatcher.add_observer(fast_observer)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      dispatcher.dispatch(:performance_test, {})
      processing_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      # Even with slow observer, dispatching should be fast
      # (actual async processing would happen separately).
      # The bound is deliberately loose: this guards against pathological
      # blocking, not scheduler jitter on a loaded CI box.
      expect(processing_time).to be < 0.5
      expect(slow_observer).to have_received(:update)
      expect(fast_observer).to have_received(:update)
    end

    it "maintains performance metrics" do
      dispatcher.add_observer(mock_observer)

      10.times { dispatcher.dispatch(:metrics_test, {data: rand(100)}) }

      stats = dispatcher.statistics
      expect(stats[:events_processed]).to eq(10)
      expect(stats[:average_processing_time]).to be >= 0
      expect(stats[:buffer_utilization]).to be_between(0.0, 1.0)
    end
  end
end
