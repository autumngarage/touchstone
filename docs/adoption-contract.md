# Adoption Contract

This document fixes the planned public repository-adoption interface before
its AUT-283 implementation lands. The commands below are not available in the
current release. The durable product boundary remains in
[product-contract.md](product-contract.md), and the generated declaration is
defined by [validation-contract.md](validation-contract.md).

## Planned commands

`touchstone adopt --check` will report whether the repository needs adoption.
`touchstone adopt --dry-run` will print the complete proposed repository diff
and report remote policy as a separate operation. `touchstone adopt` will apply
that same diff only from a clean, non-default branch. All three modes will accept
`--json` and `--project DIR`; repeated `--task NAME=COMMAND` arguments select
the explicit manual path.

The interface reserves these exit classes: 0 is success, 2 is invalid
invocation, 3 means check found a required change, 4 is ambiguous or
unsupported input, 5 is an apply safety refusal, and 6 is an operational
failure.

## V1 automatic scope

Automatic detection is deliberately limited to the project shapes captured in
`tests/fixtures/adoption-v1/portfolio.tsv`:

- npm with `package.json` and `package-lock.json`;
- Python with `pyproject.toml`, with or without `uv.lock`; and
- Swift Package Manager with `Package.swift`.

The snapshot records the exact repository head that justified each shape.
Adding another ecosystem requires a current portfolio repository, its captured
root evidence, and an independent fixture before detector code. A detector
never guesses beyond that data: no supported evidence or competing ecosystem
evidence requires explicit `--task` arguments.

Legacy `.touchstone-config` is read only for explicit validation commands. It
is never deleted. Accepted commands are written to `.touchstone.toml`, after
which validation uses only that declaration and never detects a project type.

## Plan and ownership

Detectors return records in one plan model. They do not write. One applier owns
the presented patch and refuses if repository bytes changed after planning.
Applying the accepted plan twice is a no-op.

The local plan may create `.touchstone.toml`, create Touchstone-owned steering
sources, and replace only the marked `touchstone:steering` block in root agent
files. Existing declarations and all prose outside those markers remain
project-owned. Symlinks, malformed or repeated markers, dirty/default-branch
apply, unsupported schema, and paths outside the repository fail without a
partial write.

Repository-file adoption never reads or mutates GitHub policy. Human and JSON
output report the remote-policy operation separately.
