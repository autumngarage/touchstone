## Touchstone — Shared Agent Steering

You are an AI agent (Claude Code, Codex, or another driving CLI) working in a Touchstone-bootstrapped project. This block is the universal contract: rules that apply on every turn, plus a routing table to deeper docs you should consult when specific triggers fire. Project-specific guidance lives outside this block in your driver's steering doc (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`).

## Purpose

**Humans approve plans. Agents write and ship code. GitHub reviews code.**

That division is the entire product; everything Touchstone ships exists to hold one of those three lines in place. No human reads a diff as a merge precondition, so machines are the whole quality bar.

**GitHub's effective repository policy is the enforcement authority.** Where the Touchstone policy has been installed and verified, the protected validation workflow and required `review-binding` check must pass, every finding must be answered, every thread must be resolved, and native rules reject direct and force pushes and branch deletion. Do not infer adoption from this document: inspect the repository's effective rules.

**Review is always required.** The configured AI reviewer reports `COMMENTED`, not `APPROVED`, so approval count does not represent it. Where `review-binding` is required, GitHub binds trusted review evidence and answers to the exact head. Until that gate is installed and verified, exact-head review remains mandatory driver procedure and the missing enforcement is a rollout gap, not permission to skip it.

**A security-review quota notice is never a blocker.** It is provisional, not review evidence. Keep watching, then use bounded stalled-request recovery.

Local hooks are fast feedback; configured GitHub policy is the real boundary. An adopted policy limits emergency admin bypass to pull requests, where GitHub records it. A repository without that enforcement still does not authorize a driver to push directly.

To hold those lines, Touchstone does three things and nothing else:

1. **Constrain** — adopted GitHub policy blocks unsafe delivery; before adoption, the driver follows the same delivery contract and treats missing enforcement as a tracked gap.
2. **Make state legible** — what happened lives in git, PRs, and issues, verifiable without trusting your narration.
3. **Carry the contract** — the same rules reach every project and every agent, automatically.

Before adding anything here, name which of the three it serves; if you cannot, it does not belong. "Is it useful?" is not the test: **does it constrain the agent, or merely serve it?** Automating what you can already do (retrying a push, recovering a moved base) belongs in the project, not here: you are the recovery mechanism.

## Agent Roles And Fallbacks

- **Driving CLI** — Claude Code, Codex, or Gemini CLI. Owns file edits, git state, tests, commits, PR creation, PR comment triage, fix commits, approval tracking, and merge. Drivers are interchangeable; driver fallback is shared-contract fallback — if one is unavailable, another reads the same files and continues.
- **PR-visible reviewer** — GitHub-hosted review runs asynchronously against the exact pushed head. It reports findings on the PR; it never owns local files, git state, validation, or merge authority.

## Engineering principles (always in mind)

Non-negotiable. Every code change is reviewed against them. Full rationale lives in `principles/engineering-principles.md`.

- **No band-aids** — fix the root cause; if patching a symptom, say so explicitly and name the root cause.
- **Keep interfaces narrow** — expose the smallest stable contract; don't leak storage shape, vendor SDKs, or workflow sequencing.
- **Derive limits from domain** — thresholds and sizes come from input/config/named constants; test at small, typical, and large scales.
- **Derive, don't persist** — compute from the source of truth; persist derived state only with documented invalidation + rebuild path.
- **No silent failures** — every exception is re-raised or logged with debug context. No `except: pass`, no swallowed errors.
- **Every fix gets a test** — bug fix includes a regression test that runs in CI and fails on the old code.
- **Think in invariants** — name and assert at least one invariant for nontrivial logic.
- **One code path** — share business logic across modes; confine mode-specific differences to adapters, config, or the I/O boundary.
- **Version your data boundaries** — when a model/algorithm/source change affects decisions, version the boundary; don't aggregate across.
- **Separate behavior changes from tidying** — never mix functional changes with broad renames, formatting sweeps, or unrelated refactors.
- **Make irreversible actions recoverable** — destructive operations need dry-run, backup, idempotency, rollback, or forward-fix plan before they run.
- **Preserve compatibility at boundaries** — public API/config/schema/CLI/hook/template changes need a compatibility or migration plan.
- **Audit weak-point classes** — find a structural bug → audit the class + add a guardrail. Use the `touchstone-audit-weak-points` skill (Claude) or read `principles/audit-weak-points.md` (other drivers).
- **Isolate file-writing subagents** — parallel agents use dedicated worktrees and disjoint file ownership by default.
- **File tracked bugs** — open an item in the configured tracker when you find a bug, here or in an upstream tool. Don't silently work around it.
- **Keep review subordinate to scope** — review cannot amend approved scope. Implement only diff-created or in-scope defects; route the rest. Three finding-bearing rounds follow the capability across replacement PRs; closing or renaming never resets the budget.

