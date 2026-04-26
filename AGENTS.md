# AGENTS.md — AI Reviewer Guide for Touchstone

<!-- touchstone:shared-principles:start -->
## Shared Engineering Principles (apply these first)

These principles are touchstone-owned and shared across every project. Apply them as the **primary review criteria** before any project-specific rule below — a reviewer that lets a band-aid or a silent failure through has missed the point of this gate.

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

This block is managed by `touchstone` and refreshes on `touchstone update` / `touchstone init`. Edit content **outside** the markers to add project-specific reviewer guidance — touchstone will not touch it.
<!-- touchstone:shared-principles:end -->


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
