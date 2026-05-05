# ADR-0001: Hybrid Pinned Touchstone Script Shims

**Date:** 2026-05-05

## Status

Proposed

## Context

Touchstone copies operational shell scripts into each project so a repository's
branch, PR, review, merge, and cleanup behavior is reviewable in that
repository. That boundary is useful, but it creates drift: an installed
Touchstone CLI can be newer than the project-local scripts it is expected to
drive.

Recent Vesper Agent Tab work exposed the weak point. The installed package had
newer worktree helpers while the project still had older copied scripts. A user
reasonably expected the installed Touchstone behavior, but the reviewed project
boundary still pointed at stale local copies.

## Options

### Keep Copied Scripts

This preserves maximum reviewability and rollback. Every behavior change lands
as a normal project diff. The cost is repeated large file copies, stale script
surfaces, and harder UI integration because the active implementation is easy
to confuse with the installed CLI version.

### Replace Scripts With Latest-CLI Shims

A project-local file could simply delegate to the newest installed CLI. That
minimizes drift but weakens the review boundary: a Homebrew upgrade could
change merge behavior in every project without a project PR.

### Use Pinned Shims With Capability Checks

A project-local shim can declare the Touchstone script contract it was reviewed
against, then call an installed CLI dispatcher only if the CLI satisfies that
contract. The shim stays reviewable, while the large implementation can live in
one maintained copy.

## Decision

Use a hybrid migration path:

1. Keep project-local copied scripts as the default implementation for now.
2. Add a guarded dispatcher, `touchstone run-script`, as the prototype boundary
   for future pinned shims.
3. Require shims to declare a project version or capability before delegation.
4. Fail loudly when the installed CLI cannot prove it satisfies the declared
   contract.
5. Move low-risk helper scripts to pinned shims before considering merge,
   review, or hook paths.

The first safe shim candidates are cleanup and status-like helpers. `open-pr`,
`merge-pr`, and the review hook remain copied until the dispatcher has field
time and explicit rollback tooling.

## Contract

A future shim should be small enough to audit directly:

```bash
#!/usr/bin/env bash
set -euo pipefail
exec touchstone run-script cleanup-worktrees \
  --project-version "PROJECT_TOUCHSTONE_ID" \
  -- "$@"
```

The dispatcher must:

- allow only known Touchstone script names;
- verify the installed CLI version or git id satisfies the project contract;
- optionally require named capabilities for feature-level boundaries;
- run the implementation from the installed Touchstone root;
- print a clear remediation when the contract is not satisfied.

## Consequences

Copied scripts remain the conservative default, so existing projects and review
expectations do not change. The prototype gives UI clients and downstream repos
a concrete contract to test before any broad migration.

The tradeoff is that Touchstone temporarily has two script-delivery paths:
copied scripts in production and pinned shims in evaluation. `touchstone status`
and `touchstone update` must make the active implementation source visible so
callers do not infer the wrong behavior boundary.

