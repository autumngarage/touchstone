# Touchstone — Claude Code Instructions

## Who You Are on This Project

You are maintaining a shared engineering platform that provides universal principles, reusable scripts, and a Conductor-backed AI merge/default-branch review hook for all of Henry's projects. Changes here propagate to every downstream project via `sync-all.sh`. Quality matters doubly: a bug in Touchstone is a bug in every project that uses it.

Codex and other AGENTS.md-native tools read `AGENTS.md`; Gemini CLI reads `GEMINI.md`. Keep `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` aligned when Touchstone workflow, architecture, or hard-won lessons change.

## Agent Roles And Fallbacks

Claude Code is a **driving CLI** in this repo: it owns file edits, git state, tests, commits, PR creation, Conductor review invocation, and merge helper execution. Codex and Gemini CLI are equivalent fallback drivers because all three load the same managed principles and delivery workflow.

Conductor is the **worker/reviewer router**. The driving CLI may invoke Conductor for code review or bounded model work, and Conductor can fall back across configured providers such as Claude, Codex, Gemini, or local models. Conductor provider fallback does not replace the driving CLI's responsibility for the branch → PR → review → automerge workflow.

## Engineering Principles (HARD REQUIREMENTS)

Non-negotiable. Every code change is reviewed against them. Full rationale, worked examples, and the *why* behind each rule live in `principles/engineering-principles.md` — read it once; this list is the daily reminder.

- **No band-aids** — fix the root cause; if patching a symptom, say so explicitly and name the root cause.
- **Keep interfaces narrow** — expose the smallest stable contract; don't leak storage shape, vendor SDKs, or workflow sequencing.
- **Derive limits from domain** — thresholds and sizes come from input/config/named constants; test at small, typical, and large scales.
- **Derive, don't persist** — compute from the source of truth; persist derived state only with documented invalidation + rebuild path.
- **No silent failures** — every exception is re-raised or logged with debug context. No `except: pass`, no swallowed errors.
- **Every fix gets a test** — bug fix includes a regression test that runs in CI and fails on the old code.
- **Think in invariants** — name and assert at least one invariant for nontrivial logic.
- **One code path** — share business logic across modes; confine mode-specific differences to adapters, config, or the I/O boundary.
- **Version your data boundaries** — when a model/algorithm/source changes affects decisions, version the boundary; don't aggregate across.
- **Separate behavior changes from tidying** — never mix functional changes with broad renames, formatting sweeps, or unrelated refactors.
- **Make irreversible actions recoverable** — destructive operations need dry-run, backup, idempotency, rollback, or forward-fix plan before they run.
- **Preserve compatibility at boundaries** — public API/config/schema/CLI/hook/template changes need a compatibility or migration plan.
- **Audit weak-point classes** — find a structural bug → audit the class + add a guardrail. Use the `touchstone-audit-weak-points` skill.
- **Isolate file-writing subagents** — parallel workers use dedicated worktrees, slice manifests, and disjoint file ownership by default.

@principles/engineering-principles.md
@principles/pre-implementation-checklist.md
@principles/documentation-ownership.md
@principles/agent-swarms.md

## Git Workflow

@principles/git-workflow.md

### Never commit on main

Every change — including one-liners, doc tweaks, and version bumps — starts on a feature branch. **Before your first edit of a tracked file in a session**, run `git branch --show-current`; if it reports `main` (or `master`), branch first with `git checkout -b <type>/<slug>` — your unstaged changes carry over, so there's no cost to switching now. The trigger is at *edit time*, not commit time, because the recurring failure mode is: agent edits six files on main, hits `no-commit-to-branch` at commit, then has to recover the work onto a branch. Branching first is one cheap command; recovering is several. See the "Never commit on the default branch" section in `principles/git-workflow.md` for recovery steps when it happens anyway.

### The lifecycle (drive this automatically, do not ask the user for permission at each step)

