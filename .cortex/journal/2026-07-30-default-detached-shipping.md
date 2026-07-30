# Make wait-only workers the default shipping handoff

**Date:** 2026-07-30
**Type:** decision
**Trigger:** T1.1
**Cites:** principles/ai-delivery-architecture.md, principles/git-workflow.md, GitHub issues #524 and #556

> Routine shipping uses a wait-only detached worker so external review
> latency does not block the driving session or grant background mutation.

## Context

Foreground delivery kept the driving session occupied while GitHub review and
checks ran, even though that interval required no local branch mutation. The
experimental review-fix worker solved a broader problem by editing the branch,
but that authority is unnecessary for the routine path and adds recovery risk.

Issues #524 and #556 require the common workflow to return control immediately
while retaining the existing `open-pr.sh --auto-merge` review and merge gates.

## What we decided

Make `touchstone worker ship --worktree "$PWD" --detach` the routine shipping
handoff. The wait-only worker owns external review and check latency, invokes
the same foreground delivery path, and never edits the branch. Actionable
feedback or another nonzero result becomes durable `needs-attention` state for
an explicit driving-CLI takeover.

Keep foreground `open-pr.sh --auto-merge` available for diagnosis. Keep
autonomous review-fix experimental and explicitly opt-in.

## Consequences / action items

- [x] Document the handoff and takeover contract in the delivery principles.
- [x] Add deterministic worker state, event, and failure regressions.
- [x] Preserve exact-head GitHub review and merge authorization unchanged.
