# Bind merge authorization to complete exact-head PR review evidence

**Date:** 2026-07-26
**Type:** decision
**Trigger:** T1.1
**Cites:** journal/2026-06-11-pr-agentic-review-guidance, journal/2026-06-11-pr-feedback-merge-gate

> Touchstone authorizes a merge from PR-visible AI evidence only when every trusted evidence channel was inspected successfully and the globally latest result is clean for the full current head OID.

## Context

PR #472 moves the required AI review from a hidden local merge step to the GitHub pull request. GitHub Codex exposes clean results as top-level comments with abbreviated commit markers and findings as formal reviews or review threads. Treating reactions, partial API responses, API ordering, or an abbreviated-prefix comparison as approval could let stale or incomplete evidence satisfy the gate.

The rollout also has to preserve existing `[review]` boolean aliases used by downstream projects while making the new `[review.pr_triggered]` security controls fail closed on malformed values.

## What we decided

`merge-pr.sh` treats PR-visible review evidence as an authorization boundary. It refreshes policy from the trusted default branch, validates the new controls strictly, inspects both formal-review and issue-comment channels, resolves abbreviated markers to a full repository commit OID, aggregates timestamp ties without trusting API order, and requires the latest exact-head result to be clean. Inspection failures and trusted findings are distinct terminal states; findings stop polling immediately, while transient inspection failures remain retryable within the configured window.

An audited rollout bypass may use the same trusted exact-head evidence when the legacy local reviewer is unavailable, but it still requires explicit disclosure and final evidence revalidation before merge.

## Consequences / action items

- [x] Add regression coverage for stale, spoofed, malformed, colliding, tied, partial, unavailable, and non-clean review evidence.
- [x] Preserve established `[review]` boolean aliases and validate new trusted controls strictly.
- [x] Require a fresh PR-visible review after every fix changes the head.
- [x] Link the implementation and follow-up fixes to PR #472 and issues #467, #469, #471, #473, and #478-#488.
