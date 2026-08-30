# Touchstone — AI Agent Instructions

This file steers Codex and other AGENTS.md-native coding agents. Claude Code reads `CLAUDE.md`; Gemini CLI reads `GEMINI.md`. Keep these files aligned when project-level workflow changes. When you are coding, follow the authoring guidance first. When you are explicitly reviewing a PR or running the AI review hook, use the review guide below.

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
- **File tracked bugs** — file bugs found here or upstream in the configured tracker; don't silently work around them.
- **Checkpoint scope expansion before editing** — a follow-up approves doing the work, not bundling it. Route independent additions pre-edit; file count alone never decides.
- **Keep review subordinate to scope** — review cannot amend approved scope; fix only in-scope high-severity findings. A review-fix defect stops patching. A second ends same-shape work. Three rounds follow the capability across replacement PRs; closing or renaming never resets the budget.
- **Stop when the task is correct** — deterministic gates first. Implement only high-severity findings; route the rest; never reopen the design space. **Exact-head review after a fix commit is never skipped** and never authorizes mutation past a stop. See `principles/git-workflow.md`.

## Never commit on the default branch

Before the first edit of a tracked file in a session, run `git branch --show-current`. If it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<slug>` where `<type>` is `feat | fix | chore | refactor | docs`. Your unstaged changes carry over — there's no cost to switching now and a real cost to discovering at commit time. Recovery steps when it happens anyway live in `principles/git-workflow.md`.

## Required Delivery Workflow

Drive this lifecycle automatically; do not ask the user for permission at each step.

1. **Pull.** `git pull --rebase` on the default branch.
2. **Branch.** Before any edit that might become a commit.
3. **Claim tracked work before implementation.** GitHub: `touchstone tracker claim <ref>` (race-safe, verified by re-read). Linear: the adapter has no transport — assign yourself through the Linear MCP and re-read the assignee before editing. Claim every item in a bundle so two agents do not ship competing fixes; an unavailable transport is unverifiable, never success.
4. **Change + commit.** Stage explicit files. Normal: `touchstone review check`, then `touchstone review run`; failure is a waiver, never fallback. Run at most one tier-required local AI pass per coherent unit, none for trivial work, and never rerun to confirm fixes. One concern per commit. Run `git show --stat --oneline HEAD`; unchanged `HEAD`: do not ship.
5. **Local review handoff.** Serious: `codex review --base <default>` once pre-push and may waive only when Codex is unavailable. Put a pass or reasoned waiver in `- Local review:`. Rerun deterministic checks after fixes; push. Hosted review owns every pushed exact head; never confirm locally.
6. **Reconcile tracked work.** Before opening the PR, list every tracker item found, claimed, fixed, partially fixed, or made stale. Fixed items get the configured closing reference in the PR body; partial or stale items get a tracker note explaining the evidence or remaining gap. Do not leave shipped work stale silently.
7. **Ship.** `git push -u origin HEAD`, then `touchstone pr open --expect-branch <branch> --title "<type>: <what>" --body-file <file>` — the installed CLI is the sequencer everywhere: it creates or reuses the PR, posts the review request, and confirms the exact head and base binding (re-running any declared gate). Put the configured closing reference (`Closes #123` or `Fixes AUT-123`) in the **PR body**, not only a commit. Re-run it for a later head (idempotent). **Never put the sequencer's marker in a comment you write yourself** — it reads that as a request for other coordinates and refuses to repair anything. A bare `@codex review` from a collaborator is valid only in recovery — bounded stalled-request recovery, or the CLI-absent raw sequence (`gh pr create`, the bare comment, then re-run any declared gate) — never the instruction.
8. **Answer every piece of PR feedback before merging.** Answering is not implementing; classify by scope *and severity*, then answer and route whatever you are not fixing. Stop widened work; allowed fixes follow the cascade and exact-head rules. Inspect GitHub's complete review surface, reply to each comment, and resolve every thread via `principles/git-workflow.md`; unresolved threads and `CHANGES_REQUESTED` block merge.
9. **Merge.** With exact-head success, `touchstone pr merge <n> --head <reviewed-sha>`. An exact-head queue entry ends mutation; never dequeue, re-enqueue, or probe admin merge. Raw recovery: re-read the queue; only if absent and the gate is fresh, run `gh pr merge <n> --squash --match-head-commit <sha>`. Confirm state.
10. **Clean up before the session ends.** Remove everything this session created; leave sibling work untouched; make tracker terminal. `touchstone cleanup check` is repo-wide: resolve yours, route stale residue; its nonzero exit never authorizes deleting another session's work.

Raw commands are portable recovery; GitHub owns verdict and state. `principles/git-workflow.md` carries the full sequence, including thread resolution.

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
- Ship with `git push -u origin HEAD`, then use `bash bin/touchstone pr open` with the reviewed title and body, and `--expect-branch <the branch you created in step 2>` — write the name out, never `$(git branch --show-current)`, which reads the same checkout the command does and so agrees with a wrong worktree; merge with `bash bin/touchstone pr merge <n> --head <reviewed-sha>`. The source commands sequence GitHub and verify surviving state; `principles/git-workflow.md` carries their raw recovery equivalents.
- The PR is the review surface. Do not treat PR creation as completion: answer every piece of PR feedback and resolve its thread — whoever left it — before merging.
- File-writing subagents use isolated worktrees by default. Follow `principles/agent-swarms.md`; use `git worktree add` and `git worktree remove` for setup and teardown.

### Touchstone-Specific Rules

- **A rule must live at the layer that can enforce it.** GitHub enforces, prose instructs, scripts observe and sequence. Nothing lives at two layers at once. Re-deciding locally what GitHub decides at the merge button is the specific mistake that grew this repo to 49,000 lines.
- **Adoption must stay set-and-forget.** Consumer repositories carry declarations and narrow integration points, never copied Touchstone implementation. An adopted repository remains valid without routine rewrites; evolution is backward-compatible or an explicit reviewable upgrade. `docs/product-contract.md` is the canonical boundary.
- **Delete by default.** The burden of proof is on keeping. A change earns its way in when a real failure demanded it, not because a review round suggested it.
- **Portfolio scope is checked-in data.** Before adding an adoption detector, commit the supported repository shapes and real generated artifacts that justify it. An absent or ambiguous shape uses the manual plan; it does not earn a speculative parser.
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
├── hooks/          # branch-guard.sh — PreToolUse hook wired in .claude/settings.json
├── scripts/        # claim-issue, respond-review, touchstone-run
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
