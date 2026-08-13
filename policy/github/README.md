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
