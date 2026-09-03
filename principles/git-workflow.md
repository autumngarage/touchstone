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

The lifecycle is the ten-step **Required Delivery Workflow** in the steering
block, and this document does not enumerate a second one: the steps below
carry the same numbers and add only the detail the steering leaves out.

1. **Pull.** `git pull --rebase` on the default branch before starting work.
2. **Branch — before any edit that might become a commit.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`. Do this as step one of the work, not as a cleanup step later. Check the tree first: run `git status --short` and `git branch --show-current`. If the tree is dirty with unrelated user changes, do not stash them and do not auto-commit on the user's behalf — ask how to proceed, or branch around the changes when the file surfaces are disjoint. `git stash` is hidden multi-agent state, not a coordination mechanism.
3. **Claim tracked work** — see "Claiming tracked work before agent dispatch" below.
4. **Change + commit.** Stage explicit file paths (not `git add -A`). Normal tier: first require `touchstone review check`, then run `touchstone review run` on the isolated staged slice before commit (`principles/local-review.md`). A failed check or run is an explicit normal-tier waiver, never permission to fall back to an unbounded model path. A tier-required local AI pass runs at most once per coherent review unit and is never rerun to confirm fixes; trivial work initiates none. Each meaningful sub-task gets its own concise commit. The tier sets push cadence: normal pushes when a commit is ready; serious pushes once per reviewed head. After a review round, batch every fix into one commit and push once.
5. **Local review evidence.** Serious tier: capture `reviewed_head="$(git rev-parse HEAD)"`, then run `touchstone review run --base <default>` at most once on that coherent committed branch before its first push. It runs Codex and falls back to the bounded OpenRouter pass over the same branch on any Codex non-success, including an exhausted quota. This is the one step nothing else witnesses (AUT-443), so the PR body's `- Local review:` row records normal as `openrouter on the staged slice (review-normal): <n> findings, <disposition>` or serious as `<reviewer> on <captured-head-sha>: <n> findings, <disposition>` for whichever reviewer it reported. The serious SHA is the captured current head the pass reviewed; `<default>` is only its comparison boundary. Normal may waive for a failed configured check or pass; serious may waive only when Codex and the fallback are both unavailable. After allowed local findings are fixed, rerun deterministic checks and push; the hosted PR reviewer owns exact-head review for every pushed head. Another local AI pass is neither required nor authorized. `delivery-evidence` refuses a missing, malformed, or unexplained row.
6. **Reconcile tracked work** before opening the PR — fixed items get the closing reference in the PR body; partial or stale items get a tracker note.
7. **Ship.** Push and open the PR — see "Opening a PR" below.
8. **Answer every piece of PR feedback before merging.** Reply to each comment and resolve its thread, whoever left it. Where effective policy requires conversation resolution, GitHub blocks unresolved threads; elsewhere resolving them remains mandatory driver procedure.
9. **Merge**, bound to the head the review actually saw — see "Merging" below.
10. **Clean up after merge, and before the session ends** — see "Leaving no mess" below. Remove everything this session created; `touchstone cleanup check` reports repository-wide residue, including work another session may still own.

## Before trusting any merge: what does GitHub enforce here?

```bash
touchstone policy status
```

It reads the default branch's effective rules and reports `enforcement:
applied`, or names what is missing (the policy's pinned workflows or required
status, the merge queue where declared, and the native rules). Where it
is not `applied`, exact-head review and every answered finding remain
mandatory driver procedure, `touchstone pr merge` refuses without
`--unguarded`, and the gap is tracked — not inferred from this document.

## Opening a PR

```bash
git push -u origin HEAD
touchstone pr open --expect-branch "<branch>" --title "<type>: <what changed>" --body-file <(cat <<'EOF'
## Intent
<what and why>

## Invariants
<what must remain true>

## Validation
- Build: <what ran and its result, or n/a with a reason>
- Automated tests: <what ran and its result, or n/a with a reason>
- Manual validation: <what ran and its result, or n/a with a reason>
- Local review: <the tier-required record or permitted waiver>

## Review tier
<trivial | normal | serious>

## Why this tier
<why this tier applies>

<configured closing reference, for example: Fixes AUT-123>
EOF
)
```

The installed CLI is the PR-open sequencer on every machine: it creates or
reuses the PR for the branch, waits for the policy-declared
`delivery-evidence` workflow to accept the surviving body, then posts the
review request once for the exact head. It re-runs the pinned `review-gate`
where policy declares one and reports success only after the coordinates still
hold. A policy with no gate leaves
exact-head review as explicit driver procedure. `--expect-branch` is
written out, never derived from `git branch --show-current` — that reads the
same checkout the command reads and would agree with a wrong worktree. Where
the CLI is absent, the raw equivalent is `gh pr create --title … --body-file …`,
a bare `@codex review` comment, and then — because a required workflow runs
only on pull-request and merge-group events and may already have evaluated
before the comment existed — a re-run of the pinned gate's run for this head:
`gh api -X POST repos/<owner>/<repo>/actions/runs/<review-gate run id>/rerun`.
`docs/pr-cli-contract.md` records this as recovery, not as the instruction.

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
request and confirms its exact head/base binding, including the gate where
declared. Raw
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
idempotent and confirms the request's live coordinates and any declared gate.

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

A `review-gate` run that started before the exact-head review completed may
fail only because the evidence did not exist yet. Re-run the project's PR-open
command; it is idempotent and re-runs the pinned gate. Compare timestamps
before treating that red check as a review verdict.

**The configured AI reviewer reports `COMMENTED`, not `APPROVED`.** GitHub's review API can support approval for authorized integrations, but that is not this adapter's observed contract. Do not expect an approval here or treat its absence as a stalled review.

**Where the repository's effective policy requires `review-gate`, it enforces
the review contract.** It fails unless trusted review evidence covers the exact
current head after the bound request and every inline or body-only finding has
a qualifying later answer. Until that check is installed and verified as
required, exact-head review remains mandatory driver procedure. GitHub
conversation resolution separately requires every inline thread closed.
`touchstone pr merge` observes that policy-owned exact-head verdict; it does
not reconstruct a second verdict from mutable review timestamps. The merge
queue is the atomic boundary: its merge-group run re-evaluates the complete
surface, including feedback that arrived after the PR gate. A review-gated
policy without that run is an enforcement gap, not a guarded auto-merge path.

## Answering findings

More than one reviewer may post: the configured AI reviewer (Codex) and any
other installed review app (CodeRabbit, here). Their threads are equal before
the gate — every unresolved thread blocks merge under conversation
resolution, whoever opened it — so answer and resolve them all.

Use the stable root comment ID from the complete GitHub review surface, then:

```bash
touchstone pr answer <n> --comment-id <id> --body-file <reply.md> --fix-commit <sha>
touchstone pr answer <n> --comment-id <id> --body-file <reply.md> --no-code-change
touchstone pr answer <n> --all-resolved-check   # exit 0 only when no thread is unresolved
```

Exactly one disposition is required, and the CLI refuses the answer as
invalid input before any read when neither or both are given. `--fix-commit`
is proved reachable from the captured head before it is published;
`--no-code-change` says the answer explains why no commit was needed.
Touchstone never judges whether that explanation persuades — it records
which of the two states you claimed, because prose reading "fixed in `<sha>`"
once resolved a finding the evaluated head did not contain, and GitHub queued
that head (AUT-800).

It posts the reply, resolves the thread, and asks the pinned gate to
re-evaluate, once; a rerun after a timeout finds its own reply instead of
posting a second one — unless the earlier reply predates dispositions, which
is how an already-open PR records one. Where the CLI is absent, the raw
equivalent is a reply with `gh api
repos/<owner>/<repo>/pulls/<n>/comments/<id>/replies -F body=@<file>` whose
body ends with the disposition the gate reads:

```text
<!-- touchstone:review-answer v=1 id=<comment-id> disposition=fixed fix=<40-hex> -->
<!-- touchstone:review-answer v=1 id=<comment-id> disposition=no-code-change -->
```

then the GraphQL mutation:

```bash
gh api graphql -f query='
  mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
  }' -F threadId=<PRRT_...>
