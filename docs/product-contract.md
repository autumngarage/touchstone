# Touchstone Product Contract

This document owns Touchstone's durable product boundary. Linear owns the
current implementation order and issue state; this file owns what the finished
system must continue to mean after that plan changes.

This is Touchstone project strategy, not universal engineering guidance. It is
loaded only by this repository's project-specific agent instructions and must
not be copied or routed into consumer projects.

## Steering distribution

Steering reaches agents through the **installed tool**, not through consumer
repositories. `touchstone steering install` writes one delimited, idempotent
block into each supported driver's user-level instruction file, alongside the
`principles/*.md` documents its routing table names
(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`); every
driver layers project files over that, so a repository still has the last
word without carrying a copy.

This is the mechanism by which contract improvements reach every project at
once. A steering change ships with the tool; no repository is rewritten, no
pull request is opened per consumer, and nothing drifts because nothing is
duplicated.

Adoption writes a repository's own declarations and nothing else. It neither
reads nor writes instruction files, and there is no `upgrade` subcommand:
with no repository copy to refresh, the operation had no remaining job. A
copy left by a pre-retirement adoption is the operator's to remove; re-running
`adopt` never refreshes or deletes it.

Copying was the alternative and it failed measurably: on 2026-08-18, zero of
ten consumer repositories carried a block matching this contract, and several
instructed agents to do what the contract forbids. The per-repository refresh
was the tax that produced that drift.

Two costs are accepted deliberately:

- **Per machine, not per repository.** An agent on a machine that never ran
  the installer receives no steering. `touchstone steering check` reports it
  by comparing the installed block against the contract the running tool
  carries, so a stale or absent install is visible. There is deliberately no
  separate version record: the installed tool *is* the version, and a second
  number to keep in sync would be one more thing to drift.
- **The contract must stay small.** Distribution being free removes the
  friction that previously limited growth, so the size caps in
  `tests/test-steering-size-caps.sh` are the replacement constraint: adding to
  steering requires removing from it or routing the content to `principles/*`.

Content outside the managed markers belongs to the operator and is never
touched; `uninstall` removes the block and leaves the rest byte-identical.

## Outcome

Touchstone is the standard delivery baseline for one person directing many
coding agents across many projects. A project is successfully adopted when it
can keep using that baseline without routine Touchstone maintenance.

The v1 support target is this operator's Autumn Garage repositories. Interfaces
must be public-quality and versioned, but third-party onboarding, arbitrary
extension points, and compatibility with environments outside that portfolio
are not v1 requirements.

The governing consumer invariant is:

> An adopted repository remains correct if Touchstone never rewrites it again.

Portability therefore comes from a small versioned contract and backward
compatibility, not continuous propagation. A newer Touchstone may offer an
optional upgrade, but an older adopted project must not become invalid merely
because the CLI, guidance, workflow, or preset catalog advanced elsewhere.

## Product jobs and owning layers

Each job has one authoritative owner. Other layers may invoke, report, or
explain that owner's decision; they may not recompute it.

| Job | Authoritative owner | Stable interface | Proof |
| --- | --- | --- | --- |
| Prevent direct or bypassed default-branch delivery | GitHub repository ruleset | Audited ruleset definition | Direct-push and owner-bypass canaries are rejected |
| Require deterministic project validation | GitHub organization ruleset required workflow | Ruleset-selected source repository, path, and full commit SHA | A PR cannot replace its own gate; passing, failing, missing, and canceled canaries produce the expected merge state |
| Require review of the exact PR head | GitHub required `review-binding` check | Check name and versioned evidence contract | No-review, stale-head, moved-base, and API-failure fixtures fail closed; a quota notice remains provisional non-evidence while the driver continues waiting |
| Require every review finding to be answered | GitHub required `review-binding` check | Versioned answer-evidence contract and check output | An unanswered inline or body-only finding blocks; a qualifying answer after the finding passes |
| Require inline review threads to be resolved | GitHub conversation resolution | GitHub review thread state | An unresolved thread blocks even after a reply; resolution alone cannot satisfy the separate answer check |
| Bind merge to the reviewed head | GitHub merge API | Expected head passed to the merge mutation | Moving the head before merge is rejected |
| Claim work | Configured tracker adapter | Tracker-neutral claim contract | GitHub- and Linear-backed fixtures distinguish verified from unavailable transport |
| Carry agent steering | The installed tool, machine-wide | One delimited block in each driver's user-level instruction file; repositories carry none | `touchstone steering check` compares the installed block against the tool's contract; deterministic size-cap, path-integrity, and steering-contract assertions run in the required suite |
| Adopt and evolve a repository | Touchstone CLI adoption module | Versioned project declarations and reviewable plan/apply output | Fresh, current, repeat, old-compatible, and unsupported-schema fixtures |
| Install and upgrade the local tool | Homebrew | Versioned formula and checksummed release | Install, upgrade, rollback, and no-project-mutation tests pass |

The canonical Linear execution plan maps active issues to these jobs. Do not
add an issue inventory here; issue state is volatile and Linear owns it.

## Consumer boundary

An adopted repository contains declarations and narrow integration points, not
a copy of Touchstone's implementation:

- `.touchstone.toml` declares its schema version, exact validation commands,
  required tasks, runtime/setup requirements, and explicit monorepo targets.
  `.touchstone-tracker.toml` declares the project's issue tracker once.
  [The validation contract](validation-contract.md) owns the accepted schema shapes
  and verdict semantics; [the tracker contract](tracker-contract.md) owns
  claim configuration, references, and outcomes.
- An organization ruleset requires a workflow selected from a protected
  Touchstone source repository, path, and full commit SHA. A consumer PR cannot
  replace that invocation. The required workflow and Homebrew CLI execute the
  same validation semantics.
- Root agent files remain project-owned. Touchstone owns only its marked block
  or import adapter; it never replaces the surrounding project guidance.
- GitHub ruleset state is managed and verified through a separate policy
  boundary. Repository-file adoption and remote-policy mutation are never one
  transaction.

Touchstone does not vendor its CLI, general-purpose libraries, delivery
wrappers, or an updater into consumer repositories.

Steering confidence rests on deterministic checks: the required suite asserts
size caps, path integrity, render drift, and the contract phrases each
supported driver file must carry.

Phrase presence alone is not compliance evidence, and that limit is accepted
knowingly: these checks prove the contract reached the file, not that an agent
obeyed it.

The behavioral lane that once measured real agents against controls was
deleted with Milestone 6. It existed to prove the steering worked, then
required its own trust apparatus -- an evaluator evaluating the evaluator --
and the recursion cost more than the evidence was worth. The canary is the
replacement: a live repository adopting and surviving a compatible release is
stronger proof than a scripted scenario, and it needs no apparatus of its
own.

Automated checks are also insufficient as a product verdict. Before a canary,
versioned operator journeys exercise initial installation and adoption, normal
delivery, failure recovery, compatible evolution, and rollback through the
supported public interfaces. Their evidence records time, retries, user
intervention, final external state, and whether Touchstone created avoidable
work. A journey succeeds only when the product goal is met, not merely when its
commands exit zero.

## Adoption is compilation

Project-type support exists only at the adoption boundary. A detector inspects
repository facts such as manifests, lockfiles, declared scripts, and workspace
layout, then produces a proposed explicit contract. Detection is a pure input
to a plan; it never writes files itself.

The generic applier owns all writes. Before applying, it presents the complete
file diff and separately presents any proposed remote-policy change. Applying
the same accepted plan twice is a no-op.

After adoption, validation executes declarations exactly. It does not infer a
project type, select a package manager, discover targets, or silently replace a
missing command. A required task that cannot start, fails, or never runs makes
validation fail. Optional skips are visible in human and machine-readable
output.

Adding a project type means adding one detector/preset and its fixtures. It
must not add branches to the validator, upgrader, CI adapter, policy code, or
delivery commands. An unrecognized project receives a manual explicit-command
plan; ambiguous evidence fails with the competing facts instead of guessing.

## Installation and evolution

Homebrew is the canonical local install and upgrade path. `brew upgrade`
updates the installed CLI and its bundled catalog only; it never searches for
or modifies projects.

The project contract uses a major schema boundary. Within a major version:

- additions are backward-compatible;
- a new CLI and CI adapter continue accepting older contracts;
- preset improvements do not rewrite accepted commands;
- no routine migration is required.

A breaking schema requires an explicit upgrade plan and a reviewable project
diff. Upgrade planning is read-only; applying refuses dirty or default-branch
worktrees, never silently changes project-owned values, and never deletes an
obsolete path without explicit authorization and a recovery plan.

Required-workflow revisions are pinned to full commit SHAs in organization
ruleset policy. An upgrade is an audited policy diff with dry-run, verification,
and rollback; it is not a consumer-repository bump. A moving tag, background
sync, ordinary-command side effect, or fleet-wide rewrite is not an upgrade
mechanism.

## Admission test

New surface is rejected unless all of these are true:

1. It serves one of the product jobs above and names that job.
2. The owning layer cannot already provide the behavior.
3. A real observed failure, not speculative convenience, justifies it.
4. It keeps one execution path and one source of truth.
5. Its consumer compatibility and deletion path are defined before it lands.
6. Its tests cover small, typical, large, repeat, partial-failure, and
   unsupported-state boundaries appropriate to the domain.
7. It does not require routine changes in already-correct consumer projects.

The default answer is deletion or composition from GitHub, git, Homebrew, and
the configured tracker. Useful automation that merely saves an agent from a
recoverable command belongs outside Touchstone's core.

## Explicit non-goals

Touchstone does not provide:

- background auto-update, auto-sync, auto-ship, or `update-all` behavior;
- a global project registry;
- runtime project-type detection;
- a second local interpretation of GitHub's merge policy;
- a doctor command that mirrors the validator, required workflow, or GitHub;
- automatic retirement or deletion of consumer files;
- autonomous repair, general task orchestration, or worktree convenience
  wrappers.
- a v1 plugin framework or speculative third-party integration surface.

These exclusions are architectural boundaries, not an unfinished feature
list. Reintroducing one requires changing this contract explicitly and proving
why the original failure class no longer applies.
