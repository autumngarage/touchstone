# PR sequencer keep/delete recurrence audit

Audit for AUT-884 at Touchstone `5f8fcaa8` (v3.7.11). This repeats AUT-305's
raw `git`/`gh` comparison because the reviewed surface changed materially after
that audit.

## Why the earlier decision expired

AUT-305 justified a 513-line `scripts/touchstone-pr.sh` on 2026-08-18. Twelve
days later the script is 2,572 lines and `tests/test-pr-cli.sh` is 2,653 lines.
Between v3.7.0 and v3.7.11, the two files grew by 2,694 net lines. Four recent
review-orchestration PRs (#1033, #1036, #1041, and #1048) produced 40 of 55 bot
root findings across the sampled 35 merged PRs. That is recurrence evidence,
not a line-count quota: the delivery client has again become a large local
model of mutable GitHub state.

The Vesper comparison rejects raw PR size as the cause. A 127-file PR (#1056)
merged in about 40 minutes with one hosted request, while #1051 and #1057 took
about six hours with 10 and 5 hosted requests. The multiplier was repeated
heads and review-fix mutation. Touchstone's status additions described that
churn but did not prevent it.

AUT-750 / PR #1063 supplied a prospective small-change trace. One local pass
found one valid defect. The first hosted head found one different trusted P2;
an automatic CodeRabbit pass found another valid but untrusted P2. Both were
fixed in one 23-line follow-up, focused deterministic checks replaced a second
full-suite run, and one exact-head hosted request reviewed the replacement
head cleanly. The useful controls were scope, one local pass, exact-head hosted
review, and one queue mutation—not review-budget reconstruction.

## Authority test

A behavior stays only when it serves one of Touchstone's three product jobs:
constrain, make GitHub state legible, or carry the contract. GitHub owns policy,
workflow verdicts, pull-request state, and merge-queue state. The client may
read those facts, bind a mutation to an expected head, and reconcile the
result. It may not reconstruct a second verdict or preserve historical state
that GitHub and the required workflow can read directly.

## Keep/delete decision

### Keep: narrow sequencing around irreversible boundaries

| Surface | Decision | Observed failure prevented | Authority |
| --- | --- | --- | --- |
| Project, host, branch, and head resolution | Keep | Two worktree sessions opened PRs for the wrong branch; cross-host repository identity can otherwise drift. | Git and GitHub are read, never modelled. |
| Bounded retries for idempotent reads | Keep | GitHub reads have returned stale or transiently incomplete state. Mutations remain single-attempt and are reconciled. | GitHub's surviving read. |
| `policy status` | Keep | Agents repeatedly needed several raw API calls to learn that a consumer had no effective protection. | GitHub effective rules and Actions state. |
| `pr open`: create/reuse, converge title/body, re-read coordinates | Keep | A stale body silently failed delivery evidence; interrupted retries duplicated requests. | GitHub PR state. |
| Delivery evidence before hosted review | Keep | Invalid PR bodies consumed model review and then failed the required evidence check. | Required `delivery-evidence` workflow. |
| One marked exact-head review request | Keep | A bare request can be reviewed while the required gate remains bound to another head or no request. | Required `review-gate` workflow. |
| `pr answer` reply, verified disposition, resolve, and re-read | Keep | A resolved thread claimed a fix SHA that was not in the live head. | GitHub thread state plus commit ancestry. |
| `pr merge --head` and final reconciliation | Keep | `gh pr merge` can return nonzero after success or zero after merely arming delivery; Vesper queued an old reviewed head while a fix was in flight. | GitHub gate, queue, PR state, and expected head. |
| Prospective merge-group validation | Keep | It has caught real integration, concurrency, and brittle-test defects on the synthetic merge commit. | GitHub merge group and required workflow. |

### Keep, but only as read-only projection

`pr status` keeps the versioned raw observations that are expensive and easy to
mis-bind by hand: PR/head/base, durable auto-merge, merge-queue entry, effective
policy, and the policy-owned exact-head gate run. Its compact phase may remain
only as a deterministic projection of those fields because recent agents
repeatedly confused queued, reviewing, and merged. It must not request review,
enqueue, retry, or infer a repair. `nextAction` and printed commands are not an
independent authority and should be reconsidered when this surface is thinned.

### Delete: runtime review-budget reconstruction

Delete `read_review_budget`, its PR-body ledger, hosted-history reconstruction,
status fields, output, tests, and follow-up bug tasks AUT-874 and AUT-876. The
three-round stop is driver scope discipline, now stated directly in steering.
The runtime surface does not enforce it, cannot recover unrecorded local passes,
and did not change the AUT-750 decision. It added 250 script lines and 85 test
lines in #1048, then immediately created more correctness tasks. Historical
review analytics belong in the bounded AUT-885 audit, not the merge client.

### Delete: client/evaluator history reconstruction; retain current-state polling

Retain behavior-v2's useful invariant: one policy-owned exact-head run may poll
the current GitHub review surface until it reaches a verdict or a bounded
deadline. Delete the attempt-start/cutoff reconstruction used to decide which
edits, deletions, tombstones, or prior answers existed at an historical instant.
The evaluator should read current exact-head evidence on each poll; a successful
CheckRun is the durable verdict, and later review activity makes that verdict
stale. The client should preserve any unambiguous active policy-bound run for
the exact head instead of predicting whether its private cutoff observed a
request.

This removes the bug class recorded in AUT-785 rather than adding four more
cutoff exceptions. Exact-head, trusted-author, required-thread, expected-head,
and merge-group checks remain fail closed. AUT-793 event wakeups stay deferred:
observability or new triggers do not cure review-unit churn, and polling is the
bounded recovery path.

## Approved implementation slices

1. **Delete review-budget runtime state.** One deletion-only PR removes the
   sequencer/evaluator-adjacent ledger, docs, and tests; steering retains the
   stop rule. Close AUT-874/AUT-876 as obsolete only after the deletion merges.
2. **Replace historical cutoff reconstruction with current-state polling.** A
   separate PR changes the required evaluator and the smallest client reuse
   branch together. Tests preserve exact-head/trust/thread failures and prove
   an active bound run is reused without cutoff prediction. Close AUT-785 by
   deletion of the faulty mechanism, not by patching its four cases.
3. **Re-measure before any more status/event features.** AUT-885 captures model
   requests, finding-bearing heads, fix-created defects, Actions minutes, local
   compute, and elapsed time separately. AUT-793 and receipt caching remain
   unstarted unless measured evidence crosses their admission gates.

No implementation slice may add a state store, watcher, retry manager, cache,
counter, ledger, local reviewer adjudicator, or another required check.

## Acceptance after subtraction

Dogfood one small/medium source PR and one release-prep PR. Each must retain one
exact-head hosted review, all answered threads, one queue-admission mutation,
and fresh merge-group validation. Record first commit to PR, PR heads, hosted
requests, finding-bearing rounds, Actions minutes by workflow/event, queue to
merge, and any manual intervention. Stop after 10 representative PRs if the
predeclared targets hold: zero local confirming reruns, median hosted requests
at most one, no capability beyond three finding-bearing rounds without replan,
zero continued patch-forward after a fix-created defect, zero automatic
CodeRabbit code reviews, and no unsafe validation skips.
