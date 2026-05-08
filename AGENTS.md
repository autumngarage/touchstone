# Touchstone — AI Agent Instructions

This file steers Codex and other AGENTS.md-native coding agents. Claude Code reads `CLAUDE.md`; Gemini CLI reads `GEMINI.md`. Keep these files aligned when project-level workflow changes. When you are coding, follow the authoring guidance first. When you are explicitly reviewing a PR or running the AI review hook, use the review guide below.

<!-- touchstone:shared-principles:start -->
## Shared Engineering Principles (apply these first)

These principles are touchstone-owned and shared across every project. Apply them as the **primary coding and review criteria** before any project-specific rule below — an agent that lets a band-aid or a silent failure through has missed the point of this gate.

## Agent Roles And Fallbacks

There are two AI roles in a Touchstone workflow:

- **Driving CLI:** Claude Code, Codex, or Gemini CLI owns the repo workflow. The driver reads the steering files, edits files, runs tests, creates the branch and commits, opens the PR, invokes review, and ships through the merge helper.
- **Conductor worker/reviewer:** Conductor is the model router used by the driving CLI for review and bounded model work. Conductor can route to Claude, Codex, Gemini, or other providers, and can fall back between configured providers, but Conductor does not replace the driving CLI's responsibility for the branch → PR → review → automerge workflow.

Driver fallback is shared-contract fallback: Codex and other AGENTS.md-native tools start here; Gemini starts in `GEMINI.md` and delegates back here; Claude starts in `CLAUDE.md` and imports the same `principles/` files. If one driving CLI is unavailable or rate-limited, another driving CLI can continue by reading its entry file plus this managed block and `principles/*.md`. If an agent-specific file is incomplete or conflicts with this block or `principles/*.md`, follow the managed block and principles first.

- **No band-aids** — Fix the root cause unless the PR explicitly documents why a symptom patch is the safer scoped change. If it's a symptom patch, say so: *"This patches the symptom. The root cause is X and fixing it properly would require Y. Which do you want?"* Undocumented symptom patches compound — a year later you have a codebase full of thin fixes and nobody remembers which ones were intentional.
- **Keep interfaces narrow** — Expose the smallest stable interface that lets callers do their job. Don't leak storage shape, vendor SDKs, temporary flags, or workflow sequencing across module boundaries. A deep module hides substantial complexity behind a stable contract; a shallow module exports its complexity to every caller and makes every future fix broad and risky.
- **Derive limits from domain; test at scale boundaries** — Derive thresholds, sizes, limits, and allocations from input, configuration, or named domain constants. Hard-code a value only when it represents a real invariant, and document why. Test behavior at small, typical, and large scales — not just the shape you developed against. Code that only works at one scale will silently misbehave at the scales you forgot.
- **Derive, don't persist** — Compute from the source of truth by default. Persist derived state only when recomputation is too slow, too expensive, or externally required — and when you do, document in the same commit: the source of truth, the invalidation trigger, the rebuild path, and a reconciliation check. Undocumented persisted state goes stale silently; that is the failure mode this rule prevents.
- **No silent failures** — Every exception is either re-raised or logged with enough context to debug from production logs alone. No `except: pass`. No swallowed errors. No default values returned on failure without a log line. Fallback behavior may continue only when it reports what failed, what was skipped, and what safety boundary still holds.
- **Every fix gets a test** — Bug fixes must include a test that reproduces the exact failure mode, and the test must run in CI — not just locally. A bug fix without a regression test means the bug can recur silently the next time someone refactors nearby. The test should fail on the old code and pass on the new code — if it passes on both, it isn't testing the right thing.
- **Think in invariants** — For nontrivial logic, name at least one invariant and assert it — either in a test or as a runtime boundary check. What must always be true? What relationship between values must hold? Happy-path outputs tell you the code worked for one input; invariants tell you it can't be wrong for any input in the covered space.
- **One code path** — Share business logic across modes (test/prod, paper/live, dev/staging). Divergent paths drift apart silently, and bugs in one path don't surface until it's too late. If modes must differ, confine the difference to adapters, configuration, or the final I/O boundary — not a fork at the top of the pipeline.
- **Version your data boundaries** — When a model, algorithm, or data source changes in a way that affects decisions, rankings, persisted state, metrics, or user-visible behavior, establish a boundary (cohort, epoch, version) and ensure every downstream consumer honors it. Reads that drive decisions must not blend data across the boundary; aggregating across it dilutes signal with noise from the old regime.
- **Separate behavior changes from tidying** — Do not mix functional changes with broad renames, formatting sweeps, dependency churn, or unrelated refactors. If cleanup is needed, do it before or after the behavior change in a separate commit or PR. Mixed changes hide regressions and make rollback unsafe: a behavior change bundled with a rename is hard to bisect, hard to revert without losing the rename, and hard to find via `git blame` later.
- **Make irreversible actions recoverable** — Any destructive or one-way operation must have a recovery path before it runs. Deletes, migrations, format rewrites, external side effects, and history rewrites need a dry run, backup, idempotency key, rollback plan, or forward-fix plan. A change is not safe because it passed once; it is safe when failure leaves the system in a known recoverable state.
- **Preserve compatibility at boundaries** — Changes to public APIs, config files, schemas, CLIs, hooks, templates, and generated artifacts must include a compatibility or migration plan. Accept old and new formats during rollout when downstream consumers may lag. Boundary breaks multiply: one local assumption becomes N downstream failures.
- **Audit weak-point classes** — When you find a structural bug, audit the whole class — not just the one you noticed. Use the `touchstone-audit-weak-points` skill. This discipline prevents re-auditing the same code twice and catches bugs before they compound.
- **File issues for bugs** — Open a GitHub issue when you find a bug, in this project or in an autumngarage tool. Do not silently work around it.

