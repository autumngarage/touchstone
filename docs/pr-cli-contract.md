# PR CLI Contract

This document owns the narrow `touchstone pr` boundary. It sequences GitHub's
existing pull-request operations; GitHub remains the enforcement authority.
Every operation has a raw `gh` equivalent so installing Touchstone is never a
precondition for recovery.

## Interface

```text
touchstone pr open --title TITLE --body-file FILE [--base BRANCH] [--issue ITEM]
touchstone pr status PR
touchstone pr findings PR
touchstone pr respond PR --comment-id ID --body-file FILE [--fix-commit SHA]
touchstone pr merge PR [--head SHA] [--issue ITEM]
```

Every command accepts `--project DIR` and `--json`. JSON has schema
`touchstone.pr/v1`; adding fields is compatible, while changing field meaning
requires a new schema. Exit 0 means the reported state was verified, exit 1 is
an operational or transport failure, exit 2 is invalid or unsafe input, and
exit 3 means a tracker action remains externally unverifiable. A merge can
therefore be verified while the command exits 3: reconcile the configured
tracker, then rerun. No command runs a daemon, stores credentials, or persists
derived PR state.

## Operations and raw equivalents

- `open` proves the local and remote branch heads match, validates tracker
  reference grammar without claiming reconciliation, reuses an existing
  open PR for that branch or runs `gh pr create`, re-reads GitHub after the
  mutation, and posts `@codex review` once for the exact head. Its invisible
  comment marker and the server-side `touchstone/review-request-v1` status make
  partial reruns idempotent. Raw equivalent: compare `git rev-parse HEAD` with
  `git ls-remote`, inspect `gh pr list`, create with `gh pr create`, re-read,
  then inspect comments/status before `gh pr comment --body "@codex review"`.
- `status` is a read-only observation of state, URL, exact head, base ref/base
  SHA, draft state, and GitHub's merge-state observation. Raw equivalent:
  `gh pr view --json number,state,url,headRefOid,baseRefName,baseRefOid,mergeStateStatus,isDraft`.
- `findings` paginates both inline review threads through GraphQL and body-only
  formal reviews through REST. It reports resolved state and stable IDs needed
  by `respond`. Raw equivalent: paginated `gh api graphql` review-thread reads
  plus `gh api --paginate repos/OWNER/REPO/pulls/PR/reviews`.
- `respond` delegates to `scripts/respond-review.sh`, preserving the single
  reply, resolve, and fresh verification path. Raw equivalent: that script's
  documented invocation.
- `merge` binds `--match-head-commit` to the live (and optionally caller-
  expected) head, asks GitHub to merge, and always re-reads actual PR state.
  Only after that authoritative read does it reconcile tracker state.
  It does not reconstruct the ruleset, review, or conversation verdict before
  the mutation; GitHub alone decides whether the merge is allowed. Raw
  equivalent: `gh pr merge --squash --match-head-commit SHA`, then
  `gh pr view --json state,url`.

## Safety and recovery

All reads use bounded retries. Mutations are never blindly retried: their
surviving state is read first or immediately afterward, so a timeout after a
successful mutation does not create a second PR, review request, reply, or
merge. A moved head, unknown or changed review base, tracker mismatch,
ambiguous branch-to-PR mapping, GitHub rejection, or unverified final state
fails closed with a concrete remedy.

Repository identity includes the canonical GitHub hostname as well as
`owner/repo`. PR, REST, and GraphQL operations retain that host, so verification
cannot drift from GitHub Enterprise to `github.com`.

Security-review quota notices are provisional observations, never trusted
review evidence and never a blocker. `open` leaves the request recorded and the
driver waits for exact-head review; `merge` delegates the complete verdict to
GitHub.

## Ownership boundary

The CLI owns sequencing, stable output, retry limits, idempotency checks, and
post-mutation verification. The tracker adapter owns closing-reference syntax.
`respond-review.sh` owns reply-and-resolve semantics. Repository rules and the
required workflow own the merge verdict. This command neither reconstructs
those rules nor treats a local inference as permission to merge.
