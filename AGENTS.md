# Touchstone — AI Agent Instructions

This file steers Codex and other AGENTS.md-native coding agents. Claude Code reads `CLAUDE.md`; Gemini CLI reads `GEMINI.md`. Keep these files aligned when project-level workflow changes. When you are coding, follow the authoring guidance first. When you are explicitly reviewing a PR or running the AI review hook, use the review guide below.

<!-- touchstone:steering:start -->

<!-- This block is generated from TOUCHSTONE.md. `touchstone update` refreshes it.
     Edit content OUTSIDE the markers; touchstone will not touch project-owned content. -->

## Touchstone — Shared Agent Steering

You are an AI agent (Claude Code, Codex, or another driving CLI) working in a Touchstone-bootstrapped project. This block is the universal contract: rules that apply on every turn, plus a routing table to deeper docs you should consult when specific triggers fire. Project-specific guidance lives outside this block in your driver's steering doc (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`).

## Agent Roles And Fallbacks

- **Driving CLI** — Claude Code, Codex, or Gemini CLI. Owns file edits, git state, tests, commits, PR creation, PR comment triage, fix commits, approval tracking, and merge. Drivers are interchangeable; driver fallback is shared-contract fallback — if one is unavailable, another reads the same files and continues.
- **Conductor worker/reviewer router** — the model router used by the driving CLI for review and bounded model work. Conductor can route to Claude, Codex, Gemini, Kimi, Ollama, or other providers, and provider fallback runs across configured backends, but Conductor does not replace the driver's responsibility for the branch → PR → agentic review loop → approved merge workflow.

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
- **Isolate file-writing subagents** — parallel workers use dedicated worktrees, slice manifests, and disjoint file ownership by default.
- **File issues for bugs** — open a GitHub issue when you find a bug, in this project or in an autumngarage tool. Don't silently work around it.
- **Bound delivery loops** — define the smallest shippable concern, explicit non-goals, and a stop condition. Repeated structural findings or a new subsystem trigger freeze/split/replan, not indefinite same-PR fixes.
- **Escalate delivery friction upstream** — file actionable issues for tool-caused drag; don't normalize it.

## Never commit on the default branch

Before the first edit of a tracked file in a session, run `git branch --show-current`. If it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<slug>` where `<type>` is `feat | fix | chore | refactor | docs`. Your unstaged changes carry over — there's no cost to switching now and a real cost to discovering at commit time. Recovery steps when it happens anyway live in `principles/git-workflow.md`.

## Required Delivery Workflow

Drive this lifecycle automatically; do not ask the user for permission at each step.

1. **Pull.** `git pull --rebase` on the default branch.
2. **Branch.** Before any edit that might become a commit.
3. **Claim issues before implementation.** If the work starts from a GitHub issue, claim it before editing or dispatching an agent: `bash scripts/claim-issue.sh <n>`. Claim every issue in a multi-issue bundle so two agents do not ship competing fixes.
4. **Change + commit.** Stage explicit file paths. Concise message. One concern per commit.
5. **Reconcile issues.** Before opening the PR, list every GitHub issue found, claimed, fixed, partially fixed, or made stale by the work. Fully fixed issues get closing trailers (`Closes-issue: #123` or `Closes #123`) so merge auto-closes them; partial/stale issues get a comment explaining the evidence or remaining gap. Do not leave fixed issues open silently.
6. **Open PR + watch the review loop.** `bash scripts/open-pr.sh --auto-merge` pushes, opens or updates the PR, and drives shipping. Treat the PR as the review/check surface: watch comments/status, commit fixes for actionable feedback, rerun as needed, and merge only after required reviews/checks approve. The merge helper refuses to merge while GitHub reports requested changes or unresolved review threads. If no PR-visible agentic review is configured, continue with final verification instead of waiting.
7. **Clean up.** Delete the local branch if it persists.

Do not bypass the PR/review/merge path with a direct default-branch push except through the documented emergency path in `principles/git-workflow.md`.

## Memory hygiene

- Treat AI-agent memory as cached guidance, not canonical truth. Verify a remembered command, flag, path, or version against this repo before relying on it.
- Don't write memory for facts that are cheap to derive from `README.md`, the steering files, `VERSION`, `bin/touchstone --help`, or the scripts.
- If memory mentions a command, flag, file path, version, or workflow, include the date (`YYYY-MM-DD`) and the canonical source checked.
- If memory conflicts with the repo, follow the repo and propose updating the stale memory.

