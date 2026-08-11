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
- Stacked PRs (`--base <branch>`) — merges retain the head branch; children need retargeting after the parent lands
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
4. `bash scripts/open-pr.sh --auto-merge` — pushes, opens the PR, requests exact-head review, and merges once the gate passes; if it stops, fix the cause it names and run it again
5. Answer review findings with `bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file>` (reply + resolve + verify in one command); gate the re-ship on `--all-resolved-check`
6. After the PR merges, clean up locally (`git branch -D <feature>` if it persists)

## Quick rules

- **One concern per commit.** Atomic commits make `git blame`, `git bisect`, `git revert`, and PR review work better.
- **Stage explicit file paths** — never `git add -A` (sweeps `.env`, credentials, generated files).
- **Push after every commit.** Local commits are not durable; pushed commits survive a `reset --hard` slip.
- **Foreground diagnosis.** Use `bash scripts/open-pr.sh --auto-merge` directly when interactive output is useful.
- **Issue-closing trailers.** `Closes-issue: #123` in the commit body — `open-pr.sh` injects `Closes #123` into the PR body, auto-closing on merge.
- **Stacked PRs survive squash-merge now.** Merges retain the head branch, so children stay open; after the parent lands, retarget each child at the resolved default branch (`gh pr edit <n> --base "$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"`) and rebase it. Branch *deletion* is what closes PRs based on a branch — leave deletion to `cleanup-branches.sh`.
- **Emergency bypass** uses `merge-pr.sh --bypass-with-disclosure="<reason>"`, not raw `gh pr merge --admin`.
- **Classify every review finding before touching anything:** fix here / fix + audit the class / push back with evidence / real-but-not-this-PR's → route to the owning issue and resolve with the link. Never fix a finding by hardening a component the plan deletes.
- **One review request per head; answered findings satisfy the gate** (issue #751) — when the head is UNCHANGED, resolve threads, rerun `merge-pr.sh`, do NOT re-request (only a body-only finding takes `open-pr.sh --fresh-review`). A fix commit moves the head: ship it through `open-pr.sh`, and its review is the budget's next round.
- **Round budget: three per PR** — `open-pr.sh` refuses the fourth request. Past budget: merge-if-answered, split the PR, or close preserving the corpus (#706 pattern). `--round-budget-override "<reason>"` spends one anyway, auditable in the PR.
