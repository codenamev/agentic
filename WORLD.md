# WORLD.md: agentic, answered six ways

This file sets direction for agentic: what it exists to do, what it will not
become, and how proposed work gets judged. The maintainer (codenamev) owns it.
Minerva (minerva-sky), an autonomous agent that helps maintain this project,
reads this document before proposing anything and stays inside its fences. If a
proposal conflicts with this file, the proposal is wrong.

Status: PROPOSED. Drafted 2026-08-13 as a seven-section charter. Restructured
2026-09-19 under six standard headings, so the same question always has its
answer in the same place. Recalibrated 2026-11-25 around Autogenetica's loop (Seed → Assemble →
Operate → Prove → Preserve, under human governance) after the maintainer
pointed out the gem is far past plan-and-execute. Awaiting maintainer approval.

## VISION (where we hope this goes)

<!-- VAL: edit. Redrafted 2026-11-25 around the Autogenetica loop; still yours to write. -->

A Ruby developer seeds an intent and a few boundaries, and the system grows
the rest: it assembles agents out of small parts, runs them, checks what
actually worked, and keeps it. Next time it starts from what survived, not from
zero. Every part it reached for is versioned, every run leaves a journal that
says what happened and why, and a human can stop, read, or redirect it at any
step. Autonomy gets earned run by run, never assumed. Not the biggest agent
framework in Ruby. The one that carries its own work forward and can prove it.

## MISSION (what we're here to do)

A Ruby gem, library and CLI, for agents that assemble themselves from small,
reusable, composable parts. You seed it with a purpose and constraints; it
picks capabilities (and other agents) from a versioned store, composes them,
runs, observes what happened, and keeps what worked for next time. It exists
so Ruby developers get self-assembling agents whose plans, parts, and history
stay readable and editable, inside boundaries a human sets, without leaving
Ruby or adopting a framework the size of a small country.

## CONSTITUTION (what rules we must obey)

Agent contributions follow an autonomy ladder: L0 propose in an issue, L1 open
a PR the maintainer merges, L2 merge after a quiet period on green CI, L3 merge
on green CI and report in a digest. A class of change is promoted only by
maintainer approval on its acceptance record, and demoted immediately by any
revert. Gem releases and version bumps are the maintainer's alone.

Local additions for agentic:

- Small core. New runtime dependencies need strong justification; the gem
  should stay auditable in an afternoon.
- Public API changes follow semver and deprecation cycles. People's agents
  run on this.
- Tests accompany every behavior change. CI (main.yml) gates merges.
- Providers come through RubyLLM. No hand-rolled provider clients or a
  parallel abstraction layer.

Anti-goals, which are constraints wearing a different hat:

- Not a LangChain port. Ruby idioms over framework mimicry.
- Not a hosted platform. No server component, no accounts.
- Not an everything-store of integrations. Capabilities keep the core small;
  integrations belong in plugins or downstream gems.
- No speculative abstraction. Two concrete uses before one abstraction.

## ROADMAP (what next)

Ordered by the loop. Each item makes one stage real; a stage nobody can
observe doesn't count as built.

1. **Assemble.** Composable parts are the product. Capabilities and agents are
   the same kind of thing at different sizes: versioned, specified, stored,
   and callable by other agents. Depth here wins: better selection from the
   store, cleaner composition, agents that call agents. The plan is what
   assembly produces, an inspectable artifact rather than the point.
2. **Prove and preserve.** Each run is a hypothesis. The execution journal,
   resume from a torn run, and the learning system turn "it ran" into "here's
   the evidence it worked," and decide which parts and compositions earn a
   place in the store for next time. Work that closes this feedback loop beats
   work that widens the gem.
3. **Governance.** Human intervention is first-class state, not an exception:
   the run pauses, a person answers, it resumes. Boundaries set at seed time
   hold through every later stage.
4. **Provider-agnostic hypotheses.** Lean on RubyLLM for providers instead
   of building our own layer; it already speaks to the major ones. That makes
   model and parameters part of the hypothesis: a run can vary provider,
   model, temperature, and the rest, and the learning system records which
   combination worked for which kind of task and adapts what it picks next
   time. Today the gem is OpenAI-only, so the first step is swapping the
   client for RubyLLM without changing behavior.

Standing, not sequenced: good gem citizenship. Semantic versioning, honest
CHANGELOG, current Ruby. Track the latest stable Ruby; do not carry EOL
versions.

## AGENTS (how agents work here)

Improvements arrive as GitHub issues, labeled by origin and state:

- Origin: `loop:quality`, `loop:security`, `loop:deps`, `loop:research`,
  `loop:self` (agent-originated), or unlabeled (human-originated).
- State: `status:analyzed`, `status:deferred`, `status:wont-do`,
  `status:blocked`. A closed issue with `status:wont-do` records the reason in
  its final comment and is permanent institutional memory. Proposals must check
  closed and deferred issues before re-raising an idea.

Each change class has an autonomy level on the ladder above. Every class
starts at L0 or L1 and moves only by maintainer approval.

## CHARTER (why this exists, what territory, what freedoms)

**Why:** because the alternative for a Ruby developer is a framework the size
of a small country, or a loop around an API call that forgets everything the
moment it returns. Agents that build themselves are only worth having if what
they learn sticks and a human can check it.

**Territory:** <!-- VAL: edit. Redrafted 2026-11-25 to follow the loop stages. -->
agentic owns the parts (capabilities and agents, their specifications, and the
versioned store), the assembly engine that composes them, the orchestrator and
plan format that run them, the execution journal and learning system that
prove and preserve results, the intervention points where a human steps in,
and the CLI that drives all of it. It does not own hosting, accounts,
integrations beyond what the core needs to prove itself, or provider clients
(RubyLLM owns those).

**Freedoms:** the agent may open issues on anything in this territory, open
PRs at the class's autonomy level, and propose amendments to this file.

**Constraints:** the agent never merges amendments to this file, never cuts a
release or bumps a version, and never adds a provider integration that
bypasses RubyLLM.

## Amending this document

By pull request with maintainer approval, nothing else. The agent may propose
amendments; it may never merge them.
