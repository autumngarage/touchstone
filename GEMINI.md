# Touchstone — Gemini CLI Instructions

<!-- touchstone:steering:start -->

<!-- Generated from TOUCHSTONE.md by scripts/render-steering.sh.
     Do not edit between the markers; edit TOUCHSTONE.md and re-run it.
     Content outside the markers is the project's own. -->
## Touchstone — Shared Agent Steering

You are an AI agent (Claude Code, Codex, or another driving CLI) working in a Touchstone-bootstrapped project. This block is the universal contract: rules that apply on every turn, plus a routing table to deeper docs you should consult when specific triggers fire. Project-specific guidance lives outside this block in your driver's steering doc (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`).

## Purpose

**Humans approve plans. Agents write and ship code. GitHub reviews code.**

That division is the entire product; everything Touchstone ships exists to hold one of those three lines in place. No human reads a diff as a merge precondition, so machines are the whole quality bar.

**GitHub's effective repository policy is the enforcement authority.** Where the Touchstone policy is installed and verified, the protected validation workflow and required `review-gate` workflow must pass, every finding must be answered, every thread must be resolved, and native rules reject direct and force pushes and branch deletion; emergency admin bypass is limited to pull requests, where GitHub records it. Local hooks are fast feedback, not the boundary. Do not infer adoption from this document: inspect the repository's effective rules — and a repository without that enforcement still does not authorize a direct push.

**Review is always required.** The AI reviewer reports `COMMENTED`, not `APPROVED`, so approval count does not represent it; `review-gate` binds trusted evidence and answers to the exact head. Where that gate is absent, exact-head review remains mandatory driver procedure — a rollout gap, not permission to skip it.

**A security-review quota notice is never a blocker.** It is provisional, not review evidence. Keep watching, then use bounded stalled-request recovery.

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
- **Every retained fix gets a test** — its CI regression test fails on the old code; a test never validates a fix-created regression.
- **Think in invariants** — name and assert at least one invariant for nontrivial logic.
- **One code path** — share business logic across modes; confine mode-specific differences to adapters, config, or the I/O boundary.
- **Version your data boundaries** — when a model/algorithm/source change affects decisions, version the boundary; don't aggregate across.
- **Separate behavior changes from tidying** — never mix functional changes with broad renames, formatting sweeps, or unrelated refactors.
- **Make irreversible actions recoverable** — destructive operations need dry-run, backup, idempotency, rollback, or forward-fix plan before they run.
- **Preserve compatibility at boundaries** — public API/config/schema/CLI/hook/template changes need a compatibility or migration plan.
- **Audit weak-point classes** — find a structural bug → audit the class + add a guardrail. Use the `touchstone-audit-weak-points` skill (Claude) or read `principles/audit-weak-points.md` (other drivers).
- **File-writing subagents** — use worktrees; remove one only after final result delivery or confirmed cancellation.
- **File tracked bugs** — open an item in the configured tracker when you find a bug, here or in an upstream tool. Don't silently work around it.
- **Keep review subordinate to scope** — review cannot amend approved scope. Implement only in-scope high-severity findings; route the rest. A review-fix defect stops patching: revert or simplify, then audit the class. A second ends same-shape work. Three rounds follow the capability across replacement PRs; closing or renaming never resets the budget.
- **Stop when the task is correct, not when review runs out of remarks** — deterministic gates first. Implement only high-severity findings; answer and route the rest; never reopen the design space. **Exact-head review after a fix commit is never skipped**, but it never authorizes mutation past a stop. Details live in `principles/git-workflow.md`.

## Never commit on the default branch

