# GitHub Policy

This directory owns Touchstone's audited GitHub enforcement policy.
`touchstone-main.json` is the canonical consumer desired state;
`workflow-sources/` holds the distinct desired state for repositories that
publish those required workflows. `baseline-2026-08-13.json` is the
pre-migration state and rollback seed; do not rewrite it after migration.

## Operations

Policy operations require `gh`, `git`, `jq`, and `diff`. Touchstone's `setup.sh`
installs and verifies `jq` on macOS alongside the existing repository tools.

Run every command from a clean, reviewed revision:

```bash
bash scripts/github-policy.sh diff
bash scripts/github-policy.sh dry-run
bash scripts/github-policy.sh backup <new-backup.json>
bash scripts/github-policy.sh apply
bash scripts/github-policy.sh verify
bash scripts/github-policy.sh rollback policy/github/baseline-2026-08-13.json
```

`dry-run` performs all source checks without mutation. The reviewed commit used
for `dry-run` and `apply` must remove every rollback-prerequisite file, and
`apply` refuses a dirty checkout before mutation.
`apply` installs or updates the organization ruleset, verifies the effective
repository rules, then removes the duplicated legacy branch protection. Merge
the reviewed file removal immediately afterward and run `verify`; verification
fails until those files are absent from `main`. A repeated apply is a no-op.
`rollback` restores captured protection before removing or replacing the
managed ruleset, so neither direction introduces an unprotected interval.
A repository with neither a managed ruleset nor legacy branch protection — a
fresh consumer — is bootstrapped: `apply` says so, installs the policy, and
on any failure removes exactly the rulesets it created and restores the
auto-merge setting, leaving the repository as it was.

The checked-in pre-migration seed requires the historical local validation
workflow and the `review-binding` status its publisher produced. Their exact,
non-running recovery payloads are retained under `policy/github/rollback/`:
`validate.yml`, `review-binding.yml`, `review-evidence-signal.yml`, and
`review-binding-evaluate.jq` (restored to `.github/review-binding/evaluate.jq`).
To use that seed after migration, copy each payload to its recorded path and
merge that restoration through a reviewed PR while the organization ruleset
still protects the repository. Then run `rollback`.
Rollback verifies every recorded prerequisite on `main` before changing GitHub
policy, so it cannot install a required status context that no workflow can
produce. While legacy branch protection exists, `backup` copies these
prerequisites from the checked-in policy into the recovery artifact. Backups
captured after migration omit them because they restore a managed ruleset
rather than the legacy status-check gate.

The required validation workflow is referenced by repository ID, path, branch,
and full commit SHA in the separately protected `touchstone-workflows`
repository. It must never be sourced from a repository the ruleset targets:
GitHub excludes required workflows from running in their source repository. To
upgrade it, land the source workflow first, then change the SHA in a separately
reviewed policy PR. A target PR cannot weaken or replace that pinned source.

The only bypass actor is `OrganizationAdmin` in `pull_request` mode. Emergency
delivery therefore remains PR-visible and GitHub-audited; direct and force
pushes stay rejected. Never change that actor to `exempt`, and do not hand-edit
the managed ruleset in GitHub's UI. Change desired state here, review it, and
apply it with the script.

The managed ruleset name is its ownership marker. It is derived from the
contract version, organization, repository, and branch; `github-policy.sh`
refuses a policy whose name does not exactly match that marker. A generic or
same-purpose organization ruleset without that marker is never treated as
Touchstone-owned and is never updated or deleted by this script.

## Consumer policies

A private repository outside GitHub Enterprise Cloud cannot carry the merge
queue: GitHub answers `Invalid rule 'merge_queue'` (measured 2026-08-21 on
autumngarage/vesper and /arpeggio under the Team plan; public repositories
and Enterprise Cloud accept it). Autumn Garage moved to Enterprise Cloud on
2026-08-26, making those private repositories queue-eligible. In an
ineligible organization, consumers are derived with
`--no-queue`, which drops only the companion repository ruleset; the pinned
required workflows, pull-request-only delivery, thread resolution, and the
native rules still apply, and the merge is not queued — the combination of
two independently green PRs is validated by the next PR's run, not before
landing. Regenerate without the flag when the plan or visibility changes.

A consumer whose own workflow publishes a merge-blocking status the contract
does not know about (convoy's `convoy/delivery-protocol` PR-body check) keeps
it required with `--require-status CONTEXT` (repeatable): the derivation adds
one `required_status_checks` rule naming those contexts and changes nothing
else, so applying the policy never silently drops a gate the project relied
on. The canonical rules are only ever joined, never removed or weakened.
Such a policy depends on the repository's own publisher: if that workflow is
removed or stops reporting the context, every merge blocks on a pending
status until the policy is regenerated without the flag. The flag requires
`--no-queue`: a `pull_request`-only publisher never reports on a merge-queue
commit, so a queued consumer would reject every entry.

A queued consumer whose repository-owned workflow publishes the status on
`merge_group` declares it with `--require-merge-group-status CONTEXT`
(repeatable). This keeps the queue and records the publisher's event contract
explicitly. Do not use it for a pull-request-only workflow: the queue commit
would never receive the required context and GitHub would eject every entry.

Every adopted repository's policy is an exact derivation of the canonical
one — `scripts/derive-consumer-policy.sh REPOSITORY [--no-queue]
[--require-status CONTEXT]... [--require-merge-group-status CONTEXT]...` — checked in under
`policy/github/consumers/` and refused by the test suite if it drifts. Apply
one with `scripts/github-policy.sh apply policy/github/consumers/REPOSITORY.json`
only once both hold: the repository has adopted (`touchstone adopt`), and
its declaration runs on a bare hosted runner, because the pinned `validate`
workflow executes it there on every pull request and queue commit. The
policy's gates are all pinned required workflows (`validate`, `review-gate`,
`delivery-evidence`) from `touchstone-workflows`, so nothing in the consumer
repository has to publish a check. Applying to a repository whose
declaration cannot run centrally blocks every merge and queue entry.

