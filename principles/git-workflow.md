# Git Workflow

Every code change goes through a feature branch + PR + PR-visible review loop + merge. The documented emergency bypass remains inside that PR and must be disclosed there. This discipline catches bugs before they land on the default branch and creates an audit trail for every change, while leaving a legible escape hatch for production incidents.

**There is no wrapper.** Every step below is a raw `git` or `gh` command you can run and verify yourself. That is deliberate: the mechanics live here, in prose, so that any agent with a shell and `gh` can deliver correctly. Tooling may accelerate these commands later, but it may never become the only way to run them.

## Never commit on the default branch

**This is the one rule that makes everything else work.** Every code change — including a one-line typo fix, a doc tweak, a version bump, a README edit — starts on a feature branch. Committing directly to `main` (or `master`) bypasses PR review and the audit trail, and leaves you in a local state that's awkward to untangle without rewriting history someone else may already have pulled.

**The concrete rule for any AI or human working here:** before the first edit of a tracked file in a session — `Edit`, `Write`, or any tool that mutates a file under git — run `git branch --show-current`. If the output is `main` or `master`, stop and branch first. `git checkout -b <type>/<slug>` preserves your staged and unstaged changes, so there's no cost to branching late — but there's real cost to discovering the mistake at commit time after batching several files of work.

**Why the trigger is at edit time, not commit time.** The earlier version of this rule said "check before your first commit." That phrasing reliably fails — for LLMs especially, but for humans in flow too. The actual sequence that produces the failure mode is: (1) agent reads a file on `main`, edits it; (2) edits another, and another; (3) reaches commit, the `no-commit-to-branch` hook refuses, and now the agent has to recover the accumulated work onto a new branch. The recovery is mechanically fine and documented below — but it costs more than the one `git branch --show-current` would have. The "before-edit" trigger moves the cost from *discovered at commit, recover* to *discovered before any work, prevent*.

**If you've already committed to main by accident**, don't push. Instead: `git branch <type>/<slug>` to save the work, then `git reset --hard origin/main` to restore the local default branch, then `git checkout <type>/<slug>` to continue. The commits are preserved on the new branch; main is restored to match the remote.

**If you've already pushed**, the standard ship path is broken. Don't try to rewrite history on the default branch. Disclose the slip in the next PR (see "Emergency path" below) and carry on — the commit is now part of history, and the audit trail captures what happened.

**The mechanical guardrails** that back this rule:

- `hooks/branch-guard.sh` runs as a Claude Code `PreToolUse` hook and refuses a `git commit` invocation on the default branch before the tool call runs at all.
- The `no-commit-to-branch` hook in `.pre-commit-config.yaml` is configured with `--branch main --branch master`. It runs at `pre-commit` stage and refuses the commit outright. `git commit --no-verify` bypasses this local feedback only.
- The GitHub organization ruleset requires the change to go through a PR. Direct pushes to `main` are rejected by the server even for organization admins.

The layers are complementary: the tool-boundary hook catches the intent, the local hook catches the honest mistake before it becomes a commit, and the ruleset rejects direct pushes at the server.

## The lifecycle

1. **Pull.** `git pull --rebase` on the default branch before starting work.
2. **Branch — before any edit that might become a commit.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`. Do this as step one of the work, not as a cleanup step later.
3. **Check the tree before changing it.** Run `git status --short` and `git branch --show-current` before starting implementation. If the tree is dirty with unrelated user changes, do not stash them and do not auto-commit on the user's behalf. Ask how to proceed, or branch around the changes when the file surfaces are disjoint. `git stash` is hidden multi-agent state, not a coordination mechanism.
4. **Loop: change → commit → push.** Each meaningful sub-task gets its own commit and push. Stage explicit file paths (not `git add -A`), write a concise message, push to the open branch.
5. **Ship.** Push and open the PR — see "Opening a PR" below.
6. **Answer every piece of PR feedback before merging.** Reply to each comment and resolve its thread, whoever left it. Unresolved threads genuinely block the merge — `required_conversation_resolution` is on, so this one GitHub enforces.
7. **Merge**, bound to the head the review actually saw — see "Merging" below.
8. **Clean up after merge.** Delete the local feature branch once the PR is merged.

## Opening a PR

```bash
git push -u origin HEAD
gh pr create --title "<type>: <what changed>" --body-file <(cat <<'EOF'
<what and why>

Closes #123
EOF
)
```

**The closing reference must be in the PR body.** This is the silent-failure trap in the whole flow: `Closes-issue: #123` in a *commit* body does nothing on a squash merge, because GitHub reads the **PR body** to decide what to auto-close. A commit trailer alone leaves the issue open and nothing reports it. If you write the trailer in commits, lift it into the PR body yourself before shipping.

