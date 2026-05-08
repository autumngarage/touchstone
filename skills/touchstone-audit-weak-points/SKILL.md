---
name: audit-weak-points
description: Use after finding a structural bug to systematically audit the codebase for the same anti-pattern, fix instances by tier, and add a guardrail that catches the next one before it ships.
---

# Audit Weak Points

When you find a structural bug, the same pattern is almost certainly repeated elsewhere. The copies you don't find now will surface later — usually in a worse place.

## When to invoke

This skill activates when a bug points at a *class* of problem rather than a single instance:
- "stale data contamination" found in one cache → probably in others
- "hardcoded resource list instead of registry lookup" in one file → probably elsewhere
- "file-persisted state on a read-only filesystem" in one path → probably elsewhere
- "hardcoded absolute values instead of ratios"
- "silent exception swallowing" — same anti-pattern, different files

Don't invoke for one-off bugs (typos, narrow logic errors). Invoke when the fix you just wrote feels like it could apply to N other files.

## The methodology (six steps)

1. **Identify the pattern.** Name it precisely. Vague names produce vague audits. "Functions returning None on error without logging" is auditable; "error handling problems" is not.

2. **Search until the reviewed surface is explicit.** Use grep, AST tools, or an exploration agent. State what you searched (queries, tools, directories) and what you intentionally left out of scope. "Exhaustive" is unverifiable; "reviewed and bounded" is. The most dangerous instances are in code paths you weren't looking at — cast wide and make coverage legible.

3. **Produce a ranked punch-list.** Sort by *production impact*, not ease of fix. The instance that silently corrupts data in a hot path matters more than the one in a rarely-used utility.

4. **Fix in tiers, and track the tail.** Start with the highest-impact instances. Don't try to fix everything in one PR — large blast radius increases review and rollback risk. If you split across PRs, commit the ranked list somewhere durable (issue, ADR, follow-up task) so the lower-priority instances don't get abandoned. **Land the guardrail in the first PR** — it stops new copies while you work through the existing ones.

5. **Reset contaminated state where filtering doesn't work.** Some derived state (trained models, accumulated statistics, cached computations) can't be filtered to exclude pre-fix data — it has to be rebuilt from scratch. Identify these cases explicitly.

6. **Add a guardrail.** Write a test or lint rule that catches the next instance of the pattern before it ships. This is the step that turns a one-time fix into a permanent improvement. Options:
   - AST-based test that scans for the anti-pattern
   - Lint rule (custom or built-in)
   - Integration test exercising the failure mode
   - Import-time assertion validating an invariant

## Why this matters

Without the audit, you fix one bug and leave N copies alive. Without the guardrail, the pattern re-emerges next time someone writes similar code. The audit + guardrail combination is what turns bug-fixing from whack-a-mole into systematic improvement.

## Reference

Full rationale and worked examples: `principles/audit-weak-points.md` (the deeper "why" lives there; this skill is the activation handle).
