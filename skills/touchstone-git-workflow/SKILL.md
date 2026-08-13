---
name: touchstone-git-workflow
description: Use when committing, branching, opening a PR, watching PR reviews/comments, merging, recovering from no-commit-to-branch, or coordinating worktrees — covers the Touchstone branch → PR → agentic review → merge lifecycle.
---

# Touchstone Git Workflow

Every change goes through a feature branch + PR + PR-visible review loop + squash-merge. Local hooks stop common mistakes. Inspect the repository's effective rules before claiming server enforcement; do not infer ruleset adoption from this skill.

**There is no wrapper.** Every command below is raw `git` or `gh`. Run them and verify what GitHub actually says.

## When to invoke

- About to make a tracked-file edit, commit, or push
- Opening a PR, or requesting review on a pushed head
- Watching PR comments, requested changes, checks, or reviewer errors
- Hitting `no-commit-to-branch` and need to recover work onto a branch
- Stacked PRs — merges must retain the head branch; children need retargeting after the parent lands
- Fanning out parallel work across worktrees
- Cleaning up branches or worktrees
- Emergency ruleset bypass — only where effective policy exposes a PR-only bypass, with disclosure in that PR

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
- **The configured AI reviewer reports `COMMENTED`, not `APPROVED`.** Do not wait for an approval from this adapter; the review-binding check represents its verdict.
- **Review is always required.** Where installed and verified as required, `review-binding` enforces exact-head review and answers to every finding, while GitHub conversation resolution independently requires every inline thread closed. Without those gates, follow the same review loop and treat missing enforcement as an adoption gap.
- **Stacked PRs survive squash-merge** as long as the head branch is retained. After the parent lands, retarget each child at the resolved default branch (`gh pr edit <n> --base "$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"`) and rebase it. Branch *deletion* is what closes PRs based on a branch.
- **Classify every review finding before touching anything:** fix here / fix + audit the class / push back with evidence / real-but-not-this-PR's → route to the owning issue and resolve with the link. Never fix a finding by hardening a component the plan deletes.
- **One ordinary review request per exact head-and-base binding; answered findings satisfy the gate** (issue #751) — the binding is head SHA, base ref, and base SHA. When that binding is unchanged, resolve thread-backed findings and merge. Three cases permit another request while the head stays unchanged: the base ref or base SHA changed (one ordinary request for the new binding), one body-only-finding request, or the single audited provider-recovery trigger below. Never manufacture an empty commit to refresh review. A fix commit moves the head: push it and request its one review for the current base.
- **A request has distinct submitted, accepted, and completed states.** Watch formal reviews, PR conversation comments, inline threads, reactions, and linked provider tasks; a clean result may be a conversation comment, while a reaction proves only acceptance. The observation deadline is the later of the provider's published SLA or at least 30 minutes after submission. If it passes with the request unacknowledged or accepted but stalled, reconfirm the unchanged head and base, post a PR-visible audit note, and allow exactly one replacement trigger. That replacement must still produce trusted exact-head review evidence; if it does not, file or update the upstream incident and remain blocked. Never loop replacements, synthesize evidence, merge on acceptance alone, or use emergency bypass for ordinary provider friction.
- **Round budget: three per PR.** A discipline now, not an enforced limit — the wrapper that refused a fourth request is gone. Past budget: merge-if-answered, split the PR, or close preserving the corpus (#706 pattern). Spending a fourth round is a decision to state out loud in the PR.
- **Emergency bypass remains a PR.** Where effective policy provides the audited PR-only admin bypass, add an "Emergency-bypass disclosure" section before using it. Missing enforcement does not authorize a direct push. Emergency bypass is for production incidents, not an inconvenient gate.
