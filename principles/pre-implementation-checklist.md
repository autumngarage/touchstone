# Pre-Implementation Checklist

Before writing code, walk through these questions. If any answer exposes duplicated infrastructure, a symptom patch, a second code path, or unclear ownership, stop and discuss scope before continuing.

This checklist is a pre-flight prompt; the canonical rules live in [engineering-principles.md](engineering-principles.md).

## 1. Am I adding to or patching local infrastructure that shared infrastructure should own?

Search the project's existing shared layers (utilities, base classes, common modules) before writing or extending anything local. If a subsystem hand-rolls something the shared layer already provides, the fix is migration — not more hand-rolling. A patch on hand-rolled code deepens the debt; migration eliminates it.

## 2. Am I fixing the root cause or the symptom?

See **No band-aids** in the engineering principles. If this is a symptom patch, the PR must say so explicitly and name the root cause. Patching a symptom is sometimes the right call (time pressure, scope, risk) — but it must be a conscious, documented choice, not an accident.

## 3. Will this create a second code path?

See **One code path** in the engineering principles. If you must add a divergence, can you delete the old path in the same PR? If not, document the owner, the removal condition, and a follow-up issue before merging. Two code paths that do "almost the same thing" are a maintenance trap — they drift apart silently and bugs in one don't surface until production.

## 4. Am I changing a public boundary?

If this touches a public API, config file, schema, CLI flag, hook, template, or generated artifact, see **Preserve compatibility at boundaries** in the engineering principles. Downstream consumers may lag — the PR must include a compatibility or migration plan before merging.

## 5. Is this action reversible?

If this deletes, migrates, rewrites history, or has external side effects, see **Make irreversible actions recoverable**. The PR must describe how failure leaves the system in a known recoverable state — dry run, backup, idempotency key, rollback, or forward-fix plan.

## 6. Am I removing or replacing a subsystem with existing persisted or deployed state?

Removals look clean in a fresh checkout and break in the field, one starting state at a time — each edge case discovered by an external reviewer one head after another instead of enumerated up front. The gate fires on **any existing persisted or deployed state**, whoever owns it: user-visible config and artifacts, but equally system- or operator-owned state such as database schemas, queued work, cache contents, and internal checkpoints. Before the first review request, enumerate the observable starting states **derived from this subsystem's own persistence boundary** — its config files, generated artifacts, installed hooks and skills, CLI entry points, downstream copies, schemas, queues, and checkpoints. Do not work from a fixed global matrix; the states that matter are wherever *this* subsystem actually persists itself.

For each state you decide to support, write down:

- the **invariant** that must hold after the change;
- the **source of truth** that decides that state's outcome;
- the **fail-closed behavior** when an input matches no supported state — an explicit error naming the replacement, never silence;
- a **regression fixture** exercising that state, landed before the first review request — not added one reviewer round at a time.

The fail-closed fallback is itself a state to verify: include a dedicated fixture that presents an unmatched or unsupported persisted-state combination and asserts the explicit error, so the safeguard is exercised rather than assumed.

Distinguish **active compatibility** (behavior the new code keeps indefinitely) from **inert, time-bounded migration shims** (warn-and-rewrite paths with a named removal version or condition). The distinction sets lifetime expectations — it exempts nothing: every executable compatibility shim is a temporary second code path and carries all of question 3's controls (named owner, removal condition, follow-up issue) until it is deleted. A named expiry bounds the drift window; it does not remove the drift.

A bounded example, removing a config-file-backed subsystem: fresh project (no config → defaults, doctor clean); current project (modern config → behavior unchanged); legacy-only (retired file → migrate or fail closed with the migration command); mixed (both files → named precedence); retired CLI flags and subcommands (explicit error naming the replacement); stale downstream copies (update path reconciles or refuses loudly). Your subsystem's boundary decides which of these exist and which additional ones do.
