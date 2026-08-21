# Git Workflow

Every code change goes through a feature branch + PR + PR-visible review loop + merge. The documented emergency bypass remains inside that PR and must be disclosed there. This discipline catches bugs before they land on the default branch and creates an audit trail for every change, while leaving a legible escape hatch for production incidents.

The raw `git` and `gh` commands below are the portable recovery surface: any
agent with a shell and `gh` can run and verify them. When repository-specific
guidance names an executable boundary for one operation, use it; that boundary
may sequence and reconcile these commands, but it may never replace GitHub's
verdict or make the raw recovery path unavailable.

## Never commit on the default branch

**This is the one rule that makes everything else work.** Every code change — including a one-line typo fix, a doc tweak, a version bump, a README edit — starts on a feature branch. Committing directly to `main` (or `master`) bypasses PR review and the audit trail, and leaves you in a local state that's awkward to untangle without rewriting history someone else may already have pulled.

**The concrete rule for any AI or human working here:** before the first edit of a tracked file in a session — `Edit`, `Write`, or any tool that mutates a file under git — run `git branch --show-current`. If the output is `main` or `master`, stop and branch first. `git checkout -b <type>/<slug>` preserves your staged and unstaged changes, so there's no cost to branching late — but there's real cost to discovering the mistake at commit time after batching several files of work.

**Why the trigger is at edit time, not commit time.** The earlier version of this rule said "check before your first commit." That phrasing reliably fails — for LLMs especially, but for humans in flow too. The actual sequence that produces the failure mode is: (1) agent reads a file on `main`, edits it; (2) edits another, and another; (3) reaches commit, the `no-commit-to-branch` hook refuses, and now the agent has to recover the accumulated work onto a new branch. The recovery is mechanically fine and documented below — but it costs more than the one `git branch --show-current` would have. The "before-edit" trigger moves the cost from *discovered at commit, recover* to *discovered before any work, prevent*.

**If you've already committed to main by accident**, don't push. Instead: `git branch <type>/<slug>` to save the work, then `git reset --hard origin/main` to restore the local default branch, then `git checkout <type>/<slug>` to continue. The commits are preserved on the new branch; main is restored to match the remote.

**If you've already pushed**, the standard ship path is broken. Don't try to rewrite history on the default branch. Disclose the slip in the next PR (see "Emergency path" below) and carry on — the commit is now part of history, and the audit trail captures what happened.

**Local guardrails are optional feedback, not authority.** A repository may
configure a driver hook or pre-commit hook that refuses commits on its default
branch. Inspect the repository before relying on either integration; their
absence never changes the branching rule, and `git commit --no-verify` bypasses
pre-commit feedback only.

- Where the repository's effective policy contains the Touchstone organization
  ruleset, GitHub requires the change to go through a PR and rejects direct
  pushes to `main`, including from organization admins.

Local feedback and server policy are complementary when both are present.
Missing local hooks do not change the branching rule; where effective GitHub
policy contains the Touchstone ruleset, the server rejects direct pushes.

## The lifecycle

1. **Pull.** `git pull --rebase` on the default branch before starting work.
2. **Branch — before any edit that might become a commit.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`. Do this as step one of the work, not as a cleanup step later.
3. **Check the tree before changing it.** Run `git status --short` and `git branch --show-current` before starting implementation. If the tree is dirty with unrelated user changes, do not stash them and do not auto-commit on the user's behalf. Ask how to proceed, or branch around the changes when the file surfaces are disjoint. `git stash` is hidden multi-agent state, not a coordination mechanism.
4. **Loop: change → commit → push.** Each meaningful sub-task gets its own commit and push. Stage explicit file paths (not `git add -A`), write a concise message, push to the open branch.
5. **Ship.** Push and open the PR — see "Opening a PR" below.
6. **Answer every piece of PR feedback before merging.** Reply to each comment and resolve its thread, whoever left it. Where effective policy requires conversation resolution, GitHub blocks unresolved threads; elsewhere resolving them remains mandatory driver procedure.
7. **Merge**, bound to the head the review actually saw — see "Merging" below.
8. **Clean up after merge.** Delete the local feature branch once the PR is merged.

## Opening a PR

```bash
git push -u origin HEAD
touchstone pr open --expect-branch "<branch>" --title "<type>: <what changed>" --body-file <(cat <<'EOF'
<what and why>

<configured closing reference, for example: Fixes AUT-123>
EOF
)
```

The installed CLI is the PR-open sequencer on every machine: it creates or
reuses the PR for the branch, posts the review request once for the exact
head, and reports success only after the pinned `review-gate` has been asked
to evaluate that head and the coordinates still hold. `--expect-branch` is
written out, never derived from `git branch --show-current` — that reads the
same checkout the command reads and would agree with a wrong worktree. Where
the CLI is absent, the raw equivalent is `gh pr create --title … --body-file …`
followed by a bare `@codex review` comment; `docs/pr-cli-contract.md` records
it as recovery, not as the instruction.

**The configured closing reference must be in the PR body.** A GitHub
`Closes #123` or Linear `Fixes AUT-123` only in a commit body may disappear
during squash merge. Put the configured tracker's closing grammar in the PR
body and verify it there before shipping.