```

Thread IDs (`PRRT_…`) and their numeric root review comment IDs come from the
mapped `unresolvedThreads` result above — the reply takes the numeric ID, the
mutation takes the thread ID. After the mutation, re-read the thread and
confirm `isResolved == true` before counting it answered; the token needs
Contents: read and write. Then re-run the pinned gate for the head, as
`touchstone pr answer` does.

## Recovering a `DIRTY` PR

With a verified merge queue, do nothing when the base merely advances: the
queue tests the combined result. Without one, a base advance uses the sequence
below even when GitHub is not `DIRTY`. Always act when GitHub reports
`mergeStateStatus: DIRTY`, because the branch cannot be merged as-is. Read the
PR's base repository, `baseRefName`, and `baseRefOid`; inherited stacks,
explicit bases, and forks do not necessarily target `origin` or the repository
default branch.

1. Record the current head and base binding. Fetch `baseRefName` from the base
   repository, refuse unless `FETCH_HEAD` equals the recorded `baseRefOid`, and
   merge that verified commit into the feature branch.
2. Resolve conflicts deliberately and commit the merge. `--ours` and
   `--theirs` are whole-file operations, not hunk choices; either discards all
   changes from the other side of that file, including changes far from the
   conflict.
3. Prove the feature side survived: for every file the feature branch changed,
   inspect `git diff <pre-merge-head> HEAD -- <file...>` and confirm that the
   merge did not delete or replace those edits.
4. If effective policy contains the protected validation workflow, run focused
   deterministic tests for the integrated behavior; otherwise run the complete
   suite locally and track the rollout gap. Push the new head and re-run the
   PR-open command with the same `--base`. The hosted workflow validates the
   prospective merge; the pushed head still requires exact-head review.

Never let a green suite substitute for step 3: a developer machine can carry
state that masks a discarded fixture or precondition.

## Merging

```bash
touchstone pr merge <n> --head <reviewed-sha>
```

It requires the policy-owned gate to have already succeeded for that exact
head, asks GitHub to merge bound to it, and reports merged, queued, or
auto-merge-enabled only while the head still equals the reviewed one. It never
starts or waits for review, or reconstructs another verdict from review
timestamps. Where the CLI is absent, first verify that effective enforcement
includes both the declared exact-head gate and the merge queue. Without the
queue, stop and repair enforcement: raw recovery cannot preserve review
freshness. With both applied, verify the gate is successful and immediately
re-read `mergeQueueEntry`; a live entry for the reviewed head ends the mutation
path. Only when no such entry exists, run

```bash
gh pr merge <n> --squash --match-head-commit <reviewed-sha>
```

(`<reviewed-sha>` is the head the review covered, written out — never the
live `headRefOid`, which would bind the merge to whatever was pushed last),
then re-read `state`, `headRefOid`, merge-queue and auto-merge state: merged,
queued, or auto-merge-enabled count only while `headRefOid` still equals the
reviewed head, and only `state == MERGED` proves the merge.

The protected merge group's prospective gate re-evaluates the complete review
surface after admission. It owns feedback that arrives after the PR gate;
client-side timestamp comparisons do not make that boundary atomic.

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

**A live exact-head queue entry ends merge mutation.** Read `mergeQueueEntry`
before any raw recovery or emergency attempt. When the same PR head is already
`QUEUED`, `AWAITING_CHECKS`, `MERGEABLE`, or `LOCKED`, wait for GitHub. Do not
dequeue, enqueue, re-enqueue, cancel its merge-group run, or probe `--admin`:
GitHub may remove the valid queue entry before it rejects the alternate merge,
discarding paid prospective validation without changing the code or base. An
unknown or `UNMERGEABLE` queue state is inspect-and-fix-forward, not permission
to mutate the queue.

**`gh pr merge` exit codes lie in both directions.** It can exit nonzero after the merge actually succeeded, and it can exit zero having merely *armed* auto-merge while a check is still red. Never trust the exit code alone:

```bash
gh pr view <n> --json state,mergedAt --jq '{state, mergedAt}'
```

`MERGED` with a non-null `mergedAt` is the only proof.

## Commit discipline

**One concern per commit.** A commit should describe a single logical change — a feature, a fix, a refactor, a doc update — not a multi-day grab bag. The diff might span many files, but it should be one coherent thought.

**Why it matters.** Atomic commits pay back continuously: they make `git blame` and `git log` informative, they make `git bisect` able to pin a regression to a single change, they make `git revert` surgical, and they let reviewers reason about one semantic change at a time.

**Concise commit messages.** Lead with *what* changed in the subject line. Use the body to explain *why* when the why isn't obvious from the diff.

**Per-commit release evidence.** Where a project validates release-note
fragments per commit, every follow-up commit needs its own fragment or explicit
skip record; an earlier commit's record does not cover it.

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
4. **Behavior-v3 attest** — where the effective gate implements gate behavior
   contract 3, answered findings never satisfy it: only a later trusted clean
   verdict for the exact head does. Resolving the last thread-backed finding
   therefore earns exactly one fresh request on the unchanged binding —
   `touchstone pr answer` posts it automatically with a head-scoped
   idempotency marker, so neither the driver nor a retry posts a second one.

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

1. **Fix here** — a **P0 or P1** defect the diff creates, or a **P0 or P1**
   violation of a recorded acceptance criterion or invariant. Fix it in the
   batch.
   A scope boundary never permits the PR to ship a **P0/P1** regression of its
   own; fix or revert that behavior here even when it falls outside the
   planned change. At P2 or P3 the badge rule below governs instead: route it,
   and say in the answer that the diff created it.
   If the immediately preceding review fix created the regression, follow the
   cascade rule below instead of stacking another fix onto it.

   **The badge is the bar; nothing else is.** Do not re-derive severity from a
   finding's prose. The reviewer is instructed to report *only* concrete
   correctness, security, data-loss, compatibility, lifecycle, and material
   performance defects (`config/review-normal-prompt.md`), and only then to
   rank them: P0 release-stopping, P1 high-impact, P2 ordinary, P3 low-impact.
   Those categories are its *admission* criteria, not its severity scale —
   every finding it is capable of emitting matches them. A bar phrased in
   those categories selects everything, which is exactly how the old wording
   ("high severity means correctness, crashes, data loss, security, broken
   behaviour…") was read on #706, #755, and #1091: the reviewer's own words
   were quoted back as proof the finding cleared the bar. Read the badge.

   This rule has been written once before. The steering size cap was raised
   deliberately on 2026-08-19 to carry "only high-severity findings are
   implemented", because #925 had just spent twenty review rounds on a change
   that was correct and tested after three
   (`tests/test-steering-size-caps.sh`). It did not hold, and the reason was
   the wording rather than the agent: a bar naming the reviewer's own
   admission categories cannot exclude anything the reviewer says. Restating
   it more forcefully would fail the same way. The badge is the only part of
   a finding the agent cannot argue with, so the badge is the bar.

   **P2 and P3 are never fixed in the PR that received them.** They take
   disposition 3 or 4 — never 1 or 2. Push back where the finding is wrong;
   otherwise answer, route to an issue, resolve the thread, and merge. That holds when the finding is correct, when the fix is one
   line, when the file is already open in the diff, and when fixing looks
   cheaper than writing the answer — those four are the rationalizations that
   produced the loops, not exceptions to the rule. "The diff created it" does
   not promote a P2. A finding with no badge, or an ambiguous one, is a P2.
   If a P2 looks release-stopping to you, route it and say so in the answer;
   promoting a finding is the human's call on the tracked issue, never a
   reason to keep mutating the PR.
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

**A review-fix regression is a stop signal.** At the first defect created by the
preceding review fix, stop patch-forward work: restore the last known-good
behavior by reverting that fix, or replace it with a materially simpler design,
then audit the weak-point class before another mutation. A regression test
records the failure; it does not justify retaining the failed fix. At the
second fix-created defect, or the third finding-bearing round, end same-shape
mutation: genuinely split the approved capability or close and replan it.
Exact-head review remains mandatory for any head that might merge; it does not
authorize further mutation after this stop signal.

**The loop.** If the cascade rule has fired, take its exit instead of continuing
this loop. Otherwise, if every finding resolves **without moving the head**
(dispositions 3–4), answer every thread, prove none remain with the complete
paginated thread check above, then merge — answered findings satisfy the gate
(issue #751); do not request another review. If any allowed fix lands as a
commit (dispositions 1–2), batch ALL of them into ONE commit, answer every
thread, push, and request one review for the new head.

**The budget: three finding-bearing rounds per capability, never more than three
on one PR.** This is a discipline, not an enforced limit — the wrapper that
refused a fourth request is gone, and a rule enforced by a script you can
decline to run was never a rule. Closing, renaming, restacking, or reopening the
same acceptance criterion does not reset its count. Past three rounds, the
legitimate exits are:

- **Merge if answered** — only when no known P0/P1 defect remains; all
  threads resolved satisfies the gate, but routing a low-severity or
  out-of-scope finding is not permission to ship a known serious regression;
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

## Leaving no mess

Cleanup is the step a session skips when the merge lands and attention
moves on. It is what turned one day of agent work into two stale worktrees,
ten merged local branches, fifty-six merged remote branches, a `__pycache__`
that refused the next ship as "dirty", and tracker items left In Progress
(2026-08-21). Before a session ends, every item it created satisfies the
steps below, in this order — each line is a command, not advice:

```bash
touchstone cleanup check            # read-only: lists what is left; exit 0 means nothing
git checkout <default> && git pull --rebase    # first: Git refuses to delete the branch you are on
git worktree remove <path>          # only after terminal result delivery or confirmed cancellation
git worktree prune                  # only after every prunable worker meets that lifecycle proof
git branch -D <branch>              # after the merged-head proof under "Periodic branch hygiene"
git push origin --force-with-lease=<branch>:<merged-sha> :<branch>   # delete the MERGED PR's remote branch only if it is still at the merged SHA (a CLOSED one may hold abandoned work: decide, don't reflexively delete)
git status --porcelain --untracked-files=all   # must print nothing: remove test/build residue or ignore it
```

Then the tracker: every item this session claimed has been re-read and left in
the state it should end in — "Keeping a tracked item current, and closing it"
owns which state that is. Scratch files under `$TMPDIR` that the session
created go too.

`touchstone cleanup check` never deletes anything — what is finished is the
driver's decision, and a tool that pruned branches on its own would be
adjudicating it. The check is repository-scoped, not a session-ownership
oracle: a nonzero exit says residue exists, not that this session may remove
it. Resolve every finding this session owns; leave active sibling work
untouched, and route stale unowned residue to its owner or tracker. Never
delete another session's branch or worktree without its lifecycle proof.

The check makes residue legible: checkout not on the default branch or behind
origin, linked worktrees, local or remote branches whose PR is merged or
closed, untracked and dirty files. Run it with `--project <dir>` for each
repository the session touched, and with `--json` when a script consumes it
(`touchstone.cleanup/v1`).

## Periodic branch hygiene

```bash
git branch --merged main                    # ancestor-merged: safe to delete
git branch -d <branch>                      # git refuses unmerged work
```

Squash-merged branches are the common case, and their commits are *not* ancestors of the default branch even though their changes are applied, so `git branch -d` refuses them — and `git diff main...<branch>` stays non-empty after a squash (it compares against the merge base, not the squash commit), so it proves nothing either. The proof that the content landed is GitHub's: the PR is `MERGED` at the head you reviewed. Then force-delete that branch and only that branch:

```bash
branch=<branch>
default="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
# Exactly one merged PR for THIS branch, and the local branch ref (not a
# same-named tag) still at the head it merged: otherwise stop.
merged_head="$(gh pr list --head "$branch" --state merged --json headRefOid --jq 'if length == 1 then .[0].headRefOid else error("expected exactly one merged PR for \(length) found") end')" || exit 1
[ "$(git rev-parse --verify "refs/heads/$branch")" = "$merged_head" ] || { echo "local $branch is not at the merged head; unmerged work"; exit 1; }
git checkout "$default" && git pull --rebase
git branch -D "$branch"
```

The sequence fails closed: zero or several merged PRs, or a local ref that
moved past the merged head, stops before anything is deleted. Never
`git branch -D` without it.

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

A stacked change is a dependent chain prepared as separate branches so each
step remains reviewable. The supported default publication path keeps each
child local until its parent merges, rebases the child onto the protected
default branch, then opens it with `touchstone pr open`. Do not bypass a
refusal by opening the child against an unmodeled parent with raw `gh`.

**Exact-head review makes moving stacks multiply work.** Every parent update
changes or invalidates each descendant's reviewed head. Do not open dependent
descendants while a parent is still finding-bearing. Prepare them locally, then
merge the parent and open the rebased child; use parallel PRs only for changes
that are independently based on the default branch. An open stack is not a
parallelization mechanism when exact-head evidence is required.

**Recover an inherited open stack; do not create another one.** A stack created
outside this contract may still exist. Do not enable `deleteBranchOnMerge`, and
do not delete a parent branch that children are based on. If a head branch is
deleted while open PRs are based on it, those PRs can be closed-without-merge
with their review discussion abandoned. This fired on sentinel PRs #49/#50/#51
(2026-04-16) and is the reason the merge path retains branches (issue #713).

**An inherited open child still needs retargeting after the parent lands.**
Nothing rebases a child automatically. After the parent merges (resolve the
default branch once — downstream repositories are not all `main`):

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

**Bundle one coherent review unit.** "Ship it all" means deliver every approved
unit, not combine them. Use one PR when commits share an invariant and
validation story. Independent units use separate PRs based on the default
branch; dependent units proceed sequentially so exact-head review does not
multiply.

## Claiming tracked work before agent dispatch

Before spawning a coding agent to implement a tracker item, **claim it first**
through the tracker declared in `.touchstone-tracker.toml`. Verify sole ownership, post
a one-line dispatch comment only after the claim is stable, then spawn the
agent.

Start with the installed claim adapter:

```bash
touchstone tracker claim <reference>
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
- **Drive-by fixes during unrelated work that have no tracker item of their own.** A one-line typo fix doesn't need a claim — but if it warrants its own commit, it warrants a closing reference at minimum, and if an item exists for it, step 3 applies: claim it.

