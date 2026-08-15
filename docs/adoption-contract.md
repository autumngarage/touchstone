# Adoption Contract

This document owns the public adoption and upgrade interface. The durable
product boundary remains in [product-contract.md](product-contract.md), and
the generated project declaration is owned by
[validation-contract.md](validation-contract.md).

## Commands and modes

`bin/touchstone` exposes three command modules today:

- `touchstone validate` invokes the schema-v1 declaration engine;
- `touchstone adopt` compiles repository facts into a complete local-file plan;
  and
- `touchstone upgrade` refreshes only Touchstone-owned steering content while
  preserving an accepted schema-v1 declaration.

Adopt and upgrade accept `--check`, `--dry-run`, `--json`, and `--project DIR`.
Adopt additionally accepts repeated `--task NAME=COMMAND` arguments for the
generic manual-declaration path. Check and dry-run are read-only. Apply uses
the same plan as dry-run and is permitted only from a clean, non-default
branch.

Repeating adopt against an existing valid declaration fills missing steering
integration points but preserves existing managed steering bytes. Refreshing
those bytes requires the explicit upgrade command, so installing a newer CLI
does not silently turn an already-correct project into a mandatory rewrite.

Exit classes are stable: 0 means current, planned, or applied successfully; 2
means invalid invocation; 3 means `--check` found a required change; 4 means
the repository contract was ambiguous or unsupported; 5 means apply refused a
worktree safety precondition; and 6 means an operational failure prevented the
plan or write.

## Versioned plan

Human dry-run output is a deterministic unified diff. `--json` emits schema 1
with the operation, status, detected profile, ordered file changes, the same
diff, and a `remotePolicy` result. Repository adoption never reads or mutates
GitHub policy: the plan always reports that as a separate operation.

The plan model has one invariant: detectors can add proposed records, but only
the generic applier can write them. Detection never runs during validation.
The core compiler covers explicit manual tasks and legacy explicit validation
commands. Automatic profile adapters are separate reviewable compiler units;
when a detected adapter is unavailable, adoption refuses with the manual-task
remedy instead of guessing. AUT-283 closes only after the Node, Python, Swift,
Rust, Go, and monorepo adapters are installed and independently reviewed.

Each adapter owns its runtime-specific evidence, offline setup, and generated
task contract. The accepted commands and setup are written explicitly to
`.touchstone.toml`; later adapter changes never rewrite that file.

The Node adapter derives tasks only from non-empty package scripts. A declared
`validate` or `verify` script is the single task; otherwise it records declared
`lint`, `typecheck`, `test`, and `build` scripts in that order. Install steps
require a completely verified dependency-free lock and run offline with package
scripts disabled. Every pnpm or Yarn task requires an exact supported runtime
version and disables Corepack network access. Project-controlled npm, pnpm, or
Yarn configuration at the task or effective setup root requires a manual task,
including unlocked projects where hooks can still run. Workspace children
inherit root setup only when an explicit supported workspace pattern proves
membership; ambiguous or unsupported declarations refuse.

## Ownership and safety

The applier owns only these boundaries:

- `.touchstone.toml` when creating a new declaration; an existing valid
  schema-v1 declaration is project-owned and remains byte-for-byte unchanged;
- `.touchstone/TOUCHSTONE.md` and `.touchstone/principles/*.md` as complete
  Touchstone-managed steering sources; and
- the exact `touchstone:steering` block in `AGENTS.md`, `CLAUDE.md`, and
  `GEMINI.md`. Everything outside the markers remains project-owned.

Every proposed path is repository-relative. A symlink at a managed file or any
managed ancestor is a contract refusal, so planning and apply cannot follow a
write outside the repository. Malformed or repeated steering markers also
refuse rather than guessing which project prose is owned.

Adoption never deletes `.touchstone-config` or another legacy path. Explicit
legacy validation commands may seed the new declaration, but retiring the old
file remains a separate reviewed action with its own recovery plan. Repeating
an accepted apply produces no second diff.

Repository facts that decide generated commands or setup must be tracked.
Touchstone-managed outputs are exempt from that input rule so an immediate
second plan after apply can report `current` before the user stages the new
files. Any apply that still has changes retains the clean-worktree guard.

Schema-v1 upgrade is intentionally conservative. A newer v1 CLI validates and
preserves an older valid v1 declaration; upgrade may refresh the marked
steering sources, but no v1 preset or catalog change forces repository
migration.
