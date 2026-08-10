# Cut the backlog to what is extremely important, and stop patching text-matching guards

**Date:** 2026-08-10
**Type:** decision
**Trigger:** T1.1
**Cites:** journal/2026-08-09-capability-registry-decision.md

> The backlog went 47 → 7 against an explicit importance bar; PR #706 was closed unmerged after six review rounds because patching a regex guard kept creating new holes, and that work folds into #507.

## Context

Two days of work on Touchstone's own delivery machinery, driven by one question: what is actually worth building?

The backlog had 47 open issues, most of them real defects, accumulated from a period when the product was building recovery automation it has since removed (PR #697, the worker engine). The operator's direction was explicit: build only extremely important things, cancel everything else.

## What we decided

**1. The bar, and what survived it.** 47 → 7. Seventeen issues closed on 2026-08-09 (four verified fixed, thirteen off-mission or from dead eras); twenty-seven cancelled on 2026-08-10 under an explicit "cancelled scope" rationale recorded on each. Four issues survived: **#640** (the merge gate authorized itself on ~30% of this repo's PRs), **#694** (the 2.13.0 cuts, 1 of 6 landed), **#507** (the 1,965-line disclosure hook), **#702** (dead surface the registry exposed).

Several cancelled issues describe live, reproducible defects. They were cancelled anyway. That is what a hard bar means, and the comments say so rather than implying the issues were wrong.

**2. #593 was reopened.** It had been auto-closed by a `Closes` trailer that survived a revert inside its own PR (#680, commit 5 of 8). The fix never shipped; the bug was live. Nothing re-checks that a closing trailer still describes the merged tree. That class has no issue yet.

**3. PR #706 closed unmerged — the significant decision.** Six review rounds on `hooks/branch-guard.sh`, sixteen findings, all legitimate. Rounds 3, 4, 5 and 6 each contained defects created by the previous round's fix.

The mechanism: every normalization added to catch a new token spelling (encoded newlines, tabs, continuations, empty quote pairs) created a new way for quoted data to be rewritten into an executable-looking line, which the segment walker then adopted as a `cd` or `-C` redirect. **Detection and fabrication grow together.** Round 6 also revealed the fast path had been dead since round 5 — every payload contains structural JSON quotes, so widening the test to any quote matched everything.

After six rounds the branch closed seven bypasses and opened three. It could not be shown strictly better than `main`, which is not a merge candidate for the file enforcing the product's central rule.

The corpus (nine reproduced bypasses, five fabrication vectors) and a coherent design are recorded on #634. The design's load-bearing idea, which all six rounds missed: **any normalization ⇒ distrust every redirect**, making fabrication and bypass-granting mutually exclusive instead of chasing carriers.

**4. `main` keeps seven live bypasses until #507.** Stated plainly rather than minimized: an agent's multi-line Bash block can still commit on the default branch. Judged the lesser cost against merging three fresh unreviewed holes into a guard every downstream project vendors.

## Consequences / action items

- [x] Backlog cut to 7; every closure carries its rationale
- [x] #593 reopened with evidence
- [x] PR #706 closed; corpus + design preserved on #634
- [x] #507 given an executable spec: grammar, decision rules, non-goals, acceptance criteria
- [ ] **#507 is the next work, and it should take `branch-guard.sh` with it** — same principle, two hooks, both corpora
- [ ] #694: five cuts outstanding; 2.13.0 claims ~44% smaller and delivered ~12%
- [ ] No issue tracks the reverted-fix-closed-the-issue class from #593
- [ ] 22 worktrees and 56 unmerged local branches have accumulated; not addressed

## Honest note on execution

This session produced two branch mix-ups, one verification pass that was invalid (an untracked file restored with `git checkout`, so perturbations accumulated and every guard "passed" for the wrong reason), three self-inflicted P1s on #706, and one bug found only by self-audit — a refuse path that printed "Blocked" and then exited 0 under the emergency override.

Recorded because the decisions above were made partly *from* that error rate. A high error rate on a security-critical file is itself evidence for rewriting rather than patching it, and for not attempting that rewrite at the end of a long session.
