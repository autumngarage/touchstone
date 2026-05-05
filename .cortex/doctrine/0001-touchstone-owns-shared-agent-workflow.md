# 0001 — Touchstone owns shared agent workflow and review scaffolding

> Touchstone is the shared engineering platform for agent instructions, engineering principles, review hooks, helper scripts, and bootstrap/update flows that downstream projects consume.

**Status:** Accepted
**Date:** 2026-05-05
**Promoted-from:** journal/2026-05-05-cortex-install-baseline.md
**Cites:** journal/2026-05-05-cortex-install-baseline.md, ../../README.md, ../../CLAUDE.md, ../../AGENTS.md
**Grounds-in:** ../../principles/engineering-principles.md
**Load-priority:** always

## Context

Touchstone is not a normal application repo. Changes to `principles/`, `hooks/`, `scripts/`, and the bootstrap/update flow propagate into downstream projects, so its local workflow guidance is also platform policy.

Cortex was installed on Touchstone during the Cortex v0.9.0 dogfood gate to validate that project memory can coexist with the tool that owns shared agent scaffolding. The install deliberately keeps Cortex files under `.cortex/` plus project steering imports, and avoids Touchstone-managed write paths.

## Decision

Touchstone owns shared agent workflow and review scaffolding. Treat changes to its platform-owned paths as downstream-affecting behavior changes, not local cleanup.

Cortex records Touchstone memory in `.cortex/` and project steering imports only. Cortex must not mutate Touchstone-managed propagation paths unless a future task explicitly changes Touchstone itself.

## Consequences

- **What becomes easier:** Agents can load the project purpose and ownership boundary without rereading every steering file.
- **What becomes harder:** Cortex install and refresh work must keep platform-owned paths out of generated or incidental edits.
- **What this forecloses:** Silent Cortex rewrites of `principles/`, `scripts/`, `.codex-review.toml`, or `.pre-commit-config.yaml` as part of memory maintenance.
