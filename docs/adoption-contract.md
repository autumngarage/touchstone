# Adoption Contract

This document owns the public adoption and upgrade interface. The durable
product boundary remains in [product-contract.md](product-contract.md), and the
generated project declaration is owned by
[validation-contract.md](validation-contract.md).

## Commands and modes

`touchstone adopt --check` reports whether repository-file adoption is current.
`touchstone adopt --dry-run` prints the complete proposed diff. Plain
`touchstone adopt` applies that same plan. `touchstone upgrade` exposes the same
three modes but refreshes only Touchstone-owned steering bytes; it never
rewrites an accepted declaration of any supported schema.

Both commands accept `--json` and `--project DIR`. Fresh adoption accepts
repeated `--task NAME=COMMAND` arguments for the explicit manual path and
`--tracker github|linear`; Linear also requires `--tracker-prefix KEY`.
Compatibility defaults a missing tracker option or declaration to GitHub.
Repeating adoption against an existing tracker declaration accepts no
replacement tracker or task options; an older adopted project without the
tracker declaration may select it during adoption.

Exit classes are stable: 0 means current, planned, or applied; 2 is invalid
invocation; 3 means `--check` found a required change; 4 is ambiguous or
unsupported input; 5 is an apply-safety refusal; and 6 is an operational
failure.

## Versioned plan

Human dry-run output is a deterministic unified diff. JSON schema
`touchstone.adoption/v1` carries the operation, status, detected profile,
ordered file changes, the same diff, and a `remotePolicy` result. Repository
adoption never reads or mutates GitHub policy; the plan always reports that as
a separate operation.

Detectors return records in one model. They do not write, and validation never
runs them. One generic planner renders every candidate file without mutating
the repository.

## Automatic scope

Version 1 recognizes only the byte-bound portfolio in
`tests/fixtures/adoption-v1`:

- npm with `package.json` and `package-lock.json`;
- Python with `pyproject.toml`; automatic locked setup also requires `uv.lock`,
  while an explicit legacy or manual command remains available without it; and
- Swift Package Manager with `Package.swift`.

The npm adapter parses JSON with the portable `awk` already in Touchstone's
base tool surface. It validates the complete document, reads only the top-level
`scripts` object, and never requires the project's Node runtime to inspect a
plan.

An absent shape or competing ecosystem evidence selects the explicit manual
path; it never earns a speculative parser. Adding a profile requires a current
portfolio repository, captured source artifacts, and an independent case before
detector code.

Adapters may declare locked setup that installs a project's own dependencies.
That provisioning is an explicit project command and part of project
validation, not a toolchain dependency secretly added by the central workflow.
Touchstone's own required test remains offline; consumer declarations remain
responsible for the availability and determinism of their intrinsic
dependencies.

Legacy `.touchstone-config` is read only for explicit validation commands and
is never deleted. A full-validation alias wins over individual commands. When
no explicit legacy command exists, the captured automatic profile decides the
proposal.

## Ownership and safety

The planner may propose the project-owned `.touchstone.toml` and
`.touchstone-tracker.toml` declarations, create complete Touchstone-owned
sources under `.touchstone/`, and create or replace only the exact
`touchstone:steering` block in `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md`.
Everything outside those markers remains project-owned. Updates preserve each
existing file's mode as project-owned metadata.

Existing valid declarations of any supported schema remain byte-for-byte unchanged. Adopt
fills missing steering integration points without refreshing existing managed
sources; explicit upgrade refreshes them. Symlinks, malformed or repeated
markers, ignored managed outputs, untracked existing managed output,
unsupported schema and paths outside the repository refuse without a write.

No adoption or upgrade operation deletes a project file. A breaking schema,
obsolete path, or remote-policy change requires its own explicit reviewable
operation and recovery plan.

Apply requires a clean, attached, non-default branch. The remote default-branch
symbolic ref is authoritative; without it, exactly one local `main` or `master`
branch must identify the default. Before writing, the applier rechecks the
complete accepted diff. Every planned output is then byte-verified. A failed
apply restores original files and removes newly created files; unexpected
concurrent content is preserved with recovery snapshots instead of overwritten.