Verify it took, rather than assuming:

```bash
expected='<configured closing reference>' # for example: Fixes AUT-123
gh pr view <n> --json body --jq .body | grep -F -- "$expected"
```

Set `expected` to the exact tracker item being reconciled, using the grammar
declared by `.touchstone-tracker.toml`; a generic GitHub-or-Linear pattern can
accept the wrong tracker or Linear team key.

**Request review through `touchstone pr open`, not by hand** — it posts the
request and confirms the gate bound it to the exact head and base. Raw
`gh pr create` alone posts no request, so a PR opened that way waits on a gate
with nothing to evaluate.

A bare `@codex review` from an OWNER, MEMBER, or COLLABORATOR is separately
valid: `review-gate` binds it to the head that was current when it was posted
and to the base at that time, deriving both itself. That is what bounded
stalled-request recovery below depends on.
What must never be hand-written is a comment carrying the *sequencer's* marker —
the sequencer reads it as a request for other coordinates and refuses to repair
anything, wedging the pull request until the comment is deleted.

When a later head needs re-review, re-run the project's PR-open command; it is
idempotent and confirms the gate bound the request.

**Before the PR exists** — work slicing, the review tier, and the bounded
local review — is owned by `principles/local-review.md`. This document owns
everything after: answering findings, thread resolution, the round budget,
merge, and recovery.

**Head convergence.** A pre-commit or pre-push hook can create a *newer* commit than the one you thought you were pushing. Review binds the head that actually landed on the remote, so confirm which one that is before reading a verdict as covering your work:

```bash
git rev-parse HEAD                       # local
gh pr view <n> --json headRefOid --jq .headRefOid   # what GitHub has
```

If they differ, push again before requesting review — otherwise the review binds a commit nobody is merging.

## Checking the gate

What the merge gate says right now, in three checks:

```bash
gh pr checks <n>                                          # required checks
gh pr view <n> --json reviews --jq '.reviews[-1].state'   # latest review state
unresolved_threads="$(
  gh api graphql --paginate -f query='
  query($owner:String!, $repo:String!, $pr:Int!, $endCursor:String) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100, after:$endCursor) {
          nodes {
            id
            isResolved
            comments(first:100) { nodes { databaseId url } }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }' -F owner=<owner> -F repo=<repo> -F pr=<n> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved | not)
    | [.id, (.comments.nodes[0].databaseId | tostring),
       .comments.nodes[0].url]
    | @tsv'
)" || exit 1
if [ -n "$unresolved_threads" ]; then
  printf 'Unresolved review threads (thread ID, root comment ID, URL):\n%s\n' \
    "$unresolved_threads" >&2
  exit 1
fi
printf 'All review threads are resolved.\n'
```

The last check paginates the complete thread connection. On failure it prints
the `PRRT_` thread ID to root comment-ID mapping needed to answer and resolve
each finding. Replies are deliberately omitted because the raw reply endpoint
accepts the root finding ID. A zero exit proves no unresolved thread remains.

**The configured AI reviewer reports `COMMENTED`, not `APPROVED`.** GitHub's review API can support approval for authorized integrations, but that is not this adapter's observed contract. Do not expect an approval here or treat its absence as a stalled review.

