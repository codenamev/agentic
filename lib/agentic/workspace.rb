# frozen_string_literal: true

require "securerandom"
require "fileutils"
require_relative "artifact"
require_relative "artifact_graph"
require_relative "observable"
require_relative "verification/artifact_verification_strategy"

module Agentic
  # Manages an isolated workspace for artifact generation
  #
  # A Workspace provides:
  # - Isolated directory for file generation
  # - Security boundaries (path validation, size limits)
  # - Artifact graph management
  # - Lifecycle management (create, use, cleanup)
  # - Observable events for monitoring
  #
  # @example Creating a workspace
  #   workspace = Workspace.new("/tmp/my_project")
  #   artifact = Artifact.new(name: "user.rb", type: :ruby_class, content: "...")
  #   workspace.add_artifact(artifact)
  #   workspace.cleanup # removes directory
  #
  # @example Persistent workspace
  #   workspace = Workspace.new("/path/to/project", persistent: true)
  #   workspace.add_artifact(artifact)
  #   workspace.cleanup # does nothing (persistent)
  class Workspace
    include Observable

    # @return [String] Unique workspace identifier
    attr_reader :id

    # @return [String] Absolute path to workspace directory
    attr_reader :path

    # @return [Hash] Workspace metadata
    attr_reader :metadata

    # @return [ArtifactGraph] Graph of artifacts and their relationships
    attr_reader :artifact_graph

    # @return [Time] Workspace creation time
    attr_reader :created_at

    # Maximum workspace size in bytes (100MB default)
    MAX_SIZE_BYTES = 100 * 1024 * 1024

    # Maximum size per artifact in bytes (10MB default)
    MAX_ARTIFACT_SIZE = 10 * 1024 * 1024

    # Allowed file extensions for security
    ALLOWED_EXTENSIONS = %w[.rb .js .py .json .md .txt .yml .yaml .css .html .xml .sql .sh].freeze

    # Initialize a new workspace
    #
    # Creates the directory if it doesn't exist and initializes the artifact graph.
    # Emits workspace_created observable event.
    #
    # @param path [String] Directory path for the workspace
    # @param options [Hash] Configuration options
    # @option options [Boolean] :persistent Keep workspace after cleanup (default: false)
    # @option options [Array<String>] :allowed_extensions Additional allowed extensions
    # @option options [Integer] :max_size_bytes Custom size limit
    #
    # @example
    #   workspace = Workspace.new("/tmp/project")
    #   workspace = Workspace.new("/app", persistent: true, allowed_extensions: [".tsx"])
    def initialize(path, options = {})
      @id = SecureRandom.uuid
      @path = validate_and_create_path(path)
      @metadata = build_metadata(options)
      @artifact_graph = ArtifactGraph.new
      @created_at = Time.now

      notify(
        :workspace_created,
        data: {workspace_id: @id, path: @path},
        source: "workspace"
      )
    end

    # Add an artifact to the workspace
    #
    # Validates the artifact for security, optionally verifies quality, adds it to
    # the graph, and writes it to the filesystem. Emits artifact_added observable event.
    #
    # @param artifact [Artifact] The artifact to add
    # @param verify [Boolean] Whether to run quality verification (default: true)
    # @return [Artifact] The added artifact
    # @raise [SecurityError] If artifact fails security validation
    # @raise [Verification::ArtifactVerificationError] If verification fails
    #
    # @example
    #   artifact = Artifact.new(name: "user.rb", type: :ruby_class, content: "class User; end")
    #   workspace.add_artifact(artifact)  # With verification
    #   workspace.add_artifact(artifact, verify: false)  # Skip verification
    def add_artifact(artifact, verify: true)
      # Security validation (always runs)
      validate_artifact(artifact)

      # Quality verification (optional)
      if verify
        verification_result = verify_artifact(artifact)
        unless verification_result.passed?
          raise Verification::ArtifactVerificationError.new(
            verification_result.message,
            verification_result
          )
        end
      else
        # Log audit trail when verification is bypassed
        Agentic.logger.warn("Verification bypassed for artifact: #{artifact.name} in workspace: #{@id}")
      end

      @artifact_graph.add_node(artifact)
      write_artifact_to_filesystem(artifact)

      notify(
        :artifact_added,
        data: {
          workspace_id: @id,
          artifact_name: artifact.name,
          artifact_type: artifact.type,
          size: artifact.content.bytesize,
          verified: verify
        },
        source: "workspace"
      )

      artifact
    end

    # Find an artifact by name and optionally type
    #
    # @param name [String] Artifact name (relative path)
    # @param type [Symbol, nil] Optional artifact type filter
    # @return [Artifact, nil] Found artifact or nil
    #
    # @example
    #   user = workspace.find_artifact(name: "user.rb")
    #   service = workspace.find_artifact(name: "user_service.rb", type: :ruby_class)
    def find_artifact(name:, type: nil)
      @artifact_graph.find_node(name: name, type: type)
    end

    # Get artifacts that reference the given artifact
    #
    # @param artifact [Artifact, String] Artifact object or name
    # @return [Array<Artifact>] Artifacts that depend on this one
    #
    # @example
    #   user = workspace.find_artifact(name: "user.rb")
    #   dependents = workspace.artifacts_referencing(user)
    #   # => [user_service, user_controller]
    def artifacts_referencing(artifact)
      @artifact_graph.dependents_of(artifact)
    end

    # Get artifacts referenced by the given artifact
    #
    # @param artifact [Artifact, String] Artifact object or name
    # @return [Array<Artifact>] Artifacts this one depends on
    #
    # @example
    #   service = workspace.find_artifact(name: "user_service.rb")
    #   dependencies = workspace.artifacts_referenced_by(service)
    #   # => [user_artifact]
    def artifacts_referenced_by(artifact)
      @artifact_graph.dependencies_of(artifact)
    end

    # Clean up workspace (remove directory)
    #
    # For non-persistent workspaces, removes the entire directory tree.
    # For persistent workspaces, does nothing.
    # Emits workspace_cleaned observable event.
    #
    # @return [Boolean] True if cleanup occurred, false if skipped (persistent)
    #
    # @example
    #   workspace = Workspace.new("/tmp/work")
    #   workspace.cleanup # removes /tmp/work
    #
    #   persistent = Workspace.new("/app", persistent: true)
    #   persistent.cleanup # does nothing
    def cleanup
      if @metadata[:persistent]
        Agentic.logger.debug("Skipping cleanup for persistent workspace: #{@id}")
        return false
      end

      notify(
        :workspace_cleanup_started,
        data: {workspace_id: @id, path: @path},
        source: "workspace"
      )

      if Dir.exist?(@path)
        FileUtils.rm_rf(@path)
        Agentic.logger.info("Cleaned up workspace: #{@id} at #{@path}")
      end

      notify(
        :workspace_cleaned,
        data: {workspace_id: @id},
        source: "workspace"
      )

      true
    end

    # Get current workspace size in bytes
    #
    # Sums the byte size of all artifact content.
    #
    # @return [Integer] Total size of all artifacts
    def size
      @artifact_graph.sum { |artifact| artifact.content.bytesize }
    end

    # Get count of artifacts in workspace
    #
    # @return [Integer] Number of artifacts
    def artifact_count
      @artifact_graph.size
    end

    # Check if workspace is empty
    #
    # @return [Boolean] True if no artifacts
    def empty?
      @artifact_graph.empty?
    end

    # Get all artifacts in workspace
    #
    # @return [Array<Artifact>] All artifacts
    def all_artifacts
      @artifact_graph.all_nodes
    end

    # String representation of workspace
    #
    # @return [String] Human-readable workspace description
    def to_s
      "<Workspace id=#{@id[0..7]} path=#{@path} artifacts=#{artifact_count}>"
    end

    # Inspection string for debugging
    #
    # @return [String] Detailed workspace information
    def inspect
      "#<Agentic::Workspace:0x#{object_id.to_s(16)} id=\"#{@id}\" path=\"#{@path}\" artifacts=#{artifact_count} size=#{size}>"
    end

    private

    # Validate and create workspace path
    #
    # @param path [String] Requested path
    # @return [String] Absolute path
    def validate_and_create_path(path)
      # Convert to absolute path
      abs_path = File.expand_path(path)

      # Create directory if it doesn't exist
      FileUtils.mkdir_p(abs_path) unless Dir.exist?(abs_path)

      abs_path
    end

    # Build workspace metadata
    #
    # @param options [Hash] User options
    # @return [Hash] Metadata hash
    def build_metadata(options)
      {
        persistent: options[:persistent] || false,
        allowed_extensions: options[:allowed_extensions] || [],
        max_size_bytes: options[:max_size_bytes] || MAX_SIZE_BYTES,
        created_at: Time.now,
        created_by: "agentic"
      }
    end

    # Validate artifact before adding to workspace
    #
    # Performs security checks:
    # - Path traversal prevention
    # - Extension whitelist
    # - Size limits
    # - Content validation
    # - Reference validation
    #
    # @param artifact [Artifact] Artifact to validate
    # @raise [SecurityError] If any validation fails
    def validate_artifact(artifact)
      # Path traversal prevention
      if artifact.name.include?("..") || artifact.name.start_with?("/")
        raise SecurityError, "Invalid artifact name: path traversal detected in '#{artifact.name}'"
      end

      # Alphanumeric and safe characters only in path
      unless artifact.name.match?(/\A[a-zA-Z0-9_\-\/.]+\z/)
        raise SecurityError, "Invalid artifact name: contains unsafe characters '#{artifact.name}'"
      end

      # Extension whitelist
      ext = File.extname(artifact.name)
      allowed = ALLOWED_EXTENSIONS + (@metadata[:allowed_extensions] || [])

      unless allowed.include?(ext)
        raise SecurityError, "Disallowed file extension: #{ext} in '#{artifact.name}'"
      end

      # Artifact size limit
      if artifact.content.bytesize > MAX_ARTIFACT_SIZE
        raise SecurityError, "Artifact too large: #{artifact.content.bytesize} bytes (max #{MAX_ARTIFACT_SIZE})"
      end

      # Workspace size limit
      max_size = @metadata[:max_size_bytes]
      if size + artifact.content.bytesize > max_size
        raise SecurityError, "Workspace size limit exceeded: current #{size}, adding #{artifact.content.bytesize}, max #{max_size}"
      end

      # Content validation (via Security::Sanitizer)
      Security::Sanitizer.sanitize_file_content(artifact.content, artifact.type)

      # Reference validation
      artifact.references.each do |ref|
        if ref.include?("..") || ref.start_with?("/")
          raise SecurityError, "Invalid artifact reference: path traversal in '#{ref}'"
        end
      end

      # Filesystem containment (symlinks)
      validate_write_target(artifact.name)
    end

    # Ensure the artifact's on-disk destination stays inside the workspace
    #
    # The lexical checks above reject `..` and absolute names, but a symlink
    # already present in the workspace (a persistent workspace is usually a
    # real project directory) can still carry a write outside it: either the
    # target file is itself a symlink, or one of its parent directories is.
    # Both must resolve to a real path under the workspace's real path;
    # symlinks that stay inside the workspace keep working.
    #
    # @param name [String] Validated artifact name (relative path)
    # @raise [SecurityError] If the destination resolves outside the workspace
    def validate_write_target(name)
      full_path = File.join(@path, name)
      root = File.realpath(existing_ancestor(@path, name))

      if File.symlink?(full_path)
        target = begin
          File.realpath(full_path)
        rescue Errno::ENOENT
          raise SecurityError, "Invalid artifact name: '#{name}' is a dangling symlink"
        end

        unless within?(target, root)
          raise SecurityError, "Invalid artifact name: '#{name}' is a symlink outside the workspace"
        end
      end

      parent = File.realpath(existing_ancestor(File.dirname(full_path), name))
      unless within?(parent, root)
        raise SecurityError, "Invalid artifact name: '#{name}' resolves outside the workspace"
      end
    end

    # Walk up from +dir+ to the nearest directory that exists on disk
    #
    # @raise [SecurityError] If the walk crosses a dangling symlink
    def existing_ancestor(dir, name)
      until Dir.exist?(dir)
        if File.symlink?(dir)
          raise SecurityError, "Invalid artifact name: '#{name}' passes through a dangling symlink"
        end
        dir = File.dirname(dir)
      end
      dir
    end

    def within?(real_path, root)
      real_path == root || real_path.start_with?(root + File::SEPARATOR)
    end

    # Write artifact to filesystem
    #
    # @param artifact [Artifact] Artifact to write
    def write_artifact_to_filesystem(artifact)
      full_path = File.join(@path, artifact.name)

      # Ensure parent directory exists
      parent_dir = File.dirname(full_path)
      FileUtils.mkdir_p(parent_dir) unless Dir.exist?(parent_dir)

      # Write file with restrictive permissions
      File.open(full_path, "w", 0o644) do |file|
        file.write(artifact.content)
      end

      # Audit log
      Agentic.logger.info("Artifact written: #{artifact.name} (#{artifact.content.bytesize} bytes) to workspace #{@id}")
    rescue => e
      Agentic.logger.error("Failed to write artifact #{artifact.name}: #{e.message}")
      raise
    end

    # Verify artifact quality using appropriate verification strategy
    #
    # @param artifact [Artifact] Artifact to verify
    # @return [Verification::VerificationResult] Verification result
    def verify_artifact(artifact)
      strategy = Verification::ArtifactVerificationStrategy.for_type(artifact.type)
      result = strategy.verify(artifact)

      # Log verification result
      if result.passed?
        Agentic.logger.debug("Artifact verification passed: #{artifact.name}")
      else
        Agentic.logger.warn("Artifact verification failed: #{artifact.name} - #{result.message}")
      end

      result
    end
  end
end
