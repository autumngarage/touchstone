# AGENTS.md — AI Agent Instructions for {{PROJECT_NAME}}

This file steers Codex and other AGENTS.md-native coding agents. Claude Code reads `CLAUDE.md`; Gemini CLI reads `GEMINI.md`. Keep these files aligned when project-level workflow changes.

When coding, follow the authoring guide. When explicitly reviewing a PR or running the AI review hook, use the review guide.

## Authoring Guide

### Who You Are on This Project

{{PROJECT_DESCRIPTION — describe the project's purpose, your role, and what "good" looks like for this codebase. Be specific about the domain.}}

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
- `principles/agent-swarms.md`

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

### Git Workflow

Every change starts on a feature branch. Before editing tracked files, run `git branch --show-current`; if it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<short-description>`.

Use the normal lifecycle unless the user asks for a different flow:

1. Pull/rebase the default branch.
2. Branch before editing.
3. Make the change, stage explicit file paths, and commit with a concise message.
4. From a clean worktree, run `CODEX_REVIEW_FORCE=1 bash scripts/codex-review.sh` so Conductor can review and safely auto-fix before merge. If Conductor creates fix commits, let the loop finish; if it blocks, address findings, commit, and rerun until clean.
5. Ship with `bash scripts/open-pr.sh --auto-merge`; it creates the PR, runs the final read-only Conductor merge review, squash-merges, and syncs the default branch.
6. Clean up the feature branch if it still exists locally.

File-writing subagents use isolated worktrees by default. Follow `principles/agent-swarms.md` for slice manifests, file ownership, concurrency caps, and cleanup; use `scripts/spawn-worktree.sh` and `scripts/cleanup-worktrees.sh` for local setup and teardown.

### Testing

```bash
# Reinstall dependencies without rerunning the full machine setup
bash setup.sh --deps-only

# Before any push — uses .touchstone-config profile defaults and command overrides
bash scripts/touchstone-run.sh validate
```

Fix failing tests before pushing.

### Release & Distribution

{{RELEASE_AND_DISTRIBUTION — how is this project shipped? Include the release command, package registry or deployment target, required version bump, post-release verification, and rollback path. Examples: Homebrew tap, npm package, Docker image, Vercel/Railway deploy, app store build.}}

After merging release-affecting changes, verify the shipped artifact or deployed environment matches the pushed code.

### Architecture

{{ARCHITECTURE — describe key packages, their responsibilities, and how data flows between them. Keep it high-level.}}

### Key Files

| File | Purpose |
|------|---------|
| {{key files and their purposes}} | |

### State & Config

{{STATE_AND_CONFIG — where does mutable state live? What's gitignored? Where's the config template?}}

### Hard-Won Lessons

{{HARD_WON_LESSONS — bugs that cost real time or money. Each should teach a generalizable lesson. Format: what happened, what was the root cause, what's the fix/guard now in place.}}

---

## Review Guide

You are reviewing pull requests for **{{PROJECT_NAME}}**. Optimize your review for catching the things that bite this repo, not generic style polish.

### What to prioritize (in order)

{{PRIORITIES — list your project's review priorities in order of importance. Examples:

1. **Data integrity.** Anything that changes how data is written, migrated, or deleted.
2. **Security.** Auth, input validation, secrets handling, injection risks.
3. **Silent failures.** New `except: pass`, swallowed exceptions, fallbacks that mask broken state.
4. **Tests for new failure modes.** Bug fixes must add a test that reproduces the original failure.

Be specific to your project's actual risks. Generic priorities are useless.}}

Style nits, formatting, and theoretical refactors are **out of scope** unless they hide a bug. Do not flag them.

---

### Specific review rules

#### High-scrutiny paths

{{HIGH_SCRUTINY_PATHS — list the files/directories where mistakes are most expensive. Examples:

Files: `src/auth/`, `src/payments/`, `migrations/`

Flag any of the following:
- (specific anti-patterns relevant to your project)
- (things that have gone wrong before)
- (invariants that must hold)}}

#### Silent failures

Flag any of the following:

- New `except: pass`, `except Exception: pass`, or `except: ...` without logging.
- New `try / except` that catches a broad exception and continues without logging the exception object.
- Default values returned on error without a log line.
- Fallback behavior that masks broken state.

The rule: every exception is either re-raised or logged with enough context to debug from production logs alone.

#### Tests

- Bug fixes must include a test that reproduces the original failure mode.
- Tests should use relative values (percentages, ratios) not absolute values where applicable.
- Integration tests should hit real infrastructure for critical paths (mocks have masked real bugs in the past).

---

### What NOT to flag

- Formatting, whitespace, import order — pre-commit hooks handle these.
- Type annotations on existing untyped code.
- "You could refactor this for clarity" — only if the unclarity hides a bug.
- Missing docstrings on small private functions.
- Speculative future-proofing — don't suggest abstractions for hypothetical future requirements.
- Naming preferences absent a clear convention violation.

If you find yourself writing "consider" or "you might want to" without a concrete bug or risk attached, delete the comment.

---

### Output format

1. **Summary** — one paragraph: what this PR does and your overall verdict (approve / request changes / comment).
2. **Blocking issues** — bugs or risks that must be fixed before merge. Each item: file:line, what's wrong, why it matters, suggested fix.
3. **Non-blocking observations** — things worth noting but not blocking. Keep this section short.
4. **Tests** — does this PR add tests for the changed behavior? If not, is that OK?

If there are zero blocking issues, the review is just: "LGTM."
