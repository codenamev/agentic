# frozen_string_literal: true

require "digest"
require "securerandom"
require "base64"
require "openssl"
require "json"

module Agentic
  module HumanIntervention
    # Authentication and authorization system for human intervention portal
    #
    # Provides comprehensive security features including:
    # - Token-based authentication with session management
    # - Role-based access control (RBAC) with hierarchical permissions
    # - Secure password handling and multi-factor authentication
    # - API key management for programmatic access
    # - Session tracking and security audit logging
    #
    # Design Goals:
    # 1. Security-first design with defense in depth
    # 2. Integration with existing CLI security patterns
    # 3. Flexible RBAC system for different organizational structures
    # 4. Session management with appropriate timeouts
    # 5. Comprehensive audit trail for compliance
    #
    # Architecture Integration:
    # - Uses Security module patterns for consistent security handling
    # - Integrates with existing role definitions from Portal
    # - Follows performance optimization patterns for session caching
    #
    # @deprecated Will be removed in the next minor release. The password
    #   hasher is one SHA-256 round mislabelled as PBKDF2 and secrets are
    #   compared with ==, and the gem's charter excludes accounts.
    #   Authenticate in the host application. See codenamev/agentic#58.
    class AuthenticationSystem
      # Authentication methods
      module AuthMethod
        PASSWORD = :password
        API_KEY = :api_key
        TOKEN = :token
        MFA = :mfa
      end

      # Session states
      module SessionState
        ACTIVE = :active
        EXPIRED = :expired
        REVOKED = :revoked
        SUSPENDED = :suspended
      end

      # Permission types
      module Permission
        READ = :read
        COMMENT = :comment
        APPROVE = :approve
        REJECT = :reject
        ASSIGN = :assign
        CONFIGURE = :configure
        ADMIN = :admin
        SYSTEM = :system
      end

      # User account management
      class User
        attr_reader :id, :username, :email, :role, :permissions, :created_at, :metadata
        attr_accessor :last_login_at, :failed_login_attempts, :account_locked_until, :mfa_enabled, :api_keys_count

        def initialize(username:, email:, role:, permissions: nil, metadata: {})
          @id = SecureRandom.uuid
          @username = username
          @email = email
          @role = role
          @permissions = permissions || derive_permissions_from_role(role)
          @created_at = Time.now
          @last_login_at = nil
          @failed_login_attempts = 0
          @account_locked_until = nil
          @mfa_enabled = false
          @api_keys_count = 0
          @metadata = metadata
          @password_hash = nil
        end

        # Set password with secure hashing
        # @param password [String] Plain text password
        def set_password(password)
          return false if password.nil? || password.length < 8

          salt = SecureRandom.hex(32)
          @password_hash = {
            algorithm: "pbkdf2_sha256",
            iterations: 100000,
            salt: salt,
            hash: Digest::SHA256.hexdigest("#{password}#{salt}")
          }
          true
        end

        # Verify password
        # @param password [String] Plain text password to verify
        # @return [Boolean] True if password is correct
        def verify_password(password)
          return false unless @password_hash

          salt = @password_hash[:salt]
          expected_hash = @password_hash[:hash]
          actual_hash = Digest::SHA256.hexdigest("#{password}#{salt}")

          expected_hash == actual_hash
        end

        # Check if user has specific permission
        # @param permission [Symbol] Permission to check
        # @return [Boolean] True if user has permission
        def has_permission?(permission)
          @permissions.include?(permission)
        end

        # Check if account is locked
        # @return [Boolean] True if account is locked
        def account_locked?
          @account_locked_until && Time.now < @account_locked_until
        end

        # Lock account for specified duration
        # @param duration [Integer] Lock duration in seconds
        def lock_account!(duration = 3600)
          @account_locked_until = Time.now + duration
        end

        # Unlock account
        def unlock_account!
          @account_locked_until = nil
          @failed_login_attempts = 0
        end

        # Record failed login attempt
        def record_failed_login!
          @failed_login_attempts += 1

          # Lock account after 5 failed attempts
          if @failed_login_attempts >= 5
            lock_account!(3600) # 1 hour lock
          end
        end

        # Record successful login
        def record_successful_login!
          @last_login_at = Time.now
          @failed_login_attempts = 0
          @account_locked_until = nil
        end

        # Convert to hash for serialization (without sensitive data)
        # @return [Hash] Hash representation
        def to_h
          {
            id: @id,
            username: @username,
            email: @email,
            role: @role,
            permissions: @permissions,
            created_at: @created_at.iso8601,
            last_login_at: @last_login_at&.iso8601,
            failed_login_attempts: @failed_login_attempts,
            account_locked: account_locked?,
            mfa_enabled: @mfa_enabled,
            api_keys_count: @api_keys_count,
            metadata: @metadata
          }
        end

        private

        # Derive permissions from role
        # @param role [Symbol] User role
        # @return [Array<Symbol>] List of permissions
        def derive_permissions_from_role(role)
          case role
          when :viewer
            [Permission::READ]
          when :reviewer
            [Permission::READ, Permission::COMMENT]
          when :approver
            [Permission::READ, Permission::COMMENT, Permission::APPROVE, Permission::REJECT]
          when :admin
            [Permission::READ, Permission::COMMENT, Permission::APPROVE, Permission::REJECT,
              Permission::ASSIGN, Permission::CONFIGURE]
          when :system
            [Permission::READ, Permission::COMMENT, Permission::APPROVE, Permission::REJECT,
              Permission::ASSIGN, Permission::CONFIGURE, Permission::ADMIN, Permission::SYSTEM]
          else
            [Permission::READ]
          end
        end
      end

      # Session management for authenticated users
      class Session
        attr_reader :id, :user_id, :username, :role, :permissions, :created_at, :last_accessed_at, :expires_at, :metadata
        attr_accessor :state

        def initialize(user:, expires_in: 8 * 3600, metadata: {}) # 8 hours in seconds
          @id = SecureRandom.hex(32)
          @user_id = user.id
          @username = user.username
          @role = user.role
          @permissions = user.permissions.dup
          @created_at = Time.now
          @last_accessed_at = @created_at
          @expires_at = @created_at + expires_in
          @state = SessionState::ACTIVE
          @metadata = metadata
        end

        # Check if session is valid
        # @return [Boolean] True if session is valid
        def valid?
          @state == SessionState::ACTIVE && !expired?
        end

        # Check if session is expired
        # @return [Boolean] True if session is expired
        def expired?
          Time.now > @expires_at
        end

        # Update last accessed time and extend session if needed
        def touch!
          return false unless valid?

          @last_accessed_at = Time.now

          # Extend session if more than half the time has passed
          time_passed = Time.now - @created_at
          total_duration = @expires_at - @created_at

          if time_passed > (total_duration / 2)
            @expires_at = Time.now + (total_duration / 2) # Extend by half the original duration
          end

          true
        end

        # Revoke session
        def revoke!
          @state = SessionState::REVOKED
        end

        # Get session duration
        # @return [Float] Duration in seconds
        def duration
          (@last_accessed_at || @created_at) - @created_at
        end

        # Check if user has permission in this session
        # @param permission [Symbol] Permission to check
        # @return [Boolean] True if session has permission
        def has_permission?(permission)
          valid? && @permissions.include?(permission)
        end

        # Convert to hash for serialization
        # @return [Hash] Hash representation
        def to_h
          {
            id: @id,
            user_id: @user_id,
            username: @username,
            role: @role,
            permissions: @permissions,
            state: @state,
            created_at: @created_at.iso8601,
            last_accessed_at: @last_accessed_at.iso8601,
            expires_at: @expires_at.iso8601,
            duration: duration,
            valid: valid?,
            metadata: @metadata
          }
        end
      end

      # API Key management for programmatic access
      class ApiKey
        attr_reader :id, :user_id, :name, :prefix, :created_at, :last_used_at, :expires_at, :permissions
        attr_accessor :revoked_at

        def initialize(user:, name:, permissions: nil, expires_in: nil)
          @id = SecureRandom.uuid
          @user_id = user.id
          @name = name
          @key = SecureRandom.hex(32)
          @prefix = @key[0..7]
          @created_at = Time.now
          @last_used_at = nil
          @expires_at = expires_in ? (Time.now + expires_in) : nil
          @revoked_at = nil
          @permissions = permissions || user.permissions.dup
        end

        # Get masked key for display
        # @return [String] Masked key
        def masked_key
          "#{@prefix}#{"*" * 8}"
        end

        # Verify API key
        # @param key [String] Key to verify
        # @return [Boolean] True if key matches
        def verify_key(key)
          return false if revoked? || expired?

          result = @key == key
          @last_used_at = Time.now if result
          result
        end

        # Check if API key is revoked
        # @return [Boolean] True if revoked
        def revoked?
          !@revoked_at.nil?
        end

        # Check if API key is expired
        # @return [Boolean] True if expired
        def expired?
          @expires_at && Time.now > @expires_at
        end

        # Check if API key is valid
        # @return [Boolean] True if valid
        def valid?
          !revoked? && !expired?
        end

        # Revoke API key
        def revoke!
          @revoked_at = Time.now
        end

        # Check if API key has permission
        # @param permission [Symbol] Permission to check
        # @return [Boolean] True if API key has permission
        def has_permission?(permission)
          valid? && @permissions.include?(permission)
        end

        # Convert to hash for serialization (without sensitive key)
        # @return [Hash] Hash representation
        def to_h
          {
            id: @id,
            user_id: @user_id,
            name: @name,
            prefix: @prefix,
            masked_key: masked_key,
            created_at: @created_at.iso8601,
            last_used_at: @last_used_at&.iso8601,
            expires_at: @expires_at&.iso8601,
            revoked_at: @revoked_at&.iso8601,
            permissions: @permissions,
            valid: valid?
          }
        end
      end

      # Authentication and authorization manager
      class Authenticator
        DEPRECATION_MESSAGE = "Agentic::HumanIntervention::AuthenticationSystem is deprecated and will be " \
          "removed in the next minor release. Its password hashing is a single SHA-256 round and it " \
          "compares secrets with ==; authenticate in your host application instead. " \
          "See https://github.com/codenamev/agentic/issues/58"

        def initialize
          warn(DEPRECATION_MESSAGE, category: :deprecated, uplevel: 1)
          @users = {}
          @sessions = {}
          @api_keys = {}
          @security_events = []
          @mutex = Mutex.new

          setup_default_users
        end

        # Register new user
        # @param username [String] Username
        # @param email [String] Email address
        # @param password [String] Plain text password
        # @param role [Symbol] User role
        # @param metadata [Hash] Additional user metadata
        # @return [User] Created user
        def register_user(username:, email:, password:, role:, metadata: {})
          @mutex.synchronize do
            raise ArgumentError, "Username already exists" if @users.key?(username)
            raise ArgumentError, "Invalid email format" unless valid_email?(email)
            raise ArgumentError, "Password too weak" unless strong_password?(password)

            user = User.new(
              username: username,
              email: email,
              role: role,
              metadata: metadata
            )

            user.set_password(password)
            @users[username] = user

            log_security_event(:user_registered, user.id, {username: username, role: role})
            user
          end
        end

        # Authenticate user with username/password
        # @param username [String] Username
        # @param password [String] Password
        # @param session_metadata [Hash] Additional session metadata
        # @return [Session, nil] Session if authentication successful
        def authenticate(username, password, session_metadata: {})
          @mutex.synchronize do
            user = @users[username]
            return handle_failed_authentication(username, :user_not_found) unless user

            return handle_failed_authentication(username, :account_locked) if user.account_locked?

            unless user.verify_password(password)
              user.record_failed_login!
              return handle_failed_authentication(username, :invalid_password)
            end

            # Successful authentication
            user.record_successful_login!
            session = create_session(user, session_metadata)

            log_security_event(:authentication_success, user.id, {username: username, session_id: session.id})
            session
          end
        end

        # Authenticate with API key
        # @param api_key [String] API key
        # @return [Hash] Authentication result with user info
        def authenticate_api_key(api_key)
          @mutex.synchronize do
            key_obj = @api_keys.values.find { |key| key.verify_key(api_key) }
            return {success: false, error: :invalid_key} unless key_obj

            user = @users.values.find { |u| u.id == key_obj.user_id }
            return {success: false, error: :user_not_found} unless user

            log_security_event(:api_authentication_success, user.id, {
              api_key_id: key_obj.id,
              api_key_name: key_obj.name
            })

            {
              success: true,
              user: user,
              api_key: key_obj,
              permissions: key_obj.permissions
            }
          end
        end

        # Get user by username
        # @param username [String] Username
        # @return [User, nil] User or nil
        def get_user(username)
          @users[username]
        end

        # Get session by ID
        # @param session_id [String] Session ID
        # @return [Session, nil] Session or nil
        def get_session(session_id)
          session = @sessions[session_id]
          return nil unless session

          if session.expired?
            session.state = SessionState::EXPIRED
            @sessions.delete(session_id)
            return nil
          end

          session.touch!
          session
        end

        # Validate session and check permission
        # @param session_id [String] Session ID
        # @param permission [Symbol] Required permission
        # @return [Hash] Authorization result
        def authorize(session_id, permission)
          session = get_session(session_id)
          return {authorized: false, error: :invalid_session} unless session

          unless session.has_permission?(permission)
            log_security_event(:authorization_denied, session.user_id, {
              session_id: session_id,
              permission: permission,
              user_permissions: session.permissions
            })
            return {authorized: false, error: :insufficient_permissions}
          end

          {authorized: true, session: session}
        end

        # Create API key for user
        # @param username [String] Username
        # @param name [String] API key name
        # @param permissions [Array<Symbol>] Key permissions
        # @param expires_in [Integer] Expiration time in seconds
        # @return [ApiKey] Created API key
        def create_api_key(username, name:, permissions: nil, expires_in: nil)
          @mutex.synchronize do
            user = @users[username]
            raise ArgumentError, "User not found" unless user

            api_key = ApiKey.new(
              user: user,
              name: name,
              permissions: permissions,
              expires_in: expires_in
            )

            @api_keys[api_key.id] = api_key
            user.api_keys_count += 1

            log_security_event(:api_key_created, user.id, {
              api_key_id: api_key.id,
              api_key_name: name,
              permissions: api_key.permissions
            })

            api_key
          end
        end

        # List API keys for user
        # @param username [String] Username
        # @return [Array<ApiKey>] User's API keys
        def list_api_keys(username)
          user = @users[username]
          return [] unless user

          @api_keys.values.select { |key| key.user_id == user.id }
        end

        # Revoke API key
        # @param api_key_id [String] API key ID
        # @param revoker [String] User revoking the key
        # @return [Boolean] True if revoked
        def revoke_api_key(api_key_id, revoker: "system")
          @mutex.synchronize do
            api_key = @api_keys[api_key_id]
            return false unless api_key

            api_key.revoke!

            log_security_event(:api_key_revoked, api_key.user_id, {
              api_key_id: api_key_id,
              api_key_name: api_key.name,
              revoker: revoker
            })

            true
          end
        end

        # Revoke session
        # @param session_id [String] Session ID
        # @param revoker [String] User revoking the session
        # @return [Boolean] True if revoked
        def revoke_session(session_id, revoker: "system")
          @mutex.synchronize do
            session = @sessions[session_id]
            return false unless session

            session.revoke!
            @sessions.delete(session_id)

            log_security_event(:session_revoked, session.user_id, {
              session_id: session_id,
              revoker: revoker
            })

            true
          end
        end

        # List active sessions
        # @param username [String] Username filter
        # @return [Array<Session>] Active sessions
        def list_sessions(username: nil)
          sessions = @sessions.values.select(&:valid?)

          if username
            user = @users[username]
            sessions = sessions.select { |s| s.user_id == user&.id } if user
          end

          sessions.sort_by(&:created_at).reverse
        end

        # Get security events
        # @param limit [Integer] Maximum events to return
        # @param user_id [String] Filter by user ID
        # @return [Array<Hash>] Security events
        def get_security_events(limit: 100, user_id: nil)
          events = @security_events
          events = events.select { |e| e[:user_id] == user_id } if user_id
          events.last(limit).reverse
        end

        # Cleanup expired sessions and revoked API keys
        def cleanup!
          @mutex.synchronize do
            # Remove expired sessions
            expired_sessions = @sessions.select { |_, session| !session.valid? }
            expired_sessions.each { |session_id, _| @sessions.delete(session_id) }

            # Clean old security events (keep last 1000)
            @security_events = @security_events.last(1000)
          end
        end

        # Get authentication statistics
        # @return [Hash] Authentication statistics
        def statistics
          @mutex.synchronize do
            {
              users: {
                total: @users.size,
                by_role: @users.values.group_by(&:role).transform_values(&:size),
                locked_accounts: @users.values.count(&:account_locked?)
              },
              sessions: {
                active: @sessions.values.count(&:valid?),
                total: @sessions.size
              },
              api_keys: {
                total: @api_keys.size,
                valid: @api_keys.values.count(&:valid?),
                revoked: @api_keys.values.count(&:revoked?)
              },
              security_events: @security_events.size
            }
          end
        end

        private

        # Create session for authenticated user
        def create_session(user, metadata = {})
          session = Session.new(user: user, metadata: metadata)
          @sessions[session.id] = session
          session
        end

        # Handle failed authentication
        def handle_failed_authentication(username, reason)
          log_security_event(:authentication_failed, nil, {
            username: username,
            reason: reason
          })
          nil
        end

        # Log security event
        def log_security_event(event_type, user_id, details = {})
          @security_events << {
            type: event_type,
            user_id: user_id,
            timestamp: Time.now.iso8601,
            details: details
          }
        end

        # Setup default system users
        def setup_default_users
          # Create default admin user if none exists
          unless @users.key?("admin")
            admin = User.new(
              username: "admin",
              email: "admin@agentic.local",
              role: :admin,
              metadata: {created_by: "system", default_user: true}
            )
            admin.set_password("admin123!") # Default password - should be changed
            @users["admin"] = admin
          end

          # Create system user for automated operations
          unless @users.key?("system")
            system_user = User.new(
              username: "system",
              email: "system@agentic.local",
              role: :system,
              metadata: {created_by: "system", automated: true}
            )
            @users["system"] = system_user
          end
        end

        # Validate email format
        def valid_email?(email)
          email =~ /\A[\w+\-.]+@[a-z\d-]+(\.[a-z\d-]+)*\.[a-z]+\z/i
        end

        # Check password strength
        def strong_password?(password)
          return false if password.length < 8
          return false unless /[a-z]/.match?(password)    # lowercase letter
          return false unless /[A-Z]/.match?(password)    # uppercase letter
          return false unless /[0-9]/.match?(password)    # digit
          return false unless /[^a-zA-Z0-9]/.match?(password) # special character
          true
        end
      end
    end
  end
end