**Where the repository's effective policy requires `review-gate`, it enforces
the review contract.** It fails unless trusted review evidence covers the exact
current head after the bound request and every inline or body-only finding has
a qualifying later answer. Until that check is installed and verified as
required, exact-head review remains mandatory driver procedure. GitHub
conversation resolution separately requires every inline thread closed.

## Answering findings

Use the stable root comment ID from the complete GitHub review surface. Reply
with `gh api repos/<owner>/<repo>/pulls/<n>/comments/<id>/replies -F
body=@<file>`, then resolve with the GraphQL mutation:

```bash
gh api graphql -f query='
  mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
  }' -F threadId=<PRRT_...>
```

Thread IDs and their numeric root review comment IDs come from the mapped
`unresolvedThreads` result above. The token needs Contents: read and write.

## Merging

```bash
touchstone pr merge <n> --head <reviewed-sha>
```

It re-runs the pinned gate for that head, asks GitHub to merge bound to it,
and reports merged, queued, or auto-merge-enabled only while the head still
equals the reviewed one. Where the CLI is absent, the raw equivalent is:

```bash
gh pr merge <n> --squash --match-head-commit "$(gh pr view <n> --json headRefOid --jq .headRefOid)"
```

**`--match-head-commit` is the head binding.** It refuses the merge if the PR head moved since you checked the gate — which is exactly the race that lets an unreviewed commit slip in behind a passing review.

**Where the ruleset requires a merge queue, that command enqueues instead of
merging.** The queue builds the merged result — your head on top of the current
default branch and anything ahead of you — and runs the required checks there,
so two PRs that are each green alone cannot land a broken combination. You do
not rebase because the default branch moved: a request binds the base it was
made against or any ancestor of the current tip, and the queue owns the
combination. If the queue ejects the PR, that is GitHub's verdict on the
combination: fix forward on the branch, re-review the new head, re-enqueue.
`touchstone pr merge` reports `queued`; `MERGED` arrives when the queue lands
it.

**`gh pr merge` exit codes lie in both directions.** It can exit nonzero after the merge actually succeeded, and it can exit zero having merely *armed* auto-merge while a check is still red. Never trust the exit code alone:

```bash
gh pr view <n> --json state,mergedAt --jq '{state, mergedAt}'
```

`MERGED` with a non-null `mergedAt` is the only proof.

## Commit discipline

**One concern per commit.** A commit should describe a single logical change — a feature, a fix, a refactor, a doc update — not a multi-day grab bag. The diff might span many files, but it should be one coherent thought.

**Why it matters.** Atomic commits pay back continuously: they make `git blame` and `git log` informative, they make `git bisect` able to pin a regression to a single change, they make `git revert` surgical, and they let reviewers reason about one semantic change at a time.

**Concise commit messages.** Lead with *what* changed in the subject line. Use the body to explain *why* when the why isn't obvious from the diff.

**Tracker reconciliation before PR.** Treat tracker state as part of delivery,
not cleanup after the fact. Before opening the PR, make a short ledger of every
item touched: fixed, partially fixed, made stale, or investigated and left
open. Fixed items use the configured closing grammar in the **PR body**.
Partial work uses `Refs <item>` plus a tracker note naming what landed and what
remains. Stale work gets an evidence note before closure. The invariant: after
merge, nobody should have to infer whether shipped work was forgotten,
partial, or unrelated.

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

The PR is the only semantic review surface. Request one ordinary review per exact head-and-base binding: head SHA, base ref, and base SHA. The driving CLI watches the PR, fixes actionable findings, pushes a new head, and repeats until the current binding's review is answered — a clean verdict, or findings with every thread resolved.

### Review-request states and bounded recovery

A request has distinct submitted, accepted, and completed states; its comment
is not proof that the provider accepted or completed the job. Record the
request URL, timestamp, exact head, base, and submission deadline. That
deadline is at least 30 minutes after submission, or longer when the provider
publishes a longer acceptance SLA. The 30-minute floor is the conservative
recovery interval established by the dropped-request incident on Touchstone PR
number 827. Then distinguish these states:

1. **Submitted** — GitHub contains the request comment for the recorded head
   and base.
