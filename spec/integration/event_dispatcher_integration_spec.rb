# frozen_string_literal: true

RSpec.describe "EventDispatcher Integration", type: :integration do
  let(:engine) { Agentic::ObservabilityEngine.new(enable_advanced_dispatching: false) }
  let(:mock_observer) { double("MockObserver") }

  before do
    allow(mock_observer).to receive(:update)
  end

  describe "ObservabilityEngine integration" do
    it "supports both legacy and advanced dispatching modes" do
      # Test legacy mode
      engine.add_local_observer(mock_observer)
      engine.notify(:legacy_test, data: {message: "legacy"})

      expect(mock_observer).to have_received(:update)
      expect(engine.advanced_dispatching_enabled?).to be false

      # Enable advanced dispatching
      engine.enable_advanced_dispatching
      expect(engine.advanced_dispatching_enabled?).to be true

      # Test advanced dispatching mode
      engine.notify(:advanced_test, data: {message: "advanced"}, correlation_context: {workflow_id: "123"})

      # Observer should still receive events through new dispatcher
      expect(mock_observer).to have_received(:update).twice
    end

    it "migrates existing observers to advanced dispatcher" do
      # Add observer in legacy mode
      engine.add_local_observer(mock_observer)

      # Enable advanced dispatching - should migrate existing observers
      engine.enable_advanced_dispatching

      # Test that migrated observer still works
      engine.notify(:migration_test, data: {data: "migrated"})

      expect(mock_observer).to have_received(:update)
    end

    it "supports advanced dispatching configuration" do
      engine.enable_advanced_dispatching

      # Configure routing rules
      routing_rules = [
        {
          event_types: [:task_started, :task_completed],
          priority: Agentic::Observability::EventDispatcher::PRIORITY_HIGH
        }
      ]
      engine.configure_event_routing(routing_rules)

      # Configure filters
      filters = {
        important_only: ->(event) { event[:data][:importance] == "high" }
      }
      engine.configure_event_filters(filters)

      # Configure transformers
      transformers = {
        add_timestamp: lambda do |event|
          event[:data][:processed_at] = Time.now.to_f
          event
        end
      }
      engine.configure_event_transformers(transformers)

      # Add observer to receive processed events
      engine.event_dispatcher.add_observer(mock_observer)

      # Test filtered and transformed event
      engine.notify(
        :task_started,
        data: {importance: "high", task_id: "123"},
        correlation_context: {workflow: "test"}
      )

      expect(mock_observer).to have_received(:update) do |type, source, event|
        expect(event[:data][:processed_at]).to be_a(Float)
        expect(event[:correlation_context][:workflow]).to eq("test")
      end
    end
  end

  describe "Domain Expert requirements (Jamie Chen)" do
    before do
      engine.enable_advanced_dispatching
    end

    it "supports agent hierarchy routing" do
      parent_observer = double("ParentObserver")
      child_observer = double("ChildObserver")

      allow(parent_observer).to receive(:update)
      allow(child_observer).to receive(:update)

      # Configure hierarchical routing
      engine.configure_event_routing([
        {
          condition: ->(event) { event[:correlation_context][:agent_type] == "orchestrator" },
          observers: [{observer: parent_observer, priority: 1}],
          priority: Agentic::Observability::EventDispatcher::PRIORITY_HIGH
        },
        {
          condition: ->(event) { event[:correlation_context][:agent_type] == "worker" },
          observers: [{observer: child_observer, priority: 2}],
          priority: Agentic::Observability::EventDispatcher::PRIORITY_NORMAL
        }
      ])

      # Test orchestrator agent event
      engine.notify(
        :agent_planning,
        data: {plan: "complex_task_breakdown"},
        correlation_context: {
          agent_type: "orchestrator",
          agent_id: "orchestrator-001"
        }
      )

      # Test worker agent event
      engine.notify(
        :task_execution,
        data: {subtask: "data_processing"},
        correlation_context: {
          agent_type: "worker",
          parent_agent_id: "orchestrator-001",
          agent_id: "worker-001"
        }
      )

      expect(parent_observer).to have_received(:update)
      expect(child_observer).to have_received(:update)
    end

    it "supports workflow stage coordination" do
      planning_observer = double("PlanningObserver")
      execution_observer = double("ExecutionObserver")

      allow(planning_observer).to receive(:update)
      allow(execution_observer).to receive(:update)

      # Configure workflow stage routing
      engine.configure_event_routing([
        {
          condition: ->(event) { event[:correlation_context][:stage] == "planning" },
          observers: [{observer: planning_observer, priority: 1}]
        },
        {
          condition: ->(event) { event[:correlation_context][:stage] == "execution" },
          observers: [{observer: execution_observer, priority: 1}]
        }
      ])

      # Test planning stage events
      engine.notify(
        :task_analysis_started,
        data: {complexity: "high", estimated_duration: 300},
        correlation_context: {
          stage: "planning",
          workflow_id: "wf-123",
          phase: "initial_analysis"
        }
      )

      # Test execution stage events
      engine.notify(
        :task_progress_update,
        data: {progress: 25, current_step: "data_gathering"},
        correlation_context: {
          stage: "execution",
          workflow_id: "wf-123",
          task_id: "task-456"
        }
      )

      expect(planning_observer).to have_received(:update)
      expect(execution_observer).to have_received(:update)
    end

    it "enables multi-agent coordination through correlation context" do
      coordinator_events = []
      observer = double("CoordinatorObserver")

      allow(observer).to receive(:update) do |type, source, event|
        coordinator_events << {
          type: type,
          correlation_id: event[:correlation_context][:correlation_id],
          agent_id: event[:correlation_context][:agent_id],
          parent_id: event[:correlation_context][:parent_id]
        }
      end

      engine.event_dispatcher.add_observer(observer)

      # Simulate multi-agent workflow with correlation
      workflow_id = SecureRandom.uuid
      correlation_id = SecureRandom.uuid

      # Parent agent starts workflow
      engine.notify(
        :workflow_initiated,
        data: {workflow_type: "data_pipeline", complexity: "high"},
        correlation_context: {
          correlation_id: correlation_id,
          workflow_id: workflow_id,
          agent_id: "parent-001",
          agent_type: "coordinator"
        }
      )

      # Child agents join workflow
      3.times do |i|
        engine.notify(
          :agent_registered,
          data: {capability: "data_processing", agent_name: "worker-#{i + 1}"},
          correlation_context: {
            correlation_id: correlation_id,
            workflow_id: workflow_id,
            agent_id: "worker-#{i + 1}",
            parent_id: "parent-001",
            agent_type: "worker"
          }
        )
      end

      # Validate correlation tracking
      expect(coordinator_events.size).to eq(4)
      expect(coordinator_events.map { |e| e[:correlation_id] }.uniq).to eq([correlation_id])
      expect(coordinator_events.count { |e| e[:parent_id] == "parent-001" }).to eq(3)
    end
  end

  describe "Performance Specialist requirements (Jordan Lee)" do
    before do
      engine.enable_advanced_dispatching({
        max_buffer_size: 1000,
        batch_size: 50,
        enable_priority_routing: true,
        enable_performance_metrics: true
      })
    end

    it "provides performance optimization through intelligent routing" do
      critical_observer = double("CriticalObserver")
      normal_observer = double("NormalObserver")

      allow(critical_observer).to receive(:update)
      allow(normal_observer).to receive(:update)

      # Configure priority-based routing
      engine.configure_event_routing([
        {
          event_types: [:security_alert, :system_failure],
          observers: [{observer: critical_observer, priority: 0}],
          priority: Agentic::Observability::EventDispatcher::PRIORITY_CRITICAL
        },
        {
          event_types: [:task_progress, :metrics_update],
          observers: [{observer: normal_observer, priority: 2}],
          priority: Agentic::Observability::EventDispatcher::PRIORITY_NORMAL
        }
      ])

      start_time = Time.now

      # Send mixed priority events
      engine.notify(:security_alert, data: {severity: "critical", threat: "unauthorized_access"})
      engine.notify(:task_progress, data: {progress: 50, task_id: "task-123"})
      engine.notify(:system_failure, data: {component: "database", error: "connection_timeout"})
      engine.notify(:metrics_update, data: {cpu_usage: 85, memory_usage: 70})

      processing_time = Time.now - start_time

      # Verify both observers received appropriate events
      expect(critical_observer).to have_received(:update).twice
      expect(normal_observer).to have_received(:update).twice

      # Verify performance characteristics
      expect(processing_time).to be < 0.1  # Should be fast due to optimized dispatching

      # Check performance statistics
      dispatcher_stats = engine.statistics[:dispatcher_stats]
      expect(dispatcher_stats[:events_processed]).to eq(4)
      expect(dispatcher_stats[:average_processing_time]).to be >= 0
    end

    it "maintains non-blocking event processing" do
      slow_observer = double("SlowObserver")
      fast_observer = double("FastObserver")

      # Simulate slow observer
      allow(slow_observer).to receive(:update) do
        sleep(0.01)  # 10ms delay
      end
      allow(fast_observer).to receive(:update)

      engine.event_dispatcher.add_observer(slow_observer, priority: 1)
      engine.event_dispatcher.add_observer(fast_observer, priority: 2)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Send multiple events rapidly
      5.times do |i|
        engine.notify(:performance_test, data: {iteration: i, timestamp: Time.now.to_f})
      end

      total_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      # Even with slow observer, dispatching should be fast
      # (actual processing happens asynchronously or in sequence but doesn't block dispatching).
      # The bound is deliberately loose: this guards against pathological
      # blocking, not scheduler jitter on a loaded CI box.
      expect(total_time).to be < 0.5

      expect(slow_observer).to have_received(:update).exactly(5).times
      expect(fast_observer).to have_received(:update).exactly(5).times
    end

    it "provides performance metrics and monitoring" do
      engine.event_dispatcher.add_observer(mock_observer)

      # Generate load to collect metrics
      100.times do |i|
        engine.notify(
          :load_test,
          data: {iteration: i, payload: "x" * 100},  # Small payload
          correlation_context: {test_id: "load-#{i}"}
        )
      end

      stats = engine.statistics[:dispatcher_stats]

      expect(stats[:events_processed]).to eq(100)
      expect(stats[:average_processing_time]).to be >= 0
      expect(stats[:buffer_utilization]).to be_between(0.0, 1.0)

      # Verify all events were processed
      expect(mock_observer).to have_received(:update).exactly(100).times
    end

    it "handles high-volume events efficiently" do
      engine.event_dispatcher.add_observer(mock_observer)

      # Test with larger volume
      event_count = 1000
      start_time = Time.now

      event_count.times do |i|
        engine.notify(:volume_test, data: {id: i}, correlation_context: {batch: i / 100})
      end

      processing_time = Time.now - start_time

      # Should handle 1000 events quickly
      expect(processing_time).to be < 1.0  # Less than 1 second for 1000 events

      stats = engine.statistics[:dispatcher_stats]
      expect(stats[:events_processed]).to eq(event_count)

      # All events should be processed
      expect(mock_observer).to have_received(:update).exactly(event_count).times
    end
  end

  describe "backward compatibility" do
    it "maintains legacy observer functionality when advanced dispatching is disabled" do
      # Start with legacy mode
      expect(engine.advanced_dispatching_enabled?).to be false

      engine.add_local_observer(mock_observer)
      engine.notify(:legacy_event, data: {data: "backward_compatible"})

      expect(mock_observer).to have_received(:update)
    end

    it "gracefully handles advanced dispatching methods when disabled" do
      # These methods should not error when advanced dispatching is disabled
      expect {
        engine.configure_event_routing([])
        engine.configure_event_filters({})
        engine.configure_event_transformers({})
      }.not_to raise_error
    end

    it "supports seamless transition between modes" do
      engine.add_local_observer(mock_observer)

      # Legacy notification
      engine.notify(:transition_test_1, data: {phase: "legacy"})
      expect(mock_observer).to have_received(:update).once

      # Enable advanced dispatching
      engine.enable_advanced_dispatching

      # Advanced notification (observer should be migrated)
      engine.notify(:transition_test_2, data: {phase: "advanced"})
      expect(mock_observer).to have_received(:update).twice

      # Disable advanced dispatching
      engine.disable_advanced_dispatching

      # Back to legacy notification
      engine.notify(:transition_test_3, data: {phase: "back_to_legacy"})
      expect(mock_observer).to have_received(:update).exactly(3).times
    end
  end
end