## Never commit on the default branch

Before the first edit of a tracked file in a session, run `git branch --show-current`. If it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<slug>` where `<type>` is `feat | fix | chore | refactor | docs`. Your unstaged changes carry over — there's no cost to switching now and a real cost to discovering at commit time. Recovery steps when it happens anyway live in `principles/git-workflow.md`.

## Required Delivery Workflow

Drive this lifecycle automatically; do not ask the user for permission at each step.

1. **Pull.** `git pull --rebase` on the default branch.
2. **Branch.** Before any edit that might become a commit.
3. **Claim tracked work before implementation.** Use the configured tracker's race-safe claim before editing or dispatching an agent. Claim every item in a bundle so two agents do not ship competing fixes; an unavailable transport is unverifiable, never success.
4. **Change + commit.** Stage explicit file paths. Concise message. One concern per commit.
5. **Reconcile tracked work.** Before opening the PR, list every tracker item found, claimed, fixed, partially fixed, or made stale. Fixed items get the configured closing reference in the PR body; partial or stale items get a tracker note explaining the evidence or remaining gap. Do not leave shipped work stale silently.
6. **Ship.** `git push -u origin HEAD`, then `gh pr create`. Put the configured closing reference (`Closes #123` or `Fixes AUT-123`) in the **PR body**, not only a commit. Request review by commenting `@codex review` on the PR.
7. **Answer every piece of PR feedback before merging.** Answering is not implementing; classify against approved scope, then answer and route out-of-scope findings. Scope widening stops implementation and further review requests. Inspect GitHub's complete review surface, reply to each comment, and resolve every thread via `principles/git-workflow.md`; unresolved threads and `CHANGES_REQUESTED` block merge.
8. **Merge.** Use a project-documented executable merge boundary when present; otherwise run `gh pr merge <n> --squash --match-head-commit <sha>`. Always bind the reviewed head and confirm GitHub state, regardless of exit code.
9. **Clean up after merge.** Delete the local branch if it persists.

Raw commands remain portable recovery. A narrow project sequencer may call them, but GitHub owns verdict and state. `principles/git-workflow.md` carries the full sequence, including thread resolution.

Never use a direct default-branch push as an emergency path. Repositories with the audited policy enforce PR-only bypass; elsewhere this remains mandatory procedure until adoption. See `principles/git-workflow.md`.

## Routing table — read these when the trigger fires

| When you're about to... | Read |
|---|---|
| commit, branch, open a PR, run review, merge, recover from `no-commit-to-branch`, work with stacked PRs, or fan out worktrees | `principles/git-workflow.md` |
| understand the AI-authored change lifecycle or PR review loop architecture | `principles/ai-delivery-architecture.md` |
| start a non-trivial code change | `principles/pre-implementation-checklist.md` |
| understand the *why* of a daily-reminder rule | `principles/engineering-principles.md` |
| edit, write, or audit documentation | `principles/documentation-ownership.md` |
| coordinate parallel agents (subagents or worktrees) | `principles/agent-swarms.md` |
| audit a structural bug class after fixing one instance | `principles/audit-weak-points.md` |
| hit a bug in an upstream tool (don't silently work around it) | `principles/file-upstream-bugs.md` |
| write, trust, or audit agent memory — it is a cache, not truth | `principles/memory-hygiene.md` |

Claude Code agents: the bundled `touchstone-*` and `memory-audit` skills mirror this table in your session header. Trust whichever surface fires first.
