---
name: touchstone-pre-impl
description: Use before writing code on any non-trivial change — applies the 5-question pre-implementation gate (shared infra, root cause, code paths, public or persisted boundaries, reversibility).
---

# Pre-Implementation Checklist

Walk through these five questions before writing code. If any answer exposes duplicated infrastructure, a symptom patch, a second code path, or unclear ownership, stop and discuss scope before continuing.

## When to invoke

- About to write or modify code (any non-trivial change)
- User describes a new feature, refactor, or bug fix
- About to add a new module, class, function group, or workflow
- About to touch a public API, config schema, CLI flag, hook, or template
- About to replace a subsystem that owns persisted or managed state
- About to delete, migrate, or rewrite — actions that are hard to reverse

For the canonical version: read **`principles/pre-implementation-checklist.md`** now.

## The five questions

1. **Am I patching local infrastructure that shared infrastructure should own?**
   Search the project's existing utilities, base classes, and common modules first. Hand-rolling a thing the shared layer already provides deepens debt; migration eliminates it.

2. **Am I fixing the root cause or the symptom?**
   See "No band-aids." If you must patch a symptom, the PR must say so explicitly and name the root cause.

3. **Will this create a second code path?**
   See "One code path." If you must add a divergence, can you delete the old path in the same PR? If not, document the owner, the removal condition, and a follow-up issue before merging.

4. **Am I changing a public or persisted boundary?**
   API, config, schema, CLI flag, hook, template, generated artifact, or persisted/managed state. See "Preserve compatibility at boundaries" — needs a compatibility or migration plan before merge.
   For a subsystem removal or replacement, use the canonical migration-state
   matrix in `principles/pre-implementation-checklist.md`. Record it in a
   pre-edit planning artifact; put it in or link it from the PR body before
   review. Cover absent, every supported legacy layout, canonical-only,
   completed-both, interrupted-partial, and invalid starting states with
   focused fixtures before the first PR review request. Classify retained
   legacy paths as active compatibility or inert, time-bounded migration shims.

5. **Is this action reversible?**
   Deletes, migrations, history rewrites, external side effects. See "Make irreversible actions recoverable" — needs dry-run, backup, idempotency key, rollback plan, or forward-fix plan before it runs.

## When to stop and ask

Any "no" answer to a check is a stop signal. Discuss scope with the user before writing code, not after.