**For bundles.** When one lane closes multiple items, claim and comment on all
of them with the same branch reference.

**Enforcement is repository policy, not a prose assumption.** Where effective
GitHub policy includes an issue-claim check, it may parse closing references,
verify assignees, and document a repository-specific bypass. Inspect that
policy before relying on either behavior. Without such a check, the
claim-and-reconcile discipline remains mandatory driver procedure; there is no
universal bypass token.

## Keeping a tracked item current, and closing it

Claiming is the start of a task's life; this is the rest of it. The rules are
the same for whichever tracker `.touchstone-tracker.toml` declares — only the
transport differs.

**One item per unit of work.** Independent work you discover mid-task gets its
own item; do not widen the one you claimed. Work the approved acceptance
criterion already implies — its regression test, the change that holds the same
invariant — belongs to the item you are on.

**Update it at each milestone, not in a batch at the end.** PR merged, finding
routed, scope split, work blocked: move the state and add one comment naming
the evidence — the PR and SHA where they exist, the blocker or the receiving
item where they do not — in the same breath as the event. A tracker reconciled
hours later is how someone following the work without reading your session gets
a wrong answer from it.

**Close it when the work lands, and confirm it closed.** The proof is the state
you read back, never the call you made:

- GitHub — `Closes #n` in the PR body closes the item on merge when it fires,
  and silently does not for a PR merged into a non-default branch, a body edited
  after the merge, or a reference to an issue in another repository
  (`owner/repo#n`), which GitHub links but never closes. A PR from a fork is not
  an exception: the pull request lives in the upstream repository, so its
  `Closes #n` resolves there. Re-read the item rather than assuming the
  reference did its job.
