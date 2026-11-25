# ADR-023: Human Intervention as Journal State

## Status

Proposed

Depends on #21 (journal resume). Tracks #101.

## Context

The orchestrator already knows when to stop for a human. `requires_intervention?` (`plan_orchestrator.rb:364`) flags `AuthenticationError`, `PermissionDeniedError` and `ConfigurationError`, and `handle_task_failure` holds every dependent when it fires. Then `request_human_intervention` (`plan_orchestrator.rb:806`) logs one warning and returns. The comment says it "would integrate with the yet-to-be-implemented human intervention system."

That system exists and can't do the job. `lib/agentic/human_intervention/` is 3,111 lines. Its store is an in-memory hash (`portal.rb:299`) with two background threads for cleanup and stats. Every `agentic intervention` subcommand builds a fresh `Portal.new` (`cli/human_intervention_commands.rb:336`), so `list` sees an empty hash and `respond ID` can't find the request `list` would have shown. Each CLI call is a new process. A request can't outlive the process that made it, which is exactly the case where a human gets involved: they answer later, from somewhere else.

Meanwhile agentic already owns a durable, fsync'd, cross-process-locked event log: `ExecutionJournal`. `replay` rebuilds `completed_task_ids`, `outputs` and `failures`, and #21 turns that into resume. RubyLLM 2.2 reached the same shape from the other direction ("`ask` in a tool pauses the call with no process waiting, and `execute` runs again with the answer"), and had to add a table to get it. We don't.

## Decision Drivers

* An intervention must survive process exit; the human is slower than the run.
* One durable store, not two. The journal is already the source of truth for crash recovery.
* Plan-as-data: the paused task plus its dependents is the set resume already re-runs.
* Don't break `agentic intervention` users without a deprecation window.

## Decision

A run that needs a human pauses by writing to the journal and exiting cleanly. Resume carries the answer back in.

1. **Pause event.** When `requires_intervention?` is true, the orchestrator records `task_awaiting_human` with `task_id`, `description`, `error_type`, `message`, and an optional `question` (a task or agent may supply one; otherwise the failure message is the question). The task gets status `:awaiting_human`, not `:failed`. Dependents stay held. Independent tasks keep running to completion.
2. **Plan status.** If any task is awaiting a human when the scheduler drains, `plan_completed` records `status: "awaiting_human"`. Callers branch on it the same way they branch on `:partial_failure`.
3. **Replay.** `ReplayedState` gains `awaiting_human` (task id to `{question, error_type, message, at}`). A later `task_succeeded` or `task_human_answered` for the same id clears it. Unknown events stay tolerated, so old readers keep working on new journals.
4. **Resume payload.** `execute_plan(resume_from: state, answers: {task_id => String})`. For each answered task the orchestrator records `task_human_answered` (task id, answer, `answered_by` when known), then re-runs the task with the answer added to its input under `human_response:`. Unanswered awaiting tasks stay paused and the run ends `awaiting_human` again. An answer for a task that isn't awaiting raises `ArgumentError` before anything runs.
5. **CLI.** `agentic resume JOURNAL --answer TASK=TEXT` (repeatable) and `agentic pending JOURNAL` to list open questions. Both read the journal, so they work from any process.
6. **Double submit.** Resume takes the journal's `flock` for the claim: it re-replays under the lock and refuses if the task already has a `task_human_answered` or `task_succeeded`. Two people answering the same question get one run and one clear error.

**Architectural Components Affected:**
* `PlanOrchestrator`: `request_human_intervention` writes the pause; new `:awaiting_human` task and plan status; `answers:` on `execute_plan`
* `ExecutionJournal`: two event types, `awaiting_human` on `ReplayedState`, a claim helper
* CLI: `resume --answer`, `pending`; `intervention` subcommands deprecated
* `HumanIntervention::Portal`: deprecated, then removed

**Interface Changes:**
* New: `execute_plan(..., answers:)`, `ReplayedState#awaiting_human`, `PlanResult` status `:awaiting_human`, journal events `task_awaiting_human` and `task_human_answered`
* Deprecated: `Agentic::HumanIntervention::Portal` and `agentic intervention *`

## Consequences

### Positive

* An intervention survives restarts, machine changes and days of waiting, for free.
* `requires_intervention?` finally has a consumer.
* About 3,100 lines of unreachable code and two idle threads go away at the end of the deprecation.
* The journal stays the only record of what a run did, including what a human said.

### Negative

* Answers are plain text in the journal. Anyone who can read the journal can read them. Same exposure as task outputs today, but worth stating in the docs.
* Interventions are scoped to a journal. Running without `--journal` can't pause durably; that run fails the task as it does today and says why.
* No push notification. Something outside agentic has to watch for `awaiting_human` and tell a person.

### Neutral

* Portal's richer request kinds (approval, choice lists, priorities) aren't carried over. If someone needs them, `question` can grow a structured form later without a new event.

## Implementation

**Phase 1: pause and resume (after #21 merges)**
* Journal events + `ReplayedState#awaiting_human`, with replay specs for old journals
* Orchestrator pause path and `answers:` resume, claim under `flock`
* `agentic resume --answer`, `agentic pending`

**Phase 2: Portal deprecation**
* `Portal.new` and `agentic intervention *` warn once per process and point at `pending` / `resume --answer`
* CHANGELOG entry; one minor release with the warning

**Phase 3: removal**
* Delete `lib/agentic/human_intervention/` and its CLI in the next minor after Phase 2 ships

## Alternatives Considered

### Wire the orchestrator into the Portal

The smallest diff, and the wrong one. The store dies with the process, so the human can't answer from a second CLI call. Making Portal durable means building a second journal.

### A separate SQLite store for interventions

Durable, but it splits one run's history across two files that can disagree after a crash. The journal is already fsync'd and locked.

## Validation

* A spec that pauses a run, exits, replays the journal in a fresh orchestrator, answers, and asserts the answer reached the task input and the dependents ran.
* A spec that submits the same answer twice from two processes and asserts exactly one re-run.
* A live CLI run: `execute --journal`, hit an auth failure on purpose, `pending`, `resume --answer`.
