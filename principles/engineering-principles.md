# Engineering Principles

Use these principles to choose a design, not to generate a checklist in every reply. Start from the requested outcome and existing code. Explain material tradeoffs; keep routine reasoning internal. Delivery authorization and review policy live in [git-workflow.md](git-workflow.md).

## No band-aids
Fix the root cause. If a symptom patch is the safer scoped change, document the root cause, why the patch is appropriate, and what remains unfixed. A root-cause fix that widens approved scope needs a separate scope decision.

## Extend existing systems before inventing new ones
Before adding a system, search for the one that already owns the responsibility. Prefer extending and improving it over building a parallel mechanism. Reuse follows shared responsibility, not similar-looking code. A new system needs a concrete requirement the existing one cannot reasonably support; reuse does not authorize an unrelated migration.

Before implementing, trace the existing owner and its callers. Prefer deleting unnecessary work, extending that owner, or using an existing dependency or standard library over introducing a new mechanism. Similar code is not proof of shared responsibility. Reviewers apply the same test and name a concrete consequence, not a design preference.

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
During iteration, write the smallest reproducer or test that resolves the current uncertainty. Defer broad scaffolding and unrelated coverage. Complete required regression evidence before shipping; [Exploration and shipping](local-review.md#exploration-and-shipping) owns delivery timing.

Retained bug fixes need CI regression evidence that fails on the old code and passes on the new code. Reuse an already-failing check or extend an existing case before adding a test, file, fixture, or harness. Test observable behavior, not implementation structure. A regression test does not justify retaining a review fix that created another defect; revert or simplify that fix before another mutation.

Each added test must catch a distinct plausible defect. Use the smallest responsible layer and fixture; explain why a subprocess, compiler, browser, database, or full-system setup is necessary. Keep integration coverage for real boundary behavior, not repetitions of lower-layer assertions. Derive expected results from the requirement, never by copying the implementation. Prefer behavior assertions over private call order or source spelling unless that structure is itself a supported contract.

Test count and coverage percentage are not goals. Trivial changes with no behavior change use applicable existing checks. Before pruning, identify the retained owner of each assertion and verify equivalent defect detection; consistent passing alone is not redundancy. Separate assertion failures from compilation, resource exhaustion, and infrastructure failures. Measure compilation and execution separately before claiming savings.

## Think in invariants
For nontrivial logic, name at least one invariant and assert it in a test or runtime boundary check. Make invalid states hard to represent: prefer explicit states and transitions over independent flags that permit contradictions, and validate external inputs at the boundary. Tests exercise an invariant over covered cases; they do not prove it for untested inputs.

## One code path
Share the same business rules across modes (test/prod, paper/live, dev/staging). Confine mode-specific differences to adapters, configuration, or the I/O boundary. Similar-looking code with different responsibilities need not share an abstraction.

## Version your data boundaries
Version changes to meaning, compatibility, or interpretation at the boundary consumers use. Preserve provenance so results remain attributable. Do not silently combine incompatible regimes; intentional cross-version comparisons or aggregation are valid when their semantics are comparable and explicit. An ordinary data refresh does not require a new architecture or migration by itself.

## Separate behavior changes from tidying
Keep functional changes separate from broad renames, formatting sweeps, dependency churn, and unrelated refactors. Separate commits or PRs make the behavior change easier to review, bisect, and revert.

## Leave no residue
Code describes the system as it is. A comment states what the code cannot: a constraint, an invariant, an external quirk, the reason for a non-obvious choice. It does not narrate how the code got here, such as an incident story, a date, "previously", or "no longer"; commits, pull requests, and decision records hold that history, and `git blame` reaches them. Keep an issue or decision reference only when it names the constraint a reader must respect.

Retiring a feature, tool, role, client, or dependency is complete only when its code, tests, comments, configuration, suppression directives, and steering references are gone, in the same change or in a tracked follow-up whose done-evidence is an empty search for its name. Code that only its own tests call is dead; delete it with those tests. Prefer a cheap automated check (unused exports, unused imports, unreferenced symbols) over review to keep this true.

## Make irreversible actions recoverable
Before a destructive or one-way operation, define how failure leaves a known recoverable state. Use appropriate safeguards: dry run, backup, idempotency, rollback, or forward-fix plan. Account for partial completion and retries; a successful run alone does not establish recoverability.

## Preserve compatibility at boundaries
Changes to public APIs, config files, schemas, CLIs, hooks, templates, and generated artifacts need a compatibility or migration plan. Account for downstream consumers that may lag during rollout.

## Audit weak-point classes
When you find a structural bug, search the relevant callers and sibling paths. Reuse regression coverage; add a broader guardrail only when recurrence and reliable detection justify it. Follow [audit-weak-points.md](audit-weak-points.md) for bounded scope, prioritization, and follow-up.
