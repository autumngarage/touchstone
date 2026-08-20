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
touchstone pr merge PR --head SHA
```

Every command accepts `--project DIR` and `--json`. JSON has schema
`touchstone.pr/v1`; adding fields is compatible, while changing field meaning
requires a new schema. Exit 0 means the reported state was verified, exit 1 is
an operational or transport failure, and exit 2 is invalid or unsafe input. No
command runs a daemon, stores credentials, or persists derived PR state.

## Operations and raw equivalents

The strip's acceptance test was that a change ships end-to-end on bare `git`
and `gh`, and that whatever proves awkward specifies the CLI replacing them.
Each operation below records the awkwardness that justifies it. A reader who
doubts one can re-run that test on raw commands and compare, rather than
taking this document's word for it.

- `open` proves the local and remote branch heads match, reuses an existing
  open PR for that branch or runs `gh pr create`, re-reads GitHub after the
  mutation, and posts `@codex review` once for the exact head. Its invisible
  comment marker and the server-side `touchstone/review-request-v1` status make
  partial reruns idempotent. It reports success only after the status binds the
  request comment and a fresh PR read still matches the head and base. Raw
  equivalent: compare `git rev-parse HEAD` with
  `git ls-remote`, inspect `gh pr list`, create with `gh pr create`, re-read,
  then inspect comments/status before `gh pr comment --body "@codex review"`.

  `--expect-branch` binds the caller's intent to the branch the resolved
  project actually has checked out, the way `merge --head` binds the reviewed
  commit. It is optional and checked twice: once up front, so a mismatch is
  refused before GitHub is consulted at all, and again where the branch is
  selected, because the checkout can change while those reads are in flight. It exists because `open` otherwise acts on whatever
  branch the invoking directory happens to be on, and a worktree has a
  different one per directory — which opened two pull requests for the wrong
  branch. The result payload names the branch acted on for the same reason.

  Why not the raw sequence: the required `review-binding` check writes its
  marker only for a request comment matching its exact grammar, so a driver
  that posts `@codex review` and moves on can have the provider review the
  correct head while the check stays red and no marker is ever written
  (autumngarage/touchstone#833). Reporting success before the binding is
  confirmed is therefore reporting success for a merge that cannot happen. The
  invisible marker additionally makes a retry after a timeout reuse the
  existing request instead of posting a second one.

- `status` is a read-only observation of state, URL, exact head, base ref/base
  SHA, draft state, and GitHub's merge-state observation. Raw equivalent:
  `gh pr view --json number,state,url,headRefOid,baseRefName,baseRefOid,mergeStateStatus,isDraft`.

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
  `review-gate` workflow, it first asks that gate to re-evaluate the evidence
  present now (a required workflow cannot see a review that lands after the
  request) and then asks GitHub to merge; auto-merge arms while the run is
  pending and the queue admits the PR when it passes — the verdict stays
  GitHub's. Raw equivalent: `gh api -X POST
  repos/O/R/actions/runs/ID/rerun` on the gate's run for the head, then
  `gh pr merge --squash --match-head-commit SHA`, then re-read `state`,
  `headRefOid`, merge queue, and auto-merge state.

  Why not the raw sequence: `gh pr merge` exit codes lie in both directions —
  nonzero after a merge that actually succeeded, and zero having merely *armed*
  auto-merge while a check is still red (`principles/git-workflow.md`). A driver
  that trusts the exit code misreports the outcome either way, and the raw
  recovery is a four-part reconciliation that is easy to skip precisely when it
  matters. Binding the reviewed head to both the mutation and the reconciliation
  is one step here and two easily-forgotten flags there.

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

The CLI owns three GitHub PR operations: exact-head review request, bounded
state observation, and exact-head merge reconciliation. Each is justified above
against its raw equivalent, with the failure it prevents named. Any operation
added here needs the same record — the specific friction, and the failure a
driver hits without it — or it does not belong. Wrapping `gh` for symmetry is
how a sequencer becomes a second implementation of the layer beneath it. It does not
reconstruct review findings, conversation state, tracker state, or the merge
verdict. Drivers inspect GitHub's review surface directly and use
`scripts/respond-review.sh` for inline reply-and-resolve semantics. Repository
rules and the required workflow remain authoritative.