Verify it took, rather than assuming:

```bash
gh pr view <n> --json body --jq .body | grep -E '(Closes|Fixes|Resolves) #'
```

**Requesting review.** The PR-visible reviewer runs asynchronously against the exact pushed head:

```bash
gh pr comment <n> --body "@codex review"
```

**Head convergence.** A pre-commit or pre-push hook can create a *newer* commit than the one you thought you were pushing. Always request review against the head that actually landed on the remote:

```bash
git rev-parse HEAD                       # local
gh pr view <n> --json headRefOid --jq .headRefOid   # what GitHub has
```

If they differ, push again before requesting review — otherwise the review binds a commit nobody is merging.

## Checking the gate

What the merge gate says right now, in three commands:

```bash
gh pr checks <n>                                          # required checks
gh pr view <n> --json reviews --jq '.reviews[-1].state'   # latest review state
gh api graphql -f query='
  query($owner:String!, $repo:String!, $pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) { nodes { id isResolved } }
      }
    }
  }' -F owner=<owner> -F repo=<repo> -F pr=<n> \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length'
```

The last one is the count of unresolved threads. Zero is the requirement.

**The configured AI reviewer reports `COMMENTED`, not `APPROVED`.** GitHub's review API can support approval for authorized integrations, but that is not this adapter's observed contract. Do not expect an approval here or treat its absence as a stalled review.

**`review-binding` enforces the review contract.** It fails unless trusted review evidence covers the exact current head after the bound request and every inline or body-only finding has a qualifying later answer. GitHub conversation resolution separately requires every inline thread closed.

## Answering findings

Answer each finding with the canonical response command instead of hand-rolling API calls:

```bash
bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file> [--fix-commit <sha>]
bash scripts/respond-review.sh <pr> --all-resolved-check
```

It posts the threaded reply, resolves the thread, and verifies the resolution stuck, with bounded retries for transient API failures. GitHub needs four separate calls to do this correctly, which is why it is a script rather than a line of prose.

The raw equivalent, if you need it: reply with `gh api repos/<owner>/<repo>/pulls/<n>/comments/<id>/replies -f body=@<file>`, then resolve with the GraphQL mutation:

```bash
gh api graphql -f query='
  mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
  }' -F threadId=<PRRT_...>
```

Thread IDs are the `PRRT_`-prefixed `id` values from the `reviewThreads` query above. The token needs Contents: read and write.

## Merging

```bash
gh pr merge <n> --squash --match-head-commit "$(gh pr view <n> --json headRefOid --jq .headRefOid)"
```

**`--match-head-commit` is the head binding.** It refuses the merge if the PR head moved since you checked the gate — which is exactly the race that lets an unreviewed commit slip in behind a passing review.

**`gh pr merge` exit codes lie in both directions.** It can exit nonzero after the merge actually succeeded, and it can exit zero having merely *armed* auto-merge while a check is still red. Never trust the exit code alone:

```bash
gh pr view <n> --json state,mergedAt --jq '{state, mergedAt}'
```

`MERGED` with a non-null `mergedAt` is the only proof.

## Commit discipline

**One concern per commit.** A commit should describe a single logical change — a feature, a fix, a refactor, a doc update — not a multi-day grab bag. The diff might span many files, but it should be one coherent thought.

**Why it matters.** Atomic commits pay back continuously: they make `git blame` and `git log` informative, they make `git bisect` able to pin a regression to a single change, they make `git revert` surgical, and they let reviewers reason about one semantic change at a time.

**Concise commit messages.** Lead with *what* changed in the subject line. Use the body to explain *why* when the why isn't obvious from the diff.

