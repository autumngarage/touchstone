---
Generated: 2026-05-05T09:47:13-04:00
Generator: cortex refresh-state v0.8.2 + hand-authored install baseline
Sources:
  - HEAD sha: d7262aa
  - .cortex/plans/*.md (2 files)
  - .cortex/journal/*.md (2 entries, 2026-05-05..2026-05-05)
  - .cortex/doctrine/*.md (1 entries)
  - .cortex/config.toml
  - CLAUDE.md
  - AGENTS.md
  - .cortex/templates/**/*.md (12 templates)
  - docs/case-studies/*.md (0 case studies)
  - SPEC version: 0.5.0
  - (no project manifest detected) + cortex package version: 0.8.2
Corpus: 2 Journal entries, 2 Plans, 1 Doctrine entries, 12 Templates, 0 Case studies
Omitted:
  []
Incomplete:
  - docs/case-studies — missing source directory
Conflicts-preserved: []
Spec: 0.5.0
---

# Project State

## Current work

Touchstone now has a Cortex v0.5.0 scaffold on `main` from PR #149. The follow-up Cortex install branch adds the remaining production dogfood pieces: `.cortex/config.toml` audit configuration, a Touchstone ownership doctrine entry, a baseline journal entry, `.gitignore` Cortex runtime ignores, and explicit Cortex imports in `CLAUDE.md` / `AGENTS.md`.

Critical guardrail: Cortex must stay out of Touchstone-managed write paths (`principles/`, `scripts/`, `.codex-review.toml`, `.pre-commit-config.yaml`) unless the task is explicitly a Touchstone platform change.

## Active plans

- `touchstone-cortex-metadata` — Complete Touchstone Cortex metadata; Goal-hash `8ff95fbf`; 100% complete (4/4 checkboxes)

## Open questions

`cortex doctor --audit-instructions` currently emits noisy false positives on Touchstone. Track upstream Cortex issues before treating a warning-free audit as a Touchstone gate:

- cortex#123 — README placeholder `~/Repos/my-*` paths are treated as missing filesystem siblings.
- cortex#124 — all `vX.Y.Z` strings are compared against every configured GitHub/Homebrew release surface.
- cortex#125 — config-reference docs still mention the removed `gh_release` key.

## Shipped recently

- **2026-05-05** — Touchstone Conductor integration plan — active -> shipped (`.cortex/journal/2026-05-05-touchstone-conductor-plan-shipped.md`, Type: plan-transition)
- **2026-05-05** — Cortex install baseline recorded (`.cortex/journal/2026-05-05-cortex-install-baseline.md`, Type: decision)

## Stale-now / handle-later

- none
