# PR CLI Contract

This document owns the narrow `touchstone pr` boundary. It sequences GitHub's
existing pull-request operations; GitHub remains the enforcement authority.
Every operation has a raw `gh` equivalent so installing Touchstone is never a
precondition for recovery.

## Interface

```text
touchstone pr open --title TITLE --body-file FILE [--base BRANCH]
touchstone pr status PR
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
  partial reruns idempotent. It reports success only after the status binds the
  request comment and a fresh PR read still matches the head and base. Raw
  equivalent: compare `git rev-parse HEAD` with
  `git ls-remote`, inspect `gh pr list`, create with `gh pr create`, re-read,
  then inspect comments/status before `gh pr comment --body "@codex review"`.
- `status` is a read-only observation of state, URL, exact head, base ref/base
  SHA, draft state, and GitHub's merge-state observation. Raw equivalent:
  `gh pr view --json number,state,url,headRefOid,baseRefName,baseRefOid,mergeStateStatus,isDraft`.
- `merge` requires the caller's exact reviewed head, passes it through
  `--match-head-commit`, and re-reads state and head after the mutation. It
  accepts merged, queued, or auto-merge-enabled only while the reconciled head
  still equals the reviewed head. Raw equivalent: `gh pr merge --squash
  --match-head-commit SHA`, then re-read `state`, `headRefOid`, merge queue, and
  auto-merge state.

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
repository identity.

Repository identity includes the canonical GitHub hostname as well as
`owner/repo`. PR, REST, and GraphQL operations retain that host, so verification
cannot drift from GitHub Enterprise to `github.com`.

Security-review quota notices are provisional observations, never trusted
review evidence and never a blocker. `open` leaves the request recorded and the
driver waits for exact-head review; `merge` delegates GitHub's complete verdict
while binding both the mutation and reconciliation to the reviewed head.

## Ownership boundary

The CLI owns three GitHub PR operations whose boundaries have concrete failure
evidence: exact-head review request, bounded state observation, and exact-head
merge reconciliation. It does not
reconstruct review findings, conversation state, tracker state, or the merge
verdict. Drivers inspect GitHub's review surface directly and use
`scripts/respond-review.sh` for inline reply-and-resolve semantics. Repository
rules and the required workflow remain authoritative.
