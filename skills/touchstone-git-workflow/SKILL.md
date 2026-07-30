---
name: touchstone-git-workflow
description: Use when committing, branching, opening a PR, watching PR reviews/comments, merging, recovering from no-commit-to-branch, or coordinating worktrees — covers the Touchstone branch → PR → agentic review → merge lifecycle.
---

# Touchstone Git Workflow

Every change goes through a feature branch + PR + PR-visible review loop where configured + squash-merge. Direct pushes to the default branch are blocked at three layers (pre-commit hook, GitHub branch protection, AI review/backstop where configured). Bypassing all three is the documented emergency path, not a daily shortcut.

## When to invoke

- About to make a tracked-file edit, commit, or push
- Opening a PR via `scripts/open-pr.sh`
- Watching PR comments, requested changes, checks, or reviewer errors
- Hitting `no-commit-to-branch` and need to recover work onto a branch
- Stacked PRs (`--base <branch>`) — there's a gotcha that orphans children on squash-merge
- Fanning out parallel work across worktrees
- Cleaning up branches or worktrees
- Emergency push (`--no-verify`) — needs disclosure in the next PR

For the full reference: read **`principles/git-workflow.md`** now.

## The rule that fires before any edit

Before your first edit of a tracked file in a session, run `git branch --show-current`. If it reports `main` or `master`, branch first:

```bash
git checkout -b <type>/<slug>   # type: feat | fix | chore | refactor | docs
```

Your unstaged changes carry over. The trigger is *edit time*, not commit time — discovering at commit means recovering accumulated work.

## The lifecycle

1. `git pull --rebase` on the default branch
2. Branch (before any edit)
3. Commit (explicit file paths, concise message, one concern per commit)
4. `bash scripts/open-pr.sh --auto-merge` — pushes, opens the PR, requests exact-head review, runs deterministic preflight, blocks unresolved PR feedback, squash-merges, and syncs default; the driver owns watching PR comments and committing fixes between PR open and merge
5. Local cleanup (`git branch -D <feature>` if it persists)

## Quick rules

- **One concern per commit.** Atomic commits make `git blame`, `git bisect`, `git revert`, and PR review work better.
- **Stage explicit file paths** — never `git add -A` (sweeps `.env`, credentials, generated files).
- **Push after every commit.** Local commits are not durable; pushed commits survive a `reset --hard` slip.
- **Issue-closing trailers.** `Closes-issue: #123` in the commit body — `open-pr.sh` injects `Closes #123` into the PR body, auto-closing on merge.
- **Stacked PRs + `--auto-merge` = orphaned children.** If you stack, drop `--auto-merge` and merge manually with merge-commit/rebase (not squash).
- **Emergency bypass** uses `merge-pr.sh --bypass-with-disclosure="<reason>"`, not raw `gh pr merge --admin`.
