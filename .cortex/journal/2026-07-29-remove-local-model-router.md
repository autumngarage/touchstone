# Remove the local model router from Touchstone delivery

**Date:** 2026-07-29
**Type:** decision
**Trigger:** T1.1, T1.4
**Cites:** journal/2026-07-26-exact-head-pr-review-gate.md

> Touchstone now owns deterministic local verification and exact-revision GitHub review orchestration, without a local semantic-review or provider-routing subsystem.

## Context

The supported delivery path had accumulated two overlapping review systems:
local provider-routed semantic review and PR-visible GitHub Codex review.
That duplication increased setup requirements, configuration states, fallback
behavior, test volume, and time-to-ship without improving the final
authorization invariant. Issue #552 records the removal scope.

The exact-head review gate introduced on 2026-07-26 already provides the
durable review boundary needed for merge authorization: the trusted result is
bound to the PR, head revision, and base revision, then revalidated immediately
before merge.

## What we decided

Remove Conductor and the local semantic-review subsystem from every supported
Touchstone surface. Keep one delivery path:

1. Run deterministic local checks.
2. Push the branch and request GitHub Codex review for the exact head and base.
3. Address actionable PR feedback on a new revision.
4. Require a fresh trusted review for that revision before merge.

Downstream updates remove formerly manifest-managed review helpers. Historical
Journal and feedback records remain unchanged because Cortex history is
append-only.

## Consequences / action items

- [x] Remove provider routing, local reviewer hooks, CLI commands, configs, setup guidance, and obsolete tests.
- [x] Add guards that reject disabling exact-revision review or request-on-push.
- [x] Preserve deterministic preflight and PR review evidence tests.
- [ ] Merge issue #552 and publish the Homebrew upgrade.
