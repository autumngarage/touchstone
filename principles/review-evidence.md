# Review Evidence Contract

This document owns Touchstone's durable GitHub evidence contract for
PR-triggered semantic review. The merge architecture and operator flow live in
[AI Delivery Architecture](ai-delivery-architecture.md).

## Invariant

A review result is portable across a later rebase only when GitHub evidence
binds it to the full reviewed commit, pull request, base revision, request
timestamp, result timestamp, and a trusted writer. A short commit prefix is
display text, not authorization evidence.

## Version 1 clean-result status

When the merge gate observes a trusted clean GitHub Codex result after a
durable exact-head request, it writes a commit status on the full reviewed SHA:

- context: `touchstone/review-result-clean`
- state: `success`
- description: `v=1 pr=<number> base=<full-sha> req=<utc> result=<utc>`

The commit that owns the status is the reviewed head. The description binds the
same observation to its PR, reviewed base, request-completion freshness anchor,
and reviewer-result timestamp. The merge gate records this status immediately
after accepting the clean signal, before deterministic preflight, so a later
stale-base or packaging failure cannot erase proof that the review completed.

The status is derived evidence. Its source of truth remains the trusted review
result plus `touchstone/review-request-complete`. A consumer must reject the
status when any of these checks fail:

- the status creator lacks repository write, maintain, or admin permission;
- the status is not attached to the full reviewed SHA;
- the version, PR number, base, or timestamps are missing or malformed;
- the request-completion status on that SHA does not match the PR, base, and
  request timestamp;
- the result does not occur after the request;
- another trusted result at the same or a later timestamp makes cleanliness
  ambiguous or false.

The status records a historical fact. It does not by itself authorize merging
a rewritten head, satisfy deterministic checks, reset a review budget, or make
a new head reviewed.

## Rebase recovery and compatibility

New Touchstone merge gates publish the version 1 status. Downstream projects
may lag that producer, so root-cause-reset consumers should accept two
fail-closed evidence shapes during rollout:

1. the version 1 status with its matching trusted request completion; or
2. a legacy trusted clean reviewer result whose short prefix resolves uniquely
   through a trusted full-SHA review-request marker and a matching trusted
   request-completion status.

Legacy reconstruction is only for a rewritten, exhausted epoch immediately
preceding a substantive root-cause-reset commit. Missing, mismatched,
untrusted, or colliding evidence remains an error. The reset commit must still
carry the project's reset trailer, change repository content, and receive the
first exact-head review of the new epoch.

Projects can remove the legacy reconstruction path after every review result
that may still participate in recovery was produced by a Touchstone version
that writes the version 1 status. Until then, consumers must use one shared
parser for delivery checks and review-request checks so the two gates cannot
disagree about the same evidence.
