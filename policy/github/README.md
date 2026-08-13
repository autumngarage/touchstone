# GitHub Policy

This directory owns Touchstone's audited GitHub enforcement policy.
`touchstone-main.json` is desired state. `baseline-2026-08-13.json` is the
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

The checked-in pre-migration seed requires the historical local validation
workflow. Its exact, non-running recovery payload is retained at
`policy/github/rollback/validate.yml`. To use that seed after migration, copy
the payload to `.github/workflows/validate.yml` and merge that restoration
through a reviewed PR while the organization ruleset still protects the
repository. Then run `rollback`.
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

## Live canary testing

[`autumngarage/touchstone-policy-canary`](https://github.com/autumngarage/touchstone-policy-canary)
is the permanent disposable-state target for live policy tests. Use it before a
production policy migration when behavior depends on GitHub's live ruleset API
or merge enforcement and cannot be proven by the offline suite alone. Do not
use it for application development or as a required-workflow source.

Derive a temporary canary policy from the reviewed production policy; do not
commit a second desired-state file that can drift. Change only the target
repository, derived ownership-marker name, and repository-name condition.
Before each test, capture a fresh backup with `github-policy.sh backup`.
Exercise the migration, effective-rule verification, blocked unsafe operation,
and rollback paths as the change requires. Finish by rolling back the captured
backup and verifying that the canary's `main` branch is protected and no canary
organization ruleset remains. The canary's contents are expendable, but its
protection baseline is not.
