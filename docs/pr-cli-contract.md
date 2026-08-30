# PR CLI Contract

This document owns the narrow `touchstone pr` boundary. It sequences GitHub's
existing pull-request operations; GitHub remains the enforcement authority.
Every operation has a raw `gh` equivalent so installing Touchstone is never a
precondition for recovery.

## Interface

```text
touchstone pr open --title TITLE --body-file FILE [--base BRANCH]
                   [--expect-branch BRANCH]
touchstone pr status PR
touchstone pr merge PR --head SHA [--unguarded]
touchstone policy status [--base BRANCH]
touchstone pr answer PR --comment-id ID --body-file FILE (--fix-commit SHA | --no-code-change)
touchstone pr answer PR --all-resolved-check
```

Every command accepts `--project DIR`; every command except `answer` accepts `--json` (`answer` has no observation to report and refuses it). JSON has schema
`touchstone.pr/v1`; adding fields or enum values is compatible, while changing
an existing value's meaning requires a new schema. Exit 0 means the reported state was verified, exit 1 is
an operational or transport failure, and exit 2 is invalid or unsafe input. No
command runs a daemon, stores credentials, or persists derived PR state.
When `open` requests a policy-declared review gate, its JSON result includes
`reviewGate.runId` and `reviewGate.action`. `rerun-requested` means the client
refreshed a completed attempt; `already-active` means a behavior-v2 run is the
authoritative evaluator and the client returned while that run waits. A
successful guarded `merge` reports `verified-success`: it observed an existing
policy-bound successful gate and did not request another evaluation.
`open` and `status` also include an additive `reviewBudget` observation. It is
round-accounting state, never a review verdict or permission to skip the
required exact-head review.

## Operations and raw equivalents

The strip's acceptance test was that a change ships end-to-end on bare `git`
and `gh`, and that whatever proves awkward specifies the CLI replacing them.
Each operation below records the awkwardness that justifies it. A reader who
doubts one can re-run that test on raw commands and compare, rather than
taking this document's word for it.

