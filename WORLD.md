# WORLD.md — project charter

This file sets direction for agentic: what it exists to do, what it will not
become, and how proposed work gets judged. The maintainer (codenamev) owns it.
Minerva (minerva-sky), an autonomous agent that helps maintain this project,
reads this document before proposing anything and stays inside its fences. If a
proposal conflicts with this file, the proposal is wrong.

Status: PROPOSED. Drafted 2026-08-13, awaiting maintainer approval.

## Purpose

A Ruby gem for building and running AI agents in a plan-and-execute fashion,
as a library and a CLI. It exists so Ruby developers can build purpose-driven
agents with plans they can inspect, edit, and save, without leaving Ruby or
adopting a framework the size of a small country.

## Direction

- The plan is the product. Inspectable, editable, persistable plans are what
  separate this from "call the API in a loop." Depth here wins: better plan
  quality, better failure recovery, better execution history.
- The self-assembly and capability system (v0.2.0) is the bet worth maturing:
  agents that construct themselves from task requirements, with versioned
  capabilities and a persistent store.
- Good gem citizenship: semantic versioning, honest CHANGELOG, current Ruby.
  Track the latest stable Ruby; do not carry EOL versions.
- Provider strategy is an open question. The gem is OpenAI-only today. Whether
  to abstract providers (and which second provider earns the abstraction) needs
  a researched proposal with a real cost, not a drive-by PR. Until decided,
  no provider abstraction lands.

## Constraints

- Small core. New runtime dependencies need strong justification; the gem
  should stay auditable in an afternoon.
- Public API changes follow semver and deprecation cycles. People's agents
  run on this.
- Tests accompany every behavior change. CI (main.yml) gates merges.

## Anti-goals

- Not a LangChain port. Ruby idioms over framework mimicry.
- Not a hosted platform. No server component, no accounts.
- Not an everything-store of integrations. Capabilities keep the core small;
  integrations belong in plugins or downstream gems.
- No speculative abstraction. Two concrete uses before one abstraction.

## How work gets proposed

Improvements arrive as GitHub issues, labeled by origin and state:

- Origin: `loop:quality`, `loop:security`, `loop:deps`, `loop:research`,
  `loop:self` (agent-originated), or unlabeled (human-originated).
- State: `status:analyzed`, `status:deferred`, `status:wont-do`,
  `status:blocked`. A closed issue with `status:wont-do` records the reason in
  its final comment and is permanent institutional memory. Proposals must check
  closed and deferred issues before re-raising an idea.

## Review policy

Changes are classed by risk (external visibility times reversibility), and each
class has an autonomy level that can rise as the agent's track record earns it:

- L0: propose in an issue only.
- L1: open a PR; the maintainer merges.
- L2: open a PR; it may merge after a 72-hour quiet period with green CI.
- L3: merge on green CI, reported in a digest.

Every class starts at L0 or L1. Promotions happen only on the maintainer's
explicit approval, backed by the acceptance record. Any revert demotes the
class immediately. Gem releases and version bumps are the maintainer's alone.

## Amending this document

By pull request with maintainer approval, nothing else. The agent may propose
amendments; it may never merge them.