## Workflow source policy

GitHub does not run a required workflow against the repository that publishes
it, so a workflow source cannot use the consumer policy shape. It is not an
exception that weakens the consumer contract: a checked-in `policyType` of
`workflow-source` selects a separate fail-closed shape with native deletion and
non-fast-forward protection, pull requests, resolved review threads, a
repository-published required status, and a merge queue. A consumer
still requires at least one externally pinned workflow, and a self-referential
workflow rule is still refused.

The workflow repository owns the publisher name in its checked-in
`.touchstone-source-contract.json`. Its tests bind every `.yml` or `.yaml` file
under `.github/workflows/` to that manifest. Before any dry run, apply, or
verify, `github-policy.sh` reads the manifest from the target branch and
requires the policy's status rule to name the same context exactly once. This
is the compatibility boundary for a job rename: change the workflow, manifest,
and desired policy in a reviewable sequence; a partial change fails closed.

The current source desired state is
`workflow-sources/touchstone-workflows.json`. Apply it only after the manifest,
workflow inventory test, and CODEOWNERS file are reviewed on the source
repository's default branch:

```bash
bash scripts/github-policy.sh dry-run \
  policy/github/workflow-sources/touchstone-workflows.json
bash scripts/github-policy.sh backup <new-backup.json> \
  policy/github/workflow-sources/touchstone-workflows.json
bash scripts/github-policy.sh apply \
  policy/github/workflow-sources/touchstone-workflows.json
bash scripts/github-policy.sh verify \
  policy/github/workflow-sources/touchstone-workflows.json
```

The apply transaction installs and verifies the organization and repository
rulesets before deleting legacy branch protection, and restores the captured
state if replacement fails. CODEOWNERS makes ownership of itself, the manifest,
the workflow directory, and its contract test explicit. This solo-member
repository cannot require an approving review without deadlocking every PR (an
author cannot approve their own change), so exact-head semantic review remains
mandatory driver procedure at this root-of-trust boundary; the ruleset does not
claim to enforce that part.

Consumer policy operations accept the declared legacy branch protection until
this migration runs. Afterward they require both workflow-source rulesets to
match this checked-in desired state, require every declared rule to be effective,
and require auto-merge to remain enabled. A partial source-policy install is not
treated as the legacy fallback.

## After an apply that adds a required workflow

GitHub runs a required workflow only on `pull_request` opened / synchronize /
reopened (the workflow file's own `types:` are ignored for required runs), so
a pull request whose head predates the apply shows the new check as expected
forever and neither auto-merge nor the queue will take it. Editing the PR
does nothing. For every open pull request in the repository:

```bash
gh pr close N && gh pr reopen N   # fires `reopened`; the head and its review stay valid
```

then re-run `touchstone pr merge`. Observed on touchstone #949, 2026-08-20.

## Live canary testing

[`autumngarage/touchstone-policy-canary`](https://github.com/autumngarage/touchstone-policy-canary)
is the permanent disposable-state target for live policy tests. Use it before a
production policy migration when behavior depends on GitHub's live ruleset API
or merge enforcement and cannot be proven by the offline suite alone. Do not
use it for application development or as a required-workflow source. Keep it
long term as the fleet's scratch consumer for required-workflow validation as
well: missing, malformed, passing, failing, canceled, local-workflow bypass,
and source-revision upgrade/rollback scenarios all belong there.

Derive a temporary canary policy from the reviewed production policy; do not
commit a second desired-state file that can drift. Change only the target
repository, derived ownership-marker name, repository-name condition, and the
rollback prerequisites. The production prerequisite records Touchstone's
historical local workflow, which the canary has never carried; leaving it in the
derived policy makes backup and rollback demand an unrelated file.

```bash
canary_policy="$(mktemp)"
bash scripts/derive-consumer-policy.sh touchstone-policy-canary >"$canary_policy"
```

The empty canary prerequisite list is deliberate: rollback restores the fresh
branch-protection backup captured from the canary itself, not Touchstone's
historical status-check workflow.

Before each test, capture a fresh backup with `github-policy.sh backup`.
Exercise the migration, effective-rule verification, blocked unsafe operation,
and rollback paths as the change requires. Finish by rolling back the captured
backup and verifying that the canary's `main` branch is protected and no canary
organization ruleset remains. The canary's contents are expendable, but its
protection baseline is not.
