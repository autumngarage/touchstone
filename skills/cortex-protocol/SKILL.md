---
name: cortex-protocol
description: Use when writing .cortex/ Journal/Doctrine/Plan artifacts, when a Tier-1 trigger fires (PR merged, plan transition, dependency change, release tag), or when validating cortex doctor compliance.
---

# Cortex Protocol

The Cortex protocol defines when AI agents write durable artifacts to `.cortex/` and the invariants those writes obey. Tier-1 triggers are machine-observable and audited; Tier-2 signals are advisory.

## When to invoke

- About to write a Journal, Doctrine, Plan, or Digest entry under `.cortex/`
- A Tier-1 trigger just fired (see list below)
- Validating compliance via `cortex doctor --audit`
- Promoting a Doctrine candidate, superseding existing Doctrine, or generating a digest
- Explaining a historical decision the project has captured in Cortex

For the full protocol (templates, frontmatter shape, generation rules): read **`.cortex/protocol.md`** now.

## Tier-1 triggers (machine-observable, audited)

Each fires writes from a matching template:

- **T1.1** — Diff touches `.cortex/doctrine/`, `.cortex/plans/`, `principles/`, or `SPEC.md`
- **T1.2** — Test command failed after succeeding earlier in the session
- **T1.3** — Plan `Status:` field changed (`active` → `shipped|cancelled|deferred|blocked`)
- **T1.4** — File deletion exceeding N lines (default 100)
- **T1.5** — Dependency manifest changed (`pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, `Gemfile`)
- **T1.6** — Sentinel cycle ended
- **T1.7** — Touchstone pre-merge ran on architecturally significant diff (writes a Doctrine candidate)
- **T1.8** — Commit matches `fix: ... regression`, `refactor: ... (removes|introduces)`, `feat: ... (breaking|replaces)`
- **T1.9** — PR merged to the default branch
- **T1.10** — Tagged release shipped (writes a `release.md` Journal entry)

## Invariants (apply to every write)

- **Journal is append-only.** Never edit an existing entry. New information that revises an old conclusion → new entry that cites the old one.
- **Doctrine is immutable.** Changes happen via a new entry with `supersedes: NNNN` frontmatter; the old entry stays with `Status: Superseded-by NNNN`.
- **Generated layers declare provenance.** Generated files (`map.md`, `state.md`, digests) include seven metadata fields: `Generated`, `Generator`, `Sources`, `Corpus`, `Omitted`, `Incomplete`, `Conflicts-preserved`. Individual Journal/Doctrine entries do NOT need these — they're written by humans/agents directly.
- **Digests cap depth.** A digest may cite other digests at most one level deep; quarterly digests cite ≥5 raw Journal entries directly.

## Session start

`cortex manifest --budget <N>` loads the budgeted slice (state + always-priority Doctrine + active plans + recent Journal). The agent does NOT read `.cortex/` directly at session start unless the CLI is unavailable; in that fallback, `@.cortex/protocol.md` and `@.cortex/state.md` are the minimum viable manifest.
