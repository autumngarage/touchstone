# Bound review-fix loops at the driving CLI

**Date:** 2026-07-29
**Type:** decision
**Trigger:** T1.1
**Cites:** doctrine/0001-touchstone-owns-shared-agent-workflow, journal/2026-07-26-exact-head-pr-review-gate

> The driving CLI stops dispatching fixes when repeated structural review cycles show that the branch no longer represents one shippable concern.

## Context

PR #523 grew to 34 commits because the driving session kept accepting valid findings across review authorization, worker lifecycle, concurrency, diagnostics, and guidance. Replacement PRs #538 and #542 were closed when their own reviews crossed the same boundary. Issue #536 records the failure and the required driving behavior.

GitHub review of #542 also proved that guidance cannot claim to enforce the inner loop of an already-running autonomous worker. That separate orchestration requirement is tracked in issue #543.

## What we decided

Before initiating or dispatching another edit, the driving CLI stops after two consecutive review/fix cycles reveal new structural defects or review expands the work to another independently shippable concern. It preserves the branch, records the stop state in the PR or issue, and splits or replans.

Regressions introduced by the current diff remain blocking. Pre-existing independent findings become unclaimed issues. This release deliberately makes no claim about autonomous worker enforcement.

## Consequences / action items

- [x] Add the driving-CLI stop rule to always-loaded and canonical guidance.
- [x] Reconcile the older "ship it all" bundling instruction.
- [ ] Enforce the same threshold inside autonomous workers in issue #543.