2. **Accepted** — the provider reacted to the request, exposed a task, or
   emitted other provider-owned output. Record the earliest acceptance signal
   and start a new completion deadline at least 30 minutes later, or later when
   the provider publishes a longer completion SLA. Acceptance is not review
   evidence.
3. **Completed** — trusted review evidence covers the exact head. A clean
   result may be a formal review or a provider-owned PR conversation comment;
   findings may also appear in inline threads.
4. **Provisional quota signal** — the provider reports a security-review quota
   or usage limit. This signal is never a blocker or a terminal review result;
   treat it as acceptance and keep watching through the completion deadline
   measured from the earliest provider-owned signal. It is not review evidence,
   so merge remains gated until trusted evidence covers the exact head.
5. **Explicitly failed** — the provider reports a terminal no-review result or
   error other than a security-review quota notice and makes clear that the job
   will not continue.
6. **Unacknowledged** — the observation deadline passes with no
   provider-owned signal.
7. **Accepted but stalled** — the completion deadline measured from the
   earliest acceptance signal passes without completed or explicitly failed
   output.

Watch the complete PR review surface: formal reviews, PR conversation comments,
inline review threads, request-comment reactions, and any linked provider task.
Polling formal reviews alone can miss a clean result posted as a conversation
comment. A reaction or task proves only acceptance and never permits merge.

The one-request-per-binding rule has one fail-closed recovery exception. If
the original request is **unacknowledged** or accepted but stalled, the driving
CLI may post exactly one replacement trigger on the unchanged binding after it:

- reconfirms that the PR head and base match the original request;
- adds a PR-visible audit note naming the original comment, state, observed
  signals, relevant start and deadline, and elapsed interval;
- re-fetches the complete PR review surface immediately before posting and
  stops if the original request completed or explicitly failed; and
- identifies the new comment as the sole replacement for that unchanged binding.

After posting, re-fetch the live head and base and prove they still equal the
pre-post head, base ref, and base SHA; then re-run the pinned `review-gate` for
that head (`touchstone pr open` does both) so the gate derives the replacement
request from the comment. A gate that still reports no request is a blocked
upstream failure, not permission to retry. If either binding drifted during
posting, edit the replacement into a non-trigger audit note and follow the
base-change rule below.

There is one other final posting race: the original can complete after the
last evidence check but before the replacement comment exists. Capture the
replacement comment ID. If the original completion predates the replacement,
edit the replacement into a non-trigger audit note so it no longer begins with
`@codex review`:

```bash
gh api -X PATCH repos/<owner>/<repo>/issues/comments/<replacement-comment-id> \
  -f body='Recovery trigger withdrawn: <reason and observed binding>.'
```

The edit preserves the audit trail and invalidates the replacement marker.
Verify the check reruns. It may fall back to the original marker only when that
marker still matches the live binding; otherwise remain blocked. If the
provider still completes the replacement, treat any resulting findings as
review feedback; never discard them.

The replacement must still produce trusted exact-head review evidence. If it
also remains unacknowledged, stalls, or fails, file or update an upstream
incident and remain blocked. Never loop replacement requests, synthesize review
evidence, merge on acceptance alone, or use emergency bypass for ordinary
review-provider friction.

**Never re-request review for an unchanged head-and-base binding** for thread-backed findings. The reviewer is non-deterministic, so re-asking about the same binding manufactures new findings instead of confirming the old ones. A new head gets exactly one ordinary request for its current base. Three cases permit another request while the head stays unchanged:

1. **The base binding changed** — if the base ref or base SHA differs from the
   recorded request, that evidence is invalid. Before requesting against the
   new base on an unchanged head, prove the earlier request is completed or explicitly failed. Provider results identify the head but not their request
   or base, so a late old-base result can otherwise masquerade as new-base
   evidence. If the earlier request is nonterminal, wait for terminal output or
   integrate the current base into the branch to produce a genuinely new head;
   then request review for that new head-and-base binding.
   Never manufacture an empty head commit to force review.
2. **Provider recovery** — use the single audited recovery trigger above only
   after its applicable state deadline, with the original binding unchanged.
3. **Body-only finding** — a non-clean verdict with no inline thread has
   nothing resolvable to answer, so one fresh request on the unchanged binding
   is the only path forward.

