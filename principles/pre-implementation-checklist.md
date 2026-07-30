# Pre-Implementation Checklist

Before writing code, walk through these questions. If any answer exposes duplicated infrastructure, a symptom patch, a second code path, or unclear ownership, stop and discuss scope before continuing.

This checklist is a pre-flight prompt; the canonical rules live in [engineering-principles.md](engineering-principles.md).

## 1. Am I adding to or patching local infrastructure that shared infrastructure should own?

Search the project's existing shared layers (utilities, base classes, common modules) before writing or extending anything local. If a subsystem hand-rolls something the shared layer already provides, the fix is migration — not more hand-rolling. A patch on hand-rolled code deepens the debt; migration eliminates it.

## 2. Am I fixing the root cause or the symptom?

See **No band-aids** in the engineering principles. If this is a symptom patch, the PR must say so explicitly and name the root cause. Patching a symptom is sometimes the right call (time pressure, scope, risk) — but it must be a conscious, documented choice, not an accident.

## 3. Will this create a second code path?

See **One code path** in the engineering principles. If you must add a divergence, can you delete the old path in the same PR? If not, document the owner, the removal condition, and a follow-up issue before merging. Two code paths that do "almost the same thing" are a maintenance trap — they drift apart silently and bugs in one don't surface until production.

## 4. Am I changing a public or persisted boundary?

If this touches a public API, config file, schema, CLI flag, hook, template,
generated artifact, or persisted/managed state, see **Preserve compatibility
at boundaries** in the engineering principles. Downstream consumers may lag —
the PR must include a compatibility or migration plan before merging.

When removing or replacing any subsystem that owns persisted or managed state,
including an internal-only store, cache, or metadata subsystem, record a
migration-state matrix in a pre-edit planning artifact such as the
implementation plan, issue, or task brief. Replace "legacy" and "canonical"
with the concrete boundary names. Before the first PR review request, the PR
body must copy or link the matrix, and every applicable row must have a focused
regression fixture.

| Starting state | Required outcome and invariant | Focused regression fixture |
|---|---|---|
| Absent / fresh | Preserve intentional absence unless a documented invariant requires canonical state; never activate an optional replacement by default. | Bootstrap and update with the subsystem never configured or explicitly disabled. |
| Legacy only | Preserve supported user intent while migrating, or stop with actionable recovery guidance. | Derive fixtures from every distinct legacy layout in the supported upgrade range. |
| Canonical only | Leave valid canonical state unchanged; reruns are idempotent. | Seed non-default valid canonical state and assert it is preserved; separately rerun install, init, or update. |
| Both / partially migrated | For completed coexistence, apply one documented precedence rule or fail closed. For interrupted partial state, resume, roll back, or forward-recover without losing intent. | Use separate fixtures for matching/conflicting completed state and failure after a partial canonical write, then verify recovery. |
| Invalid / dirty overlap | Make no partial boundary change; report the exact repair or takeover path. | Exercise malformed input and dirty managed files. |

Also cover retired CLI entry points and generated artifacts when they belong to
the removed subsystem. Classify every retained legacy path as either **active compatibility**
with supported behavior and tests, or an **inert, time-bounded migration shim**
that cannot invoke retired behavior and names its removal condition. Do not
leave an unclassified compatibility path.

## 5. Is this action reversible?

If this deletes, migrates, rewrites history, or has external side effects, see **Make irreversible actions recoverable**. The PR must describe how failure leaves the system in a known recoverable state — dry run, backup, idempotency key, rollback, or forward-fix plan.
