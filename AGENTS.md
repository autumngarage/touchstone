# AGENTS.md — AI Reviewer Guide for Toolkit

You are reviewing pull requests for the **toolkit** repo — a shared engineering platform whose files propagate to all downstream projects. A bug here becomes a bug everywhere.

---

## What to prioritize (in order)

1. **Bootstrap/update correctness.** `new-project.sh` and `update-project.sh` must never silently lose user data. File overwrites without `.bak` backups, incorrect copy paths, broken skip logic for project-owned files — these are critical bugs.
2. **Script portability.** All scripts must work on macOS (zsh default) with standard tools (`bash`, `git`, `gh`, `sed`, `awk`). No Linux-only flags, no GNU-specific extensions without fallbacks.
3. **Codex hook safety.** `hooks/codex-review.sh` runs during `git push`. A bug here can block or silently skip all pushes. The fail-open design (graceful skip on errors) must be preserved.
4. **Config parsing correctness.** The TOML parser in `codex-review.sh` is minimal — it handles simple key=value and single-line arrays. Changes must not break on edge cases (quoted strings, comments, empty arrays).
5. **Principle accuracy.** Changes to `principles/*.md` should reflect genuinely universal engineering standards. Project-specific advice doesn't belong here.
6. **Template quality.** `templates/` should have clear `{{PLACEHOLDER}}` markers and be immediately useful after bootstrap. No placeholder that requires understanding the toolkit's internals to fill in.

Style nits and theoretical refactors are **out of scope**.

---

## Specific review rules

### High-scrutiny paths

Files: `bootstrap/new-project.sh`, `bootstrap/update-project.sh`, `hooks/codex-review.sh`

Flag any of the following:

- **Silent overwrites.** Any file copy without checking existence or creating a `.bak` backup. `copy_file_force` is for toolkit-owned files only. Project-owned files (CLAUDE.md, AGENTS.md, .codex-review.toml) must use `copy_file` (skip if exists).
- **Missing error handling.** The bootstrap scripts use `set -euo pipefail`. New commands that can fail legitimately (network calls, optional tools) must be guarded with `|| true` or `set +e`.
- **Path assumptions.** Never assume repo root is `~/Repos/toolkit`. Always derive paths from `$0` or `git rev-parse`.
- **Registry corruption.** `~/.toolkit-projects` is append-only during bootstrap. Changes must not truncate it or write duplicate entries.

### Codex hook

- The three-sentinel contract (CLEAN/FIXED/BLOCKED) is the API boundary. Any change to sentinel handling must be backwards-compatible.
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
