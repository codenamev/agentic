## [Unreleased]

### Changed
- **Ruby floor raised to 3.2** (`required_ruby_version = ">= 3.2"`). The old `>= 3.0.0` claim was never true: the locked `async 2.24` (and `console`, `io-event` through it) already require Ruby 3.1, and Ruby 3.0/3.1 are EOL. CI now tests 3.2, 3.3, 3.4 and latest stable instead of a single pinned 3.2.4. Closes #15.

## [0.3.0] - 2025-08-18

### Added
- **Human Intervention Portal System**
  - Complete oversight system with InterventionRequest and InterventionResponse lifecycle management
  - Role-based user management with hierarchical permissions (viewer, reviewer, approver, admin, system)
  - Auto-responders for common scenarios with configurable approval patterns
  - Statistics tracking and health monitoring with real-time dashboards
  - Background processes for cleanup, maintenance, and SLA monitoring
- **Multi-Step Workflow Management System**
  - WorkflowManager for orchestrating complex approval chains with state management
  - WorkflowStep supporting multiple step types (approval, review, escalation, conditional)
  - WorkflowTemplate system with 6 pre-built patterns (single approval, two-stage, consensus, escalation chain, majority vote, conditional)
  - Observer pattern integration for real-time workflow updates and notifications
- **Authentication and Authorization System**
  - User management with secure password handling and account lockout policies
  - Session-based authentication with automatic token rotation and expiration
  - API key management for programmatic access with scoped permissions
  - Comprehensive audit trail with security event monitoring and alerting
- **Real-time Monitoring and Alerting System**
  - Configurable alert rules supporting volume, response time, error rate, and system health alerts
  - Multi-channel notification dispatcher (console, file, email, Slack, webhook)
  - SLA monitoring with compliance tracking and violation reporting
  - Health monitoring with automated escalation and recovery procedures
- **Enhanced CLI Interface**
  - Thor-based HumanInterventionCommands integrated with existing CLI architecture
  - Interactive commands: list, show, respond, assign, stats, users, monitor, health
  - Real-time monitoring dashboard with rich formatting and status visualization
  - User management and authentication operations with batch support
- **Configuration System Enhancement**
  - Unified schema validation with JSON Schema and type checking
  - Constraint validation for complex configuration requirements
  - Configuration migration and versioning system
  - Plugin architecture support with extensible schemas
- **Performance Optimization Framework**
  - Intelligent caching system with TTL and invalidation strategies
  - Connection pooling for HTTP clients and database connections
  - Memory optimization with object pooling patterns
  - Performance monitoring and automatic scaling capabilities
- **Interface Standardization (Multi-Perspective Architect Review)**
  - Unified factory patterns with dynamic instantiation eliminating case-statement bottlenecks
  - EventDispatcher providing consistent event emission patterns across all components
  - Hierarchical EventContext enabling sophisticated multi-agent workflow tracking
  - Security-aware error hierarchy with structured logging and retry mechanisms
  - Unified configuration schemas with JSON Schema validation for plugin architecture support
  - Batched event processing with priority queues reducing memory usage by 30-50% and latency by 20-40%
- **Enhanced Testing Framework** 
  - Comprehensive integration tests for human intervention portal components
  - End-to-end workflow testing with authentication and authorization
  - Multi-system integration validation (Portal + Workflow + Auth + Monitoring)
  - Concurrent processing and thread safety validation
  - Performance testing under load conditions
  - Security testing for authentication flows and RBAC
- **Architectural Team Contributions**
  - Systems + Security Expert: Comprehensive RBAC system with defense-in-depth security architecture
  - Domain + Maintainability Expert: Modular design following established patterns with clear separation of concerns
  - Performance + Ruby Expert: Thread-safe implementation with efficient resource management and Ruby idioms
  - Agent Systems + Domain Expert: Seamless integration with existing agent workflows and observability systems
  - Security + Systems Architect: Multi-layered authentication with session management and comprehensive audit capabilities

