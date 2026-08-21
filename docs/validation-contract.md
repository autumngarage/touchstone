# Validation Contract

This document owns Touchstone's validation boundary: schema 1 and schema 2, which differ only by the optional task `stage` key. The canonical
example is [`.touchstone.toml`](../.touchstone.toml); other documentation links
here instead of copying the shape.

## Ownership

Projects own declarations. `scripts/touchstone-run.sh` is the single generic
engine: the future Homebrew CLI invokes it locally, and the organization
required workflow invokes the same reviewed revision remotely. Neither path
detects a project type, package manager, command, or target.

## Schema 2 — execution stages

Schema 2 adds one optional key and changes nothing else. A task may declare
`stage = "commit"`; the default is `"enforce"`.

* **enforce** — what a gate must see. The organization-required workflow and
  `touchstone-run.sh validate` run exactly these.
* **commit** — an authoring guard: local fast feedback, run by
  `validate --stage commit`, never by the enforcement run.

The distinction exists because a project invariant that holds *per commit*
cannot be enforced by a check that only runs at push. By then the commit
exists and the cheap fix is gone; the remaining fix is a history rewrite. That
is not hypothetical — it stalled a delivery mid-flight, and the driver had to
ask an operator to choose between three bad options.

An authoring guard is **fast feedback, never a gate**. `--no-verify` skips it,
and a project must not delete its enforcement-stage check because a
commit-stage guard exists; the two are complements, not alternatives. A
staged-tree check is also meaningless in CI, which is why stage lives in the
declaration: the engine can exclude authoring guards from the enforcement run
rather than each project inventing its own wiring.

A declaration that runs nothing at the enforcement stage fails — a gate must
execute something. A commit stage with no tasks passes: most projects have no
authoring guards, and that is not a broken contract.

## Wiring the commit stage

Declaring a commit-stage task gives the engine the capability; the project
wires when it runs, because hooks are project-owned and Touchstone does not
install them. The wiring is one pre-commit entry:

```yaml
  - repo: local
    hooks:
      - id: touchstone-authoring-guards
        name: Touchstone authoring guards
        entry: touchstone validate --stage commit
        language: system
        stages: [pre-commit]
        always_run: true
        pass_filenames: false
```

A project with no commit-stage tasks can add this safely: the stage runs
nothing and passes. `--no-verify` skips it, which is the point — an authoring
guard is fast feedback, and the enforcement stage still gates the merge.

`stage` in a schema-1 file is a contract error, not a silent default. Accepting
it would let a consumer believe it declared a guard that runs nowhere.

Schema 1 is a deliberately narrow TOML subset:

- `schema = 1` at the root (or `schema = 2`, which adds only `stage`);
- one `[validation]` table with `runtime = "bash"`, an optional, non-empty
  `setup` command, and an optional `runner` — the GitHub-hosted runner label
  the central workflow executes the declaration on (`ubuntu-latest` when
  absent; a project whose checks need another OS declares, for example,
  `macos-15`). The engine validates and reports the label through
  `--check-contract --json`; it never schedules anything itself. The label
  takes effect only once the pinned central workflow reads it (a
  `touchstone-workflows` revision bump in the policy); until then every
  declaration runs on `ubuntu-latest` regardless;
- one or more `[[validation.targets]]` tables, each with a unique `name` and a
  project-relative `path` that cannot escape the repository;
- one or more `[[validation.tasks]]` tables, each with a unique `name`, an
  existing target name, an explicit `required` boolean, and a `command`;
- an optional task may omit `command` and then skips visibly; a required task
  may not omit it; and
- strings are single-line TOML basic strings. Schema 1 accepts `\"` and `\\`
  escapes and intentionally rejects multiline strings and broader TOML syntax.

The last restriction is part of the versioned contract, not an incomplete
parser. Schema 2 demonstrates the rule: it adds syntax without changing what schema 1 means, and a schema-1 file is read exactly as it was before schema 2 existed.

## Verdict semantics

A declaration is a promise. A required command that is missing, cannot start,
or exits nonzero fails. The engine executes each command exactly as declared
and reports what the shell returned: exit 126 or 127 is labelled
`command-not-started` and does not count as ran; any other non-zero exit is
`command-failed`. The engine never predicts whether a command can start
ahead of the shell, so what a declared command does with its own exit status
is the project's promise. Earlier target failures remain failures even when
later targets pass. A validation in which no
task ran fails at the enforcement stage, where a gate must execute something;
a commit stage with no declared tasks passes, because most projects have no
authoring guards and that is not a broken contract.

Human output and `--json` both report ran, skipped, and failed counts. JSON is
the stable automation boundary and identifies every failing task, target,
status, and reason. Configuration is the only behavioral source of truth;
ambient variables cannot select another project, config, command, or target.
Tests and adapters that need a different location pass the explicit
`--project` or `--config` arguments.

Missing, malformed, ambiguous, path-escaping, and unsupported-schema contracts
fail closed. Schema 1 and 2 are both accepted; every schema-1 declaration means
exactly what it meant before schema 2 existed, and `tests/test-validation-engine.sh`
asserts that. A repository that still has `.touchstone-config` receives an
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

The workflow adapter installs no unrelated package or lint toolchain. A
project's declared `validation.setup` may provision that project's own locked
dependencies; it is executable project policy and is evaluated with the same
failure semantics as every other declared command. Touchstone's own required
test remains offline, while consumer projects own the availability and
determinism of their intrinsic dependencies.
