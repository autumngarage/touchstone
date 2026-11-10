# Pre-Implementation Decisions

Resolve these questions from the repository before editing a non-trivial change. Keep routine answers internal; record decisions that affect scope, compatibility, or recovery. Proceed within existing authorization. Ask only when missing intent, unapproved scope, or material irreversible risk prevents a sound decision. A justified scoped patch or planned migration is not automatically a reason to stop.

The canonical design guidance is [engineering-principles.md](engineering-principles.md). **Choose the simplest design that meets the requirement**; avoid turning the questions below into new machinery.

## 1. What existing system owns this responsibility?

Trace its implementation, callers, tests, and recorded decisions. Extend that owner before creating another system. Prefer a standard library or existing dependency over a custom implementation. Reuse follows responsibility, not similar syntax; a new owner needs a concrete unmet requirement.

## 2. What outcome and invariant must change?

Name the observable before/after behavior and the invariant to preserve. Reproduce a bug at the smallest useful boundary before fixing it. A scoped symptom patch may be safer than a broad root-cause migration: explain why and track the unresolved cause.

## 3. What is the smallest complete delivery unit?

Keep one independently acceptable outcome together, including callers and required generated artifacts. Multiple test scenarios do not imply multiple PRs. Split independent behavior or unrelated tidying, not an atomic migration. Temporary parallel implementations need an owner, removal condition, and tracked remainder.

## 4. Which boundaries can break?

Inspect only the boundaries this change reaches: external input, public APIs, configuration, persisted data, authorization, resource lifetime, and deployed consumers. Preserve ownership and validation at the existing boundary. Name unsupported inputs and report failures explicitly; do not invent fallback success.

## 5. How will correctness be demonstrated?

Choose the smallest test that catches the actual defect; reuse existing fixtures. For external formats, use authoritative implementations or captured real artifacts rather than teaching a fake the same assumptions as the implementation. Cover meaningful ordinary, invalid, and boundary cases. Record what was not checked. Follow [local-review.md](local-review.md) for delivery evidence and review disposition.

## When migrating or replacing persisted/deployed behavior

Derive supported starting states from the actual persistence and deployment boundary, including mixed versions where rollout permits them. For each materially different state, identify the invariant, source of truth, migration or explicit refusal, and regression evidence. Test partial completion and recovery; preserve recoverable data. Include an unsupported-state case when that state can occur. Keep compatibility shims owned and give temporary shims a removal condition.

## When translating external declarations into actions

Define the supported input domains from a versioned specification or reproducible inventory. Inspect effective inputs, including inherited configuration and symlinks where relevant. Unknown formats take an explicit unsupported/manual path. Prove generated actions with a focused execution check when static inspection is insufficient; do not claim execution from source inspection alone. If independent domains keep expanding the design, split or narrow scope before adding more branches.
