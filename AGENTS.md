# Touchstone — AI Agent Instructions

This file steers Codex and other AGENTS.md-native coding agents. Claude Code reads `CLAUDE.md`; Gemini CLI reads `GEMINI.md`. Keep these files aligned when project-level workflow changes. When you are coding, follow the authoring guidance first. When you are explicitly reviewing a PR or running the AI review hook, use the review guide below.

<!-- touchstone:steering:start -->

<!-- This block is a hand-maintained copy of TOUCHSTONE.md. The renderer that
     generated it (lib/touchstone-block.sh) was deleted; edit TOUCHSTONE.md first,
     then mirror the change here. Edit content OUTSIDE the markers freely. -->

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
- **File issues for bugs** — open a GitHub issue when you find a bug, in this project or in an autumngarage tool. Don't silently work around it.
- **Bound review convergence** — three finding-bearing rounds follow the capability across replacement PRs; closing or renaming never resets the budget. After exhaustion, narrow scope or redesign before requesting review again; record recurring tool/reviewer drag upstream.

## Never commit on the default branch

Before the first edit of a tracked file in a session, run `git branch --show-current`. If it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<slug>` where `<type>` is `feat | fix | chore | refactor | docs`. Your unstaged changes carry over — there's no cost to switching now and a real cost to discovering at commit time. Recovery steps when it happens anyway live in `principles/git-workflow.md`.

## Required Delivery Workflow

Drive this lifecycle automatically; do not ask the user for permission at each step.

1. **Pull.** `git pull --rebase` on the default branch.
2. **Branch.** Before any edit that might become a commit.
3. **Claim issues before implementation.** If the work starts from a GitHub issue, claim it before editing or dispatching an agent: `bash scripts/claim-issue.sh <n>`. Claim every issue in a multi-issue bundle so two agents do not ship competing fixes.
4. **Change + commit.** Stage explicit file paths. Concise message. One concern per commit.
5. **Reconcile issues.** Before opening the PR, list every GitHub issue found, claimed, fixed, partially fixed, or made stale by the work. Fully fixed issues get closing trailers (`Closes-issue: #123` or `Closes #123`) so merge auto-closes them; partial/stale issues get a comment explaining the evidence or remaining gap. Do not leave fixed issues open silently.
6. **Ship.** `git push -u origin HEAD`, then `gh pr create`. Put the closing reference (`Closes #123`) in the **PR body** — squash-merge reads the body, not the commit. Request review by commenting `@codex review` on the PR.
7. **Answer every piece of PR feedback before merging.** Whoever reviews (hosted AI, bot, or colleague), reply to each comment and resolve the thread; unresolved threads and `CHANGES_REQUESTED` block the merge. `bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file>` replies and resolves in one step; `--all-resolved-check` proves none remain.
8. **Merge** with `gh pr merge <n> --squash --match-head-commit <sha>`, binding to the head the review actually saw. Its exit code lies in both directions — confirm against real state rather than trusting it.
9. **Clean up after merge.** Delete the local branch if it persists.

Every command above is the whole mechanism; there is no wrapper. `principles/git-workflow.md` carries the full sequence, including thread resolution.

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

<!-- touchstone:steering:end -->

## Authoring Guide

You are maintaining the standard baseline for a solo developer directing many agents across many projects. Touchstone ships two things, and both are the product: the guidance prompts an agent reads, and the small script surface that makes the agent use GitHub correctly. A bug here is a bug in how every project ships.

### Git Workflow

- Start each code change from a feature branch. Before editing tracked files, run `git branch --show-current`; if it reports `main` or `master`, branch with `git checkout -b <type>/<short-description>`.
- Claim every configured-tracker item before editing or dispatching an agent.
  Touchstone uses Linear: assign the `AUT-N` item through Linear's API/MCP and
  verify the surviving assignee. An unavailable transport is not verification.
- Keep changes logically grouped. Stage explicit file paths, commit with a concise message, and avoid unrelated refactors.
- Reconcile configured-tracker state before opening the PR. Touchstone fixes
  put `Fixes AUT-N` in the **PR body**; linked GitHub issues remain evidence, not
  a competing execution plan. A commit trailer alone does not survive every
  squash merge.
- Ship with `git push -u origin HEAD` then `gh pr create`; request review with `gh pr comment <n> --body "@codex review"`; merge with `gh pr merge <n> --squash --match-head-commit <reviewed-sha>`. There is no wrapper — `principles/git-workflow.md` carries the full sequence.
- The PR is the review surface. Do not treat PR creation as completion: answer every piece of PR feedback and resolve its thread — whoever left it — before merging.
- File-writing subagents use isolated worktrees by default. Follow `principles/agent-swarms.md`; use `git worktree add` and `git worktree remove` for setup and teardown.

### Touchstone-Specific Rules