**Issue reconciliation before PR.** Treat issue state as part of delivery, not cleanup after the fact. Before opening the PR, make a short ledger of every issue you touched: fixed, partially fixed, made stale, or investigated and left open. Fixed issues must be represented by `Closes #N` lines **in the PR body**. Partial fixes get `Refs #N` plus an issue comment that names what landed and what remains. Stale issues get a comment with the commit/test evidence before closing. The invariant: after a merge, a reader scanning issues should not have to infer whether a shipped fix was forgotten, partial, or unrelated.

**Stage explicit file paths.** Avoid `git add -A` or `git add .` — they accidentally stage sensitive files (`.env`, credentials) or large binaries. Naming files makes intent visible at the staging step.

## Commit and push frequency

**Commit at every clear stopping point.** A sub-task is complete and its tests pass — that's a commit boundary. Don't wait until "the whole feature is done." Holding hours of work in an uncommitted working tree creates four problems: (1) review faces one giant diff instead of a legible sequence, (2) any single mistake can lose all of it, (3) other branches can't pull your in-flight work, and (4) you lose the per-step `git log` story that future-you will rely on when debugging months later.

**Push after every commit.** Local commits are not durable. Pushing means your work survives a laptop dying or a `git reset --hard` finger-slip. On a PR branch, pushing also makes incremental work visible from another worktree or session.

**Cadence guidance.** A useful rhythm is roughly one commit per 30–60 minutes. If a session goes longer without a commit, ask whether you've passed a clean stopping point and didn't notice. If you can describe what you just finished in one sentence, that's a commit.

**When *not* to commit.** Two cases: (1) a half-finished thought where the code is in a deliberately-broken intermediate state — squash that into a single sensible commit before pushing; (2) actively-iterating exploration where commits would just be noise.

**No checkpoint commits in review artifacts.** Local recovery commits are fine, but pushed `WIP:`, `checkpoint`, or deliberately broken commits do not belong on real review branches. Squash or fix them before opening the PR.

## Background reading

