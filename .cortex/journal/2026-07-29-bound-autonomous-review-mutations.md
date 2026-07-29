# Bound autonomous review mutations without semantic classification

**Date:** 2026-07-29
**Type:** decision
**Trigger:** T1.1
**Cites:** principles/ai-delivery-architecture.md, principles/git-workflow.md, GitHub issue #543

> Touchstone permits at most two model-authored mutation cycles before
> preserving the branch for explicit takeover.

## Context

Issue #543 identified that detached review-fix and the legacy fix-capable hook
could dispatch a third edit even after repeated review cycles kept exposing new
defects. The proposed remedy persisted a model-derived "structural" finding
classification across cycles. That would have added another semantic state
protocol to shell implementations that already coordinate reviewer output,
branch state, GitHub evidence, and recovery checkpoints.

The safety requirement is narrower: autonomous tooling must stop before a third
model-authored mutation while preserving validated work for a driver.

## What we decided

Apply a deterministic ceiling of two mutation cycles to both edit-capable
review paths. Lower operator budgets remain valid, while higher configured or
requested values are clamped visibly. Finding classification is unnecessary
because the ceiling applies to every finding class.

Detached review-fix remains experimental. On any `needs-attention` terminal
state, it records the stop reason, invariant, last validated fix head, and
non-goals without cleaning the worktree or dispatching another edit. Wait-only
detached shipping remains the supported background-latency adapter.

## Consequences / action items

- [x] Add deterministic regressions for both autonomous mutation paths.
- [x] Document the supported core and experimental adapter boundary.
- [x] Track removal of the duplicated review-hook implementation in issue
  #546 instead of combining consolidation with this behavior change.
- [ ] Resolve the broader preflight runtime problem separately in issue #517.
