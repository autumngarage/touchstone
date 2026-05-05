---
Status: active
Written: 2026-05-05
Author: codex
Goal-hash: 8ff95fbf
Updated-by:
  - 2026-05-05T09:00 codex (created for Touchstone issue #136)
Cites: state.md § Active plans, GitHub issue #136
---

# Complete Touchstone Cortex metadata

> Complete the missing `.cortex/` scaffold and make the manifest load Touchstone's current state instead of stale roadmap content.

## Why (grounding)

GitHub issue #136 records that `cortex manifest --budget 12000` warned about a missing `.cortex/SPEC_VERSION` and emitted an unusably small manifest. `state.md § Active plans` now identifies this metadata cleanup as the active Cortex work and records the old Conductor roadmap as historical.

## Approach

Use `cortex init` with AGENTS/CLAUDE and gitignore edits disabled so the change stays limited to `.cortex/`. Keep generated scaffold files from Cortex v0.8.2, then hand-author only the small canonical state and active plan needed for clean manifests.

Preserve the existing Touchstone x Conductor plan as historical context, but do not let it remain the active session-start plan after the implementation has landed in the codebase.

## Success Criteria

- `cortex manifest --budget 12000` exits without compatibility warnings.
- `cortex doctor` exits 0, or reports only documented warnings outside the `.cortex/` metadata contract.
- `.cortex/state.md` names the current active Cortex metadata plan and does not duplicate repo-root roadmap/status content.

## Work items

- [x] Scaffold missing `.cortex/SPEC_VERSION`, protocol, state, map, directory, and template metadata with Cortex v0.8.2.
- [x] Replace placeholder state with the canonical current Touchstone Cortex state.
- [x] Add this focused active plan for issue #136.
- [x] Validate `cortex manifest --budget 12000` and `cortex doctor`.

## Follow-ups (deferred)

No deferred follow-ups.

## Known limitations at exit

- This plan does not rewrite the agent steering files unless Cortex reports a `.cortex/` compatibility problem that requires it.
