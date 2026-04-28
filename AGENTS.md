# Touchstone — AI Agent Instructions

This file steers Codex and other AGENTS.md-native coding agents. Claude Code reads `CLAUDE.md`; Gemini CLI reads `GEMINI.md`. Keep these files aligned when project-level workflow changes. When you are coding, follow the authoring guidance first. When you are explicitly reviewing a PR or running the AI review hook, use the review guide below.

<!-- touchstone:shared-principles:start -->
## Shared Engineering Principles (apply these first)

These principles are touchstone-owned and shared across every project. Apply them as the **primary coding and review criteria** before any project-specific rule below — an agent that lets a band-aid or a silent failure through has missed the point of this gate.

## Agent Roles And Fallbacks

There are two AI roles in a Touchstone workflow:

- **Driving CLI:** Claude Code, Codex, or Gemini CLI owns the repo workflow. The driver reads the steering files, edits files, runs tests, creates the branch and commits, opens the PR, invokes review, and ships through the merge helper.
- **Conductor worker/reviewer:** Conductor is the model router used by the driving CLI for review and bounded worker tasks. Conductor can route to Claude, Codex, Gemini, or other providers, and can fall back between configured providers, but Conductor does not replace the driving CLI's responsibility for git, PR, and merge workflow.

Driver fallback is shared-contract fallback: Codex and other AGENTS.md-native tools start here; Gemini starts in `GEMINI.md` and delegates back here; Claude starts in `CLAUDE.md` and imports the same `principles/` files. If one driving CLI is unavailable or rate-limited, another driving CLI can continue by reading its entry file plus this managed block and `principles/*.md`. If an agent-specific file is incomplete or conflicts with this block or `principles/*.md`, follow the managed block and principles first.

- **No band-aids** — fix the root cause; if patching a symptom, say so explicitly and name the root cause.
- **Keep interfaces narrow** — expose the smallest stable contract; don't leak storage shape, vendor SDKs, or workflow sequencing.
- **Derive limits from domain** — thresholds and sizes come from input/config/named constants; test at small, typical, and large scales.
- **Derive, don't persist** — compute from the source of truth; persist derived state only with a documented invalidation + rebuild path.
- **No silent failures** — every exception is re-raised or logged with debug context. No `except: pass`, no swallowed errors.
- **Every fix gets a test** — bug fix includes a regression test that runs in CI and fails on the old code.
- **Think in invariants** — name and assert at least one invariant for nontrivial logic.
- **One code path** — share business logic across modes; confine mode-specific differences to adapters, config, or the I/O boundary.
- **Version your data boundaries** — when a model/algorithm/source change affects decisions, version the boundary; don't aggregate across.
- **Separate behavior changes from tidying** — never mix functional changes with broad renames, formatting sweeps, or unrelated refactors.
- **Make irreversible actions recoverable** — destructive operations need a dry-run, backup, idempotency, rollback, or forward-fix plan before they run.
- **Preserve compatibility at boundaries** — public API/config/schema/CLI/hook/template changes need a compatibility or migration plan.
- **Audit weak-point classes** — when a structural bug is found, audit the class and add a guardrail; don't fix only the one instance.

Full rationale, worked examples, and the *why* behind each rule:

- `principles/engineering-principles.md`
- `principles/pre-implementation-checklist.md`
- `principles/documentation-ownership.md`
- `principles/git-workflow.md`

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

### Touchstone-Specific Rules

- Files in `principles/`, `hooks/`, and `scripts/` are touchstone-owned and copied into downstream projects by `update-project.sh`.
- Files in `templates/` are copied once at bootstrap time and then project-owned; template changes affect new projects only.
- `bootstrap/new-project.sh`, `bootstrap/update-project.sh`, and `hooks/codex-review.sh` are high-risk. Preserve backup, clean-worktree, branch/commit, skip, and fail-open behavior.
- All shell must stay portable to macOS with standard tools: `bash`, `git`, `gh`, `sed`, and `awk`.

### Testing

Before pushing, run:

```bash
for test in tests/test-*.sh; do bash "$test"; done
```

For focused bootstrap/update changes, at minimum run `bash tests/test-bootstrap.sh` and `bash tests/test-update.sh`, then run the broader suite before shipping.

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

## Review Guide

You are reviewing pull requests for the **touchstone** repo — a shared engineering platform whose files propagate to all downstream projects. A bug here becomes a bug everywhere.

---

## What to prioritize (in order)

1. **Bootstrap/update correctness.** `new-project.sh` and `update-project.sh` must never silently lose user data. For bootstrap, file overwrites without `.bak` backups are critical. For update, bypassing the clean-git branch/commit boundary, incorrect copy paths, or broken skip logic for project-owned files are critical bugs.
2. **Script portability.** All scripts must work on macOS (zsh default) with standard tools (`bash`, `git`, `gh`, `sed`, `awk`). No Linux-only flags, no GNU-specific extensions without fallbacks.
3. **Codex hook safety.** `hooks/codex-review.sh` runs during `git push`. A bug here can block or silently skip all pushes. The fail-open design (graceful skip on errors) must be preserved.
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
