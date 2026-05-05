# Cortex install baseline

**Date:** 2026-05-05
**Type:** decision
**Trigger:** T1.1
**Cites:** doctrine/0001-touchstone-owns-shared-agent-workflow.md, plans/touchstone-conductor-integration.md, journal/2026-05-05-touchstone-conductor-plan-shipped.md

> Cortex was installed on Touchstone as the second v0.9.0 dogfood target, with audit findings filed upstream instead of hidden in local config.

## Context

Touchstone had a partial pre-v0.5 Cortex scaffold: `.cortex/plans/touchstone-conductor-integration.md` existed, but the rest of the protocol scaffolding was absent. PR #149 completed the basic scaffold, marked the historical Touchstone x Conductor plan shipped in place, and added a focused metadata plan for that cleanup.

The install ran from a clean worktree because the primary Touchstone checkout had an unrelated local edit in `bootstrap/new-project.sh`. Cortex stayed out of Touchstone-managed write paths: `principles/`, `scripts/`, `.codex-review.toml`, and `.pre-commit-config.yaml` were not modified.

## What we decided

The historical Touchstone x Conductor plan stays in `.cortex/plans/` with `Status: shipped` as design history rather than active session-start work.

The audit config names Touchstone's distribution surface and Autumn Garage sibling paths, including the vanguard `CLAUDE.md` cross-link that references Conductor as Touchstone's review router. The first audit intentionally kept the noisy findings visible and filed them as Cortex bugs:

- cortex#123 — README placeholder `~/Repos/my-*` paths are treated as missing sibling repos.
- cortex#124 — unrelated version strings are compared against every configured GitHub/Homebrew release surface.
- cortex#125 — `docs/config-reference.md` still documents the removed `gh_release` key.

## Consequences / action items

- [ ] Keep the Touchstone install PR scoped to Cortex metadata and steering imports.
- [ ] Track cortex#123 and cortex#124 before using Touchstone's audit output as a clean external-claim gate.
- [ ] After Cortex audit false positives are fixed, rerun `cortex doctor --audit-instructions` on Touchstone and expect a non-noisy result.
