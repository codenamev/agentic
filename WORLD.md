# WORLD.md: agentic, answered six ways

This file sets direction for agentic: what it exists to do, what it will not
become, and how proposed work gets judged. The maintainer (codenamev) owns it.
Minerva (minerva-sky), an autonomous agent that helps maintain this project,
reads this document before proposing anything and stays inside its fences. If a
proposal conflicts with this file, the proposal is wrong.

Status: PROPOSED. Drafted 2026-08-13 as a seven-section charter. Restructured
2026-09-19 under the six headings every repo in the fleet now shares, so a loop
session or a portfolio pass finds the same answer in the same place in every
repo. Awaiting maintainer approval.

## VISION (where we hope this goes)

<!-- VAL: edit. Drafted from the old Direction section; the charter never said where this goes, only which way it leans. -->

A Ruby developer describes a task and gets back an agent they can read. The
plan sits in a file they can open, edit, and save. The capabilities were
assembled from a versioned store the agent chose from itself. The execution
history explains what ran, what failed, and what it did about the failure. Not
the biggest agent framework in Ruby. The one you can argue with.

## MISSION (what we're here to do)

A Ruby gem for building and running AI agents in a plan-and-execute fashion,
as a library and a CLI. It exists so Ruby developers can build purpose-driven
agents with plans they can inspect, edit, and save, without leaving Ruby or
adopting a framework the size of a small country.

## CONSTITUTION (what rules we must obey)

The fleet's shared rules live in one place and this file links to them rather
than pasting: the [operator's constitution](https://github.com/minerva-sky/workspace/blob/master/WORLD.md#constitution-what-rules-we-must-obey).
That covers the autonomy ladder (L0 propose in an issue, L1 open a PR the
maintainer merges, L2 merge after a quiet period on green CI, L3 merge on green
CI and report in a digest), how a class gets promoted (maintainer approval on
the acceptance record) and demoted (any revert, immediately), and the rule that
gem releases and version bumps are the maintainer's alone.

Local additions for agentic:

- Small core. New runtime dependencies need strong justification; the gem
  should stay auditable in an afternoon.
- Public API changes follow semver and deprecation cycles. People's agents
  run on this.
- Tests accompany every behavior change. CI (main.yml) gates merges.
- No provider abstraction lands until the provider question below is decided.

Anti-goals, which are constraints wearing a different hat:

- Not a LangChain port. Ruby idioms over framework mimicry.
- Not a hosted platform. No server component, no accounts.
- Not an everything-store of integrations. Capabilities keep the core small;
  integrations belong in plugins or downstream gems.
- No speculative abstraction. Two concrete uses before one abstraction.

## ROADMAP (what next)

The old Direction section gave bearings. This is the same content as an order.

1. The plan is the product. Inspectable, editable, persistable plans are what
   separate this from "call the API in a loop." Depth here wins: better plan
   quality, better failure recovery, better execution history. Work that
   deepens the plan beats work that widens the gem.
2. The self-assembly and capability system (v0.2.0) is the bet worth maturing:
   agents that construct themselves from task requirements, with versioned
   capabilities and a persistent store.
3. Provider strategy is an open question. The gem is OpenAI-only today.
   Whether to abstract providers (and which second provider earns the
   abstraction) needs a researched proposal with a real cost, not a drive-by
   PR. This is third because the first two are what a second provider would
   have to plug into.

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

Each change class has an autonomy level per the constitution above. Every class
starts at L0 or L1, and the current level per class is recorded on the
operator's side, not here.

## CHARTER (why this exists, what territory, what freedoms)

**Why:** because the alternative for a Ruby developer is a framework the size
of a small country, or a loop around an API call with no plan anyone can read.

**Territory:** <!-- VAL: edit. The old charter drew this border only by negation (the anti-goals); this states it positively. -->
agentic owns the plan format, the executor, the capability and self-assembly
system, and the CLI that drives them. It does not own hosting, accounts,
integrations beyond what the core needs to prove itself, or a second provider
until one is chosen.

**Freedoms:** the agent may open issues on anything in this territory, open
PRs at the class's autonomy level, and propose amendments to this file.

**Constraints:** the agent never merges amendments to this file, never cuts a
release or bumps a version, and never lands a provider abstraction ahead of
the decision.

## Amending this document

By pull request with maintainer approval, nothing else. The agent may propose
amendments; it may never merge them.
