# Gate subsystem removals on migration-state enumeration, not a fixed matrix

**Date:** 2026-08-05
**Type:** decision
**Trigger:** T1.1
**Cites:** journal/2026-07-29-remove-local-model-router.md, GitHub issue #558, GitHub PR #562 (closed), GitHub PR #639

> Question 6 of the pre-implementation gate requires enumerating migration
> states from the subsystem's own persistence boundary instead of walking a
> prescribed global matrix.

## Context

PR #554 (local model-router removal) needed six serial external review rounds
because supported starting states — legacy-only config, mixed policy files,
re-init, retired CLI flags, downstream manifests — were discovered one head at
a time rather than enumerated up front. The first codification attempt
(PR #562) prescribed a fixed five-row migration matrix; three review rounds
showed the fixed shape accumulating special cases (optional absence, multiple
legacy layouts, interrupted writes, in-place schema changes) while still
missing domain-specific states, and it was closed without merge.

## What we decided

The gate asks each removal to derive its own state inventory from where the
subsystem actually persists itself (config files, generated artifacts,
installed hooks and skills, CLI entry points, downstream copies). For every
supported state the author names the invariant, the source of truth, and the
fail-closed behavior for unmatched inputs, and lands a per-state regression
fixture — plus a dedicated fixture for the unmatched-state explicit-error
fallback — before the first review request. Active compatibility is
distinguished from inert, time-bounded migration shims; a shim without a
removal condition is a second code path (gate question 3). No global state
count is prescribed.

## Consequences / action items

- [x] `principles/pre-implementation-checklist.md` question 6 (canonical)
- [x] `skills/touchstone-pre-impl/SKILL.md` compressed mirror
- [x] Steering-contract test pins both surfaces in sync and forbids
      Touchstone-local identifiers in the synced principle
