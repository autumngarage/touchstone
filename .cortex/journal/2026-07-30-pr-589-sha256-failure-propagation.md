# PR #589 merged — propagate SHA-256 command failures

**Date:** 2026-07-30
**Type:** pr-merged
**Trigger:** T1.9
**Cites:** GitHub issue #588, GitHub PR #589, journal/2026-07-30-pr-587-windows-sha256
**Merge-commit:** e6ed7dc691758ae556c7eee39d42dd82724848ba
**Branch:** fix/sha256-failure-propagation

> Touchstone made checksum failure propagation independent of caller shell
> options after downstream exact-head review exposed the weak point.

## What shipped

- Capture the selected checksum executable's output before parsing it.
- Preserve the executable's exact nonzero status without relying on ambient
  `pipefail`.
- Reject successful command output unless it contains a 64-digit hexadecimal
  digest.
- Add regressions for a failing preferred executable, malformed output,
  `sha256sum` fallback, and missing implementations.
- Re-prove the adapter in the focused Git for Windows workflow and the complete
  deterministic merge gate.

## Closes / advances

- **Plans:** none
- **Doctrine:** none
- **Journal linkage:** hardens
  `journal/2026-07-30-pr-587-windows-sha256`

## Follow-ups (deferred to future work)

_None._

(Per SPEC § 4.2, deferred items must resolve to another Plan, Journal entry, or
Doctrine entry in the same commit as the merge note.)

## What we'd do differently

Test shared helpers under callers without ambient strict-shell options during
the first portability change, rather than relying only on strict Touchstone
callers.
