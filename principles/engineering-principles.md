# Engineering Principles (HARD REQUIREMENTS)

These are non-negotiable. Every code change must be reviewed against them; any exception must be explicit, justified, and disclosed in the PR.

## No band-aids
Fix the root cause. If a symptom patch is the safer scoped change, document the root cause, why the patch is appropriate, and what remains unfixed. A root-cause fix that widens approved scope needs a separate scope decision.

## Extend existing systems before inventing new ones
Before adding a system, search for the one that already owns the responsibility. Prefer extending and improving it over building a parallel mechanism. Reuse follows shared responsibility, not similar-looking code. A new system needs a concrete requirement the existing one cannot reasonably support; reuse does not authorize an unrelated migration.

## Choose the simplest design that meets the requirement
Build for demonstrated needs. Each abstraction, option, dependency, and layer must justify its complexity by helping satisfy the current requirement or making the system easier to understand or change. Prefer clear names and direct control flow. Simplicity means fewer concepts and interactions to understand, not the fewest lines; small duplication can be cheaper than coupling unrelated responsibilities.

## Keep interfaces narrow
Expose the smallest stable interface that lets callers do their job. Hide storage shape, vendor SDKs, and internal sequencing. Keep decisions separate from side effects: pass inputs explicitly and put filesystem, network, and clock access at clear boundaries. Each mutable state, resource, and background operation needs an explicit owner for its lifetime and cleanup; make ownership transfers explicit.

## Derive limits from domain; test at scale boundaries
Derive thresholds, sizes, limits, and allocations from input, configuration, or named domain constants. Hard-code a value only when it represents a real invariant, and document why. Test behavior at small, typical, and large scales.

## Derive, don't persist
Compute from the source of truth by default. Persist derived state only when recomputation is too slow, too expensive, or externally required. Document its source of truth, invalidation trigger, rebuild path, and reconciliation check in the same commit.

## No silent failures
Propagate failures or report them with enough context to diagnose them, without exposing secrets. No swallowed errors or success-shaped defaults that hide failure. Fallback behavior must report what failed, what was skipped, and what safety boundary still holds.

## Every retained fix gets a test
Retained bug fixes need a CI regression test that reproduces the failure: it must fail on the old code and pass on the new code. Test observable behavior, not implementation structure. A regression test does not justify retaining a review fix that created another defect; revert or simplify that fix before another mutation.

## Think in invariants
For nontrivial logic, name at least one invariant and assert it in a test or runtime boundary check. Make invalid states hard to represent: prefer explicit states and transitions over independent flags that permit contradictions, and validate external inputs at the boundary. Tests exercise an invariant over covered cases; they do not prove it for untested inputs.

## One code path
Share the same business rules across modes (test/prod, paper/live, dev/staging). Confine mode-specific differences to adapters, configuration, or the I/O boundary. Similar-looking code with different responsibilities need not share an abstraction.

## Version your data boundaries
When a model, algorithm, or data source changes in a way that affects decisions, rankings, persisted state, metrics, or user-visible behavior, establish a boundary (cohort, epoch, version) and ensure every downstream consumer honors it. Reads that drive decisions must not blend data across the boundary; aggregating across it dilutes signal with noise from the old regime.

## Separate behavior changes from tidying
Keep functional changes separate from broad renames, formatting sweeps, dependency churn, and unrelated refactors. Separate commits or PRs make the behavior change easier to review, bisect, and revert.

## Make irreversible actions recoverable
Before a destructive or one-way operation, define how failure leaves a known recoverable state. Use appropriate safeguards: dry run, backup, idempotency, rollback, or forward-fix plan. Account for partial completion and retries; a successful run alone does not establish recoverability.

## Preserve compatibility at boundaries
Changes to public APIs, config files, schemas, CLIs, hooks, templates, and generated artifacts need a compatibility or migration plan. Account for downstream consumers that may lag during rollout.

## Audit weak-point classes
When you find a structural bug, search for other instances and add a guardrail against recurrence. Follow [audit-weak-points.md](audit-weak-points.md) for bounded scope, prioritization, and follow-up.
