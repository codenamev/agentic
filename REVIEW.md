# REVIEW.md

What a bad merge looks like in this repo. A reviewer (human, review panel, or an agent on a tick) reads this before the diff. It is a prior, not a checklist: it says where this codebase has actually broken so the review spends its attention there.

## What failure looks like here

- **Sanitizer regex drift.** A change to `lib/agentic/security/sanitizer.rb` widens or narrows a redaction pattern and something that was never a secret gets eaten (UUIDs redacted as phone numbers, #54) or something that is a secret gets through. Every pattern change needs a spec that pins both sides.
- **Secrets steered onto disk.** CLI, setup, or README code that writes a key into a file nothing gitignores or nothing reads (`.agentic.yml`, #59/#66). Any new file write that can carry a credential is a finding.
- **Writes that escape the workspace.** Artifact or store paths built from model output without containment (symlinks, `..`, absolute paths; #28/#30), or a `SecurityError` swallowed by a `StandardError` rescue (#50).
- **Works in the dev bundle, breaks on `require "agentic"`.** A `lib/` file requires a gem the gemspec does not declare (#63/#74), or a `require_relative` between siblings reappears where Zeitwerk should load it (#57/#78). Green specs do not catch this; a gem-contents or load spec does.
- **One-Ruby green.** Behaviour that splits across the CI matrix (3.2 floor through 4.0, #27/#33): frozen-string defaults, timing specs, `json` strictness (#76). A PR is green on every matrix row or it is not green.
- **Documented, wired to nothing.** A new public class, config, or option with zero callers (#69/#70/#71, `secure_error_class!` #60), or an existing public API removed without a deprecation cycle. The README describing it is not evidence it runs.

## Evidence rule

Every finding cites `path:line` and names the input, command, or Ruby version that triggers it. No file and line, no finding. A finding that cannot be checked from a phone is a comment, not a finding.

## Nit cap

Three nits per review. Past three, pick the three that matter and drop the rest. Style is StandardRB's job.

## Skip paths

Ignore these unless the PR is about them:

- `CHANGELOG.md` (an Unreleased-entry collision is noise, not a review finding)
- `Gemfile.lock` (dependency PRs excepted; the audit workflow owns advisories)
- `coverage/**`, `reports/**`, and the root `plan-*.json` / `result-*.json` run artifacts
- `examples/**` (they are samples, not the gem's surface)
