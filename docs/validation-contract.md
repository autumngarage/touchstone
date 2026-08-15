# Validation Contract

This document owns Touchstone's schema-v1 validation boundary. The canonical
example is [`.touchstone.toml`](../.touchstone.toml); other documentation links
here instead of copying the shape.

## Ownership

Projects own declarations. `scripts/touchstone-run.sh` is the single generic
engine: the future Homebrew CLI invokes it locally, and the organization
required workflow invokes the same reviewed revision remotely. Neither path
detects a project type, package manager, command, or target.

Schema 1 is a deliberately narrow TOML subset:

- `schema = 1` at the root;
- one `[validation]` table with `runtime = "bash"` and an optional, non-empty
  `setup` command;
- one or more `[[validation.targets]]` tables, each with a unique `name` and a
  project-relative `path` that cannot escape the repository;
- one or more `[[validation.tasks]]` tables, each with a unique `name`, an
  existing target name, an explicit `required` boolean, and a `command`;
- an optional task may omit `command` and then skips visibly; a required task
  may not omit it; and
- strings are single-line TOML basic strings. Schema 1 accepts `\"` and `\\`
  escapes and intentionally rejects multiline strings and broader TOML syntax.

The optional `[tracker]` table belongs to the
[tracker adapter contract](tracker-contract.md). The validation reader accepts
and validates that public shape without using it to choose tasks or verdicts;
no tracker value changes validation behavior.

The last restriction is part of the versioned contract, not an incomplete
parser. A future schema may add syntax without changing what schema 1 means.

## Verdict semantics

A declaration is a promise. A required command that is missing, cannot start,
or exits nonzero fails. A command whose process starts and returns 126 or 127
counts as ran; a command head the shell cannot start does not. Earlier target
failures remain failures even when later targets pass. A validation in which no
task ran fails.

Human output and `--json` both report ran, skipped, and failed counts. JSON is
the stable automation boundary and identifies every failing task, target,
status, and reason. Configuration is the only behavioral source of truth;
ambient variables cannot select another project, config, command, or target.
Tests and adapters that need a different location pass the explicit
`--project` or `--config` arguments.

Missing, malformed, ambiguous, path-escaping, and unsupported-schema contracts
fail closed. A repository that still has `.touchstone-config` receives an
explicit migration error; frozen consumers keep their committed legacy runner
until a reviewable adoption plan creates `.touchstone.toml`.

## Legacy CI compatibility audit

`scripts/check-legacy-ci.sh <repository>` detects the known-bad frozen pairing:
a default-branch push workflow runs every pre-commit-stage hook while
`no-commit-to-branch` is enabled for that stage. It is read-only and exits 3
with the reviewable repair: set `SKIP=no-commit-to-branch` only on the protected
branch push step, leaving pull-request hygiene and all other hooks intact.

The organization-required workflow does not run pre-commit and therefore
cannot compose a local authoring guard into CI. Fleet audits and live
required-workflow scenarios use the permanent
`autumngarage/touchstone-policy-canary` repository documented in
`policy/github/README.md`; the canary is retained for future policy and
validation tests.