## Routing table — read these when the trigger fires

| When you're about to... | Read |
|---|---|
| commit, branch, open a PR, run review, merge, recover from `no-commit-to-branch`, work with stacked PRs, or fan out worktrees | `principles/git-workflow.md` |
| understand the AI-authored change lifecycle, PR review loop architecture, or where Conductor fits | `principles/ai-delivery-architecture.md` |
| start a non-trivial code change | `principles/pre-implementation-checklist.md` |
| understand the *why* of a daily-reminder rule | `principles/engineering-principles.md` |
| edit, write, or audit documentation | `principles/documentation-ownership.md` |
| coordinate parallel agents (subagents, worktrees, conductor swarm) | `principles/agent-swarms.md` |
| audit a structural bug class after fixing one instance | `principles/audit-weak-points.md` |
| hit a bug in an upstream tool (don't silently work around it) | `principles/file-upstream-bugs.md` |
| write a `.cortex/` artifact or see a Tier-1 trigger fire | `.cortex/protocol.md` |
| delegate to Conductor — pick a provider, write a brief, choose `--kind` / `--effort` | `~/.conductor/delegation-guidance.md` |

Claude Code agents: the Touchstone-bundled user-scoped skills (`touchstone-git-workflow`, `touchstone-pre-impl`, `cortex-protocol`, `conductor-delegation`, `touchstone-audit-weak-points`, `touchstone-agent-swarms`, `memory-audit`) provide the same routing surface as this table, with descriptions in your session header. Trust whichever surface fires first.

## Orientation

If `.cortex/state.md` exists in the project, read it at session start for the current state of in-flight work.

<!-- touchstone:steering:end -->

## Authoring Guide

You are maintaining a shared engineering platform that provides universal principles, reusable scripts, and a Conductor-backed AI review workflow for Henry's projects. Changes here propagate to downstream projects via `sync-all.sh`, so treat fixes here as platform changes, not isolated repo edits.

### Git Workflow

- Start each code change from a feature branch. Before editing tracked files, run `git branch --show-current`; if it reports `main` or `master`, branch with `git checkout -b <type>/<short-description>`.
- Claim every GitHub issue you are actively implementing with `bash scripts/claim-issue.sh <n>` before editing or dispatching an agent.
- Keep changes logically grouped. Stage explicit file paths, commit with a concise message, and avoid unrelated refactors.
- Reconcile issue state before opening the PR: fixed issues get closing trailers/PR body lines; partial or stale issues get an issue comment with evidence and remaining gaps.
- To ship a completed branch, run `bash scripts/open-pr.sh --auto-merge` to push and create or update the PR; then watch the review/check loop yourself, commit fixes for any actionable feedback, and continue until the PR is approved and merged.
- The PR is the review surface. Do not treat PR creation as completion; watch comments, checks, and requested changes until the PR is approved and merged.
- File-writing subagents use isolated worktrees by default. Follow `principles/agent-swarms.md` for slice manifests, file ownership, concurrency caps, and cleanup; use `scripts/spawn-worktree.sh` and `scripts/cleanup-worktrees.sh` for local setup and teardown.

### Touchstone-Specific Rules

- Files in `principles/`, `hooks/`, and `scripts/` are touchstone-owned and copied into downstream projects by `update-project.sh`.
- Files in `templates/` are copied once at bootstrap time and then project-owned; template changes affect new projects only.
- `bootstrap/new-project.sh`, `bootstrap/update-project.sh`, and `hooks/conductor-review.sh` are high-risk. `hooks/codex-review.sh` remains the legacy compatibility path. Preserve backup, clean-worktree, branch/commit, skip, and fail-open behavior.
- All shell must stay portable to macOS with standard tools: `bash`, `git`, `gh`, `sed`, and `awk`.

### Testing

Before pushing, run:

```bash
for test in tests/test-*.sh; do
  echo "==> $test"
  bash "$test" || exit 1
done
```

That is the fast default tier and must not spend live model/provider quota. Slow opt-in probes live under `tests/slow-*.sh`:

```bash
for test in tests/slow-*.sh; do
  echo "==> $test"
  bash "$test" || exit 1
done
```

Run the slow tier when changing live guidance-probe behavior or before release-level confidence checks. Fast tier is the "safe to push" gate; slow tier is the "safe to ship" gate.

For focused bootstrap/update changes, at minimum run `bash tests/test-bootstrap.sh` and `bash tests/test-update.sh`, then run the broader suite before shipping.

Lint is not part of the test suite. The full lint suite runs at pre-commit and via `pre-commit run --all-files`: `shellcheck`, `shfmt` for shell-script formatting, `markdownlint` for prose, and `actionlint` for `.github/workflows/`. `.pre-commit-config.yaml` and `.markdownlint.json` are the canonical config files; `actionlint` is repo-only and is not synced to downstream templates.

### Architecture

```
touchstone/
├── principles/     # Universal docs (touchstone-owned, synced to all projects)
├── templates/      # Starter files (copied once at bootstrap, then project-owned)
├── hooks/          # Reusable git hooks (touchstone-owned, synced as scripts/* in projects)
├── scripts/        # Helper scripts (touchstone-owned, synced)
├── bootstrap/      # new-project.sh, update-project.sh, sync-all.sh
├── bin/            # The `touchstone` CLI entry point (installed via brew or PATH)
├── lib/            # Shared bash modules sourced by bin/touchstone and bootstrap (release, install-hooks, ui, colors, auto-update, agents-principles-block, claude-md-principles-ref)
├── completions/    # Shell completion scripts for the touchstone CLI (bash, zsh)
├── audits/         # Dated drift/health reports produced by the touchstone-audit skill (never auto-modified)
├── feedback/       # Dated dogfooding bug reports and usage notes from downstream projects
├── prototypes/     # Throwaway design experiments (e.g. UI banners) — not shipped to projects
└── tests/          # Self-tests for bootstrap and update flows
```

### Key Helper Scripts

| File | Purpose |
|------|---------|
| `scripts/spawn-worktree.sh` | Create an isolated branch/worktree for parallel file-writing agent slices |
| `scripts/cleanup-worktrees.sh` | Dry-run-first cleanup for clean merged-or-equivalent worktrees |

## Review Guide

You are reviewing pull requests for the **touchstone** repo — a shared engineering platform whose files propagate to all downstream projects. A bug here becomes a bug everywhere.

---

## What to prioritize (in order)

1. **Bootstrap/update correctness.** `new-project.sh` and `update-project.sh` must never silently lose user data. For bootstrap, file overwrites without `.bak` backups are critical. For update, bypassing the clean-git branch/commit boundary, incorrect copy paths, or broken skip logic for project-owned files are critical bugs.
2. **Script portability.** All scripts must work on macOS (zsh default) with standard tools (`bash`, `git`, `gh`, `sed`, `awk`). No Linux-only flags, no GNU-specific extensions without fallbacks.
3. **Conductor hook safety.** `hooks/conductor-review.sh` runs during `git push` (`hooks/codex-review.sh` remains a legacy compatibility entry point). A bug here can block or silently skip all pushes. The fail-open design (graceful skip on errors) must be preserved. **AI review is advisory** — it does not replace deterministic checks (lint, tests, type checking). The hook fails open by default (`on_error=fail-open`): infra errors (timeout, missing provider, malformed output, reviewer crash) allow the push rather than blocking it. Each fail-open event emits a visible `[fail-open:<code>]` line to stderr and writes a structured entry to `~/.touchstone-review-log`; taxonomy codes include `FAIL_OPEN_TIMEOUT`, `FAIL_OPEN_PARSE_ERROR`, `FAIL_OPEN_DEPENDENCY_MISSING`, `FAIL_OPEN_PROVIDER_UNAVAILABLE`, and `FAIL_OPEN_REVIEWER_ERROR`. The trade-off is explicit: a Conductor outage during a critical week will not block pushes, but the AI safety net will be visibly absent rather than silently bypassed.
4. **Config parsing correctness.** The TOML parser in the Conductor review hook is minimal — it handles simple key=value and single-line arrays. Changes must not break on edge cases (quoted strings, comments, empty arrays).
5. **Principle accuracy.** Changes to `principles/*.md` should reflect genuinely universal engineering standards. Project-specific advice doesn't belong here.
6. **Template quality.** `templates/` should have clear `{{PLACEHOLDER}}` markers and be immediately useful after bootstrap. No placeholder that requires understanding Touchstone's internals to fill in.

Style nits and theoretical refactors are **out of scope**.

---

## Specific review rules

### High-scrutiny paths

Files: `bootstrap/new-project.sh`, `bootstrap/update-project.sh`, `hooks/conductor-review.sh`, `hooks/codex-review.sh`

Flag any of the following:

- **Silent overwrites.** `new-project.sh` may overwrite touchstone-owned files only through `copy_file_force`, which backs up existing content as `.bak`. `update-project.sh` must not create `.bak` files; instead it must require a clean git worktree, create a `chore/touchstone-*` branch, and commit the update as the review/recovery boundary. Project-owned files (CLAUDE.md, AGENTS.md, .touchstone-review.toml, legacy .codex-review.toml) must use `copy_file` (skip if exists) and must not be auto-updated.
- **Missing error handling.** The bootstrap scripts use `set -euo pipefail`. New commands that can fail legitimately (network calls, optional tools) must be guarded with `|| true` or `set +e`.
- **Path assumptions.** Never assume repo root is `~/Repos/touchstone`. Always derive paths from `$0` or `git rev-parse`.
- **Registry corruption.** `~/.touchstone-projects` is append-only during bootstrap. Changes must not truncate it or write duplicate entries.

### Codex hook

- The three final-marker contract (CLEAN/FIXED/BLOCKED) is the API boundary. Any change to marker handling must be backwards-compatible.
- The hook must never block a push due to its own infrastructure failure (network, missing tool, parse error). It must block *only* on actual code review findings.
- `.touchstone-review.toml` and legacy `.codex-review.toml` parsing must handle missing keys gracefully (use defaults).

### Self-tests

- Every PR that changes `new-project.sh` or `update-project.sh` must verify `tests/test-bootstrap.sh` and `tests/test-update.sh` still pass.
- New features should add assertions to existing tests, not create separate test files (avoid test fragmentation).

---

## What NOT to flag

- Formatting, whitespace, import order.
- "You could refactor this for clarity" — only if the unclarity hides a bug.
- Missing comments on straightforward shell commands.
- Speculative future-proofing.

---

## Output format

1. **Summary** — what this PR does and your verdict.
2. **Blocking issues** — file:line, what's wrong, suggested fix.
3. **Non-blocking observations** — brief.
4. **Tests** — do the self-tests pass?

If there are zero blocking issues: "LGTM."

<!-- conductor:begin v0.10.38 -->
## Conductor delegation

This project has [conductor](https://github.com/autumngarage/conductor)
available for delegating tasks to other LLMs from inside an agent loop.
You can shell out to it instead of trying to do everything yourself.

Pick the job type first; do not pick a provider unless the user explicitly
asks for one:

- Quick factual/background ask:
  `conductor ask --kind research --effort minimal --brief-file /tmp/brief.md`.
- Deeper synthesis/research:
  `conductor ask --kind research --effort medium --brief-file /tmp/brief.md`.
- Text/prose/docs/instructions review:
  `conductor ask --kind text-review --effort medium --brief-file /tmp/brief.md`.
- Code explanation or small coding judgment:
  `conductor ask --kind code --effort low --brief-file /tmp/brief.md`.
- Repo-changing implementation/debugging:
  `conductor ask --kind code --effort high --brief-file /tmp/brief.md`.
- Merge/PR/diff review:
  `conductor ask --kind review --effort medium --base <ref> --brief-file /tmp/review.md`.
- Architecture/product judgment needing multiple views:
  `conductor ask --kind council --effort medium --brief-file /tmp/brief.md`.
- `conductor list` — show configured providers and their tags.

Conductor does not inherit your conversation context. For delegation,
write a complete brief with goal, context, scope, constraints, expected
output, and validation; use `--brief-file` for nontrivial `exec` tasks.
Default to `conductor ask`; use provider-specific `call` / `exec` only
when the user explicitly asks for a provider or the semantic API does not
fit.
Do not attach `--with` or `--model` to `conductor ask`; provider/model
overrides belong to lower-level commands, for example:

    conductor call --with openrouter --brief-file /tmp/brief.md

Default routing is flat-rate-first when the job contract allows it, then
OpenRouter as metered overflow. `review` means code diff/PR review;
`text-review` means prose/docs/prompt review without diff tooling.

Full delegation guidance (when to delegate, when not to, error handling):

    ~/.conductor/delegation-guidance.md
<!-- conductor:end -->

## Current state (read this first)

@.cortex/state.md

## Cortex Protocol

@.cortex/protocol.md
