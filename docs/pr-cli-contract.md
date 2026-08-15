# PR CLI Contract

This document owns the narrow `touchstone pr` boundary. It sequences GitHub's
existing pull-request operations; GitHub remains the enforcement authority.
Every operation has a raw `gh` equivalent so installing Touchstone is never a
precondition for recovery.

## Interface

```text
touchstone pr open --title TITLE --body-file FILE [--base BRANCH]
touchstone pr status PR
touchstone pr findings PR
touchstone pr respond PR --comment-id ID --body-file FILE [--fix-commit SHA]
touchstone pr merge PR --head SHA
```

Every command accepts `--project DIR` and `--json`. JSON has schema
`touchstone.pr/v1`; adding fields is compatible, while changing field meaning
requires a new schema. Exit 0 means the reported state was verified, exit 1 is
an operational or transport failure, and exit 2 is invalid or unsafe input. No
command runs a daemon, stores credentials, or persists derived PR state.

## Operations and raw equivalents

- `open` proves the local and remote branch heads match, reuses an existing
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
- `respond` delegates to `scripts/respond-review.sh`, passing the already
  resolved canonical repository and hostname while preserving the single
  reply, resolve, and fresh verification path. Raw equivalent: that script's
  documented invocation.
- `merge` requires the caller's exact reviewed head, binds
  `--match-head-commit` to it, asks GitHub to merge, and always re-reads actual
  PR state. A verified merge-queue entry or enabled auto-merge request is a
  successful queued result, distinct from an already completed merge.
  It does not reconstruct the ruleset, review, or conversation verdict before
  the mutation; GitHub alone decides whether the merge is allowed. Raw
  equivalent: `gh pr merge --squash --match-head-commit SHA`, then
  `gh pr view --json state,url`.

## Safety and recovery

All reads use bounded retries. Mutations are never blindly retried: their
surviving state is read first or immediately afterward, so a timeout after a
successful mutation does not create a second PR, review request, reply, or
merge. A moved head, unknown or changed review base, ambiguous branch-to-PR
mapping, GitHub rejection, or unverified final state fails closed with a
concrete remedy.

GitHub response data and diagnostics remain separate. Successful commands are
parsed from stdout alone; failed commands retain a bounded, sanitized
diagnostic. Debug output on stderr therefore cannot become a head, URL, or
repository identity.

Repository identity includes the canonical GitHub hostname as well as
`owner/repo`. PR, REST, and GraphQL operations retain that host, so verification
cannot drift from GitHub Enterprise to `github.com`.

Security-review quota notices are provisional observations, never trusted
review evidence and never a blocker. `open` leaves the request recorded and the
driver waits for exact-head review; `merge` delegates the complete verdict to
GitHub.

## Ownership boundary

The CLI owns GitHub PR sequencing, stable output, retry limits, idempotency
checks, and post-mutation verification. It does not parse tracker closing
language or mutate tracker state. Drivers reconcile delivered work through the
configured tracker API or CLI. `respond-review.sh` owns reply-and-resolve
semantics. Repository rules and the required workflow own the merge verdict.
This command neither reconstructs those rules nor treats a local inference as
permission to merge.