1. **Pull.** `git pull --rebase` on main before starting work.
2. **Branch — before any edit that might become a commit.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`. Branching is step one, not cleanup.
3. **Change + commit.** Make the code change, stage explicit file paths, commit with a concise message.
4. **Conductor review + auto-fix.** From a clean worktree, run `CODEX_REVIEW_FORCE=1 bash scripts/codex-review.sh`. This asks Conductor for code review and safe auto-fixes before merge. If Conductor creates fix commits, let the loop finish; if it blocks, address findings, commit, and rerun until clean.
5. **Ship.** `bash scripts/open-pr.sh --auto-merge` — pushes, creates the PR, runs the final read-only Conductor merge review, squash-merges, and syncs main in one step.
6. **Clean up.** `git branch -D <feature-branch>` if it still exists locally.

### Housekeeping

- Concise commit messages. Logically grouped changes.
- File-writing subagents use isolated worktrees by default. Follow `principles/agent-swarms.md`; use `scripts/spawn-worktree.sh` and `scripts/cleanup-worktrees.sh` for local setup and teardown.
- Run `/compact` at ~50% context. Start fresh sessions for unrelated work.

### Memory Hygiene

- Treat Claude Code memory as cached guidance, not canonical truth. Before relying on a remembered command, flag, path, version, or workflow, verify it against this repo.
- Do not write memory for facts that are cheap to derive from `README.md`, `CLAUDE.md`, `AGENTS.md`, `VERSION`, `bin/touchstone --help`, or the scripts themselves.
- If you write memory that mentions a command, flag, file path, version, release process, or "current/primary" workflow, include the date (`YYYY-MM-DD`) and the canonical source checked.
- If memory conflicts with the repo, follow the repo and ask to audit or update the stale memory. Use the `memory-audit` skill when the user asks to clean or verify Claude memory.

## Touchstone-Specific Principles

- **Changes propagate.** Every file in `principles/`, `hooks/`, and `scripts/` gets copied into downstream projects by `update-project.sh`. Updates must happen on a clean git worktree and land as a `chore/touchstone-*` branch commit, not as orphaned dirty files. Test changes here before syncing.
- **Templates are starting points.** Files in `templates/` are copied once at bootstrap time and then owned by the project. Changes to templates only affect *new* projects.
- **Self-tests are mandatory.** Run every `tests/test-*.sh` script before pushing. This is the fast default tier and must not spend live model/provider quota. Slow opt-in probes live under `tests/slow-*.sh` and are run explicitly when validating model-steering behavior.
- **Parallel agent work is isolated.** Use `principles/agent-swarms.md` for slice manifests and parent orchestration. Use `scripts/spawn-worktree.sh` to create branch/worktree slices and `scripts/cleanup-worktrees.sh` for dry-run-first teardown.
- **Release completeness.** A touchstone release is not done until GitHub Releases, the Homebrew tap, `origin/main`, and the locally installed brew package all agree on the same version.

## Testing

```bash
# Before any push
for test in tests/test-*.sh; do
  echo "==> $test"
  bash "$test" || exit 1
done

# Opt-in slow tier for live model/provider probes
for test in tests/slow-*.sh; do
  echo "==> $test"
  bash "$test" || exit 1
done
```

The fast tier must pass before pushing — it's the "is this safe to push" gate (deterministic, offline, ~100s). The slow tier is the "is this safe to ship" gate, run when changing live guidance-probe behavior or before release-level confidence checks. The bootstrap and update tests exercise the full propagation flow against temp directories.

Lint is not part of the test suite. Shellcheck runs at pre-commit via `.pre-commit-config.yaml`. For an explicit full-repo lint pass: `pre-commit run shellcheck --all-files`.

## Architecture

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

## Key Files

| File | Purpose |
|------|---------|
| `bootstrap/new-project.sh` | Spin up a new project with all touchstone files |
| `bootstrap/update-project.sh` | Pull latest touchstone files into an existing project |
| `bootstrap/sync-all.sh` | Update all registered projects at once |
| `hooks/codex-review.sh` | Conductor-backed AI merge/default-branch review + auto-fix hook |
| `scripts/spawn-worktree.sh` | Create an isolated branch/worktree for parallel file-writing agent slices |
| `scripts/cleanup-worktrees.sh` | Dry-run-first cleanup for clean merged-or-equivalent worktrees |
| `lib/release.sh` | Release automation for GitHub Releases and the Homebrew tap |
| `VERSION` | Current semver version |
| `~/.touchstone-projects` | Registry of all bootstrapped projects |

Release history lives in `git log` and `gh release list` — there is no `CHANGELOG.md`. Duplicating release history in a markdown file was a documentation-ownership violation (see `principles/documentation-ownership.md`). Run `gh release list` or `git log --oneline` for the canonical list.

## Release & Distribution

Touchstone ships through GitHub Releases and the `autumngarage/homebrew-touchstone` tap.

Release flow:

1. Merge code to `main`.
2. Run `TOUCHSTONE_NO_AUTO_UPDATE=1 bin/touchstone release --patch` or `--minor` / `--major`. The helper bumps `VERSION`, commits, tags, pushes `main` and the tag, and runs `gh release create`.
3. Verify the release helper pushed the release commit to `origin/main` and pushed the matching tag.
4. The release-published event triggers `.github/workflows/release.yml`, which calls the shared `homebrew-bump.yml` reusable workflow in `autumngarage/autumn-garage` (pinned `@v1`) to rewrite the tap formula's `url` + `sha256` and commit directly to the tap's `main` — no hand-editing, no local tap clone. Watch with `gh run list --workflow=release.yml --repo autumngarage/touchstone`. Manual escape hatch: `gh workflow run release.yml -f tag_name=vX.Y.Z` re-bumps for an existing tag.
5. Verify the shipped artifact (after the workflow completes, ~30s):
   - `git status --short --branch` is clean and not ahead of `origin/main`
   - `gh release view vX.Y.Z`
   - the Homebrew formula points at `vX.Y.Z` with the expected SHA
   - `brew update && brew upgrade touchstone`
   - `TOUCHSTONE_NO_AUTO_UPDATE=1 touchstone version` reports `touchstone vX.Y.Z`

Required repo secret: `HOMEBREW_TAP_PAT` (classic PAT with `repo` scope on the tap, or fine-grained with `contents:write` on `autumngarage/homebrew-touchstone`).

Do not call a Touchstone release complete until GitHub Releases, the Homebrew formula, `origin/main`, and the local brew install all agree on the same version.

<!-- conductor:begin v0.8.2 -->
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
