# Agentic

A Ruby gem for building and running AI agents in a [plan-and-execute](https://blog.langchain.dev/planning-agents/#plan-and-execute) fashion. Agentic provides a simple command-line tool and library to build, manage, deploy, and run purpose-driven AI agents using OpenAI's LLM API.

## What's New in v0.2.0

🚀 **Agent Self-Assembly System** - Agents can now dynamically construct themselves based on task requirements<br>
🎯 **Capability System** - Rich specification and versioning system for agent capabilities<br>
💾 **Persistent Agent Store** - Save and reuse agents across sessions<br>
🔧 **Enhanced CLI** - Comprehensive command-line interface with agent and capability management<br>
📊 **Learning System** - Agents improve over time through execution history analysis<br>
🎨 **Real-time Feedback** - Progress bars, spinners, and colorized output for better user experience<br>

## Demo Video

<div>
    <a href="https://www.loom.com/share/278bc1749f68480fa8a0a3a6658a0291">
      <p>Agentic Gem v0.2.0 Release - Watch Video</p>
    </a>
    <a href="https://www.loom.com/share/278bc1749f68480fa8a0a3a6658a0291">
      <img style="max-width:300px;" src="https://cdn.loom.com/sessions/thumbnails/278bc1749f68480fa8a0a3a6658a0291-2146dcc57ee7b47f-full-play.gif">
    </a>
  </div>

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
$ bundle add agentic
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
$ gem install agentic
```

## Usage

### Command-Line Interface

Agentic comes with a rich command-line interface featuring colored output, spinners for long-running tasks, and progress tracking:

```bash
# Display version information
$ agentic version

# Configuration Management
$ agentic config init                               # Initialize configuration
$ agentic config init --global                      # Initialize global configuration
$ agentic config list                               # List all configuration settings
$ agentic config get model                          # Get a specific configuration value
$ agentic config set api_token=your_openai_api_key  # Set your OpenAI API token
$ agentic config set model=gpt-4o-mini             # Configure the default model

# Plan Creation and Execution
$ agentic plan "Generate a market research report on AI trends"          # Create a plan
$ agentic plan "Write a blog post about Ruby" --save plan.json           # Save plan to file
$ agentic plan "Research quantum computing" --output json                # Output in JSON format
$ agentic plan "Analyze market trends" --model gpt-4o                    # Use a specific model
$ agentic plan "Create documentation" --execute                          # Create and execute immediately
$ agentic plan "Research topics" --no-interactive                        # Skip interactive prompts

$ agentic execute --plan plan.json                  # Execute a saved plan
$ agentic execute --from-stdin                      # Read plan from stdin
$ agentic execute --max-concurrency 5               # Limit concurrent tasks
$ agentic execute --file results.json               # Save results to specific file

# Agent Management
$ agentic agent list                                # List available agents
$ agentic agent list --detailed                    # List with detailed information
$ agentic agent create "ResearchAgent" \            # Create a new agent
    --role="Research Assistant" \
    --purpose="Conduct thorough research" \
    --capabilities=text_generation,web_search
$ agentic agent show "ResearchAgent"                # Show agent details
$ agentic agent build "ResearchAgent"               # Build an agent from storage
$ agentic agent delete "ResearchAgent"              # Delete an agent

# Capability Management
$ agentic capabilities list                         # List available capabilities
$ agentic capabilities show text_generation         # Show capability details
$ agentic capabilities search generation            # Search for capabilities
```

The CLI provides real-time feedback with spinners for long-running operations, colored status updates, and detailed progress tracking. It supports both global and project-specific configuration, allowing you to customize the behavior for different projects.

### Programmatic API

To use Agentic in your Ruby code:

#### Basic Usage

```ruby
require 'agentic'

# Configure your OpenAI API key
Agentic.configure do |config|
  config.access_token = 'your_openai_api_key'
end

# Create a TaskPlanner instance with a goal
planner = Agentic::TaskPlanner.new("Write a blog post about Ruby on Rails")

# Generate the plan
plan = planner.plan

# Display the plan
puts plan.to_s

# Or access the structured data
plan.tasks.each do |task|
  puts "Task: #{task.description}"
  puts "Agent: #{task.agent.name}"
end
```

#### Working with Agents

```ruby
# Create an agent with specific configuration
agent = Agentic::Agent.build do |a|
  a.name = "ResearchAgent"
  a.role = "Research Assistant"
  a.instructions = "Conduct thorough research on the given topic"
end

# Configure the LLM
config = Agentic::LlmConfig.new(
  model: "gpt-4o-mini",
  temperature: 0.7
)

# Create a task
task = Agentic::Task.new(
  description: "Research the latest trends in Ruby on Rails",
  agent_spec: {
    "name" => "ResearchAgent",
    "description" => "An agent that performs research",
    "instructions" => "Research the given topic thoroughly"
  }
)

# Execute the task with the agent
result = task.perform(agent)

# Check the result
if result.successful?
  puts "Task completed successfully!"
  puts result.output
else
  puts "Task failed: #{result.failure.message}"
end
```

#### Plan Orchestration

```ruby
# Create an orchestrator
orchestrator = Agentic::PlanOrchestrator.new(concurrency_limit: 5)

# Add tasks (each with its own agent - see the next section for providers)
collect = Agentic::Task.new(
  description: "collect entries",
  agent_spec: {"name" => "Collector", "instructions" => "collect"}
)
report = Agentic::Task.new(
  description: "write the report",
  agent_spec: {"name" => "Reporter", "instructions" => "report"}
)
orchestrator.add_task(collect, agent: ->(_task) { %w[alpha beta gamma] })
orchestrator.add_task(report, [collect], agent: ->(task) { "#{task.previous_output.size} entries reported" })

# Execute the plan
result = orchestrator.execute_plan

# Process the results
if result.successful?
  puts "Plan executed successfully!"
else
  puts "Plan execution had issues: #{result.status}"
  result.results.each do |task_id, task_result|
    if task_result.failed?
      puts "Task #{task_id} failed: #{task_result.failure.message}"
    end
  end
end
```

### Passing work to the orchestrator directly

You don't need an agent provider to run a plan. Tasks carry an arbitrary
`payload`, accept their agent (or a bare callable) directly, and receive the
outputs of the tasks they depend on:

```ruby
# Stand-ins for your app's objects:
module OrderApi
  def self.fetch(id) = {id: id, status: "shipped"}
end
module Mailer
  def self.deliver(order) = "notified customer for order #{order[:id]}"
end
order_id = 42

orchestrator = Agentic::PlanOrchestrator.new

fetch = Agentic::Task.new(
  description: "fetch the order",
  agent_spec: {"name" => "Fetcher", "instructions" => "fetch"},
  payload: order_id                       # any domain object, opaque to the framework
)
notify = Agentic::Task.new(
  description: "notify the customer",
  agent_spec: {"name" => "Notifier", "instructions" => "notify"}
)

# A callable receives the Task itself; its return value becomes the output
orchestrator.add_task(fetch, agent: ->(task) { OrderApi.fetch(task.payload) })

# Dependencies pipe their outputs into dependents
orchestrator.add_task(notify, [fetch], agent: ->(task) {
  Mailer.deliver(task.output_of(fetch))   # or task.dependency_outputs
})

result = orchestrator.execute_plan        # no provider needed
```

A plan-wide block acts as an agent factory when you do want one place that
builds agents: `orchestrator.execute_plan { |task| build_agent_for(task) }`.

Dependencies can be **named**, so they're declared and consumed under one
word, and single-dependency chains have a shorthand:

```ruby
orchestrator = Agentic::PlanOrchestrator.new
new_task = ->(name) { Agentic::Task.new(description: name, agent_spec: {"name" => name, "instructions" => name}) }
commits, debt, digest = new_task["commits"], new_task["debt"], new_task["digest"]

orchestrator.add_task(commits, agent: ->(_t) { 12 })
orchestrator.add_task(debt, agent: ->(_t) { 3 })
orchestrator.add_task(digest, needs: {shipped: commits, owed: debt}, agent: ->(task) {
  "#{task.needs.shipped} commits shipped, #{task.needs.owed} TODOs owed"
})

previous_verse, next_verse = new_task["first verse"], new_task["second verse"]
orchestrator.add_task(previous_verse, agent: ->(_t) { "an old pond" })
orchestrator.add_task(next_verse, [previous_verse], agent: ->(task) {
  "#{task.previous_output} / a frog leaps in"   # the sole dependency's output
})
```

Capability contracts can constrain values beyond type and presence —
`enum: %w[standard express]`, `min:`/`max:` bounds, `non_empty: true` for
strings and arrays, and cross-field `rules:` checked over the whole input
(`rules: {"express max 10 items" => ->(i) { i[:speed] != "express" || i[:quantity] <= 10 }}`).
`ValidationError#expectations` carries the declared contract for each
violated key, so error messages can name what would have been legal.

The `task_slot_acquired` lifecycle hook fires when a task obtains a
concurrency slot (with `waited:` time), separating queue wait from run
time; retry policies consult an error's own `retryable?` verdict before
falling back to the `retryable_errors` list, and backoff jitter is on by
default so fleets don't retry in lockstep (`backoff_jitter: :full` draws
uniformly from `[0, delay]` for the hardest herd-flattening).