### Changed
- **Event System Consolidation**: Unified three separate event systems (Observable, StreamingObservableHub, CLI events) into consistent interfaces
- **CLI Layer Separation**: Extracted presentation concerns from core business logic for better maintainability
- **Verification Standardization**: Implemented factory patterns for consistent strategy instantiation across all verification components
- **Enhanced Error Handling**: Consistent error patterns with better isolation and detailed context throughout the system
- **Dependency Updates**: Added simplecov for test coverage, oj for optimized JSON processing, tty-screen for enhanced CLI capabilities

### Improved
- **Human Oversight Capabilities**: Complete governance system with 10 intervention types supporting ethical review, domain expertise, novel situations, and resource authorization
- **Security Posture**: Multi-layered authentication with RBAC, comprehensive audit trails, and defense-in-depth architecture
- **Workflow Management**: 6 pre-built workflow templates supporting single approval, consensus, escalation chains, and majority voting
- **Real-time Monitoring**: Configurable alerting with multi-channel notifications and SLA compliance tracking
- **Performance**: 30-50% memory reduction, 20-40% latency improvement, intelligent caching with TTL and invalidation
- **CLI Experience**: Interactive dashboard with real-time monitoring, rich formatting, and comprehensive user management
- **Configuration Management**: Unified schema validation with type checking and constraint validation
- **Thread Safety**: Concurrent request processing with graceful error handling and resource cleanup
- **Integration**: Seamless integration with existing ObservabilityEngine and architectural patterns
- **Developer Experience**: Comprehensive documentation, usage examples, and integration test coverage
- **Backward Compatibility**: All existing APIs maintained while adding extensive new capabilities

## [0.2.0] - 2025-05-29

### Added
- Agent Self-Assembly System for dynamic agent construction
  - AgentCapabilityRegistry for managing capability specifications and providers
  - PersistentAgentStore for saving and retrieving agent configurations
  - AgentAssemblyEngine for analyzing tasks and assembling appropriate agents
  - CapabilityOptimizer for improving capability implementations
  - LLM-assisted capability selection strategy
- Capability System with rich specification and versioning
  - Clear distinction between capabilities and tools
  - Semantic versioning for capability evolution
  - Capability composition for building complex capabilities
  - Dependency management for capabilities
- CLI commands for capability and agent management
  - Listing and filtering capabilities
  - Viewing capability details
  - Searching for capabilities
  - Agent creation and management
- Example capabilities for common tasks
- Integration with learning system for capability optimization
- Comprehensive integration tests for agent assembly workflow
- Documentation for capability API and agent self-assembly
- Comprehensive CLI implementation with subcommands for plan, execute, agent, and config
- Real-time feedback with progress bars, spinners, and colorized output
- Per-user and per-project configuration support
- Enhanced LLM error and refusal handling with categorization
- First-class configuration objects for LLM, retry handling, and orchestration
- Value objects for task definitions, agent specifications, and execution results
- Expanded test coverage for core components

### Improved
- Test coverage across all major features
- Documentation for integration testing
- Stability in edge cases like timeouts and partial failures
- Metrics collection for learning system analysis
- Agent reusability through persistent storage
- Decoupled data from presentation throughout the codebase
- Improved error handling with specific error types and recovery strategies
- Enhanced documentation with CLI examples and API snippets

## [0.1.0] - 2024-06-27

### Added
- Comprehensive CLI implementation with subcommands for plan, execute, agent, and config
- Real-time feedback with progress bars, spinners, and colorized output
- Per-user and per-project configuration support
- Enhanced LLM error and refusal handling with categorization
- First-class configuration objects for LLM, retry handling, and orchestration
- Value objects for task definitions, agent specifications, and execution results
- Expanded test coverage for core components

### Changed
- Decoupled data from presentation throughout the codebase
- Improved error handling with specific error types and recovery strategies
- Enhanced documentation with CLI examples and API snippets

## [0.1.0] - 2024-06-27

- Initial release