Full rationale, worked examples, and the *why* behind each rule:

- `principles/engineering-principles.md`
- `principles/pre-implementation-checklist.md`
- `principles/documentation-ownership.md`
- `principles/git-workflow.md`
- `principles/agent-swarms.md`
- `principles/file-upstream-bugs.md`

## Required Delivery Workflow

For any task that may change tracked files, drive the full branch → PR → review → merge lifecycle unless the user explicitly asks you to stop before shipping:

1. Sync the default branch with `git pull --rebase`.
2. Before the first edit, run `git branch --show-current`. If it reports `main` or `master`, create a feature branch with `git checkout -b <type>/<short-description>`.
3. Make the change on that branch, keep commits scoped, stage explicit file paths, and commit with a concise message.
4. From a clean worktree, run `CODEX_REVIEW_FORCE=1 bash scripts/codex-review.sh`. If Conductor creates fix commits, let the loop finish; if it blocks, address findings, commit, and rerun until clean.
5. Ship with `bash scripts/open-pr.sh --auto-merge`. That command pushes the branch, creates the PR, runs the final read-only Conductor merge review, squash-merges after a clean review, and syncs the default branch.

Do not bypass the PR/review/automerge path with a direct default-branch push except through the documented emergency path in `principles/git-workflow.md`.

This block is managed by `touchstone` and refreshes on `touchstone update` / `touchstone init`. Edit content **outside** the markers to add project-specific agent guidance — touchstone will not touch it.
<!-- touchstone:shared-principles:end -->

## Authoring Guide

You are maintaining a shared engineering platform that provides universal principles, reusable scripts, and a Conductor-backed AI merge/default-branch review hook for Henry's projects. Changes here propagate to downstream projects via `sync-all.sh`, so treat fixes here as platform changes, not isolated repo edits.

### Git Workflow

- Start each code change from a feature branch. Before editing tracked files, run `git branch --show-current`; if it reports `main` or `master`, branch with `git checkout -b <type>/<short-description>`.
- Keep changes logically grouped. Stage explicit file paths, commit with a concise message, and avoid unrelated refactors.
- Before shipping, run `CODEX_REVIEW_FORCE=1 bash scripts/codex-review.sh` from a clean worktree to ask Conductor for review and safe auto-fixes. If Conductor commits fixes, let the loop finish; if it blocks, address the findings, commit, and rerun until clean.
- To ship a completed branch, use `bash scripts/open-pr.sh --auto-merge`; it pushes, creates the PR, runs the final read-only Conductor merge review, squash-merges, and syncs the default branch.
- File-writing subagents use isolated worktrees by default. Follow `principles/agent-swarms.md` for slice manifests, file ownership, concurrency caps, and cleanup; use `scripts/spawn-worktree.sh` and `scripts/cleanup-worktrees.sh` for local setup and teardown.

### Touchstone-Specific Rules