- **A rule must live at the layer that can enforce it.** GitHub enforces, prose instructs, scripts observe and sequence. Nothing lives at two layers at once. Re-deciding locally what GitHub decides at the merge button is the specific mistake that grew this repo to 49,000 lines.
- **Adoption must stay set-and-forget.** Consumer repositories carry declarations and narrow integration points, never copied Touchstone implementation. An adopted repository remains valid without routine rewrites; evolution is backward-compatible or an explicit reviewable upgrade. `docs/product-contract.md` is the canonical boundary.
- **Delete by default.** The burden of proof is on keeping. A change earns its way in when a real failure demanded it, not because a review round suggested it.
- **Portfolio scope is checked-in data.** Before adding an adoption detector, commit the supported repository shapes and real generated artifacts that justify it. An absent or ambiguous shape uses the manual plan; it does not earn a speculative parser.
- Files in `templates/` are legacy transition inputs for the frozen downstream shape, not the future adoption contract. Nothing copies them today; do not extend their detection, setup, or vendored-runner model.
- Downstream projects are frozen on committed copies of the old scripts, deliberately. Do not try to fix them from here.
- All shell must stay portable to macOS. The base tool surface is `bash`, `git`, `gh`, `sed`, and `awk`; policy operations additionally use `jq`, which `setup.sh` installs and verifies.

### Testing

Before pushing, run:

```bash
for test in tests/test-*.sh; do
  echo "==> $test"
  bash "$test" || exit 1
done
```

The suite must stay deterministic, offline, and free of live model/provider quota. The protected workflow pinned by `policy/github/touchstone-main.json` runs the same loop as the required check and fetches nothing at all. Do not add a duplicate target-repository validation workflow — a required check that can go red because a package host had a bad minute is not a gate (#742, #803, #808).

Lint is not part of the test suite. It runs at pre-commit and via `pre-commit run --all-files`: `shellcheck`, `shfmt`, `markdownlint`, and `actionlint`.

### Architecture

```
touchstone/
├── TOUCHSTONE.md   # Canonical steering router — the universal contract
├── docs/           # Touchstone-specific product contract and project documentation
├── principles/     # The judgment layer, routed to from TOUCHSTONE.md
├── skills/         # User-scoped Claude Code skills
├── templates/      # Legacy transition inputs (nothing copies them today)
├── hooks/          # branch-guard.sh — PreToolUse hook wired in .claude/settings.json
├── scripts/        # claim-issue, issue-claim-check, respond-review, touchstone-run
├── audits/         # Dated drift/health reports (never auto-modified)
├── feedback/       # Dated dogfooding notes from downstream projects
└── tests/          # Self-tests
```

## Review Guide

You are reviewing pull requests for the **touchstone** repo — the baseline that governs how every project ships. A bug here becomes a bug everywhere.

---

## What to prioritize (in order)

1. **Layer violations.** Does the change re-implement something GitHub already decides — a merge condition, a review verdict, a branch rule? That is the mistake this repo exists to stop repeating. A script may observe and report what GitHub said; it may not adjudicate.
2. **Script portability.** All scripts must work on macOS (zsh default) with standard tools (`bash`, `git`, `gh`, `sed`, `awk`). No Linux-only flags, no GNU-specific extensions without fallbacks.
3. **Prose accuracy.** Steering docs must not name a file that does not exist, or describe a mechanism nothing implements. Prose that instructs an agent to run a deleted script is worse than no prose — the agent follows it and the failure looks like the agent's fault.
4. **Merge-gate integrity.** The required check must not gain a third-party network dependency. Head binding at merge (`--match-head-commit`) must not be dropped.
5. **Principle accuracy.** Changes to `principles/*.md` should reflect genuinely universal engineering standards. Project-specific advice doesn't belong here.

Style nits and theoretical refactors are **out of scope**.

---

## Specific review rules

### High-scrutiny paths

Files: `policy/github/touchstone-main.json`, `hooks/branch-guard.sh`, `scripts/respond-review.sh`, `TOUCHSTONE.md`

Flag any of the following:

- **A new dependency on the merge path.** The pinned external validation workflow must remain deterministic and offline. The target repository must not add a duplicate validation workflow.
- **Unpinned actions.** Every GitHub Action must be pinned to a full commit SHA, not a tag. Only a SHA is immutable.
- **Missing error handling.** Scripts use `set -euo pipefail`. Commands that can fail legitimately must be guarded explicitly, never silently.
- **Path assumptions.** Never assume the repo root is a specific directory. Derive paths from `$0` or `git rev-parse`.

### Self-tests

- Every behavioral change needs an assertion that fails on the old code.
- New assertions should join an existing test file rather than fragmenting into new ones.

---

## What NOT to flag

- Formatting, whitespace, import order.
- "You could refactor this for clarity" — only if the unclarity hides a bug.
- Missing comments on straightforward shell commands.
- Speculative future-proofing.
- **Arguing a deleted file back in.** A finding that says "you might need this" is not evidence. Deletions are recoverable from git history; the admission test is a real failure, not a hypothetical.

---

## Output format

1. **Summary** — what this PR does and your verdict.
2. **Blocking issues** — file:line, what's wrong, suggested fix.
3. **Non-blocking observations** — brief.
4. **Tests** — do the self-tests pass?

If there are zero blocking issues: "LGTM."
