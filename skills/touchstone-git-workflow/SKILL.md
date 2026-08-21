---
name: touchstone-git-workflow
description: Use when committing, branching, opening a PR, watching PR reviews/comments, merging, recovering from no-commit-to-branch, or coordinating worktrees — covers the Touchstone branch → PR → agentic review → merge lifecycle.
---

# Touchstone Git Workflow

Every change goes through a feature branch + PR + PR-visible review loop + squash-merge. Local hooks stop common mistakes. Inspect the repository's effective rules before claiming server enforcement; do not infer ruleset adoption from this skill.

The raw `git` and `gh` commands below remain the portable recovery surface.
When repository-specific guidance names an executable boundary for one
operation, use it, then verify what GitHub actually says.

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
3. Commit (explicit file paths, concise message, one concern per commit) — deterministic gates and the tier's local pass first (`principles/local-review.md`)
4. `git push -u origin HEAD`, then `touchstone pr open --expect-branch <branch> --title … --body-file …` — the installed CLI is the sequencer everywhere: it creates or reuses the PR, posts the request, and confirms the gate bound it to the exact head and base. Put the configured close (`Closes #123` or `Fixes AUT-123`) in the PR body, not only a commit
5. Request review through `pr open`, not by hand; re-run it for any later head (idempotent). Never put its marker in a comment you write yourself; a bare `@codex review` from a collaborator is valid only for bounded stalled-request recovery. Raw `gh pr create` is recovery when the CLI is absent, not the instruction
6. Inspect GitHub's complete review surface; answer every finding but implement only the high-severity ones (correctness, crashes, data loss, security, broken behaviour, performance, lifecycle) — route the rest. Expect one confirming re-review; exact-head review after any fix commit is never skipped. Follow the raw reply and GraphQL `resolveReviewThread` procedure in `principles/git-workflow.md`
7. `touchstone pr merge <n> --head <reviewed-sha>` (re-runs the gate, merges bound to that head); raw fallback `gh pr merge <n> --squash --match-head-commit <reviewed-sha>`; then confirm `state == MERGED`
8. Clean up locally (`git branch -d <feature>`, or `-D` after confirming the content landed)

## Quick rules

- **One concern per commit.** Atomic commits make `git blame`, `git bisect`, `git revert`, and PR review work better.
- **Stage explicit file paths** — never `git add -A` (sweeps `.env`, credentials, generated files).
- **Push after every commit.** Local commits are not durable.
- **The closing reference goes in the PR body.** A `Closes-issue:` trailer in a commit body does nothing on a squash merge — GitHub reads the PR body. Nothing warns you; the issue just silently stays open.
- **Check the head you are binding.** A pre-commit hook can create a newer commit than the one you meant to push. Compare `git rev-parse HEAD` against `gh pr view <n> --json headRefOid` before requesting review or merging.
- **`gh pr merge` exit codes lie in both directions** — nonzero after a successful merge, zero after merely arming auto-merge on a red check. Confirm with `gh pr view <n> --json state,mergedAt`.
- **The configured AI reviewer reports `COMMENTED`, not `APPROVED`.** Do not wait for an approval from this adapter; the review-gate check represents its verdict.
- **Review is always required.** Where installed and verified as required, `review-gate` enforces exact-head review and answers to every finding, while GitHub conversation resolution independently requires every inline thread closed. Without those gates, follow the same review loop and treat missing enforcement as an adoption gap.
- **Moving stacks multiply exact-head review.** Do not open dependent descendants while a parent is finding-bearing: every parent update invalidates or rewrites their reviewed heads. Prepare locally, land the parent, then open the rebased child. Retain the parent branch through retargeting; branch deletion closes PRs based on it.
- **Classify every review finding before touching anything:** fix here / fix + audit the class / push back with evidence / real-but-not-this-PR's → route to the owning issue and resolve with the link. Never fix a finding by hardening a component the plan deletes.
- **Review cannot amend the approved scope; answering is not implementing.** Fix diff-created regressions and violations of recorded acceptance criteria *that are high-severity* — correctness, crashes, data loss, security, broken behaviour, unacceptable performance, lifecycle failure. A diff-created finding below that bar is answered and routed, not fixed. Answer and route real out-of-scope findings without changing the PR. Stop only widened work and requests on that shape; in-scope fixes continue to exact-head review. Then narrow, split along independently approved criteria, or redesign.
- **One ordinary review request per exact head-and-base binding; answered findings satisfy the gate** (issue #751) — the binding is head SHA, base ref, and base SHA. When that binding is unchanged, resolve thread-backed findings and merge. Three cases permit another request while the head stays unchanged: the base ref or base SHA changed after the earlier request is completed or explicitly failed, one body-only-finding request, or the single audited provider-recovery trigger below. If the base changes while the earlier request is nonterminal, wait or integrate the current base into the branch to produce a genuinely new head before requesting review; results identify the head, not their request or base. Never manufacture an empty commit to refresh review. A fix commit moves the head: push it and request its one review for the current base.
- **A request has distinct submitted, accepted, and completed states.** Watch formal reviews, PR conversation comments, inline threads, reactions, and linked provider tasks; a clean result may be a conversation comment, while a reaction proves only acceptance. The submission window is at least 30 minutes after submission (or the longer provider SLA); once accepted, start a separate completion window of at least 30 minutes (or the longer provider SLA) from the earliest acceptance signal. Only after that window can it be accepted but stalled. If the applicable deadline passes, reconfirm the unchanged binding, post a PR-visible audit note, re-fetch the complete surface immediately before posting, and allow exactly one replacement trigger only if the original still has no terminal output. Capture its comment ID, prove the live head/base still equal the pre-post coordinates, and re-run the pinned `review-gate` for that head so it derives the replacement request (`touchstone pr open` does both). A gate that still reports no request, or any drift, remains blocked. If the binding drifts or the original completes in the posting race, edit the replacement into a non-trigger audit note; `review-gate` may fall back to the original marker only when it still matches the live binding. Answer any later replacement findings. The replacement must still produce trusted exact-head review evidence; if it does not, file or update the upstream incident and remain blocked. Never loop replacements, synthesize evidence, merge on acceptance alone, or use emergency bypass for ordinary provider friction.
- **Provisional quota signal: a security-review quota notice is never a blocker or a terminal review result.** Treat it as provisional acceptance, keep watching the complete PR surface through the completion deadline, and use the single bounded stalled-request recovery only after that deadline. The notice is not review evidence: never stop delivery because it appeared, and never merge without trusted exact-head evidence.
- **Round budget: three finding-bearing rounds per capability, never more than three on one PR.** After the third, do not post a fourth request on the same implementation shape. Closing, renaming, restacking, or mechanically splitting the same acceptance criterion does not reset its count. After exhaustion, record the root cause and narrow the acceptance boundary or replace the architecture around a class-level guardrail before requesting review again. That redesigned attempt gets one validation round; another finding closes or genuinely decomposes the capability. Do not resume one-finding-at-a-time expansion.
- **Emergency bypass remains a PR.** Where effective policy provides the audited PR-only admin bypass, add an "Emergency-bypass disclosure" section before using it. Missing enforcement does not authorize a direct push. Emergency bypass is for production incidents, not an inconvenient gate.