- Files in `principles/`, `hooks/`, and `scripts/` are touchstone-owned and copied into downstream projects by `update-project.sh`.
- Files in `templates/` are copied once at bootstrap time and then project-owned; template changes affect new projects only.
- `bootstrap/new-project.sh`, `bootstrap/update-project.sh`, and `hooks/codex-review.sh` are high-risk. Preserve backup, clean-worktree, branch/commit, skip, and fail-open behavior.
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
3. **Codex hook safety.** `hooks/codex-review.sh` runs during `git push`. A bug here can block or silently skip all pushes. The fail-open design (graceful skip on errors) must be preserved. **AI review is advisory** — it does not replace deterministic checks (lint, tests, type checking). The hook fails open by default (`on_error=fail-open`): infra errors (timeout, missing provider, malformed output, reviewer crash) allow the push rather than blocking it. Each fail-open event emits a visible `[fail-open:<code>]` line to stderr and writes a structured entry to `~/.touchstone-review-log`; taxonomy codes include `FAIL_OPEN_TIMEOUT`, `FAIL_OPEN_PARSE_ERROR`, `FAIL_OPEN_DEPENDENCY_MISSING`, `FAIL_OPEN_PROVIDER_UNAVAILABLE`, and `FAIL_OPEN_REVIEWER_ERROR`. The trade-off is explicit: a Conductor outage during a critical week will not block pushes, but the AI safety net will be visibly absent rather than silently bypassed.
4. **Config parsing correctness.** The TOML parser in `codex-review.sh` is minimal — it handles simple key=value and single-line arrays. Changes must not break on edge cases (quoted strings, comments, empty arrays).
5. **Principle accuracy.** Changes to `principles/*.md` should reflect genuinely universal engineering standards. Project-specific advice doesn't belong here.
6. **Template quality.** `templates/` should have clear `{{PLACEHOLDER}}` markers and be immediately useful after bootstrap. No placeholder that requires understanding Touchstone's internals to fill in.

Style nits and theoretical refactors are **out of scope**.

---

## Specific review rules

### High-scrutiny paths

Files: `bootstrap/new-project.sh`, `bootstrap/update-project.sh`, `hooks/codex-review.sh`

Flag any of the following:

- **Silent overwrites.** `new-project.sh` may overwrite touchstone-owned files only through `copy_file_force`, which backs up existing content as `.bak`. `update-project.sh` must not create `.bak` files; instead it must require a clean git worktree, create a `chore/touchstone-*` branch, and commit the update as the review/recovery boundary. Project-owned files (CLAUDE.md, AGENTS.md, .codex-review.toml) must use `copy_file` (skip if exists) and must not be auto-updated.
- **Missing error handling.** The bootstrap scripts use `set -euo pipefail`. New commands that can fail legitimately (network calls, optional tools) must be guarded with `|| true` or `set +e`.
- **Path assumptions.** Never assume repo root is `~/Repos/touchstone`. Always derive paths from `$0` or `git rev-parse`.
- **Registry corruption.** `~/.touchstone-projects` is append-only during bootstrap. Changes must not truncate it or write duplicate entries.

### Codex hook

- The three final-marker contract (CLEAN/FIXED/BLOCKED) is the API boundary. Any change to marker handling must be backwards-compatible.
- The hook must never block a push due to its own infrastructure failure (network, missing tool, parse error). It must block *only* on actual code review findings.
- `.codex-review.toml` parsing must handle missing keys gracefully (use defaults).

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

<!-- conductor:begin v0.10.2 -->
## Conductor delegation

This project has [conductor](https://github.com/autumngarage/conductor)
available for delegating tasks to other LLMs from inside an agent loop.
You can shell out to it instead of trying to do everything yourself.

Quick reference:

- Quick factual/background ask:
  `conductor ask --kind research --effort minimal --brief-file /tmp/brief.md`.
- Deeper synthesis/research:
  `conductor ask --kind research --effort medium --brief-file /tmp/brief.md`.
- Code explanation or small coding judgment:
  `conductor ask --kind code --effort low --brief-file /tmp/brief.md`.
- Repo-changing implementation/debugging:
  `conductor ask --kind code --effort high --brief-file /tmp/brief.md`.
- Merge/PR/diff review:
  `conductor ask --kind review --base <ref> --brief-file /tmp/review.md`.
- Architecture/product judgment needing multiple views:
  `conductor ask --kind council --effort medium --brief-file /tmp/brief.md`.
- `conductor list` — show configured providers and their tags.

Conductor does not inherit your conversation context. For delegation,
write a complete brief with goal, context, scope, constraints, expected
output, and validation; use `--brief-file` for nontrivial `exec` tasks.
Default to `conductor ask`; use provider-specific `call` / `exec` only
when the user explicitly asks for a provider or the semantic API does not
fit.

Providers commonly worth delegating to:

- `kimi` — long-context summarization, cheap second opinions.
- `gemini` — web search, multimodal.
- `claude` / `codex` — strongest reasoning / coding agent loops.
- `ollama` — local, offline, privacy-sensitive.
- `council` kind — OpenRouter-only multi-model deliberation and synthesis.

Full delegation guidance (when to delegate, when not to, error handling):

    ~/.conductor/delegation-guidance.md
<!-- conductor:end -->

## Current state (read this first)

@.cortex/state.md

## Cortex Protocol

@.cortex/protocol.md