- `open` proves the local and remote branch heads match, reuses an existing
  open PR for that branch or runs `gh pr create`, re-reads GitHub after the
  mutation, and posts `@codex review` once for the exact head. On a reused
  PR it applies the `--title` and `--body-file` given now when they differ
  from the live values (`gh pr edit`, re-read to verify) and reports `body:
  updated` or `unchanged` — idempotent means "converges on the arguments",
  not "no-ops": a body silently kept let the required `delivery-evidence`
  gate fail with no signal from the one command the driver uses (AUT-437).
  After convergence, a reused PR asks the policy-declared organization-required
  `delivery-evidence` run to evaluate the surviving body. GitHub exposes only a
  PR-wide update timestamp, so the sequencer does not guess whether activity was
  a body edit: it requests a fresh attempt, then re-verifies the body, head, and
  base immediately before success without closing the PR or disturbing
  auto-merge (AUT-481). Its invisible
  comment marker (`<!-- touchstone:pr-open head=… base=… base_sha=… -->`)
  is what a pinned `review-gate` reads as the request, and it makes partial
  reruns idempotent. It reports success only after any policy-declared gate
  has been asked to evaluate the new request and a fresh PR read still matches
  the head and base. Under behavior v1, an active run is allowed to finish and
  then re-run. Under behavior v2, the run owns the bounded evidence poll, so an
  already queued exact-head run, or one still inside the relevant request or
  review evidence window, is preserved and reported instead of making the
  client poll it for up to five minutes. A run outside that conservative
  lower-bound window follows the behavior-v1 finish-and-refresh path so newly
  posted evidence cannot be stranded beyond its cutoff. A newly posted request
  uses the short request window; an idempotent retry that finds the exact
  request already present uses the longer review window.
  Immediately before inspecting or posting that request, `open` reports the
  same review-budget observation as `status`. It then re-reads the request
  surface for sequencing; the earlier observation cannot suppress a request
  after intervening PR or workflow activity.
  Raw equivalent: compare `git rev-parse HEAD` with `git ls-remote`, inspect
  `gh pr list`, create with `gh pr create`, re-read, then inspect comments
  before `gh pr comment --body "@codex review"`, then re-run a completed gate
  attempt for the head or leave its behavior-v2 polling run active.

  `--expect-branch` binds the caller's intent to the branch the resolved
  project actually has checked out, the way `merge --head` binds the reviewed
  commit. It is optional and checked twice: once up front, so a mismatch is
  refused before GitHub is consulted at all, and again where the branch is
  selected, because the checkout can change while those reads are in flight. It exists because `open` otherwise acts on whatever
  branch the invoking directory happens to be on, and a worktree has a
  different one per directory — which opened two pull requests for the wrong
  branch. The result payload names the branch acted on for the same reason.

  Why not the raw sequence: the required `review-gate` workflow derives the
  request from the driver's comment and its marker grammar; a driver that
  posts `@codex review` and moves on can have the provider review the correct
  head while the gate, evaluated before that review landed, stays red
  (autumngarage/touchstone#833). `open` therefore asks the gate to evaluate the
  exact head and confirms the coordinates still hold before reporting success.
  A behavior-v2 gate waits for the evidence itself; the client does not wait
  for that long-running workflow or start a competing attempt. The invisible
  marker additionally makes a retry after a timeout
  reuse the existing request instead of posting a second one. Where no pinned
  gate protects the base, `open` verifies the authenticated author's exact
  request comment and coordinates. It names an enforcement gap where one
  exists; a fully applied workflow-source policy instead states that
  exact-head review remains driver procedure.
- `status` is a read-only observation of state, URL, exact head, base ref/base
  SHA, draft state, GitHub's merge-state observation, whether GitHub's durable
  `autoMergeRequest` is armed, and the current `mergeQueueEntry.state`. Armed
  state includes its `enabledAt` timestamp and the live PR head that state
  belongs to. It also reports the
  newest exact-head CheckRun belonging to the effectively required
  `review-gate` workflow run: its id, status, conclusion, details URL, and
  bounded policy-owned title and summary, plus the owning workflow-run id,
  attempt, attempt-start timestamp, and CheckRun completion timestamp. The
  binding excludes same-named repository-local checks, requires
  the workflow run to name this pull request, and selects the job from the
  current run attempt so a superseded rerun cannot look green. The selected run's
  immutable GraphQL workflow file must also match the effective rule's source
  repository, path, and exact verified revision; a historical run from a replaced
  rule is reported as unbound rather than current. If the effective
  rules do not declare the central gate, status reports it as unconfigured and
  does not attribute historical same-named runs to policy. If GitHub reports
  no such CheckRun, `reviewGateCheck.present` is false; when a bound workflow run
  already exists, its current status remains visible. The adjacent
  `reviewGateBehaviorContractVersion` is the version verified at the effective
  exact pinned revision, or `null` when that live binding is not verified; PR
  clients use this field instead of inferring behavior from local policy bytes.
  If distinct runs share GitHub's newest second-resolution attempt-start
  timestamp, status reports the ambiguity and their run ids instead of
  inventing an order.

  The additive `reviewBudget` object combines a versioned PR-body record of
  finding-bearing local rounds and hosted rounds from replaced PRs with
  paginated current-PR review evidence. Current-PR hosted rounds are collapsed
  by requested head, so retries for one head count once; clean rounds and
  findings on an unrequested head do not spend the finding-bearing budget. The
  object reports the capability, local/hosted/total counts, same-shape rounds
  remaining from the three-round limit, exhaustion, the latest reviewed head,
  cascade state, and selected exit. An older PR with no record reports local
  totals and remaining rounds as `null` while still exposing its hosted count.
  A malformed or duplicate record fails explicitly.
  This is derived status plus the irreducible local-history input, not a second
  verdict: exhaustion selects a stop path, while exact-head review remains
  mandatory for the code that will merge.

  The additive `phase` field reduces those authoritative observations to one
  stable enum: `reviewing`, `fix-required`, `ready-to-queue`, `queued`,
  `merged`, or `action-required`. Its one-to-one `nextAction` values are
  `wait`, `address-review`, `queue`, `done`, and `inspect`; both `reviewing`
  and `queued` intentionally use `wait`. Human output prints the exact-head
  `touchstone pr merge PR --head SHA` command only for `ready-to-queue`, where
  that mutation is safe to attempt. No other phase invents a recovery command.

  Classification is deliberately small and fail closed. `MERGED` is terminal.
  Any non-open or draft PR is `action-required`. Effective enforcement is
  checked before queue state, so a queue entry never implies that review was
  authorized in a partially adopted repository. A known live queue state is
  `queued`; `UNMERGEABLE` or an unknown future queue state is
  `action-required`. An armed legacy auto-merge request is also `queued`
  because GitHub can land it without another local mutation. Conflicts,
  ambiguous or unbound gates, and incomplete policy bindings are
  `action-required`. After that, only the policy-owned exact-head gate decides:
  active is `reviewing`, explicit `failure` is `fix-required`, and success that
  postdates the complete review surface is `ready-to-queue` only when GitHub
  reports the PR `CLEAN`. A blocked merge state, operational conclusion,
  missing completion timestamp, or later review activity is `action-required`,
  matching the merge command's existing fail-closed behavior.
  An absent gate with no active bound workflow is `action-required`, never
  guessed to be pending or passing.

  Status does not parse gate output or reviewer prose, recognize a reviewer,
  reconstruct auto-merge from local wait conditions, decide whether review is
  complete, request review, enqueue, retry, or wait for delivery. Queue
  position, ETA, and merge-group internals stay outside the versioned contract.
  Raw equivalent: `gh pr view --json
  number,state,url,headRefOid,baseRefName,baseRefOid,mergeStateStatus,isDraft`
  plus `autoMergeRequest { enabledAt }` and `mergeQueueEntry { state }` from
  GitHub's GraphQL API and
  `gh api repos/O/R/commits/HEAD/check-runs?check_name=review-gate&filter=all`
  plus the matching external workflow run and its current-attempt jobs, with
  exact-head and job-id filtering. The CheckRun endpoint belongs to the consumer
  commit, so this observation also works when the required workflow definition
  lives in the central policy repository.

  Why not the raw sequence: over the raw call it adds bounded retries and the
  versioned `touchstone.pr/v1` field names, so an agent parses one stable
  schema across all three operations instead of two.

  The failure it prevents is a driver trusting a local verdict over GitHub's.
  On 2026-08-18 the vendored merge gate in `henrymodisett/vesper` reported PR
  #888 as unmergeable — "resolved review thread(s) without a follow-up reply" —
  while `status` read `CLEAN` from GitHub with zero unresolved threads. That
  contrast is what identified the refusal as a local defect rather than a real
  one, and what made merging at the reviewed head an evidenced decision instead
  of a blind override. Without a cheap, schema-stable read of GitHub's own
  view, a driver facing a local gate that says no has two moves: stall, or
  bypass with no evidence. Both were taken on that PR before the read settled
  it.

  It remains the thinnest of the three, and deliberately so: its unique
  implementation is output formatting, and its read path is shared with
  `merge`. If it ever stops earning a public command, delete it.

- `merge` requires the caller's exact reviewed head, passes it through
  `--match-head-commit`, and re-reads state and head after the mutation. It
  accepts merged, queued, or auto-merge-enabled only while the reconciled head
  still equals the reviewed head. Where the base branch requires the pinned
  `review-gate` workflow, it requires the current policy-bound CheckRun to be
  complete and successful for that head before asking GitHub to merge. A
  pending, failed, absent, unbound, or ambiguous gate causes no merge or queue
  mutation. A green gate is also refused when any conversation comment, formal
  review, or inline review comment was created or edited at or after that gate
  completed; this prevents same-head feedback from arriving behind the
  verdict. Review is requested by `open` and refreshed by `answer`; `merge`
  never starts or waits for review. A review-gated policy without a merge
  queue is reported as partial and requires the explicit audited `--unguarded`
  path: only the merge group's fresh gate run makes review evidence atomic with
  admission. Raw equivalent: verify the policy-bound
  gate is successful and fresh for the exact head, then `gh pr merge --squash
  --match-head-commit SHA`, then re-read `state`, `headRefOid`, merge queue,
  and auto-merge state.

  Why not the raw sequence: `gh pr merge` exit codes lie in both directions —
  nonzero after a merge that actually succeeded, and zero having merely *armed*
  auto-merge while a check is still red (`principles/git-workflow.md`). The
  Touchstone command refuses that mutation until review is already green. A
  driver that trusts the exit code misreports the outcome either way, and the raw
  recovery is a four-part reconciliation that is easy to skip precisely when it
  matters. Binding the reviewed head to both the mutation and the reconciliation
  is one step here and two easily-forgotten flags there.

- `policy status` reads the base branch's effective rules once and reports
  `enforcement: applied | partial | none` with what is missing — the policy's
  pinned workflows or required source status, the merge queue where declared,
  the native pull-request, force-push, and deletion rules, and whether
  repository Actions are enabled at all — disabled Actions is reported first
  and forces `none`, since no required workflow can then run (AUT-467);
  `pr open` refuses up front in that state. Every observation names the policy
  path and immutable Touchstone revision it evaluated. `pr status` carries the
  same field for the PR's base; on a Touchstone policy-changing PR it evaluates
  policy bytes from the exact base SHA and reports a changed, renamed, or
  removed head policy only as post-merge intent. Raw equivalent: `gh api repos/O/R/actions/permissions --jq .enabled`,
  `gh api repos/O/R/rules/branches/<ref>`, `gh api repos/O/R --jq .allow_auto_merge`,
  and a reading of the workflows and rule types.
  Why not the raw sequence: on 2026-08-21 four fresh agents (two Claude, two
  Codex) each needed four API calls and a workflow comment to learn that
  nothing protected `main` on a consumer, and every one of them named this
  read as the single thing that would have raised their confidence. The
  steering says "inspect the repository's effective rules"; this is the
  inspection.
- `merge` takes its guarded path only when enforcement is `applied`;
  otherwise it **fails closed**. The terms: a *pinned gate* is the
  `review-gate` workflow required from the policy's source repository and ref,
  at the revision the tool's own policy carries
  (`policy/github/touchstone-main.json`) **or a descendant of it published on
  that ref**. The revision is a floor, not an identity: the policy file
  travels with the release while the ruleset is applied from a checkout that
  moves ahead of it, so demanding equality reported every repository pinned at
  a newer workflow revision as unguarded and blocked every merge until the
  next release (AUT-559). Lineage is read from the source repository — the
  repository resolved by the id the pin carries, its branch head as the
  ceiling — never assumed from the SHA. Provenance is necessary but not
  sufficient: the exact enforced revision must also carry the source manifest
  and declare the gate-behavior contract version the installed policy
  understands. A revision behind, diverged, off that branch, from another
  source, missing that behavior contract, or declaring an unsupported version
  is missing; a lineage or manifest that cannot be resolved is reported as
  unverified and stays closed.
  `applied` means the policy's pinned workflows or required source status and
  the native pull-request, force-push, and deletion rules are present, plus
  the merge queue where declared; `partial` and `none` name what is missing.
  The policy consulted is the repository's exact checked-in workflow-source or
  consumer policy where one exists (a private consumer derived `--no-queue`
  legitimately expects no queue), otherwise the canonical one. Source
  checkouts bind it to the commit containing those exact bytes; packaged tools
  bind it to their release tag. A remedy names that same revision so following
  it cannot silently apply a newer source policy than the verdict assessed.
  `applied` → refresh a completed declared gate or preserve its active
  behavior-v2 evaluation, then request the merge — with `--auto` where the
  policy carries no queue, since there is nothing to enter and GitHub refuses
  a plain merge while the gate is pending.
  Anything else → refuse with the remedy (apply the consumer policy, then
  close/reopen open PRs), or with `--unguarded` record on the PR — once per
  head, by marker — that an unguarded merge was requested and exactly what
  enforcement is missing (a partial policy may still carry the gate; other
  checks or reviews may still have run), then request the merge. A failed rules read is an operational error
  (exit 1), never a verdict. Rollout: repositories whose policy is not yet
  applied receive the refusal and its remedy; nothing merges differently
  where the policy is applied. Before this, `merge` on an unprotected
  repository was a push-and-merge button (vesper #928, 2026-08-21).

## Generated evidence

A generated PR body states only what its generator observed. A validation
row is filled for something the generator ran, or names GitHub's own check as
the witness; anything else is `n/a — <source>`. The `delivery-evidence` gate
checks the shape of the rows, so a generator that asserts "validation ran"
without running it passes the gate with a claim — the failure the rule
exists to prevent (vesper `ship-pr.sh`, 2026-08-21).
- `answer` replies to a review finding by its root comment ID, resolves its
  thread, and asks the pinned gate to evaluate the answer; a completed attempt
  is re-run, while an active behavior-v2 run observes the answer on its next
  poll and the client immediately returns control. If full policy status needs
  unavailable administration reads, `answer` reports that limitation and
  conservatively refreshes through the behavior-v1 path. Its
  `--all-resolved-check` form proves no thread remains. Exactly one
  disposition is required and is refused before any read or mutation:
  `--fix-commit SHA` appends "Fixed in SHA." only after GitHub resolves the
  revision and proves it is reachable from the captured PR head, and
  `--no-code-change` records that no commit was needed. The disposition is
  published in a versioned marker the gate verifies independently --
  `<!-- touchstone:review-answer v=1 id=FINDING_ID disposition=fixed fix=SHA -->`
  or `disposition=no-code-change` -- because prose claiming "fixed in SHA"
  once resolved a finding whose commit the evaluated head did not contain
  (AUT-800). Replies carry an invisible marker, so a rerun after a partial
  failure (reply posted, resolve failed) resolves the existing thread instead
  of posting again; `--fix-commit` on a rerun does not edit the earlier reply.
  A reply recorded before dispositions existed does not satisfy that check, so
  re-running `answer` with a disposition is how an already-open pull request
  records one. Raw equivalent:
  `gh api repos/O/R/pulls/N/comments/ID/replies -F body=@FILE`, the GraphQL
  `resolveReviewThread` mutation, and `gh api -X POST …/actions/runs/ID/rerun`.
  Why not the raw sequence: it is four calls with two ID systems (numeric
  comment IDs and `PRRT_` thread IDs), the reply is a mutation that must not
  be repeated after a timeout, and on 2026-08-21 three of four fresh agents
  hand-assembled it because the script that already did this was not
  reachable from the installed tool.

## Safety and recovery

All reads use bounded retries. Mutations are never blindly retried: their
surviving state is read first or immediately afterward, so a timeout after a
successful mutation does not create a second PR, review request, reply, or
other mutation. A moved head, unknown or changed review base, ambiguous
branch-to-PR mapping, GitHub rejection, or unverified final state fails closed
with a concrete remedy.

GitHub response data and diagnostics remain separate. Successful commands are
parsed from stdout alone; failed commands retain a bounded, sanitized
diagnostic. Debug output on stderr therefore cannot become a head, URL, or
repository identity. This is not hypothetical: review of PR #883 at commit
`6cb9b85` found successful `gh` reads becoming corrupt TSV and URL data when
stderr was merged into the parsed stream, and the same class was found across
the prepared read paths here.

Repository identity includes the canonical GitHub hostname as well as
`owner/repo`. PR, REST, and GraphQL operations retain that host, so verification
cannot drift from GitHub Enterprise to `github.com`.

Security-review quota notices are provisional observations, never trusted
review evidence and never a blocker. `open` leaves the request recorded and the
driver waits for exact-head review; `merge` delegates GitHub's complete verdict
while binding both the mutation and reconciliation to the reviewed head.

## Ownership boundary

The CLI owns four GitHub PR operations — exact-head review request, bounded
state observation, exact-head merge reconciliation, and answering a finding —
plus the branch enforcement read (`policy status`) they depend on. Each is justified above
against its raw equivalent, with the failure it prevents named. Any operation
added here needs the same record — the specific friction, and the failure a
driver hits without it — or it does not belong. Wrapping `gh` for symmetry is
how a sequencer becomes a second implementation of the layer beneath it. It does not
reconstruct review findings, conversation state, tracker state, or the merge
verdict. Drivers inspect GitHub's review surface directly and use
`touchstone pr answer` for inline reply-and-resolve semantics. Repository
rules and the required workflow remain authoritative.