- Linear — GitHub closes only its own issues, so `Fixes KEY-123` in a PR body is
  inert on GitHub's side and records intent only. Whether anything moves the item
  is repository configuration: where Linear's own GitHub integration is set to
  update a linked issue on merge it may already have done so, and where it is not
  configured nothing has. Re-read the item first, set the terminal state through
  the configured API or MCP only if it is not already terminal, then read back
  the state it returns — the same authority rule claiming follows.

**Work that stopped is not In Progress.** Work you routed elsewhere,
superseded, abandoned, or shipped in part and are not continuing gets a terminal
or explicitly parked state, plus one comment naming what landed and what
remains. Work still moving stays In Progress and gets the same comment — the
next PR in a stack, or an item whose remaining approved scope you are still
implementing, is owned, not stalled. This is the ledger from "Reconcile tracked
work" closed out; "When to unassign" above covers the narrower case where you
never started.

**End the session with no item left In Progress by accident.** An item still
being implemented may legitimately stay In Progress across sessions; what may
not survive the session is one left there because attention moved on after the
merge. This is the tracker half of "Leaving no mess", and no command reports it
for you: a shell process has no transport to every tracker, so re-reading the
items this session claimed is the driver's step.

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

Before removing a worker's tree, confirm its task is terminal and the parent
either received its final report or acknowledged its cancellation. A merged PR
and a clean tree prove neither. Because pruning is repository-wide, run it only
after every prunable worker meets that lifecycle proof.