`PlanOrchestrator#graph` returns a frozen snapshot of the plan's topology
— including `graph[:order]` (topological sort), `graph[:edges]` (labeled
by `needs:` names), and `graph[:stats]` (per-task depth, max depth, max
fan-in) — for tools that render, review, or analyze plans.
`Agentic::RateLimit` is a credential-scoped ceiling shareable across
plans and clients (`Agentic::LlmClient.new(config, limiter: rate_limit)`):
concurrent by default, a rolling-window quota with
`RateLimit.new(30, per: 60)`, or both laws at once via composition —
`quota.and(pool)`. Cross-field rules may be structured —
`rules: {air_weight_limit: {message: "...", fields: [:mode, :weight], check: ->(i) {...}}}` —
and `ValidationError#rule_violations` reports each broken rule with its
identifier, message, and the fields it reads.
`CapabilitySpecification#to_json_schema` emits a contract side as
draft-07 JSON Schema for OpenAPI and validator toolchains; journal
replays expose per-task `durations` keyed by description (performance
baselines for free); and retry policies accept an injected `rng:` for
reproducible jitter timing.

### The concurrency contract

Tasks run as fibers inside an [async](https://github.com/socketry/async)
reactor. That means:

- **IO-bound tasks scale nearly perfectly.** LLM calls, HTTP requests,
  `sleep`, database queries — anything that waits on IO yields to other
  tasks. Twenty 200ms API calls at `concurrency_limit: 20` take ~200ms of
  wall clock, not 4 seconds (see `examples/latency_lab.rb` for the measured
  curve).
- **CPU-bound tasks do not parallelize.** Fibers share one thread; parsing,
  hashing, and number crunching gain nothing from a higher concurrency
  limit. If your tasks are compute, the limit is a queue, not a speedup.
- `execute_plan` composes with a running reactor: called inside `Async`
  (e.g. under Falcon), it joins the current event loop instead of nesting
  a new one; standalone, it creates its own and blocks until done.

### Lifecycle hooks

`PlanOrchestrator.new(lifecycle_hooks: {...})` takes a hash of callables
keyed by hook name. Every hook has a no-op default, so pass only the ones
you want. All seven fire at task boundaries and receive keyword arguments:

| Hook | Fires | Keyword arguments |
| --- | --- | --- |
| `before_task_execution` | when a task is scheduled (it may still queue for a slot) | `task_id:`, `task:` |
| `task_slot_acquired` | when the task obtains a concurrency slot | `task_id:`, `task:`, `waited:` (seconds spent queued) |
| `before_agent_build` | before the task's agent is resolved | `task_id:`, `task:` |
| `after_agent_build` | after the agent is resolved | `task_id:`, `task:`, `agent:`, `build_duration:` |
| `after_task_success` | after the task returns a successful result | `task_id:`, `task:`, `result:`, `duration:` |
| `after_task_failure` | after a failed result (or an unexpected exception), before retry and intervention policy run | `task_id:`, `task:`, `failure:`, `duration:` |
| `plan_completed` | once every task has settled | `plan_id:`, `status:`, `execution_time:`, `tasks:`, `results:` |

Hooks run inline on the task's fiber. Anything slower than a hash insert
should hand off (enqueue onto an `Async::Queue`, say), or it stalls the
task that called it. Accept `**` in your lambdas so a hook keeps working
when a later version adds a keyword.

```ruby
timings = Hash.new { |h, k| h[k] = {} }

orchestrator = Agentic::PlanOrchestrator.new(
  concurrency_limit: 5,
  lifecycle_hooks: {
    task_slot_acquired: ->(task_id:, waited:, **) { timings[task_id][:queued] = waited },
    after_task_success: ->(task_id:, duration:, **) { timings[task_id][:ran] = duration },
    after_task_failure: ->(task_id:, failure:, duration:, **) {
      timings[task_id].merge!(ran: duration, failure: failure)
    },
    plan_completed: ->(status:, execution_time:, **) {
      puts "#{status} in #{execution_time.round(2)}s: #{timings.inspect}"
    }
  }
)
```

Hooks are a construction-time seam, not a registry: to combine yours with
hooks another component provides (the learning system builds a set, see
below), wrap both callables in one lambda that calls each.

### When to reach for which layer

Start with **capabilities** — lambdas with declared contracts — and call
them directly. Add the **orchestrator** when you have an actual queue:
many independent items, or tasks with dependencies. Add the **planner**
(`Agentic.run` / `TaskPlanner`) when the task list itself should come from
an LLM. Each layer is optional and composes with the ones below it.

## Extension System

Agentic includes a powerful Extension System to help integrate with external systems and customize the framework's behavior. The Extension System consists of three main components:

### Domain Adapters

Domain Adapters let you customize Agentic's behavior for specific domains like healthcare, finance, or legal:

```ruby
# Create a domain adapter for healthcare
adapter = Agentic::Extension.domain_adapter("healthcare")

# Add domain-specific knowledge
adapter.add_knowledge(:terminology, {
  terms: ["patient", "diagnosis", "treatment"],
  specialty: "cardiology"
})

# Create a custom prompt adapter
prompt_adapter = ->(prompt, context) {
  specialty = context[:domain_knowledge][:terminology][:specialty]
  "#{prompt} [Adapted for #{context[:domain]} #{specialty}]"
}

# Register the adapter
adapter.register_adapter(:prompt, prompt_adapter)

# Apply adaptation to a prompt
adapted_prompt = adapter.adapt(:prompt, "Describe the symptoms")
# => "Describe the symptoms [Adapted for healthcare cardiology]"
```

### Protocol Handlers

Protocol Handlers standardize connections to external systems and APIs:

```ruby
# Get the protocol handler
handler = Agentic::Extension.protocol_handler(
  default_headers: { "User-Agent" => "AgenticApp/1.0" }
)

# Create and register a protocol implementation
http_protocol = Object.new
def http_protocol.send_request(endpoint, options)
  # Implement HTTP request logic
  { status: 200, body: "Response data" }
end

# Register the protocol
handler.register_protocol(:http, http_protocol, { timeout: 30 })

# Send a request
response = handler.send_request(:http, "/api/data", {
  method: "GET",
  headers: { "Accept" => "application/json" }
})
```

### Plugin Manager

The Plugin Manager handles third-party extensions and their lifecycle:

```ruby
# Get the plugin manager
manager = Agentic::Extension.plugin_manager

# A plugin is any object with #initialize_plugin and #call
class GreeterPlugin
  def initialize_plugin(context = {}) = true
  def call(name) = "hello, #{name}"
end

# Register a plugin (register! replaces an existing registration)
manager.register!("greeter", GreeterPlugin.new, { version: "1.0.0" })

# Get and use a plugin
if (plugin = manager.get("greeter"))
  result = plugin.call("agentic")
end

# Disable a plugin
manager.disable("greeter")
```

## Agent Specification and Task Definition

Agentic provides structured representations for agents and tasks through several key value objects:

### Agent Specification

The AgentSpecification defines the requirements for an agent:

```ruby
# Create an agent specification
agent_spec = Agentic::AgentSpecification.new(
  name: "ResearchAgent",
  description: "An agent that performs research",
  instructions: "Research the given topic thoroughly"
)

# Convert to a hash representation
hash = agent_spec.to_h

# Create from a hash representation
agent_spec_from_hash = Agentic::AgentSpecification.from_hash(hash)
```

### Task Definition

The TaskDefinition defines a task to be performed by an agent:

```ruby
agent_spec = Agentic::AgentSpecification.new(
  name: "ResearchAgent", description: "Researches topics", instructions: "Research thoroughly"
)

# Create a task definition
task_def = Agentic::TaskDefinition.new(
  description: "Research AI trends",
  agent: agent_spec
)

# Convert to a hash representation
hash = task_def.to_h

# Create from a hash representation
task_def_from_hash = Agentic::TaskDefinition.from_hash(hash)
```

### Execution Plan

The ExecutionPlan represents a plan with tasks and expected answer format:

```ruby
agent_spec = Agentic::AgentSpecification.new(
  name: "ResearchAgent", description: "Researches topics", instructions: "Research thoroughly"
)
task_def = Agentic::TaskDefinition.new(description: "Research AI trends", agent: agent_spec)

# Create an expected answer format
expected_answer = Agentic::ExpectedAnswerFormat.new(
  format: "PDF",
  sections: ["Summary", "Trends", "Conclusion"],
  length: "10 pages"
)

# Create an execution plan
plan = Agentic::ExecutionPlan.new([task_def], expected_answer)

# Convert to a formatted string
puts plan.to_s

# Convert to a hash representation
hash = plan.to_h
```

### Agent Configuration

The AgentConfig provides a configuration object for agents:

```ruby
# Create an agent configuration
config = Agentic::AgentConfig.new(
  name: "ResearchAgent",
  role: "Research Assistant",
  backstory: "You are an expert researcher with decades of experience",
  tools: ["web_search", "document_processor"],
  llm_config: Agentic::LlmConfig.new(model: "gpt-4o-mini")
)

# Access configuration properties
puts config.name
puts config.role

# Convert to a hash representation
hash = config.to_h
```

## Agent Capabilities System

Agentic features a powerful Capability System that enables dynamic agent composition, self-assembly, and persistence. The system allows agents to be constructed with precisely the capabilities they need for specific tasks, and to be stored for future reuse.

### Capability Registry

The capability registry manages capability specifications and providers:

```ruby
# Define a capability specification
text_gen_capability = Agentic::CapabilitySpecification.new(
  name: "text_generation",
  description: "Generates text based on a prompt",
  version: "1.0.0",
  inputs: {
    prompt: { type: "string", required: true, description: "The prompt to generate text from" }
  },
  outputs: {
    response: { type: "string", description: "The generated text" }
  }
)

# Create a provider for the capability
text_gen_provider = Agentic::CapabilityProvider.new(
  capability: text_gen_capability,
  implementation: ->(inputs) { { response: "Generated text for: #{inputs[:prompt]}" } }
)

# Register the capability with the system
Agentic.register_capability(text_gen_capability, text_gen_provider)
```

### Agent Assembly Engine

The assembly engine dynamically constructs agents based on task requirements:

```ruby
# Define a task
task = Agentic::Task.new(
  description: "Generate a report on AI trends",
  agent_spec: Agentic::AgentSpecification.new(
    name: "Report Generator",
    description: "An agent that generates reports",
    instructions: "Generate a comprehensive report on the topic"
  ),
  input: {
    topic: "AI trends in 2023",
    format: "markdown"
  }
)

# Assemble an agent for the task
agent = Agentic.assemble_agent(task)

# The agent will automatically have capabilities like "text_generation"
# based on the task requirements
```

### Agent Persistence

Agents can be stored and retrieved for future use:

<!-- doctest: illustrative (requires an assembled agent, i.e. LLM credentials) -->
```ruby
# Store an agent for future use
agent_id = Agentic.agent_store.store(agent, name: "report_generator")

# Later, retrieve the agent by name
stored_agent = Agentic.agent_store.build_agent("report_generator")

# Or retrieve by ID
stored_agent = Agentic.agent_store.build_agent(agent_id)

# List all stored agents
agents = Agentic.agent_store.all
```

### Capability Composition

Capabilities can be composed into higher-level capabilities:

```ruby
registry = Agentic::AgentCapabilityRegistry.instance

# Register the two base capabilities (bare lambdas are providers)
[["text_generation", ->(i) { {response: "report on: #{i[:prompt]}"} }],
 ["data_analysis", ->(i) { {summary: "avg sales #{i[:data][:sales].sum / i[:data][:sales].size}"} }]].each do |name, impl|
  spec = Agentic::CapabilitySpecification.new(name: name, description: name, version: "1.0.0")
  Agentic.register_capability(spec, Agentic::CapabilityProvider.new(capability: spec, implementation: impl))
end

# Compose multiple capabilities into a new one
registry.compose(
  "comprehensive_report",
  "Generates a comprehensive report with research and formatting",
  "1.0.0",
  [
    { name: "text_generation", version: "1.0.0" },
    { name: "data_analysis", version: "1.0.0" }
  ],
  ->(providers, inputs) {
    analysis = providers[1].execute(data: inputs[:data])
    report = providers[0].execute(prompt: "Generate a report on: #{analysis[:summary]}")
    { report: report[:response], analysis: analysis }
  }
)

# Use the composed capability like any other
provider = registry.get_provider("comprehensive_report")
result = provider.execute(data: { sales: [120, 90, 143] })
```

## Learning System

Agentic features a Learning System that enables agents to improve over time by capturing execution metrics, recognizing patterns, and optimizing strategies. The Learning System consists of three main components:

### Execution History Store

The ExecutionHistoryStore captures and stores execution metrics and performance data:

```ruby
# Create a history store
history_store = Agentic::Learning::ExecutionHistoryStore.new(
  storage_path: "~/.agentic/history",
  anonymize: true,
  retention_days: 30
)

# Record task execution metrics
history_store.record_execution(
  task_id: "task-123",
  agent_type: "research_agent",
  duration_ms: 1500,
  success: true,
  metrics: { tokens_used: 2000, quality_score: 0.85 }
)

# Query execution history
research_tasks = history_store.get_history(agent_type: "research_agent", success: true)

# Calculate metrics
avg_tokens = history_store.get_metric(:tokens_used, { agent_type: "research_agent" }, :avg)
```

### Pattern Recognizer

The PatternRecognizer analyzes execution history to identify patterns and optimization opportunities:

```ruby
history_store = Agentic::Learning::ExecutionHistoryStore.new(storage_path: "history")
15.times do |i|
  history_store.record_execution(task_id: "t#{i}", agent_type: "research_agent",
    duration_ms: 1000 + i * 20, success: i % 4 != 0, metrics: {tokens_used: 1500 + i})
end

# Create a pattern recognizer
recognizer = Agentic::Learning::PatternRecognizer.new(
  history_store: history_store,
  min_sample_size: 10
)

# Analyze agent performance
patterns = recognizer.analyze_agent_performance("research_agent")

# Analyze correlations between properties
correlation = recognizer.analyze_correlation(:duration_ms, :tokens_used)

# Get optimization recommendations
recommendations = recognizer.recommend_optimizations("research_agent")
```

### Strategy Optimizer

The StrategyOptimizer generates improvements for prompts, parameters, and task sequences:

```ruby
history_store = Agentic::Learning::ExecutionHistoryStore.new(storage_path: "history")
15.times do |i|
  history_store.record_execution(task_id: "t#{i}", agent_type: "research_agent",
    duration_ms: 1000 + i * 20, success: i % 4 != 0, metrics: {tokens_used: 1500 + i})
end
recognizer = Agentic::Learning::PatternRecognizer.new(history_store: history_store)

# Create a strategy optimizer (add llm_client: for LLM-enhanced optimizations)
optimizer = Agentic::Learning::StrategyOptimizer.new(
  pattern_recognizer: recognizer,
  history_store: history_store
)

# Optimize a prompt template
improved_prompt = optimizer.optimize_prompt_template(
  "Research the topic: {topic}",
  "research_agent"
)

# Optimize LLM parameters
improved_params = optimizer.optimize_llm_parameters(
  { temperature: 0.7, max_tokens: 2000 },
  "research_agent",
  optimization_strategy: :balanced
)

# Generate performance report
report = optimizer.generate_performance_report("research_agent")
```

### Integrating with Plan Orchestrator

The Learning System can be automatically integrated with the PlanOrchestrator:

```ruby
# Create the learning system
learning_system = Agentic::Learning.create(
  storage_path: "history",
  auto_optimize: false
)

# Hooks are a construction-time seam: pass the learning system's hooks
# to the orchestrator (chaining any hooks you already have)
orchestrator = Agentic::PlanOrchestrator.new(
  lifecycle_hooks: Agentic::Learning.lifecycle_hooks(learning_system)
)

# The orchestrator now records execution metrics automatically
task = Agentic::Task.new(description: "work", agent_spec: {"name" => "w", "instructions" => "w"})
orchestrator.add_task(task, agent: ->(_t) { :done })
orchestrator.execute_plan

learning_system[:history_store].get_history.size # => 1
```

## Configuration

### Setting up the OpenAI API Key

You can configure the OpenAI API key in several ways:

1. Environment variable:
   ```bash
   export OPENAI_ACCESS_TOKEN="your_api_key"
   ```

2. Configuration file:
   Create `.agentic.yml` in your project directory or home directory:
   ```yaml
   api_token: "your_api_key"
   model: "gpt-4o-mini"
   ```

3. In your Ruby code:
   ```ruby
   Agentic.configure do |config|
     config.access_token = "your_api_key"
   end
   ```

### LLM Configuration

You can customize the LLM behavior:

<!-- doctest: illustrative (constructing a client requires credentials) -->
```ruby
config = Agentic::LlmConfig.new(
  model: "gpt-4o-mini",
  max_tokens: 500,
  temperature: 0.7,
  top_p: 1.0,
  frequency_penalty: 0,
  presence_penalty: 0
)

# Use in TaskPlanner
planner = Agentic::TaskPlanner.new("Write a blog post", config)

# Or with LlmClient directly
client = Agentic::LlmClient.new(config)
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

### Running Tests

Agentic includes a comprehensive test suite with both unit tests and integration tests. To run all tests:

```bash
rake spec
```

To run specific test categories:

```bash
# Run just integration tests
rspec spec/integration/

# Run a specific integration test file
rspec spec/integration/plan_orchestrator_integration_spec.rb

# Run with verbose output
rspec spec/integration/ --format documentation
```

The integration tests cover real-world scenarios including:
- Complex orchestration patterns with dependencies
- Learning system's pattern recognition capabilities
- Agent specification and task definition interactions
- Timeout and retry behaviors
- Error handling in complex scenarios

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/codenamev/agentic. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/codenamev/agentic/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Agentic project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/codenamev/agentic/blob/main/CODE_OF_CONDUCT.md).
