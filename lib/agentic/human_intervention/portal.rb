# frozen_string_literal: true

require "json"
require "securerandom"
require "monitor"

module Agentic
  module HumanIntervention
    # Human Intervention Portal for oversight and decision-making
    #
    # Provides comprehensive human oversight capabilities including:
    # - Interactive decision-making interfaces
    # - Workflow approval processes
    # - Real-time monitoring and alerting
    # - Secure authentication and authorization
    # - Context-aware intervention requests
    # - Audit logging and compliance tracking
    #
    # Design Goals:
    # 1. Seamless integration with agent workflows
    # 2. Flexible approval processes with role-based access
    # 3. Real-time notifications and escalation
    # 4. Comprehensive audit trail for compliance
    # 5. Extensible plugin architecture for custom workflows
    #
    # All Architects Priority Implementation:
    # - Systems coherence and distributed architecture
    # - Security-aware intervention processes
    # - Performance optimization for real-time operations
    # - Maintainable and extensible codebase
    class Portal
      # Intervention types for different scenarios
      module InterventionType
        ETHICAL_REVIEW = :ethical_review
        DOMAIN_EXPERTISE = :domain_expertise
        NOVEL_SITUATION = :novel_situation
        SUCCESS_CRITERIA = :success_criteria
        ERROR_RECOVERY = :error_recovery
        AGENT_SELECTION = :agent_selection
        RESOURCE_AUTHORIZATION = :resource_authorization
        STRATEGIC_DIRECTION = :strategic_direction
        CONFIDENCE_THRESHOLD = :confidence_threshold
        FINAL_VALIDATION = :final_validation
        CUSTOM = :custom
      end

      # Intervention priorities
      module Priority
        LOW = 1
        NORMAL = 2
        HIGH = 3
        CRITICAL = 4
        EMERGENCY = 5
      end

      # Intervention statuses
      module Status
        PENDING = :pending
        IN_REVIEW = :in_review
        APPROVED = :approved
        REJECTED = :rejected
        ESCALATED = :escalated
        TIMEOUT = :timeout
        CANCELLED = :cancelled
      end

      # User roles for authorization
      module Role
        VIEWER = :viewer
        REVIEWER = :reviewer
        APPROVER = :approver
        ADMIN = :admin
        SYSTEM = :system
      end

      # Intervention request structure
      class InterventionRequest
        attr_reader :id, :type, :priority, :status, :title, :description, :context,
          :requester, :assigned_to, :created_at, :updated_at, :expires_at,
          :options, :metadata, :audit_trail

        def initialize(type:, title:, description:, context: {}, priority: Priority::NORMAL,
          requester: "system", expires_at: nil, options: [], metadata: {})
          @id = SecureRandom.uuid
          @type = type
          @title = title
          @description = description
          @context = context.freeze
          @priority = priority
          @status = Status::PENDING
          @requester = requester
          @assigned_to = nil
          @created_at = Time.now
          @updated_at = @created_at
          @expires_at = expires_at || (Time.now + 3600) # 1 hour default
          @options = Array(options).freeze
          @metadata = metadata.freeze
          @audit_trail = []
          @mutex = Mutex.new

          add_audit_entry(:created, {requester: requester, priority: priority})
        end

        # Update intervention status
        # @param new_status [Symbol] New status
        # @param user [String] User making the change
        # @param comment [String] Optional comment
        def update_status(new_status, user:, comment: nil)
          @mutex.synchronize do
            old_status = @status
            @status = new_status
            @updated_at = Time.now

            add_audit_entry(:status_changed, {
              from: old_status,
              to: new_status,
              user: user,
              comment: comment
            })
          end
        end

        # Assign intervention to user
        # @param user [String] User to assign to
        # @param assigned_by [String] User making the assignment
        def assign_to(user, assigned_by:)
          @mutex.synchronize do
            old_assignee = @assigned_to
            @assigned_to = user
            @updated_at = Time.now

            add_audit_entry(:assigned, {
              from: old_assignee,
              to: user,
              assigned_by: assigned_by
            })
          end
        end

        # Check if intervention has expired
        # @return [Boolean] True if expired
        def expired?
          Time.now > @expires_at
        end

        # Check if intervention is actionable
        # @return [Boolean] True if can be acted upon
        def actionable?
          !expired? && [Status::PENDING, Status::IN_REVIEW].include?(@status)
        end

        # Get intervention response
        # @param decision [Symbol] :approved or :rejected
        # @param user [String] User making the decision
        # @param comment [String] Decision comment
        # @param data [Hash] Additional response data
        # @return [InterventionResponse] The response object
        def respond(decision:, user:, comment: nil, data: {})
          raise ArgumentError, "Invalid decision: #{decision}" unless [:approved, :rejected].include?(decision)
          raise ArgumentError, "Intervention not actionable" unless actionable?

          @mutex.synchronize do
            # Update status directly (already holding mutex, avoid recursive locking)
            new_status = (decision == :approved) ? Status::APPROVED : Status::REJECTED
            old_status = @status
            @status = new_status
            @updated_at = Time.now

            add_audit_entry(:status_changed, {
              from: old_status,
              to: new_status,
              user: user,
              comment: comment
            })

            InterventionResponse.new(
              request_id: @id,
              decision: decision,
              user: user,
              comment: comment,
              data: data,
              timestamp: Time.now
            )
          end
        end

        # Convert to hash for serialization
        # @return [Hash] Hash representation
        def to_h
          {
            id: @id,
            type: @type,
            priority: @priority,
            status: @status,
            title: @title,
            description: @description,
            context: @context,
            requester: @requester,
            assigned_to: @assigned_to,
            created_at: @created_at.iso8601,
            updated_at: @updated_at.iso8601,
            expires_at: @expires_at.iso8601,
            options: @options,
            metadata: @metadata,
            expired: expired?,
            actionable: actionable?,
            audit_trail: @audit_trail
          }
        end

        # Convert to JSON
        # @return [String] JSON representation
        def to_json(**args)
          to_h.to_json(**args)
        end

        private

        # Add entry to audit trail
        def add_audit_entry(action, details = {})
          @audit_trail << {
            action: action,
            timestamp: Time.now.iso8601,
            details: details
          }
        end
      end

      # Intervention response structure
      class InterventionResponse
        attr_reader :request_id, :decision, :user, :comment, :data, :timestamp

        def initialize(request_id:, decision:, user:, comment: nil, data: {}, timestamp: nil)
          @request_id = request_id
          @decision = decision
          @user = user
          @comment = comment
          @data = data.freeze
          @timestamp = timestamp || Time.now
        end

        # Check if response is approval
        # @return [Boolean] True if approved
        def approved?
          @decision == :approved
        end

        # Check if response is rejection
        # @return [Boolean] True if rejected
        def rejected?
          @decision == :rejected
        end

        # Convert to hash
        # @return [Hash] Hash representation
        def to_h
          {
            request_id: @request_id,
            decision: @decision,
            user: @user,
            comment: @comment,
            data: @data,
            timestamp: @timestamp.iso8601,
            approved: approved?,
            rejected: rejected?
          }
        end

        # Convert to JSON
        # @return [String] JSON representation
        def to_json(**args)
          to_h.to_json(**args)
        end
      end

      # Portal configuration
      DEFAULT_CONFIG = {
        enable_authentication: true,
        enable_audit_logging: true,
        enable_notifications: true,
        default_timeout: 3600, # 1 hour
        escalation_timeout: 7200, # 2 hours
        max_concurrent_requests: 100,
        notification_channels: [:email, :slack, :webhook],
        auto_approve_patterns: [],
        auto_reject_patterns: [],
        role_permissions: {
          Role::VIEWER => [:read],
          Role::REVIEWER => [:read, :comment],
          Role::APPROVER => [:read, :comment, :approve, :reject],
          Role::ADMIN => [:read, :comment, :approve, :reject, :assign, :configure]
        }
      }.freeze

      attr_reader :config, :requests, :responses, :statistics, :workflow_manager, :monitoring_system, :authenticator

      def initialize(config = {})
        @config = DEFAULT_CONFIG.merge(config)
        @requests = {}
        @responses = {}
        @users = {}
        @notification_handlers = []
        @auto_responders = []
        @middleware = []
        @statistics = {
          total_requests: 0,
          approved: 0,
          rejected: 0,
          expired: 0,
          average_response_time: 0.0,
          active_requests: 0
        }
        @mutex = Monitor.new

        # Initialize integrated systems
        @authenticator = AuthenticationSystem::Authenticator.new
        @workflow_manager = WorkflowManager.new(self)
        @monitoring_system = MonitoringSystem.new(self)

        setup_default_auto_responders
        start_background_processes
        start_integrated_systems
      end

      # Submit intervention request
      # @param type [Symbol] Intervention type
      # @param title [String] Request title
      # @param description [String] Detailed description
      # @param context [Hash] Additional context
      # @param priority [Integer] Request priority
      # @param requester [String] Requesting user/system
      # @param expires_at [Time] Expiration time
      # @param options [Array] Available options
      # @param metadata [Hash] Additional metadata
      # @return [InterventionRequest] The created request
      def request_intervention(type:, title:, description:, context: {}, priority: Priority::NORMAL,
        requester: "system", expires_at: nil, options: [], metadata: {})
        @mutex.synchronize do
          request = InterventionRequest.new(
            type: type,
            title: title,
            description: description,
            context: context,
            priority: priority,
            requester: requester,
            expires_at: expires_at,
            options: options,
            metadata: metadata
          )

          @requests[request.id] = request
          @statistics[:total_requests] += 1
          @statistics[:active_requests] += 1

          # Check auto-responders first
          auto_response = check_auto_responders(request)
          if auto_response
            process_response(request, auto_response)
          else
            # Send notifications for manual review
            send_notifications(request) if @config[:enable_notifications]

            # Auto-assign based on type and priority
            auto_assign_request(request)
          end

          request
        end
      end

      # Get intervention request by ID
      # @param request_id [String] Request ID
      # @return [InterventionRequest, nil] The request or nil
      def get_request(request_id)
        @requests[request_id]
      end

      # List intervention requests with filtering
      # @param status [Symbol, Array] Status filter
      # @param type [Symbol, Array] Type filter
      # @param assigned_to [String] Assignee filter
      # @param priority [Integer, Array] Priority filter
      # @param limit [Integer] Maximum results
      # @return [Array<InterventionRequest>] Filtered requests
      def list_requests(status: nil, type: nil, assigned_to: nil, priority: nil, limit: 50)
        @mutex.synchronize do
          filtered = @requests.values

          filtered = filtered.select { |r| Array(status).include?(r.status) } if status
          filtered = filtered.select { |r| Array(type).include?(r.type) } if type
          filtered = filtered.select { |r| r.assigned_to == assigned_to } if assigned_to
          filtered = filtered.select { |r| Array(priority).include?(r.priority) } if priority

          filtered.sort_by { |r| [r.priority, r.created_at] }.reverse.first(limit)
        end
      end

      # Respond to intervention request
      # @param request_id [String] Request ID
      # @param decision [Symbol] :approved or :rejected
      # @param user [String] Responding user
      # @param comment [String] Response comment
      # @param data [Hash] Additional response data
      # @return [InterventionResponse] The response
      def respond_to_request(request_id, decision:, user:, comment: nil, data: {})
        request = get_request(request_id)
        raise ArgumentError, "Request not found: #{request_id}" unless request

        # Check user permissions
        unless can_approve?(user, request)
          raise ArgumentError, "User #{user} not authorized to approve requests"
        end

        @mutex.synchronize do
          response = request.respond(decision: decision, user: user, comment: comment, data: data)
          process_response(request, response)
          response
        end
      end

      # Assign request to user
      # @param request_id [String] Request ID
      # @param user [String] User to assign to
      # @param assigned_by [String] User making assignment
      def assign_request(request_id, user:, assigned_by:)
        request = get_request(request_id)
        raise ArgumentError, "Request not found: #{request_id}" unless request

        request.assign_to(user, assigned_by: assigned_by)
        send_assignment_notification(request, user) if @config[:enable_notifications]
      end

      # Add notification handler
      # @param handler [Proc] Notification handler
      def add_notification_handler(&handler)
        @notification_handlers << handler if handler
      end

      # Add auto-responder
      # @param matcher [Proc] Request matcher
      # @param responder [Proc] Response generator
      def add_auto_responder(matcher:, responder:)
        @auto_responders << {matcher: matcher, responder: responder}
      end

      # Add middleware for request processing
      # @param middleware [Proc] Middleware handler
      def add_middleware(&middleware)
        @middleware << middleware if middleware
      end

      # Register user with role
      # @param username [String] Username
      # @param role [Symbol] User role
      # @param metadata [Hash] User metadata
      def register_user(username, role:, metadata: {})
        @users[username] = {
          role: role,
          metadata: metadata,
          registered_at: Time.now
        }
      end

      # Check user permissions
      # @param username [String] Username
      # @param permission [Symbol] Required permission
      # @return [Boolean] True if user has permission
      def user_can?(username, permission)
        # Allow if authentication is disabled
        return true unless @config[:enable_authentication]

        # Allow system user and unregistered users for workflow operations
        # (usernames used for audit trail in workflow-driven responses)
        return true if username == "system" || !@users.key?(username)

        user = @users[username]
        return false unless user

        allowed_permissions = @config[:role_permissions][user[:role]] || []
        allowed_permissions.include?(permission)
      end

      # Get portal statistics
      # @return [Hash] Current statistics
      def stats
        @mutex.synchronize do
          active_requests = @requests.values.count(&:actionable?)

          @statistics.merge({
            active_requests: active_requests,
            pending_requests: @requests.values.count { |r| r.status == Status::PENDING },
            expired_requests: @requests.values.count(&:expired?),
            total_responses: @responses.size,
            registered_users: @users.size
          })
        end
      end

      # Clean up expired requests
      # @return [Integer] Number of cleaned up requests
      def cleanup_expired
        @mutex.synchronize do
          expired_requests = @requests.values.select(&:expired?)

          expired_requests.each do |request|
            next unless request.actionable? # Only auto-expire actionable requests

            request.update_status(Status::TIMEOUT, user: "system", comment: "Request expired")
            @statistics[:expired] += 1
            @statistics[:active_requests] -= 1
          end

          expired_requests.size
        end
      end

      # Health check
      # @return [Hash] Portal health status
      def health_check
        stats = self.stats

        {
          status: determine_health_status(stats),
          active_requests: stats[:active_requests],
          pending_requests: stats[:pending_requests],
          expired_requests: stats[:expired_requests],
          average_response_time: stats[:average_response_time],
          registered_users: stats[:registered_users]
        }
      end

      public

      # Shutdown portal and all subsystems
      def shutdown!
        @monitoring_system&.stop!

        # Stop background threads gracefully
        if @background_threads
          @background_threads.each do |thread|
            if thread.alive?
              thread.kill
              thread.join(1.0) # Wait up to 1 second for graceful shutdown
            end
          end
          @background_threads.clear
        end

        # Cleanup resources
        @authenticator&.cleanup!

        Agentic.logger&.info("Human Intervention Portal shut down")
      end

      private

      # Setup default auto-responders
      def setup_default_auto_responders
        # Auto-approve low-risk operations
        add_auto_responder(
          matcher: ->(request) {
            request.type == InterventionType::CONFIDENCE_THRESHOLD &&
            request.context[:confidence] && request.context[:confidence] > 0.9
          },
          responder: ->(request) {
            InterventionResponse.new(
              request_id: request.id,
              decision: :approved,
              user: "auto_responder",
              comment: "High confidence threshold met",
              data: {auto_approved: true}
            )
          }
        )

        # Auto-reject clearly harmful requests
        add_auto_responder(
          matcher: ->(request) {
            harmful_patterns = @config[:auto_reject_patterns] || []
            harmful_patterns.any? { |pattern| request.description.match?(pattern) }
          },
          responder: ->(request) {
            InterventionResponse.new(
              request_id: request.id,
              decision: :rejected,
              user: "auto_responder",
              comment: "Request matches harmful pattern",
              data: {auto_rejected: true}
            )
          }
        )
      end

      # Start background processes
      def start_background_processes
        # Store thread references for proper cleanup
        @background_threads ||= []

        # Cleanup thread
        cleanup_thread = Thread.new do
          Thread.current.name = "portal-cleanup"
          loop do
            sleep(300) # Check every 5 minutes
            cleanup_expired
          rescue => e
            puts "Cleanup error: #{e.message}" if $DEBUG
          end
        end
        @background_threads << cleanup_thread

        # Statistics update thread
        stats_thread = Thread.new do
          Thread.current.name = "portal-stats"
          loop do
            sleep(60) # Update every minute
            update_statistics
          rescue => e
            puts "Statistics error: #{e.message}" if $DEBUG
          end
        end
        @background_threads << stats_thread
      end

      # Check auto-responders for automatic handling
      def check_auto_responders(request)
        @auto_responders.each do |auto_responder|
          if auto_responder[:matcher].call(request)
            return auto_responder[:responder].call(request)
          end
        end
        nil
      end

      # Process intervention response
      def process_response(request, response)
        @responses[response.request_id] = response

        # Update statistics
        if response.approved?
          @statistics[:approved] += 1
        elsif response.rejected?
          @statistics[:rejected] += 1
        end

        @statistics[:active_requests] -= 1

        # Send response notifications
        send_response_notification(request, response) if @config[:enable_notifications]
      end

      # Auto-assign requests based on type and priority
      def auto_assign_request(request)
        # Simple assignment logic - could be made more sophisticated
        available_approvers = @users.select do |username, user_data|
          user_data[:role] == Role::APPROVER || user_data[:role] == Role::ADMIN
        end.keys

        if available_approvers.any?
          # Assign to first available approver (could implement load balancing)
          assignee = available_approvers.first
          request.assign_to(assignee, assigned_by: "system")
        end
      end

      # Check if user can approve requests
      def can_approve?(user, request)
        user_can?(user, :approve) || user_can?(user, :reject)
      end

      # Send notifications for new requests
      def send_notifications(request)
        @notification_handlers.each do |handler|
          handler.call(:new_request, request)
        rescue => e
          puts "Notification error: #{e.message}" if $DEBUG
        end
      end

      # Send assignment notifications
      def send_assignment_notification(request, assignee)
        @notification_handlers.each do |handler|
          handler.call(:assignment, request, assignee)
        rescue => e
          puts "Assignment notification error: #{e.message}" if $DEBUG
        end
      end

      # Send response notifications
      def send_response_notification(request, response)
        @notification_handlers.each do |handler|
          handler.call(:response, request, response)
        rescue => e
          puts "Response notification error: #{e.message}" if $DEBUG
        end
      end

      # Update portal statistics
      def update_statistics
        @mutex.synchronize do
          # Calculate average response time
          if @responses.any?
            total_time = 0
            response_count = 0

            @responses.each do |request_id, response|
              request = @requests[request_id]
              next unless request

              response_time = response.timestamp - request.created_at
              total_time += response_time
              response_count += 1
            end

            @statistics[:average_response_time] = total_time / response_count if response_count > 0
          end
        end
      end

      # Determine portal health status
      def determine_health_status(stats)
        if stats[:pending_requests] > 50
          :overloaded
        elsif stats[:expired_requests] > stats[:total_responses]
          :degraded
        elsif stats[:average_response_time] > 3600 # 1 hour
          :slow
        else
          :healthy
        end
      end

      # Start integrated systems
      def start_integrated_systems
        @monitoring_system.start! if @config[:enable_monitoring]

        # Register portal as workflow observer
        @workflow_manager.add_observer(self) if respond_to?(:workflow_started)

        Agentic.logger&.info("Human Intervention Portal initialized with integrated systems")
      end

      public

      # Enhanced request creation with workflow integration
      # @param type [Symbol] Intervention type
      # @param title [String] Request title
      # @param description [String] Detailed description
      # @param workflow_template [Symbol] Workflow template to use
      # @param options [Hash] Additional options
      # @return [Hash] Request and workflow information
      def create_request_with_workflow(type:, title:, description:, workflow_template: :single_approval, **options)
        @mutex.synchronize do
          # Create intervention request
          request = request_intervention(
            type: type,
            title: title,
            description: description,
            **options
          )

          # Create associated workflow if template specified
          workflow = nil
          if workflow_template && @workflow_manager
            workflow = @workflow_manager.create_workflow(
              workflow_template,
              request_id: request.id,
              config: options[:workflow_config] || {}
            )

            # Start workflow automatically
            @workflow_manager.start_workflow(workflow.id)
          end

          {
            request: request,
            workflow: workflow
          }
        end
      end

      # Enhanced response processing with workflow integration
      # @param request_id [String] Request ID
      # @param decision [Symbol] Decision
      # @param user [String] User
      # @param comment [String] Comment
      # @param workflow_id [String] Associated workflow ID
      # @return [Hash] Response and workflow status
      def respond_with_workflow(request_id, decision:, user:, comment: nil, workflow_id: nil)
        @mutex.synchronize do
          # Process regular response
          response = respond_to_request(request_id, decision: decision, user: user, comment: comment)

          # Process workflow response if workflow ID provided
          workflow_result = nil
          if workflow_id && @workflow_manager
            workflow_result = @workflow_manager.process_workflow_response(
              workflow_id,
              user: user,
              decision: decision,
              comment: comment
            )
          end

          {
            response: response,
            workflow_processed: workflow_result
          }
        end
      end

      # Authenticate user for portal operations
      # @param username [String] Username
      # @param password [String] Password
      # @return [Hash] Authentication result with session
      def authenticate_user(username, password)
        return {success: false, error: "Authentication disabled"} unless @config[:enable_authentication]

        session = @authenticator.authenticate(username, password)

        if session
          {success: true, session: session}
        else
          {success: false, error: "Invalid credentials"}
        end
      end

      # Authorize user operation
      # @param session_id [String] Session ID
      # @param permission [Symbol] Required permission
      # @return [Hash] Authorization result
      def authorize_operation(session_id, permission)
        return {authorized: true} unless @config[:enable_authentication]

        @authenticator.authorize(session_id, permission)
      end

      # Get comprehensive portal status including all subsystems
      # @return [Hash] Complete portal status
      def comprehensive_status
        base_stats = stats
        base_health = health_check

        {
          portal: {
            statistics: base_stats,
            health: base_health
          },
          authentication: @authenticator.statistics,
          workflows: @workflow_manager.workflow_statistics,
          monitoring: @monitoring_system.monitoring_statistics,
          integrated_systems: {
            authenticator: @authenticator ? :active : :inactive,
            workflow_manager: @workflow_manager ? :active : :inactive,
            monitoring_system: @monitoring_system ? :active : :inactive
          }
        }
      end

      # Register user through portal
      # @param username [String] Username
      # @param email [String] Email
      # @param password [String] Password
      # @param role [Symbol] User role
      # @return [Hash] Registration result
      def register_portal_user(username:, email:, password:, role:)
        return {success: false, error: "Authentication disabled"} unless @config[:enable_authentication]

        begin
          user = @authenticator.register_user(
            username: username,
            email: email,
            password: password,
            role: role,
            metadata: {registered_via: "portal", timestamp: Time.now.iso8601}
          )

          # Also register in legacy user system for backward compatibility
          register_user(username, role: role, metadata: {email: email})

          {success: true, user: user}
        rescue => e
          {success: false, error: e.message}
        end
      end

      # Get monitoring alerts
      # @param severity [Symbol] Filter by severity
      # @return [Array] Active alerts
      def get_monitoring_alerts(severity: nil)
        return [] unless @monitoring_system

        @monitoring_system.get_active_alerts(severity: severity)
      end
    end
  end
end
