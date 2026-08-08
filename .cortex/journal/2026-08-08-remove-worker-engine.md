# Remove the worker engine: keep what constrains the agent, cut what serves it

**Date:** 2026-08-08
**Type:** decision
**Trigger:** T1.4
**Cites:** GitHub issue #694, GitHub issue #692, GitHub issue #693, GitHub issue #698, GitHub PR #697

> Touchstone's scope test is whether a capability constrains the agent or
> merely serves it. The worker engine served the agent, so it is removed —
> 5,860 lines, no gate weakened.

## Context

Touchstone had documents describing what it does but none stating what it is
*for* in a way that could exclude anything. Every capability passed the only
available test — "is this useful?" — so a starter kit for AI-assisted projects
accumulated a process supervisor (detached ships, takeover, PID tracking), a
bounded auto-rebase recovery engine, and an autonomous review-fix loop.

The 2026-08-08 session produced the evidence that settled it. Three mechanisms
— the emergency guard's command classifier, the force-push twin fingerprint,
and superseded-cancellation correlation — each consumed three to six review
rounds and ended in a revert (#675, #692, #693). All three share a root cause:
a shell heuristic approximating something a real parser knows exactly. The
worker engine produced roughly fifteen issues in one night.

Meanwhile every failure the engine existed to automate — base races, review
timeouts, reviewer-quota stalls, transient API errors — was resolved by hand
with "rebase, re-ship" at no cost, dozens of times in the same session.

## Decision

Adopt an explicit scope filter in the steering block:

> Does it constrain the agent, or does it merely serve the agent?

Constraints and the evidence that makes them checkable stay. Conveniences that
automate what an agent can already do for itself are out of scope: the agent
is the recovery mechanism, and automating its recovery buys a saved command in
exchange for destructive autonomous behaviour (force-push, rebase,
auto-commit). The worker engine was the only subsystem taking such action, and
it existed solely for agent comfort.

Removed: `scripts/worker.sh`, `lib/worker-ship-job.sh`, `lib/worker-review-fix.sh`,
`lib/worker-state.sh`, `tests/test-worker.sh`, the `touchstone worker` command,
its auto-update special cases, and its manifest and preflight-scope entries.
Downstream copies are retired on update so no stale engine survives the change.

Replacement: `bash scripts/open-pr.sh --auto-merge`; on failure, fix the named
cause and run it again.

## Consequences

- `touchstone worker` is a removed public command; the 2.13.0 notes carry the
  migration.
- The delivery workflow in the steering block is now reviewer-agnostic: ship,
  answer every piece of PR feedback and resolve the thread, clean up. That
  wording no longer assumes a particular review vendor, which is the same
  correction #698 applies to the merge gate itself.
- No gate is weakened: branch-guard, preflight, exact-head review, claim
  verification, and the merge gate are untouched. The fast tier passes.
- Alternative rejected: keep the engine and continue patching its heuristics.
  Three reverts in one session showed that path does not converge, and the
  code it protects is the only code that force-pushes.