### Babysitting a PR: the round discipline

Reviews are the most expensive resource in the loop — each round costs full review latency (#649), and the history is unambiguous about what unbounded rounds produce: #706 was closed unmerged after six (rounds 3–6 each contained defects created by the previous fix), and #755 spent seven rounds and +936 lines on a ~60-line core change.

**Freeze the scope before the first review request.** Record the approved issue or
plan, its acceptance criteria, and the behavior or interfaces this PR is allowed
to change. Babysitting authorizes the driver to make that approved change pass
review; it does not authorize a broader product change. Before editing for any
finding, map it to a recorded acceptance criterion or invariant, or to evidence
that the diff created the defect. A plausible bug is not automatically this
PR's bug.

**Classify every finding before touching anything.** Four dispositions, in the order to consider them:

1. **Fix here** — a *high-severity* defect the diff creates, or a
   *high-severity* violation of a recorded acceptance criterion or invariant. High severity means
   correctness, crashes, data loss, security, broken behaviour, unacceptable
   performance, or lifecycle failure. Fix it in the batch.
   A scope boundary never permits the PR to ship its own regression; fix or
   revert that behavior here even when it falls outside the planned change.
   A diff-created finding *below* that threshold takes disposition 4: answer
   it, route it to an issue, resolve the thread. Fixing every low-severity
   remark a reviewer raises is the expansion this budget exists to stop, and
   "the diff created it" does not by itself make it worth another round.
2. **Fix and audit the class** — the in-scope finding is one instance of a
   shape. Grep for siblings before responding
   (`principles/audit-weak-points.md`); fix in-scope siblings and route any
   broader product behavior to its own issue rather than absorbing it here.
3. **Push back with evidence** — the finding is factually wrong. Quote the file, cite the precedent, resolve without changing code. Never comply with a wrong finding to save a round.
4. **Real, but not this PR's to fix** — route it to the owning issue with a comment, resolve the thread with the link. The load-bearing case: **never fix a finding by hardening a component the plan deletes.** Check the plan of record before fortifying anything the reviewer points at.

**Repeated widening is a design signal, not an implementation queue.** If
successive findings keep adding syntax, runtimes, project types, or public
behavior, stop and compare the implementation with the frozen acceptance
criteria. Narrow or replace the design, split an independently approved concern,
or close the PR while preserving the findings. Do not grow the current PR one
review comment at a time. Exact-head review remains required after any redesign;
scope containment is never permission to skip review.

**The loop.** If every finding resolves **without moving the head** (dispositions 3–4), answer every thread, prove none remain with the complete paginated thread check above, then merge — answered findings satisfy the gate (issue #751); do not request another review. If any fix lands as a commit (dispositions 1–2), batch ALL of them into ONE commit, answer every thread, push, and request one review for the new head.

**The budget: three finding-bearing rounds per capability, never more than three
on one PR.** This is a discipline, not an enforced limit — the wrapper that
refused a fourth request is gone, and a rule enforced by a script you can
decline to run was never a rule. Closing, renaming, restacking, or reopening the
same acceptance criterion does not reset its count. Past three rounds, the
legitimate exits are:

- **Merge if answered** — all threads resolved satisfies the gate;
- **Split the PR** — only genuinely independent acceptance criteria receive
  independent budgets; a mechanical split is not budget laundering;
- **Close it, preserving the corpus** on the tracking issue (the #706 pattern) — correct when successive fixes keep creating defects.

After a third finding-bearing review, **do not post a fourth request on the same
implementation shape**. Stop, audit the repeated failure class, and put the
chosen exit plus evidence in the PR. A later request is justified only after a
durable root-cause record, a materially narrower acceptance boundary or
replacement architecture, and a class-level guardrail. That redesigned attempt
gets one validation round. If it produces another finding, split or close the
capability; do not resume one-finding-at-a-time expansion. Exact-head review
still applies to every replacement PR or redesigned head.

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

## Rewriting an unmerged branch

The prohibition is the **protected default branch**. Where the audited
Touchstone policy is installed and verified, GitHub enforces it; elsewhere the
missing enforcement is a rollout gap and the prohibition stays mandatory
driver procedure — inspect the effective rules rather than assuming the
server will refuse. Rewriting your own unmerged feature branch is permitted and sometimes the only
correct fix: amend, squash, or rebase, then force-push with a pinned lease.

Pin the lease to the SHA you inspected. Before rewriting, record the remote
head; after rewriting, push against exactly that value:

```bash
git fetch origin
EXPECTED=$(git rev-parse "origin/$(git branch --show-current)")
# The tip you just fetched must be one you have already integrated -- normally
# your own last push. If it is not in your local history, another agent pushed
# while you were away; the rewrite runs only when the guard passes.
if git merge-base --is-ancestor "$EXPECTED" HEAD; then
  # ...amend / squash / rebase...
  git push --force-with-lease="$(git branch --show-current):$EXPECTED"
else
  echo "remote moved beyond this branch; reconcile before rewriting" >&2
fi
```

The pin guards the window between that inspection and the push; the ancestor
check *is* the inspection. Pinning a tip you never verified is the bare lease
with extra steps.

Never bare `--force`, and don't trust bare `--force-with-lease` either: it
compares against your remote-tracking ref, and any background fetch — another
worktree, an IDE, a status prompt — refreshes that ref, so the lease can
"pass" against a commit you never looked at and silently discard another
agent's push. The pinned form refuses unless the remote still holds the exact
SHA you decided to replace.

**The cost is the reviewed head, and it is the reason to think first.** A
rewrite changes the head SHA, so every piece of evidence bound to the old head
stops applying: `review-gate`, answered findings, and resolved threads all
go outdated, and the change needs review again for the new head. That expense
— not a prohibition — is what should make a driver pause. Budget a review round
before rewriting, not after.

Rewrite when the history is actually wrong and a later commit cannot fix it: a
commit missing an artifact its own gate requires per commit, a leaked secret, a
commit that breaks bisect.

A leaked secret is the one case where the rewrite is the *smaller* half of the
fix. **Rotate or revoke the credential first, then clean the history.** A
pushed secret is already copied — clones, forks, reflogs, provider caches, CI
logs — and no rewrite reaches those. History cleanup without rotation leaves a
live credential while making the leak harder to notice.

Rewriting is the cheap fix while the branch is
yours and unmerged, and it gets more expensive the longer you wait — an amend
before review costs nothing, the same amend after three review rounds costs all
three.

Do not rewrite a branch another agent or worktree is building on, or anything
already merged. A branch serving as the base of an open stacked PR is
rewritten only as part of the chain retargeting below — parent first, each
child deliberately, its own children retargeted in turn — never as an
isolated amend that silently invalidates the stack above it. The
lease is not an ownership check: it compares only the remote ref's value, so a
collaborator with *unpushed* work on the branch is invisible to it — the
remote still equals `$EXPECTED`, the push succeeds, and they discover the
rewrite when their own push is rejected. Ownership is settled by coordination
(worktree assignments, claimed work), not by the push. What the lease does
guarantee is narrower and still worth having: nothing already *pushed* gets
discarded unseen.

Recovery: `git reflog` holds your pre-rewrite head, and the remote's prior SHA
is in the push output and the PR timeline. A rewrite you regret is recoverable;
a `--force` that clobbered someone else's push may not be.

## Stacked PRs (and how they merge)

A stacked PR is a PR whose base branch is another open PR's branch instead of the default branch. The goal: split a large change into a chain where each step is reviewable on its own. Open one with `gh pr create --base <parent-branch>`.

**Exact-head review makes moving stacks multiply work.** Every parent update
changes or invalidates each descendant's reviewed head. Do not open dependent
descendants while a parent is still finding-bearing. Prepare them locally, then
merge the parent and open the rebased child; use parallel PRs only for changes
that are independently based on the default branch. An open stack is not a
parallelization mechanism when exact-head evidence is required.

**Retain the head branch on merge.** Do not enable `deleteBranchOnMerge`, and do not delete a parent branch that children are based on. If a head branch is deleted while open PRs are based on it, those PRs can be closed-without-merge with their review discussion abandoned — this fired on sentinel PRs #49/#50/#51 (2026-04-16) and is the reason the merge path retains branches (issue #713).

**Children still need retargeting after the parent lands.** Nothing rebases a child automatically. After the parent merges (resolve the default branch once — downstream repositories are not all `main`):

```bash
DEFAULT=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
git fetch origin
EXPECTED=$(git rev-parse "origin/<child-branch>")
git merge-base --is-ancestor "$EXPECTED" <child-branch> \
  || { echo "child moved on the remote; reconcile before retargeting" >&2; exit 1; }
gh pr edit <child> --base "$DEFAULT"
git rebase --onto "origin/$DEFAULT" "origin/<parent-branch>" <child-branch>
git push --force-with-lease="<child-branch>:$EXPECTED"
```

Both rebase anchors come from the fetch: the new base is the merged remote
default branch, and the old base is the retained remote-tracking parent ref.
The local branches are disposable and may already be stale or gone after
cleanup; the remote parent is retained until every child has been retargeted
and rebased.

Merge a chain in order, parent first, repeating both steps for each next child.

**Bundling is still often simpler.** When the user says "ship it all," default to one PR with all the commits. Reviewers reason more cleanly about one coherent story than a chain. Use a stack only when a child truly depends on an unmerged parent and must be reviewable separately.

## Claiming tracked work before agent dispatch

Before spawning a coding agent to implement a tracker item, **claim it first**
through the tracker declared in `.touchstone-tracker.toml`. Verify sole ownership, post
a one-line dispatch comment only after the claim is stable, then spawn the
agent.

Start with the repository's verified claim adapter:

```bash
bash scripts/touchstone-tracker.sh claim <reference>
```

For GitHub, the adapter performs the race-safe mutation and re-read. For Linear,
it returns `unverifiable` and directs the driver to the configured API or MCP;
use that authority to assign the `KEY-N` item and re-read its assignee. Only
after either path proves sole ownership, post `Dispatched. Branch <branch>,
worktree at <path>.` through that tracker's API or CLI. If ownership changes,
publish no dispatch signal and stop. An unavailable transport is unverifiable,
never successful.

Then start the agent. Not after.

**Why this is a rule.** Without it, three failure modes recur in agent-driven workflows:

1. **Duplicate work.** Two agents pick up the same item and ship competing PRs. The first to merge wins; the second rebases into conflict or closes orphaned. Both burned budget.
2. **No in-progress signal.** A reader scanning tracked work cannot tell which items are active. Triage decays.
3. **Lost lineage.** The dispatch comment ties the work to a specific agent, branch, and worktree. That breadcrumb matters months later.

**When to unassign.** If you decide not to ship, unassign through the
configured tracker and post a "stood down — <reason>" comment. Stale
assignments are worse than no assignment at all.

**When this rule does NOT apply.**

- **Items you're proposing or analyzing, not implementing.** Claim only when implementation actually starts.
- **Drive-by fixes during unrelated work.** A one-line typo fix doesn't need a claim — but if it warrants its own commit, it warrants a closing reference at minimum.

**For bundles.** When one lane closes multiple items, claim and comment on all
of them with the same branch reference.

**Enforcement is repository policy, not a prose assumption.** Where effective
GitHub policy includes an issue-claim check, it may parse closing references,
verify assignees, and document a repository-specific bypass. Inspect that
policy before relying on either behavior. Without such a check, the
claim-and-reconcile discipline remains mandatory driver procedure; there is no
universal bypass token.

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

If a production bug cannot wait for normal gates, it still goes through a PR.
First inspect the repository's effective policy. Where it exposes the audited
PR-only organization-admin bypass, include an "Emergency-bypass disclosure"
section explaining the incident and bypass, then an organization admin may use
it (for example, `gh pr merge --admin --squash --match-head-commit <sha>`).
GitHub records that bypass, and the adopted ruleset continues to reject direct
pushes, including for admins. If the effective policy does not expose that
bypass, do not infer it from this guide; the missing enforcement is a rollout
gap and there is no audited Touchstone emergency path to use.

`--no-verify` bypasses local hooks only; it cannot bypass the server ruleset. Never configure an `exempt` ruleset actor: exempt actions skip rule evaluation and do not create the required audit entry.

Do not reach for the emergency path because the merge gate is inconvenient. A red required check, missing review, or unresolved thread is the gate working. The emergency path is for production incidents, and every use remains both PR-visible and GitHub-audited.
