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
The v1 adapters cover the project shapes in the Autumn Garage inventory:
Node, Python, Swift, Rust, Go, explicit `apps/`, `packages/`, and `services/`
targets, legacy explicit validation commands, and a generic manual task.
Conflicting manifests or lockfiles fail with the competing facts instead of
selecting one silently.

Node tasks come only from non-empty declared package scripts. A declared
`validate` or `verify` script is the single task; otherwise the adapter records
the declared `lint`, `typecheck`, `test`, and `build` scripts in that order.
When a dependency-free lockfile in the compiler's complete portable subset
exists, the declaration prepares Node dependencies only in the manager's
offline, frozen/immutable mode. Every pnpm or Yarn task, including an unlocked
one, requires an exact supported runtime version and disables Corepack network
access before resolving it. Project-owned npm, pnpm, and Yarn configuration at
the task or effective setup root requires a manual task because it can replace
the script shell, load hooks, or select project-controlled package-manager code.
Dependency-bearing or unverifiable locks require a manual declaration, and an
unlocked project gets no generated install step. Yarn Classic and Berry reject
project-controlled configuration at both the task and workspace setup roots. A
child uses the root setup only when an explicit JSON, block YAML, or single-line
flow YAML workspace glob proves membership. Every workspace entry must be a
string in the compiler's narrow, slash-aware glob subset; duplicate, mixed-type,
or unsupported declarations refuse instead of compiling a partial view.
Python tasks come from ruff declarations, mypy paired with tracked regular
Python source, or pytest paired with a tracked regular test file containing a
statically recognizable top-level test under pytest's portable default naming convention. A
dependency-free portable parser verifies the complete
`pyproject.toml` before any facts are derived and refuses TOML syntax it cannot
verify with a manual-task remedy. Explicit setup uses a completely parsed uv
lock whose schema header, Python requirement, root package, and checker packages
match the static project facts, followed by uv's own offline compatibility check;
uv setup and tasks then run offline, frozen, and with configuration discovery
disabled so preflight and execution observe the same inputs. Automatic uv
adoption therefore requires the project's declared uv tool to be available locally. Other paths use no-index
requirements or no-index editable installation only for an installable project
declaration.
Each emitted checker must also be present in dependency facts installed by that
setup; required uv dev groups are named explicitly even when project defaults
exclude them. Tracked tests without the checker dependency refuse; a checker
dependency without tracked tests does not manufacture a required pytest task.
Tool-only Python configuration without dependency facts refuses. Monorepo
plans include executable root-level checks alongside explicit child targets.
Swift automatic adoption requires a static test target with tracked source.
Go commands disable persistent environment configuration, automatic toolchain
selection, workspace discovery, the module proxy, and the checksum database;
the Go tool must confirm offline that `./...` selects a package backed by tracked,
non-excluded source. Rust requires tracked default package source plus a committed,
completely parsed `Cargo.lock`; Cargo must confirm offline that the lock matches
every verified manifest. Project-controlled Cargo execution config anywhere from
a target through the repository root, and package build programs, require a
manual task. Workspace validation tests every verified package
in frozen mode so it cannot rewrite the lock or reach the network. Every generated validation
path fails when required dependencies are not vendored or pre-provisioned;
none may turn a package-host outage into a required-check failure. The accepted commands and setup are
written explicitly to `.touchstone.toml`; later preset changes never rewrite
that file.

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

Schema-v1 upgrade is intentionally conservative. A newer v1 CLI validates and
preserves an older valid v1 declaration; upgrade may refresh the marked
steering sources, but no v1 preset or catalog change forces repository
migration.