- [Commit Often, Perfect Later, Publish Once — Git Best Practices](https://sethrobertson.github.io/GitBestPractices/) (Seth Robertson) — the canonical "commit early, commit often" essay.
- [Trunk-Based Development](https://trunkbaseddevelopment.com/) — the practice that frequent small commits enable at scale.
- The autumn-garage convention is closer to "tiny PRs to main" than "long-lived feature branches" — short branches, frequent commits, fast review.

## Agentic PR Review Loop

The PR is the only semantic review surface. Request one review per exact head. The driving CLI watches the PR, fixes actionable findings, pushes a new head, and repeats until the head's review is answered — a clean verdict, or findings with every thread resolved.

**Never re-request review on an unchanged head** for thread-backed findings. The reviewer is non-deterministic, so re-asking about the same commit manufactures new findings instead of confirming the old ones. A new head gets exactly one new review. The one exception is a body-only finding — a non-clean verdict with no inline threads — where nothing can be resolved to answer it, so a fresh request on the unchanged head is the only path forward.

### Babysitting a PR: the round discipline

Reviews are the most expensive resource in the loop — each round costs full review latency (#649), and the history is unambiguous about what unbounded rounds produce: #706 was closed unmerged after six (rounds 3–6 each contained defects created by the previous fix), and #755 spent seven rounds and +936 lines on a ~60-line core change.

**Classify every finding before touching anything.** Four dispositions, in the order to consider them:

1. **Fix here** — a defect in this diff, or one this diff created. Fix it in the batch.
2. **Fix and audit the class** — the finding is one instance of a shape. Grep for siblings before responding (`principles/audit-weak-points.md`); the class audit has found extra live bugs repeatedly.
3. **Push back with evidence** — the finding is factually wrong. Quote the file, cite the precedent, resolve without changing code. Never comply with a wrong finding to save a round.
4. **Real, but not this PR's to fix** — route it to the owning issue with a comment, resolve the thread with the link. The load-bearing case: **never fix a finding by hardening a component the plan deletes.** Check the plan of record before fortifying anything the reviewer points at.

**The loop.** If every finding resolves **without moving the head** (dispositions 3–4), answer every thread, prove none remain with `--all-resolved-check`, then merge — answered findings satisfy the gate (issue #751); do not request another review. If any fix lands as a commit (dispositions 1–2), batch ALL of them into ONE commit, answer every thread, push, and request one review for the new head.

**The budget: three rounds per PR.** This is a discipline, not an enforced limit — the wrapper that refused a fourth request is gone, and a rule enforced by a script you can decline to run was never a rule. Past three rounds, the legitimate exits are:

- **Merge if answered** — all threads resolved satisfies the gate;
- **Split the PR** — the diff is carrying more than one concern, and each fragment restarts with a budget it will rarely need;
- **Close it, preserving the corpus** on the tracking issue (the #706 pattern) — correct when successive fixes keep creating defects.

Spending a fourth round is a decision to state out loud in the PR, with the reason, so it stays auditable.

AI review supplements deterministic checks; it does not replace lint, type checking, tests, or project-specific validators.

## Periodic branch hygiene

```bash
git branch --merged main                    # ancestor-merged: safe to delete
git branch -d <branch>                      # git refuses unmerged work
```

Squash-merged branches are the common case, and their commits are *not* ancestors of the default branch even though their changes are applied. `git branch -d` will refuse them. Confirm the content actually landed before forcing:

```bash
git diff --quiet main...<branch> && git branch -D <branch>
```

That compares the branch against the merge-base with main: an empty diff means every change the branch made is already present. Never `git branch -D` without that check — it is the difference between deleting merged work and losing unmerged work.

Never delete a branch that serves as an open PR's base or head; that is what orphans a stack (see below).

## Stacked PRs (and how they merge)

A stacked PR is a PR whose base branch is another open PR's branch instead of the default branch. The goal: split a large change into a chain where each step is reviewable on its own. Open one with `gh pr create --base <parent-branch>`.

**Retain the head branch on merge.** Do not enable `deleteBranchOnMerge`, and do not delete a parent branch that children are based on. If a head branch is deleted while open PRs are based on it, those PRs can be closed-without-merge with their review discussion abandoned — this fired on sentinel PRs #49/#50/#51 (2026-04-16) and is the reason the merge path retains branches (issue #713).

**Children still need retargeting after the parent lands.** Nothing rebases a child automatically. After the parent merges (resolve the default branch once — downstream repositories are not all `main`):

```bash
DEFAULT=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
git fetch origin
gh pr edit <child> --base "$DEFAULT"
git rebase --onto "origin/$DEFAULT" "origin/<parent-branch>" <child-branch>
git push --force-with-lease
```

Both rebase anchors come from the fetch: the new base is the merged remote
default branch, and the old base is the retained remote-tracking parent ref.
The local branches are disposable and may already be stale or gone after
cleanup; the remote parent is retained until every child has been retargeted
and rebased.

Merge a chain in order, parent first, repeating both steps for each next child.

**Bundling is still often simpler.** When the user says "ship it all," default to one PR with all the commits. Reviewers reason more cleanly about one coherent story than a chain. Use a stack only when a child truly depends on an unmerged parent and must be reviewable separately.

## Claiming issues before agent dispatch

Before spawning a coding agent — Claude Code subagent, Codex CLI, or any other — to work on a GitHub issue, **claim it first**. Set the assignee, post a one-line dispatch comment, then spawn the agent. The cost is ten seconds per issue; the cost of skipping it is two agents picking up the same issue and shipping competing PRs.

**The mechanical steps.**

```bash
bash scripts/claim-issue.sh <n>
```

Under the hood this uses the same GitHub API flow (claim + dispatch comment), equivalent to:

```bash
gh issue edit <n> --add-assignee @me
gh issue comment <n> --body "Dispatched. Branch \`<branch>\`, worktree at \`<path>\`. <agent type> implementing."
```

The script is preferred because it detects races — another assignee appearing between the API read and write — and exits non-zero so the dispatching agent knows not to start work.

Then start the agent. Not after.

**Why this is a rule.** Without it, three failure modes recur in agent-driven workflows:

1. **Duplicate work.** Two agents pick up the same issue and ship competing PRs. The first to merge wins; the second rebases into conflict or closes orphaned. Both burned budget.
2. **No in-progress signal.** A reader scanning open issues can't tell which are actively being worked vs which are dormant. Triage decays.
3. **Lost lineage.** The dispatch comment is the only record on the issue thread tying the work back to a specific agent, branch, and worktree. That breadcrumb matters months later.

**When to unassign.** If you decide not to ship, unassign with `gh issue edit <n> --remove-assignee @me` and post a "stood down — <reason>" comment. Stale assignments are worse than no assignment at all.

**When this rule does NOT apply.**

- **Issues you're proposing or analyzing, not implementing.** Claim only when implementation actually starts.
- **Drive-by fixes during unrelated work.** A one-line typo fix doesn't need a claim — but if it warrants its own commit, it warrants a closing reference at minimum.

**For multi-issue bundles.** When one lane closes multiple issues, claim and comment on all of them with the same branch reference.

**Deterministic enforcement.** `.github/workflows/issue-claim-check.yml` runs on every `pull_request` open/edit/synchronize. It parses `Closes #N` / `Fixes #N` / `Resolves #N` / `Closes-issue: #N` from the PR body, fetches each open referenced issue, and fails the check if the PR author is not in the issue's assignees. The failure posts a comment on the PR explaining what to fix. `scripts/issue-claim-check.sh` is the same check, runnable locally before you push.

**Bypass token: `[skip-claim-check]`.** For documented exemptions (drive-by typo fix, true emergency, sandbox PR you don't intend to merge), put the literal token in the PR body. The CI check sees the token and skips with a workflow-run note, leaving an audit trail. This is a documented escape hatch, not a daily shortcut.

## Parallel work with worktrees

File-writing subagents must use isolated worktrees unless explicitly waived. The default is isolation; flat shared-checkout fan-out is the exception.

The default for a single driver is one branch at a time in the main checkout. When you have N genuinely independent tasks — changes that touch disjoint files and don't logically depend on each other — `git worktree` lets them run concurrently without stepping on each other.

For the full fan-out playbook — slice manifests, file ownership, parent orchestration, concurrency caps, and cleanup rules — see [agent-swarms.md](agent-swarms.md). This section defines the git workflow default; the swarm guide defines the operating model.

**The primitive.** From the main checkout, `git worktree add ../<project>-<slug> -b <type>/<slug>` creates a second working tree on a new branch, sharing the same `.git`.

**For AI subagents.** When delegating to a subagent that supports worktree isolation (e.g. Claude Code's `Agent` tool with `isolation: "worktree"`), prefer it for any task that writes files. The subagent gets its own checkout, can't clobber siblings, and the worktree is discarded automatically if the agent made no changes.

**Rules that make it actually parallel.**

- **Disjoint file sets.** If two concurrent tasks touch the same file, they're not parallel — they're a merge conflict delivered on two branches. Name the file surface each task owns before launching; if they overlap, sequence them.
- **No coordination in flight.** Each independently shippable worktree ships its own PR. If task B needs something from task A's PR before it can merge, that's stacked work — run them sequentially instead.
- **Each agent burns its own budget.** Five parallel agents use roughly 5× the tokens and CPU of one. Start with 2–3 concurrent worktrees, observe, and scale from there.

**Gotchas.**

- **Untracked files don't follow.** `.env`, local config, and built artifacts live in the working tree, not in `.git`. Copy them in after `git worktree add`, or make the setup step recreate them.
- **Shared `.git`.** Don't run destructive git ops (`git gc --prune=now`, `git worktree remove --force`) while a sibling worktree has uncommitted work.
- **Disk cost.** Each worktree is a full working tree.

**Cleanup.**

```bash
git worktree list                  # what accumulated
git worktree remove <path>         # remove one
git worktree prune                 # drop records for already-deleted paths
```

Do not substitute `rm -rf <worktree-dir>` for `git worktree remove <path>`. Deleting only the directory leaves stale Git worktree metadata behind; Git may still treat the missing path as owning the branch and refuse later branch deletes, checkouts, or merge cleanup. If that already happened, run `git worktree prune` from a remaining checkout, then retry the blocked command.

## Emergency path

If a production bug cannot wait for normal gates, it still goes through a PR. Include an "Emergency-bypass disclosure" section explaining the incident and bypass, then an organization admin may use GitHub's PR-only ruleset bypass (for example, `gh pr merge --admin --squash --match-head-commit <sha>`). GitHub records that bypass. Direct pushes remain rejected, including for admins.

`--no-verify` bypasses local hooks only; it cannot bypass the server ruleset. Never configure an `exempt` ruleset actor: exempt actions skip rule evaluation and do not create the required audit entry.

Do not reach for the emergency path because the merge gate is inconvenient. A red required check, missing review, or unresolved thread is the gate working. The emergency path is for production incidents, and every use remains both PR-visible and GitHub-audited.
