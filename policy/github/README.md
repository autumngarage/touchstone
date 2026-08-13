# GitHub Policy

This directory owns Touchstone's audited GitHub enforcement policy.
`touchstone-main.json` is desired state. `baseline-2026-08-13.json` is the
pre-migration state and rollback seed; do not rewrite it after migration.

## Operations

Run every command from a clean, reviewed revision:

```bash
bash scripts/github-policy.sh diff
bash scripts/github-policy.sh dry-run
bash scripts/github-policy.sh backup <new-backup.json>
bash scripts/github-policy.sh apply
bash scripts/github-policy.sh verify
bash scripts/github-policy.sh rollback policy/github/baseline-2026-08-13.json
```

`dry-run` performs all source checks without mutation. `apply` installs or
updates the organization ruleset, verifies the effective repository rules,
then removes the duplicated legacy branch protection. A repeated apply is a
no-op. `rollback` restores captured protection before removing or replacing
the managed ruleset, so neither direction introduces an unprotected interval.

The checked-in pre-migration seed requires the historical local validation
workflow. To use that seed after migration, first restore the exact workflow
blob recorded in `rollbackPrerequisites` through a reviewed PR while the
organization ruleset still protects the repository. Then run `rollback`.
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

## Live canary testing

[`autumngarage/touchstone-policy-canary`](https://github.com/autumngarage/touchstone-policy-canary)
is the permanent disposable-state target for live policy tests. Use it before a
production policy migration when behavior depends on GitHub's live ruleset API
or merge enforcement and cannot be proven by the offline suite alone. Do not
use it for application development or as a required-workflow source.

Derive a temporary canary policy from the reviewed production policy; do not
commit a second desired-state file that can drift. Change only the target
repository, ruleset name, and repository-name condition. Before each test,
capture a fresh backup with `github-policy.sh backup`. Exercise the migration,
effective-rule verification, blocked unsafe operation, and rollback paths as
the change requires. Finish by rolling back the captured backup and verifying
that the canary's `main` branch is protected and no canary organization ruleset
remains. The canary's contents are expendable, but its protection baseline is
not.
