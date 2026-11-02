# frozen_string_literal: true

require "tsort"

module Agentic
  # Manages the graph of artifact relationships
  #
  # ArtifactGraph maintains a directed graph where nodes are artifacts and
  # edges represent "references" relationships. For example, if UserService.rb
  # requires User.rb, there's an edge from UserService -> User.
  #
  # The graph provides:
  # - Dependency resolution (what does X depend on?)
  # - Dependent tracking (what depends on X?)
  # - Circular dependency detection
  # - Topological sorting (build order)
  #
  # Storage is a Hash from artifact name to the names it references; the
  # standard library's TSort does the sorting and the cycle detection.
  #
  # @example Building a graph
  #   graph = ArtifactGraph.new
  #   graph.add_node(user_artifact)
  #   graph.add_node(service_artifact) # references user_artifact
  #   deps = graph.dependencies_of(service_artifact) # => [user_artifact]
  #
  # @example Detecting cycles
  #   cycles = graph.detect_cycles
  #   if cycles.any?
  #     puts "Circular dependencies detected!"
  #   end
  class ArtifactGraph
    include Enumerable

    def initialize
      @artifacts = {} # artifact_name => Artifact object
      @references = {} # artifact_name => [names it references]
    end

    # Add an artifact node to the graph
    #
    # Creates a vertex for the artifact and edges for each of its references.
    # If referenced artifacts don't exist yet, vertices are still created for them
    # (they'll be populated when those artifacts are added).
    #
    # Edges are directed as: reference -> artifact (dependency -> dependent)
    # This ensures topological sort returns dependencies before dependents.
    #
    # @param artifact [Artifact] The artifact to add
    # @return [void]
    #
    # @example
    #   artifact = Artifact.new(
    #     name: "service.rb",
    #     type: :ruby_class,
    #     content: "...",
    #     references: ["user.rb"]
    #   )
    #   graph.add_node(artifact)
    def add_node(artifact)
      @artifacts[artifact.name] = artifact
      references = (@references[artifact.name] ||= [])

      artifact.references.each do |ref_name|
        # Ensure the referenced vertex exists (even if that artifact isn't added yet)
        @references[ref_name] ||= []
        references << ref_name unless references.include?(ref_name)
      end
    end

    # Get artifacts that the given artifact depends on (direct dependencies)
    #
    # @param artifact [Artifact, String] Artifact object or artifact name
    # @return [Array<Artifact>] Artifacts this one directly references
    #
    # @example
    #   service = graph.find_node(name: "service.rb")
    #   deps = graph.dependencies_of(service) # => [user_artifact]
    def dependencies_of(artifact)
      artifact_name = name_of(artifact)
      return [] unless @references.key?(artifact_name)

      @references[artifact_name].map { |name| @artifacts[name] }.compact
    end

    # Get artifacts that depend on the given artifact (reverse dependencies)
    #
    # @param artifact [Artifact, String] Artifact object or artifact name
    # @return [Array<Artifact>] Artifacts that reference this one
    #
    # @example
    #   user = graph.find_node(name: "user.rb")
    #   dependents = graph.dependents_of(user) # => [service_artifact]
    def dependents_of(artifact)
      artifact_name = name_of(artifact)
      return [] unless @references.key?(artifact_name)

      @references.filter_map do |name, references|
        @artifacts[name] if references.include?(artifact_name)
      end
    end

    # Detect circular dependencies in the graph
    #
    # Each strongly connected component with more than one artifact, or a
    # single artifact that references itself, is a cycle.
    #
    # @return [Array<Array<String>>] Arrays of artifact names forming cycles
    #
    # @example
    #   cycles = graph.detect_cycles
    #   if cycles.any?
    #     cycles.each do |cycle|
    #       puts "Cycle: #{cycle.join(' -> ')}"
    #     end
    #   end
    def detect_cycles
      strongly_connected_components.select { |component| cycle?(component) }
    end

    # Check if graph has circular dependencies
    #
    # @return [Boolean] True if cycles exist
    def has_cycles?
      detect_cycles.any?
    end

    # Get artifacts in topological order (dependencies before dependents)
    #
    # Returns artifacts sorted such that if A depends on B, B appears before A.
    # This is useful for determining build/generation order.
    #
    # @return [Array<Artifact>] Sorted artifacts
    # @raise [CircularDependencyError] If circular dependencies exist
    #
    # @example
    #   sorted = graph.topological_sort
    #   sorted.each { |a| puts "Generate: #{a.name}" }
    def topological_sort
      strongly_connected_components.map do |component|
        raise CircularDependencyError, "Circular dependency detected: #{component.join(" -> ")}" if cycle?(component)

        @artifacts[component.first]
      end.compact
    end

    # Find artifact by name and optionally type
    #
    # @param name [String] Artifact name
    # @param type [Symbol, nil] Optional type filter
    # @return [Artifact, nil] Found artifact or nil
    #
    # @example
    #   artifact = graph.find_node(name: "user.rb")
    #   ruby_artifact = graph.find_node(name: "user.rb", type: :ruby_class)
    def find_node(name:, type: nil)
      artifact = @artifacts[name]
      return nil unless artifact
      return artifact if type.nil? || artifact.type == type
      nil
    end

    # Get all artifacts in the graph
    #
    # @return [Array<Artifact>] All artifacts
    def all_nodes
      @artifacts.values
    end

    # Get count of artifacts in graph
    #
    # @return [Integer] Number of artifacts
    def size
      @artifacts.size
    end

    # Check if graph is empty
    #
    # @return [Boolean] True if no artifacts
    def empty?
      @artifacts.empty?
    end

    # Enumerate all artifacts
    #
    # Makes ArtifactGraph work with Enumerable methods like map, select, etc.
    #
    # @yieldparam artifact [Artifact] Each artifact in the graph
    #
    # @example
    #   graph.each { |artifact| puts artifact.name }
    #   ruby_files = graph.select { |a| a.type == :ruby_class }
    def each(&block)
      @artifacts.values.each(&block)
    end

    # String representation of graph
    #
    # @return [String] Human-readable graph description
    def to_s
      "<ArtifactGraph nodes=#{size} edges=#{edge_count}>"
    end

    # Inspection string for debugging
    #
    # @return [String] Detailed graph information
    def inspect
      artifacts_summary = @artifacts.keys.first(5).join(", ")
      artifacts_summary += ", ..." if @artifacts.size > 5

      "#<Agentic::ArtifactGraph:0x#{object_id.to_s(16)} nodes=#{size} edges=#{edge_count} artifacts=[#{artifacts_summary}]>"
    end

    private

    def name_of(artifact)
      artifact.is_a?(String) ? artifact : artifact.name
    end

    def edge_count
      @references.values.sum(&:size)
    end

    # Tarjan's components in dependency order: this is exactly how TSort#tsort
    # is built, minus the exception, so one pass serves both sorting and
    # cycle detection. TSort treats a self-loop as a non-cycle; we don't.
    def strongly_connected_components
      TSort.strongly_connected_components(method(:each_name), method(:each_reference))
    end

    def cycle?(component)
      component.size > 1 || @references[component.first].include?(component.first)
    end

    # TSort's node enumerator: every vertex, added or merely referenced
    def each_name(&block)
      @references.each_key(&block)
    end

    # TSort's child enumerator: an artifact's children are the artifacts it
    # references, so the sort yields dependencies before dependents
    def each_reference(name, &block)
      @references.fetch(name, []).each(&block)
    end
  end

  # Error raised when circular dependencies are detected in artifact graph
  #
  # @example
  #   begin
  #     sorted = graph.topological_sort
  #   rescue CircularDependencyError => e
  #     puts "Cannot proceed: #{e.message}"
  #   end
  class CircularDependencyError < StandardError; end
end
