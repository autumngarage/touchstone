# Bound delivery loops to one shippable invariant

**Date:** 2026-07-29
**Type:** decision
**Trigger:** T1.1
**Cites:** doctrine/0001-touchstone-owns-shared-agent-workflow, journal/2026-07-26-exact-head-pr-review-gate

> Touchstone freezes and splits a delivery branch when review repeatedly expands its scope beyond one shippable invariant.

## Context

PR #523 combined review authorization, worker lifecycle, concurrency, diagnostics, and guidance across 34 commits. Thirty-one formal reviews and repeated fix cycles kept finding valid work, but the branch had no stop condition, so review became a mechanism for indefinite scope growth. Touchstone displaced the Vesper product work it was meant to enable.

Issue #536 records the failure mode and the required guardrail. The existing guidance also told agents to bundle work when asked to "ship it all," which treated user priority as permission to erase subsystem boundaries.

## What we decided

Every nontrivial delivery slice names one invariant, the minimum coupled surfaces required to ship it, focused validation, non-goals, and a stop condition before implementation. "Ship everything" defines an ordered queue of independently shippable PRs. Review findings stay in the current PR only when they protect its invariant; independently shippable findings become filed follow-up work and are claimed only when implementation starts.

A branch freezes for split or replan when review reveals another independently shippable concern, its file surface expands beyond the minimum needed for the invariant, two consecutive review/fix cycles uncover new structural defects, the delivery platform dominates the customer work, or a failing gate cannot identify the failed command.

## Consequences / action items

- [x] Add the circuit breaker to canonical engineering, pre-implementation, and git workflow guidance in PR #538.
- [x] Align `scripts/open-pr.sh` with independent-slice guidance.
- [x] Add regression assertions that prevent the canonical and command-level guidance from drifting.
- [ ] Ship the diagnostic improvement tracked by issue #537 as a separate concern.
