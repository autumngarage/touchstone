# Enforce PR feedback at the merge gate

**Date:** 2026-06-11
**Type:** decision
**Trigger:** T1.1
**Cites:** journal/2026-06-11-pr-agentic-review-guidance, journal/2026-06-11-pr-merged-1313

> Touchstone's merge helper now treats GitHub's PR-visible review state as a hard merge input, not just driver guidance.

## Context

The previous guidance moved Touchstone toward a PR-visible agentic review loop, but `merge-pr.sh` still only enforced mergeability, deterministic checks, and Conductor review. A PR could have active requested-changes reviews or unresolved review threads and still reach the local merge helper if GitHub branch protection did not require those signals.

## What we decided

`merge-pr.sh` should fail closed before squash merge when GitHub reports a draft PR, an active `CHANGES_REQUESTED` review decision, unresolved review threads, or an inability to inspect thread-level review state. The gate runs before model-review spend and again after Conductor review/fix work on the exact reviewed head.

## Consequences / action items

- [x] Add a merge-gate PR feedback check backed by GitHub GraphQL review thread state.
- [x] Add regression coverage for draft PRs, requested changes, unresolved threads, thread-inspection failure, and post-review thread changes.