```bash
git worktree list                  # what accumulated
git worktree remove <path>         # remove one after that lifecycle proof
git worktree prune                 # only after every prunable worker passes
```

Do not substitute `rm -rf <worktree-dir>` for `git worktree remove <path>`. Deleting only the directory leaves stale Git worktree metadata behind; Git may still treat the missing path as owning the branch and refuse later branch deletes, checkouts, or merge cleanup. If that already happened, prove every prunable worker meets the lifecycle rule, run `git worktree prune` from a remaining checkout, then retry the blocked command.

## Emergency path

If a production bug cannot wait for normal gates, it still goes through a PR.
Urgency, frustration, “keep going,” or a request to file follow-up work never
authorizes bypass. The human must explicitly authorize bypassing normal policy
for this incident. After that authorization, first inspect both the
repository's effective policy and the PR's current `mergeQueueEntry` read-only.
An existing live exact-head entry still receives zero merge mutations. Where
no entry exists, inspect effective policy. Where it exposes the audited PR-only
organization-admin bypass, include an "Emergency-bypass disclosure" section
explaining the incident and bypass, then an organization admin may use it (for
example, `gh pr merge --admin --squash --match-head-commit <sha>`), but only
after one final read confirms the reviewed head still has no queue entry.
GitHub records that bypass, and the adopted ruleset continues to reject direct
pushes, including for admins. If the effective policy does not expose that
bypass — including when it requires the merge queue for admins — do not infer it from this guide:
report that no audited bypass exists. Do not probe the rule by mutation.
Missing
enforcement is a rollout gap and there is no audited Touchstone emergency path
to use.

`--no-verify` bypasses local hooks only; it cannot bypass the server ruleset. Never configure an `exempt` ruleset actor: exempt actions skip rule evaluation and do not create the required audit entry.

Do not reach for the emergency path because the merge gate is inconvenient. A red required check, missing review, or unresolved thread is the gate working. The emergency path is for production incidents, and every use remains both PR-visible and GitHub-audited.
