# PR sequencer keep/delete recurrence audit

Audit for AUT-884 at Touchstone `5f8fcaa8` (v3.7.11). This repeats AUT-305's
raw `git`/`gh` comparison because the reviewed surface changed materially after
that audit.

## Why the earlier decision expired

AUT-305 justified a 513-line `scripts/touchstone-pr.sh` on 2026-08-18. Twelve
days later the script is 2,719 lines and `tests/test-pr-cli.sh` is 2,776 lines.
Between v3.7.0 and v3.7.11, the two files grew by 2,511 net lines (2,694
insertions and 183 deletions). Four recent
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

Delete `read_review_budget`, hosted-history reconstruction, status fields,
output, tests, and follow-up bug tasks AUT-874 and AUT-876. Retain the versioned
PR-body row and concise authoring guidance only as a durable cross-PR handoff:
closing, replacing, or restacking a PR must not erase earlier finding-bearing
rounds for the same capability. The row is not parsed or adjudicated by the
client. The runtime surface did not enforce the stop, could not recover
unrecorded local passes, and did not change the AUT-750 decision. It added 250
script lines and 85 test lines in #1048, then immediately created more
correctness tasks. Historical review analytics belong in the bounded AUT-885
audit, not the merge client.

### Simplify cutoff logic without forgetting mutated findings

Retain behavior-v2's useful invariant: one policy-owned exact-head run may poll
the current GitHub review surface until it reaches a verdict or a bounded
deadline. Delete client prediction of the evaluator's private historical
cutoff, but do not delete mutation history until an equally authoritative
replacement is proven. GitHub's current review APIs remove deleted inline and
body comments; a current-state-only rerun could otherwise forget a previously
observed finding. The evaluator's bounded prior snapshot therefore remains the
minimum integrity mechanism for an active run. A cross-run replacement may use
GitHub's review-dismissal state and review/comment mutation events to leave a
durable exact-head failure, but it must be designed and tested before deletion.

Likewise, an active policy-bound run is reused only while GitHub's run start and
declared request/review windows prove it still has time to observe a new
request. The existing deadline-safe refresh is retained; this is a server-owned
time bound, not a reconstructed review verdict. AUT-785 is resolved only after
the retained behavior is replaced safely or its four cases are fixed. Exact
head, trusted author, required thread, expected head, and merge-group checks
remain fail closed. Broad AUT-793 event wakeups stay deferred: any narrowly
required mutation signal must not grow into a general event orchestrator.

## Approved implementation slices

1. **Delete review-budget runtime projection.** One deletion-only PR removes
   the sequencer parser, current-PR history reads, status/output fields, and
   their tests. The versioned PR-body row and concise guidance remain as a
   non-adjudicated cross-PR handoff. Close AUT-874/AUT-876 as obsolete only
   after the deletion merges.
2. **Prove a mutation-safe cutoff simplification.** A separate design and
   implementation must distinguish disposable client cutoff prediction from
   the evaluator history that prevents deleted, cleared, or dismissed findings
   from disappearing. Tests preserve exact-head/trust/thread failures and the
   existing deadline-safe refresh. Delete history only after a GitHub-owned
   mutation signal or equivalent durable mechanism passes those regressions;
   otherwise retain the mechanism and fix AUT-785 narrowly.
3. **Re-measure before any more status/event features.** AUT-885 captures model
   requests, finding-bearing heads, fix-created defects, Actions minutes, local
   compute, and elapsed time separately. AUT-793 and receipt caching remain
   unstarted unless measured evidence crosses their admission gates.

No implementation slice may add a state store, watcher, retry manager, cache,
runtime counter or ledger, local reviewer adjudicator, or another required
check.

## Acceptance after subtraction

Dogfood one small/medium source PR and one release-prep PR. Each must retain one
exact-head hosted review, all answered threads, one queue-admission mutation,
and fresh merge-group validation. Record first commit to PR, PR heads, hosted
requests, finding-bearing rounds, Actions minutes by workflow/event, queue to
merge, and any manual intervention. Stop after 10 representative PRs if the
predeclared targets hold: zero local confirming reruns, median hosted requests
at most one, no duplicate request on one head, no PR above three initiated
hosted requests, no capability beyond three finding-bearing rounds without
replan, zero continued patch-forward after a fix-created defect, zero automatic
CodeRabbit code reviews, and no unsafe validation skips.
