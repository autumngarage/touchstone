# Bound review-fix loops with an explicit stop

**Date:** 2026-07-29
**Type:** decision
**Trigger:** T1.1
**Cites:** doctrine/0001-touchstone-owns-shared-agent-workflow, journal/2026-07-26-exact-head-pr-review-gate

> Touchstone stops a branch after repeated structural review cycles instead of turning the branch into an unbounded backlog.

## Context

PR #523 grew to 34 commits across review authorization, worker lifecycle, concurrency, diagnostics, and guidance. Repeated reviews kept finding valid work, but no rule stopped those findings from expanding the same branch. Replacement policy PR #538 then repeated the pattern until it was closed under the circuit breaker recorded in issue #536.

## What we decided

A branch stops before another edit when two consecutive review/fix cycles reveal new structural defects or review expands the work to another independently shippable concern. Before handoff, the driver records the invariant, validation completed, non-goals, and stop reason in the PR or issue.

The boundary cannot defer a regression introduced by the current diff: current-diff correctness, security, and data-integrity defects remain blocking until fixed or reverted. Pre-existing independent findings become unclaimed issues. Work resumes with the smallest shippable concern, with release blockers first only when they exist.

## Consequences / action items

- [x] Add the stop rule to always-loaded and canonical guidance.
- [x] Add a steering contract test for the stop, regression, and handoff requirements.
- [ ] Improve failing-test diagnostics separately in issue #537.
