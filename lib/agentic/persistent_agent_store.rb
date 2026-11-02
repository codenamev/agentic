# frozen_string_literal: true

require "time" # Time#iso8601/Time.parse - require what you use

require "date"
require "json"
require "fileutils"
require "securerandom"

module Agentic
  # Responsible for storing and retrieving agent configurations persistently
  # @attr_reader [String] storage_path Directory to store agent configurations
  # @attr_reader [AgentCapabilityRegistry] registry The capability registry used for instantiation
  class PersistentAgentStore
    # Agent ids and versions become path components under storage_path.
    # Anything outside this shape (separators, "..", empty) never reaches
    # the filesystem; see #path_component!.
    PATH_COMPONENT = /\A[\w.-]+\z/

    attr_reader :storage_path, :registry

    # Initialize a new persistent agent store
    # @param storage_path [String, nil] The path to the storage directory
    # @param registry [AgentCapabilityRegistry] The capability registry for instantiation
    # @param options [Hash] Additional options
    # @option options [Logger] :logger Custom logger (defaults to Agentic.logger)
    def initialize(storage_path = nil, registry = AgentCapabilityRegistry.instance, options = {})
      @registry = registry
      @storage_path = storage_path || default_storage_path
      @logger = options[:logger] || Agentic.logger
      @index = {}

      # Create the storage directory if it doesn't exist
      FileUtils.mkdir_p(@storage_path) unless File.directory?(@storage_path)

      # Initialize the index
      initialize_index
    end

    # Store an agent configuration
    # @param agent [Agent] The agent to store
    # @param name [String, nil] The name to use for the agent (generated if nil)
    # @param metadata [Hash] Additional metadata to store with the agent
    # @return [String] The ID of the stored agent
    def store(agent, name: nil, metadata: {})
      # Generate ID if agent doesn't have one, and assign it back so that
      # storing the same agent again versions it instead of duplicating it
      id = path_component!(agent&.id || SecureRandom.uuid, "agent id")
      agent.id = id if agent&.respond_to?(:id=) && agent.id.nil?

      # Set the agent's ID if it doesn't have one yet
      agent.id = id unless agent.id

      # Generate version
      version = generate_version(id)

      # Create agent data structure
      agent_data = {
        id: id,
        name: name || generate_name(agent),
        version: version,
        timestamp: Time.now.iso8601,
        agent: agent.to_h,
        capabilities: agent.capabilities.keys.map do |capability_name|
          {
            name: capability_name,
            version: agent.capability_specification(capability_name)&.version
          }
        end,
        metadata: metadata
      }

      # Save to storage
      save_to_storage(id, version, agent_data)

      # Update index
      update_index(id, version, agent_data)

      id
    end

    # Build an agent from a stored configuration
    # @param id_or_name [String] The ID or name of the agent
    # @param version [String, nil] The version to load (latest if nil)
    # @return [Agent, nil] The built agent or nil if not found
    def build_agent(id_or_name, version: nil)
      # First try to find by ID
      agent_data = find_agent_data(id_or_name, version)

      # If not found by ID, try to find by name
      unless agent_data
        id = find_id_by_name(id_or_name)
        agent_data = id ? find_agent_data(id, version) : nil
      end

      return nil unless agent_data

      # Create a new agent
      agent = Agent.build do |a|
        a.role = agent_data[:agent][:role]
        a.purpose = agent_data[:agent][:purpose]
        a.backstory = agent_data[:agent][:backstory]
      end

      # Add capabilities
      agent_data[:capabilities].each do |capability|
        agent.add_capability(capability[:name], capability[:version])
      rescue => e
        @logger.warn("Failed to add capability: #{capability[:name]} v#{capability[:version]} - #{e.message}")
      end

      agent
    end

    # List all stored agent configurations
    # @param filter [Hash] Filter criteria
    # @option filter [String] :capability Filter by capability name
    # @option filter [String] :capability_version Filter by capability name and version
    # @option filter [Time, String] :after Filter agents stored after this time
    # @option filter [Time, String] :before Filter agents stored before this time
    # @option filter [Hash] :metadata Filter by metadata values
    # @return [Array<Hash>] Array of agent configurations
    def list_all(filter = {})
      # Support both `all(capability: "x")` and the documented
      # `all(filter: {capability: "x"})` forms (see ADR-015)
      filter = filter[:filter] || {} if filter.key?(:filter)

      results = []

      @index.each do |id, versions|
        # Convert symbol ID to string for get_latest_version
        string_id = id.to_s

        # Get the latest version for each agent by default
        version = get_latest_version(string_id)

        # Skip if no version found
        next unless version

        # Get the agent data (version is returned as string, convert to symbol for lookup)
        agent_data = versions[version.to_sym]

        # Skip if no data found
        next unless agent_data

        # Add ID and version to the data (as strings for CLI compatibility)
        full_data = agent_data.merge(
          id: string_id,
          version: version
        )

        # Apply filters
        if matches_filter?(full_data, filter)
          results << full_data
        end
      end

      # Sort by timestamp (newest first)
      results.sort_by { |data| data[:timestamp] }.reverse
    end

    # Alias to list_all for a more concise API
    # @param filter [Hash] Filter criteria
    # @return [Array<Hash>] Array of agent configurations
    alias_method :all, :list_all

    # Get the version history for an agent
    # @param id [String] The ID of the agent
    # @return [Array<Hash>] The version history or empty array if not found
    def version_history(id)
      # Convert string ID to symbol for index lookup
      id_sym = id.to_sym

      # Check if the agent exists
      return [] unless @index[id_sym]

      # Get all versions and sort by timestamp
      versions = @index[id_sym].map do |version, data|
        {
          id: id,
          name: data[:name],
          version: version.to_s,
          timestamp: data[:timestamp],
          capabilities: data[:capabilities],
          metadata: data[:metadata]
        }
      end

      # Sort by timestamp (newest first)
      versions.sort_by { |v| v[:timestamp] }.reverse
    end

    # Delete an agent from the store
    # @param id_or_name [String] The ID or name of the agent to delete
    # @param version [String, nil] The version to delete (all versions if nil)
    # @return [Boolean] True if successfully deleted
    def delete(id_or_name, version: nil)
      # First try to find by ID (convert to symbol for index lookup)
      id = id_or_name.to_sym

      # If not found in index, try to find by name
      unless @index[id]
        id = find_id_by_name(id_or_name)
        return false unless id
        id = id.to_sym
      end

      # Check if the agent exists
      return false unless @index[id]

      # Convert string ID back for file operations
      string_id = id.to_s

      if version
        # Delete specific version
        version_sym = version.to_sym
        return false unless @index[id][version_sym]

        # Delete from storage
        delete_from_storage(string_id, version)

        # Update index
        @index[id].delete(version_sym)
        @index.delete(id) if @index[id].empty?
      else
        # Delete all versions
        @index[id].each_key do |ver|
          delete_from_storage(string_id, ver.to_s)
        end

        # Update index
        @index.delete(id)
      end

      # Save the index
      save_index

      true
    end

    private

    def default_storage_path
      # Use a default path within the user's home directory
      File.join(Dir.home, ".agentic", "agents")
    end

    def initialize_index
      # Load the index from storage if it exists
      index_path = File.join(@storage_path, "index.json")
      if File.exist?(index_path)
        begin
          @index = prune_index(JSON.parse(File.read(index_path), symbolize_names: true))
        rescue JSON::ParserError => e
          @logger.error("Failed to parse agent store index: #{e.message}")
          @index = {}
        end
      end
    end

    def save_index
      # Save the index to storage
      index_path = File.join(@storage_path, "index.json")
      File.write(index_path, JSON.pretty_generate(@index))
    end

    def save_to_storage(id, version, agent_data)
      # Create directory for the agent if it doesn't exist
      agent_dir = File.join(@storage_path, path_component!(id, "agent id"))
      path_component!(version, "version")
      FileUtils.mkdir_p(agent_dir) unless File.directory?(agent_dir)

      # Save the agent data
      File.write(
        File.join(agent_dir, "#{version}.json"),
        JSON.pretty_generate(agent_data)
      )
    end

    def update_index(id, version, agent_data)
      # Convert string ID to symbol for index storage
      id_sym = id.to_sym
      version_sym = version.to_sym

      # Add to the index
      @index[id_sym] ||= {}
      @index[id_sym][version_sym] = {
        name: agent_data[:name],
        timestamp: agent_data[:timestamp],
        capabilities: agent_data[:capabilities],
        metadata: agent_data[:metadata]
      }

      # Save the index
      save_index
    end

    def delete_from_storage(id, version)
      agent_dir = File.join(@storage_path, path_component!(id, "agent id"))

      # Delete the agent file
      agent_path = File.join(agent_dir, "#{path_component!(version, "version")}.json")
      File.delete(agent_path) if File.exist?(agent_path)

      # Delete the agent directory if it's empty
      Dir.rmdir(agent_dir) if Dir.empty?(agent_dir)
    end

    def find_agent_data(id, version = nil)
      # Convert string ID to symbol for index lookup
      id_sym = id.to_sym

      # Check if the agent exists
      return nil unless @index[id_sym]

      # Determine which version to load
      version ||= get_latest_version(id)
      return nil unless version

      # Load from storage (use string ID for file path)
      agent_path = File.join(
        @storage_path,
        path_component!(id, "agent id"),
        "#{path_component!(version, "version")}.json"
      )
      return nil unless File.exist?(agent_path)

      begin
        JSON.parse(File.read(agent_path), symbolize_names: true)
      rescue JSON::ParserError => e
        @logger.error("Failed to parse agent data: #{e.message}")
        nil
      end
    end

    def find_id_by_name(name)
      # Find an agent ID by name
      @index.each do |id, versions|
        versions.each do |_, data|
          # Return as string for consistency with caller expectations
          return id.to_s if data[:name] == name
        end
      end

      nil
    end

    def get_latest_version(id)
      # Convert string ID to symbol for index lookup
      id_sym = id.to_sym

      # Check if the agent exists
      return nil unless @index[id_sym]

      # Get all versions
      versions = @index[id_sym].keys

      # Sort versions semantically (versions are symbols, convert to strings for parsing)
      versions.max do |a, b|
        a_parts = a.to_s.split(".").map(&:to_i)
        b_parts = b.to_s.split(".").map(&:to_i)

        # Compare major version
        major_comparison = a_parts[0] <=> b_parts[0]
        next major_comparison unless major_comparison == 0

        # Compare minor version
        minor_comparison = a_parts[1] <=> b_parts[1]
        next minor_comparison unless minor_comparison == 0

        # Compare patch version
        a_parts[2] <=> b_parts[2]
      end.to_s # Convert back to string for consistency
    end

    def generate_version(id)
      # Convert string ID to symbol for index lookup
      id_sym = id.to_sym

      # Get the current versions
      versions = @index[id_sym] ? @index[id_sym].keys : []

      if versions.empty?
        # First version
        "1.0.0"
      else
        # Get the latest version
        latest = get_latest_version(id)

        # Increment the patch version
        parts = latest.split(".").map(&:to_i)
        "#{parts[0]}.#{parts[1]}.#{parts[2] + 1}"
      end
    end

    # Ensure a value is safe to use as a single path component under
    # storage_path. Ids can be set on an agent by whoever built it (including
    # an LLM-driven assembly step) and the index file is plain JSON on disk,
    # so neither is trusted to stay inside the store root on its own.
    # @param value [String, Symbol] The id or version to check
    # @param label [String] What the value is, for the error message
    # @return [String] The value as a string
    # @raise [ArgumentError] If the value is not a plain path component
    def path_component!(value, label)
      string = value.to_s
      return string if path_component?(string)

      raise ArgumentError, "#{label} #{string.inspect} is not a valid path component"
    end

    def path_component?(string)
      string.match?(PATH_COMPONENT) && string != "." && string != ".."
    end

    # Drop index entries whose id or version could not have been written by
    # this store. A hand-edited index must not turn into file access outside
    # storage_path on the next read or delete.
    # @param index [Hash] The parsed index
    # @return [Hash] The index with unsafe entries removed
    def prune_index(index)
      index.select do |id, versions|
        keys = versions.is_a?(Hash) ? [id, *versions.keys] : [id, versions]
        unsafe = keys.reject { |key| path_component?(key.to_s) }
        @logger.warn("Ignoring agent store index entry with unsafe key: #{unsafe.first.inspect}") unless unsafe.empty?
        unsafe.empty?
      end
    end

    def generate_name(agent)
      # Generate a name based on the agent's role
      base = agent.role ? agent.role.downcase.gsub(/[^a-z0-9]/, "_") : "agent"
      "#{base}_#{SecureRandom.hex(4)}"
    end

    def matches_filter?(agent_data, filter)
      return true if filter.empty?

      filter.all? do |key, value|
        case key
        when :capability, "capability"
          agent_data[:capabilities]&.any? { |cap| cap[:name] == value }
        when :capability_version, "capability_version"
          name, version = value.split(":", 2)
          agent_data[:capabilities].any? { |cap| cap[:name] == name && cap[:version] == version }
        when :after, "after"
          # Convert value to Time if it's a string
          threshold = value.is_a?(String) ? Time.parse(value) : value
          Time.parse(agent_data[:timestamp]) >= threshold
        when :before, "before"
          # Convert value to Time if it's a string
          threshold = value.is_a?(String) ? Time.parse(value) : value
          Time.parse(agent_data[:timestamp]) <= threshold
        when :metadata, "metadata"
          # Match all metadata criteria
          value.all? do |meta_key, meta_value|
            agent_data[:metadata] && agent_data[:metadata][meta_key] == meta_value
          end
        else
          # For other criteria, check if the property matches
          agent_data[key] == value
        end
      end
    end
  end
end
