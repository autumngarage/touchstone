# Cut the backlog to what is extremely important, and stop patching text-matching guards

**Date:** 2026-08-10
**Type:** decision
**Trigger:** T2.1
**Cites:** PR #703 (capability registry), PR #706 (closed unmerged), issue #634, issue #507

> The backlog was cut to a handful of issues against an explicit importance bar; PR #706 was closed unmerged after six review rounds because patching a regex guard kept creating new holes, and that work folds into #507.

## Context

Two days of work on Touchstone's own delivery machinery, driven by one question: what is actually worth building?

The backlog stood at **47 open issues**, most describing real defects, accumulated from a period when the product was still building recovery automation it has since removed (PR #697, the worker engine). The operator's direction was explicit: build only extremely important things, cancel everything else.

## What we decided

**1. The bar, and what survived it.** The backlog went from **47 open at the start of 2026-08-09 to 7 at the end of 2026-08-10**.

Both numbers were **observed directly** at the time — `gh issue list --state open | wc -l` at the start of 2026-08-09 and at the end of 2026-08-10. They are point-in-time counts, not the result of arithmetic, and this entry does not claim they can be re-derived.

That distinction is deliberate, and three rounds of review on this paragraph are what established it. Reconstructing the transition after the fact would require netting closures, reopenings, and creations while excluding pull requests from all three, against an events endpoint that mixes issues and PRs and reports current state rather than state-at-the-time. Every version of that query I wrote was wrong in a different direction — it omitted the reopened #593, or subtracted PR #706's closure from an issue count, or let an issue closed *after* the window stop contributing when rerun.

A reconstruction that is wrong in a new way each time it is written is not evidence. The observation is the evidence; `gh api repos/autumngarage/touchstone/issues/events` is where someone who wants the movement between the endpoints should start, with the warning that the naive query does not reconcile.

The surviving work: **#640** (the merge gate authorized itself on roughly a third of this repo's PRs), **#694** (the 2.13.0 cuts, 1 of 6 landed), **#507** (the 1,965-line disclosure hook), **#702** (dead surface the registry exposed).

Several cancelled issues describe live, reproducible defects. They were cancelled anyway. That is what a hard bar means, and each closure comment says so rather than implying the issue was wrong.

**2. #593 was reopened.** It had been auto-closed by a `Closes` trailer that survived a revert inside its own PR (#680, commit 5 of 8). The fix never shipped; the bug was live and read as resolved for two days. That class is now tracked as **#714**.

**3. PR #706 closed unmerged — the significant decision.** Six review rounds on `hooks/branch-guard.sh`, sixteen findings, all legitimate. Rounds 3, 4, 5 and 6 each contained defects created by the previous round's fix.

The mechanism: every normalization added to catch a new token spelling (encoded newlines, tabs, continuations, empty quote pairs) created a new way for quoted data to be rewritten into an executable-looking line, which the segment walker then adopted as a `cd` or `-C` redirect. **Detection and fabrication grow together.** Round 6 also revealed the fast path had been dead since round 5 — every payload contains structural JSON quotes, so widening the test to any quote matched everything.

After six rounds the branch closed seven bypasses and opened three. It could not be shown strictly better than `main`, which is not a merge candidate for the file enforcing the product's central rule.

The corpus (nine reproduced bypasses, five fabrication vectors) and a coherent design are recorded on **#634**. The design's load-bearing idea, which all six rounds missed: **any normalization ⇒ distrust every redirect**, making fabrication and bypass-granting mutually exclusive instead of chasing carriers.

**4. `main` keeps seven live bypasses until #507.** Stated plainly rather than minimized: an agent's multi-line Bash block can still commit on the default branch. Judged the lesser cost against merging three fresh unreviewed holes into a guard every downstream project vendors.

**5. A guard that was never running.** Separately, both PreToolUse hooks were wired with relative paths. Claude Code runs hooks in the cwd at event time, so off-root the path missed, bash exited 127, and Claude Code treats any non-2 exit as non-blocking — the tool call proceeded. All five registered projects and this repo were affected: not a bypass in a guard, but a guard that never ran. Fixed in #711, tracked as **#709**, and patched in place in all five projects the same day.

## Consequences / action items

- [x] Backlog cut to 7; every closure carries its rationale
- [x] #593 reopened with evidence; the trailer class filed as #714
- [x] PR #706 closed; corpus and design preserved on #634
- [x] #507 given an executable spec: grammar, decision rules, non-goals, acceptance criteria
- [x] #709 filed and fixed; all five projects patched in place
- [ ] **#507 is the next work, and it should take `branch-guard.sh` with it** — same principle, two hooks, both corpora
- [ ] #694: five cuts outstanding; 2.13.0 claims ~44% smaller and delivered ~12%
- [ ] 22 worktrees and 56 unmerged local branches have accumulated; not addressed

## Honest note on execution

This session produced two branch mix-ups (including a PR accidentally stacked on another), one verification pass that was invalid (an untracked file restored with `git checkout`, so perturbations accumulated and every guard "passed" for the wrong reason), three self-inflicted P1s on #706, one bug found only by self-audit — a refuse path that printed "Blocked" and then exited 0 under the emergency override — and three wrong dependency edges in the capability registry, each written from what looked related rather than from the call graph.

Recorded because the decisions above were made partly *from* that error rate. A high error rate on a security-critical file is itself evidence for rewriting rather than patching it, and for not attempting that rewrite at the end of a long session.
