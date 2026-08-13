---
name: touchstone-git-workflow
description: Use when committing, branching, opening a PR, watching PR reviews/comments, merging, recovering from no-commit-to-branch, or coordinating worktrees — covers the Touchstone branch → PR → agentic review → merge lifecycle.
---

# Touchstone Git Workflow

Every change goes through a feature branch + PR + PR-visible review loop + squash-merge. Direct pushes to the default branch are blocked at three layers (the Claude tool-boundary hook, the pre-commit hook, and GitHub branch protection). Bypassing all three is the documented emergency path, not a daily shortcut.

**There is no wrapper.** Every command below is raw `git` or `gh`. Run them and verify what GitHub actually says.

## When to invoke

- About to make a tracked-file edit, commit, or push
- Opening a PR, or requesting review on a pushed head
- Watching PR comments, requested changes, checks, or reviewer errors
- Hitting `no-commit-to-branch` and need to recover work onto a branch
- Stacked PRs — merges must retain the head branch; children need retargeting after the parent lands
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
4. `git push -u origin HEAD`, then `gh pr create` — **put `Closes #123` in the PR body**, not only the commit
5. Request review: `gh pr comment <n> --body "@codex review"` — against the head that actually landed on the remote
6. Answer findings with `bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file>`; prove none remain with `--all-resolved-check`
7. `gh pr merge <n> --squash --match-head-commit <reviewed-sha>`, then confirm `state == MERGED`
8. Clean up locally (`git branch -d <feature>`, or `-D` after confirming the content landed)

## Quick rules

- **One concern per commit.** Atomic commits make `git blame`, `git bisect`, `git revert`, and PR review work better.
- **Stage explicit file paths** — never `git add -A` (sweeps `.env`, credentials, generated files).
- **Push after every commit.** Local commits are not durable.
- **The closing reference goes in the PR body.** A `Closes-issue:` trailer in a commit body does nothing on a squash merge — GitHub reads the PR body. Nothing warns you; the issue just silently stays open.
- **Check the head you are binding.** A pre-commit hook can create a newer commit than the one you meant to push. Compare `git rev-parse HEAD` against `gh pr view <n> --json headRefOid` before requesting review or merging.
- **`gh pr merge` exit codes lie in both directions** — nonzero after a successful merge, zero after merely arming auto-merge on a red check. Confirm with `gh pr view <n> --json state,mergedAt`.
- **An AI reviewer never approves.** GitHub reserves `APPROVED` for real users, so do not wait for an approval — it will not come.
- **Review is not an enforced gate right now.** GitHub enforces required checks, resolved threads, and no direct push to the default branch. It does not enforce that a review happened, because the check-run carrying that signal was deleted with the machinery it duplicated. Reviewing the head you merge is required of you and unenforced; merging an unreviewed head is possible and still wrong.
- **Stacked PRs survive squash-merge** as long as the head branch is retained. After the parent lands, retarget each child at the resolved default branch (`gh pr edit <n> --base "$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"`) and rebase it. Branch *deletion* is what closes PRs based on a branch.
- **Classify every review finding before touching anything:** fix here / fix + audit the class / push back with evidence / real-but-not-this-PR's → route to the owning issue and resolve with the link. Never fix a finding by hardening a component the plan deletes.
- **One review request per head; answered findings satisfy the gate** (issue #751) — when the head is UNCHANGED, resolve threads and merge; do NOT re-request. Only a body-only finding needs a fresh request on the unchanged head. A fix commit moves the head: push it and request its one review.
- **Round budget: three per PR.** A discipline now, not an enforced limit — the wrapper that refused a fourth request is gone. Past budget: merge-if-answered, split the PR, or close preserving the corpus (#706 pattern). Spending a fourth round is a decision to state out loud in the PR.
- **Emergency bypass** is `git push --no-verify` plus an "Emergency-bypass disclosure" section in the next PR. It is for production incidents, not for a gate you find inconvenient.