Before the first edit of a tracked file in a session, run `git branch --show-current`. If it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<slug>` where `<type>` is `feat | fix | chore | refactor | docs`. Your unstaged changes carry over — there's no cost to switching now and a real cost to discovering at commit time. Recovery steps when it happens anyway live in `principles/git-workflow.md`.

## Required Delivery Workflow

Drive this lifecycle automatically; do not ask the user for permission at each step.

1. **Pull.** `git pull --rebase` on the default branch.
2. **Branch.** Before any edit that might become a commit.
3. **Claim tracked work before implementation.** GitHub: `touchstone tracker claim <ref>` (race-safe, verified by re-read). Linear: the adapter has no transport — assign yourself through the Linear MCP and re-read the assignee before editing. Claim every item in a bundle so two agents do not ship competing fixes; an unavailable transport is unverifiable, never success.
4. **Change + commit.** Stage explicit files. Normal: run `touchstone review check`, then `touchstone review run`; failure is a waiver, not permission for default-profile fallback. One concern per commit. Run `git show --stat --oneline HEAD`; unchanged `HEAD`: do not ship.
5. **Local review evidence.** Serious: run `codex review --base <default>` before push. Either tier records `codex on <target>: <n> findings, <disposition>` in the PR body's `- Local review:` row. Normal may waive for a failed profile check/pass or Codex unavailability; serious may waive only when Codex is unavailable. `delivery-evidence` refuses a missing, malformed, or unexplained row.
6. **Reconcile tracked work.** Before opening the PR, list every tracker item found, claimed, fixed, partially fixed, or made stale. Fixed items get the configured closing reference in the PR body; partial or stale items get a tracker note explaining the evidence or remaining gap. Do not leave shipped work stale silently.
7. **Ship.** `git push -u origin HEAD`, then `touchstone pr open --expect-branch <branch> --title "<type>: <what>" --body-file <file>` — the installed CLI is the sequencer everywhere: it creates or reuses the PR, posts the review request, and confirms the exact head and base binding (re-running any declared gate). Put the configured closing reference (`Closes #123` or `Fixes AUT-123`) in the **PR body**, not only a commit. Re-run it for a later head (idempotent). **Never put the sequencer's marker in a comment you write yourself** — it reads that as a request for other coordinates and refuses to repair anything. A bare `@codex review` from a collaborator is valid only in recovery — bounded stalled-request recovery, or the CLI-absent raw sequence (`gh pr create`, the bare comment, then re-run any declared gate) — never the instruction.
8. **Answer every piece of PR feedback before merging.** Answering is not implementing; classify by scope *and severity*, then answer and route whatever you are not fixing. Stop widened work; allowed fixes follow the cascade and exact-head rules. Inspect GitHub's complete review surface, reply to each comment, and resolve every thread via `principles/git-workflow.md`; unresolved threads and `CHANGES_REQUESTED` block merge.
9. **Merge.** `touchstone pr merge <n> --head <reviewed-sha>` re-runs any policy-declared pinned gate and merges bound to that head (raw recovery: `gh pr merge <n> --squash --match-head-commit <sha>`). Confirm GitHub state regardless of exit code.
10. **Clean up before the session ends.** Remove everything this session created; leave sibling work untouched; make tracker terminal. `touchstone cleanup check` is repo-wide: resolve yours, route stale residue; its nonzero exit never authorizes deleting another session's work.

Raw commands remain portable recovery. A narrow project sequencer may call them, but GitHub owns verdict and state. `principles/git-workflow.md` carries the full sequence, including thread resolution.

Never push directly to the default branch, even in an emergency; rewriting your own unmerged branch is fine. Audited policy enforces PR-only bypass; elsewhere it stays mandatory. See `principles/git-workflow.md`.

## Routing table — read these when the trigger fires

| When you're about to... | Read |
|---|---|
| commit — pick the review tier, run its one local pass | `principles/local-review.md` |
| branch, open a PR, answer review, merge, recover from `no-commit-to-branch`, work with stacked PRs, or fan out worktrees | `principles/git-workflow.md` |
| understand the AI-authored change lifecycle or PR review loop architecture | `principles/ai-delivery-architecture.md` |
| start a non-trivial code change | `principles/pre-implementation-checklist.md` |
| understand the *why* of a daily-reminder rule | `principles/engineering-principles.md` |
| edit, write, or audit documentation | `principles/documentation-ownership.md` |
| coordinate parallel agents (subagents or worktrees) | `principles/agent-swarms.md` |
| audit a structural bug class after fixing one instance | `principles/audit-weak-points.md` |
| hit a bug in an upstream tool (don't silently work around it) | `principles/file-upstream-bugs.md` |
| write, trust, or audit agent memory — it is a cache, not truth | `principles/memory-hygiene.md` |

Claude Code agents: the bundled `touchstone-*` and `memory-audit` skills mirror this table in your session header; `touchstone steering install` keeps them current. Trust whichever surface fires first.
<!-- touchstone:steering:end -->

## Touchstone-Specific Product Guidance

Adoption must stay set-and-forget. Consumer repositories carry declarations
and narrow integration points, never copied Touchstone implementation. The
canonical boundary and anti-bloat admission test live in
`docs/product-contract.md`; they govern this repository, not consumer product
scope.

The shared steering above (agent roles, lifecycle, principles, routing table) is the universal contract — same content as Claude reads via `@TOUCHSTONE.md` in `CLAUDE.md` and Codex reads via the same managed block in `AGENTS.md`. Gemini CLI is a peer driving CLI; Claude Code and Codex are equivalent fallback drivers.

For deep references on specific topics, read `principles/*.md` files via the routing table in the block above. For project-specific authoring rules and the AI Review Guide, also read `AGENTS.md`.

## Delivery

In this source checkout, use `bash bin/touchstone pr open|status|merge|answer` for the
four bounded PR operations (`answer` replies to a finding and resolves its thread). Pass `--expect-branch <branch>` to `open` with the branch name written out:
it acts on whatever branch the invoking directory has checked out, which
differs per worktree. Never derive it from `$(git branch --show-current)` —
that reads the same checkout the command reads, so it agrees with a wrong
worktree and binds nothing. Their raw recovery equivalents and complete
lifecycle remain in `principles/git-workflow.md`.
