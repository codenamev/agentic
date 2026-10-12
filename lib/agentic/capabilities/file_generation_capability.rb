# frozen_string_literal: true

require_relative "../artifact"
require_relative "../workspace"
require "json"

module Agentic
  module Capabilities
    # File Generation Capability
    #
    # Enables agents to generate code files and artifacts within isolated workspaces.
    # This capability encapsulates the complete workflow:
    # 1. Agent generates artifact descriptions (JSON format)
    # 2. Capability parses and validates descriptions
    # 3. Creates Artifact objects with detected references
    # 4. Adds artifacts to workspace (with security & quality validation)
    #
    # ## Security Constraints
    #
    # This capability supports optional constraints for security and resource control:
    #
    # - **max_files**: Prevents denial-of-service attacks via excessive file generation.
    #   LLMs could be prompted to generate thousands of files, consuming disk space and
    #   processing time. Setting max_files provides a hard limit.
    #
    # - **allowed_types**: Prevents unauthorized file type generation. Restricts agents
    #   to generating only approved artifact types (e.g., only :ruby_class, not :sql).
    #   Helps prevent agents from generating executable scripts, configuration files,
    #   or other potentially dangerous file types outside their intended scope.
    #
    # @example Using the capability
    #   agent = Agent.new
    #   agent.add_capability("file_generation")
    #
    #   result = agent.execute_capability("file_generation", {
    #     task_description: "Create a Ruby User class",
    #     workspace: workspace,
    #     constraints: {max_files: 10, allowed_types: [:ruby_class, :markdown]}
    #   })
    #
    #   puts "Generated #{result[:artifacts].size} files"
    class FileGenerationCapability
      # Capability specification
      #
      # @return [Hash] Capability metadata
      def self.specification
        {
          name: "file_generation",
          version: "1.0.0",
          description: "Generate code files and artifacts within an isolated workspace",
          inputs: {
            task_description: {
              type: :string,
              required: true,
              description: "Description of files to generate"
            },
            workspace: {
              type: :object,
              required: true,
              description: "Workspace instance for file generation"
            },
            constraints: {
              type: :hash,
              required: false,
              description: "Optional constraints (max_files, allowed_types, etc.)"
            }
          },
          outputs: {
            artifacts: {
              type: :array,
              description: "Array of generated artifact hashes"
            },
            workspace_id: {
              type: :string,
              description: "Workspace identifier"
            },
            workspace_path: {
              type: :string,
              description: "Filesystem path to workspace"
            },
            artifact_count: {
              type: :integer,
              description: "Number of artifacts generated"
            }
          }
        }
      end

      # Execute the file generation capability
      #
      # @param agent [Agent] The agent executing this capability
      # @param inputs [Hash] Input parameters
      # @option inputs [String] :task_description Description of files to generate
      # @option inputs [Workspace] :workspace Workspace for file generation
      # @option inputs [Hash] :constraints Optional constraints
      # @return [Hash] Execution result with artifacts and workspace info;
      #   generation failures (parse errors, constraint violations) are
      #   returned as `{success: false, error: ...}` rather than raised
      # @raise [ArgumentError] If required inputs missing
      # @raise [SecurityError] If an artifact fails workspace security validation.
      #   Deliberately NOT rescued here: a path-traversal or disallowed-extension
      #   artifact means the generated output is untrustworthy, so the whole
      #   generation fails closed (ArtifactGenerator#generate turns it into a
      #   failed result; PlanOrchestrator records it as a TaskFailure).
      # @raise [StandardError] If agent execution fails (propagated unwrapped)
      def self.execute(agent:, inputs:)
        # Validate inputs
        validate_inputs(inputs)

        workspace = inputs[:workspace]
        task_description = inputs[:task_description]
        constraints = inputs[:constraints] || {}

        # Build prompt for agent
        prompt = build_file_generation_prompt(task_description, constraints)

        # Execute agent with workspace context. Agent errors propagate
        # unwrapped so callers can report the original exception class.
        response = agent.execute_with_workspace(prompt, workspace)

        # Parse artifact descriptions from response
        artifact_descriptions = parse_artifact_descriptions(response)

        # Validate artifact count against constraints
        if constraints[:max_files] && artifact_descriptions.size > constraints[:max_files]
          raise FileGenerationError, "Generated #{artifact_descriptions.size} files, but max_files constraint is #{constraints[:max_files]}"
        end

        # Create artifacts and add to workspace
        artifacts = []
        artifact_descriptions.each do |desc|
          artifact = create_artifact_from_description(desc)

          # Check type constraints
          if constraints[:allowed_types] && !constraints[:allowed_types].include?(artifact.type)
            Agentic.logger.warn("Skipping artifact #{artifact.name}: type #{artifact.type} not in allowed_types")
            next
          end

          workspace.add_artifact(artifact)
          artifacts << artifact
        rescue => e
          Agentic.logger.error("Failed to create artifact from description: #{e.message}")
          # Continue with other artifacts
        end

        # Return result
        {
          artifacts: artifacts.map(&:to_h),
          workspace_id: workspace.id,
          workspace_path: workspace.path,
          artifact_count: artifacts.size,
          success: true
        }
      rescue FileGenerationError => e
        {
          success: false,
          error: e.message,
          artifacts: [],
          artifact_count: 0
        }
      end

      # Validate required inputs
      #
      # @param inputs [Hash] Input parameters
      # @raise [ArgumentError] If required inputs missing or invalid
      def self.validate_inputs(inputs)
        unless inputs[:task_description] && !inputs[:task_description].empty?
          raise ArgumentError, "task_description is required"
        end

        unless inputs[:workspace].is_a?(Workspace)
          raise ArgumentError, "workspace must be a Workspace instance"
        end
      end

      # Build prompt for file generation
      #
      # @param task_description [String] Description of files to generate
      # @param constraints [Hash] Optional constraints
      # @return [String] Formatted prompt
      def self.build_file_generation_prompt(task_description, constraints = {})
        prompt_parts = [
          "[File Generation Task]",
          task_description
        ]

        if constraints.any?
          prompt_parts << "\n[Constraints]"
          constraints.each do |key, value|
            prompt_parts << "- #{key}: #{value}"
          end
        end

        prompt_parts << <<~INSTRUCTIONS

          [Output Format]
          Respond with a JSON object containing an "artifacts" array. Each artifact must have:
          - name: relative file path (e.g., "lib/user.rb", "models/user.py")
          - type: artifact type (ruby_class, javascript_module, python_module, json, markdown, etc.)
          - content: complete file content
          - references: array of relative paths to files this one depends on (optional)

          Example:
          {
            "artifacts": [
              {
                "name": "lib/user.rb",
                "type": "ruby_class",
                "content": "class User\\n  attr_accessor :name, :email\\nend",
                "references": []
              }
            ]
          }

          IMPORTANT:
          - Include ONLY the requested files
          - Use complete, working code
          - Follow language conventions
          - Include all necessary imports/requires
        INSTRUCTIONS

        prompt_parts.join("\n")
      end

      # Parse artifact descriptions from agent response
      #
      # @param response [String] Agent response (JSON or text containing JSON)
      # @return [Array<Hash>] Array of artifact description hashes
      # @raise [FileGenerationError] If parsing fails
      def self.parse_artifact_descriptions(response)
        # Try to extract JSON from response
        json_str = extract_json(response)

        begin
          data = JSON.parse(json_str)
        rescue JSON::ParserError => e
          raise FileGenerationError, "Failed to parse JSON response: #{e.message}"
        end

        unless data.is_a?(Hash) && data["artifacts"].is_a?(Array)
          raise FileGenerationError, "Response must contain 'artifacts' array"
        end

        data["artifacts"]
      end

      # Extract JSON from response (handles markdown code blocks)
      #
      # @param response [String] Agent response
      # @return [String] Extracted JSON string
      def self.extract_json(response)
        # Remove markdown code blocks if present
        json = response.strip

        # Check for ```json code blocks
        if json.match?(/```json\s*\n/)
          json = json.gsub(/```json\s*\n/, "").gsub(/```\s*$/, "")
        elsif json.match?(/```\s*\n/)
          json = json.gsub(/```\s*\n/, "").gsub(/```\s*$/, "")
        end

        json.strip
      end

      # Create Artifact from description hash
      #
      # @param desc [Hash] Artifact description
      # @return [Artifact] Created artifact
      # @raise [ArgumentError] If description invalid
      def self.create_artifact_from_description(desc)
        # Validate required fields
        unless desc["name"] && !desc["name"].empty?
          raise ArgumentError, "Artifact description missing 'name'"
        end

        unless desc["content"]
          raise ArgumentError, "Artifact description missing 'content' for #{desc["name"]}"
        end

        # Determine type (default to infer from extension)
        type = if desc["type"]
          desc["type"].to_sym
        else
          infer_type_from_name(desc["name"])
        end

        # Get or detect references
        references = if desc["references"]
          Array(desc["references"])
        else
          # Auto-detect references from content
          Artifact.detect_references(desc["content"], type)
        end

        # Create artifact
        Artifact.new(
          name: desc["name"],
          type: type,
          content: desc["content"],
          references: references,
          metadata: desc["metadata"] || {}
        )
      end

      # Infer artifact type from filename
      #
      # @param filename [String] Filename
      # @return [Symbol] Inferred type
      def self.infer_type_from_name(filename)
        case File.extname(filename)
        when ".rb" then :ruby_class
        when ".js" then :javascript_module
        when ".py" then :python_module
        when ".json" then :json
        when ".md" then :markdown
        when ".txt" then :text
        when ".yml", ".yaml" then :yaml
        when ".css" then :css
        when ".html" then :html
        when ".xml" then :xml
        when ".sql" then :sql
        else :text
        end
      end
    end

    # Error raised when file generation fails
    class FileGenerationError < StandardError; end
  end
end
