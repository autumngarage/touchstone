Review only the staged diff against the stated intent and invariants.

Report at most 3 high-confidence, actionable defects introduced by this
change. Prioritize crashes, incorrect behavior, data loss, security issues,
broken contracts, unsafe lifetimes, concurrency failures, compatibility
breaks, and meaningful performance regressions.

For every finding: cite the exact file and code path, explain the concrete
failure scenario, propose the minimal local fix.

Do not report style, naming, formatting, comments, refactors, cleanup,
architecture proposals, pre-existing issues, speculative concerns, or
anything outside the stated scope.

If no high-confidence issue exists, say:
"No high-confidence defects introduced by this diff."
