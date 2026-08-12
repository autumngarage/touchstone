# Touchstone — Claude Code Instructions

## Who You Are on This Project

You are maintaining a shared engineering platform that provides universal principles, reusable scripts, deterministic validation, and a PR-visible review workflow for all of Henry's projects. Changes here propagate to every downstream project via `sync-all.sh`. Quality matters doubly: a bug in Touchstone is a bug in every project that uses it.

Codex and other AGENTS.md-native tools read `AGENTS.md`; Gemini CLI reads `GEMINI.md`. Keep `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` aligned when Touchstone workflow, architecture, or hard-won lessons change.

## Universal steering

@TOUCHSTONE.md

The block above is the canonical universal contract: agent roles, the 14 daily-reminder engineering principles, the never-commit-on-main rule, the required delivery workflow, and a routing table that points to deeper docs (memory hygiene among them) rather than inlining them. Codex and Gemini agents read the same content via the `<!-- touchstone:steering -->` managed block in `AGENTS.md` / `GEMINI.md`.

## Touchstone-Specific Principles

- **Changes propagate.** Every file in `principles/`, `hooks/`, and `scripts/` gets copied into downstream projects by `update-project.sh`. Updates must happen on a clean git worktree and land as a `chore/touchstone-*` branch commit, not as orphaned dirty files. Test changes here before syncing.
- **User-scoped skills propagate too.** Files under `skills/` are installed to `~/.claude/skills/` on user machines by `lib/install-skills.sh`. Project-scoped skills under `.claude/skills/` are project-owned and stay in the source repo.
- **Templates are starting points.** Files in `templates/` are copied once at bootstrap time and then owned by the project. Changes to templates only affect *new* projects.
- **Self-tests are mandatory.** Run every `tests/test-*.sh` script before pushing. This is the fast default tier and must not spend live model/provider quota. Slow opt-in probes live under `tests/slow-*.sh` and are run explicitly when validating model-steering behavior.
- **Parallel agent work is isolated.** Use `principles/agent-swarms.md` for slice manifests and parent orchestration. Use `scripts/spawn-worktree.sh` to create branch/worktree slices and `scripts/cleanup-worktrees.sh` for dry-run-first teardown.
- **Release completeness.** A touchstone release is not done until GitHub Releases, the Homebrew tap, `origin/main`, and the locally installed brew package all agree on the same version.
- **Nothing ships unjustified.** Every file under `bin/`, `bootstrap/`, `hooks/`, `lib/`, and `scripts/` must declare a mission job in `capabilities.toml`, and `tests/test-steering-size-caps.sh` fails if it does not. Adding a capability means writing down which of the three jobs it serves — constrain, make state legible, or carry the contract — in the same diff. If you cannot name one, do not add the file. A capability that is kept only until its removal lands is marked `cut` with a tracking issue, so the debt is reported on every test run instead of quietly becoming normal.

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

Lint is not part of the test suite. The full lint suite runs at pre-commit and via `pre-commit run --all-files`: `shellcheck`, `shfmt` for shell-script formatting, `markdownlint` for prose, and `actionlint` for `.github/workflows/`. `.pre-commit-config.yaml` and `.markdownlint.json` are the canonical config files; `actionlint` is repo-only and is not synced to downstream templates.

## Architecture

```
touchstone/
├── TOUCHSTONE.md   # Lean steering router — universal contract for all drivers
├── capabilities.toml # Scope ledger — every shipped file declares its mission job (repo-only, not synced)
├── principles/     # Universal docs (touchstone-owned, synced to all projects)
├── skills/         # User-scoped Claude Code skills (touchstone-owned, installed to ~/.claude/skills/)
├── templates/      # Starter files (copied once at bootstrap, then project-owned)
├── hooks/          # Reusable git hooks (touchstone-owned, synced as scripts/* in projects)
├── scripts/        # Helper scripts (touchstone-owned, synced)
├── bootstrap/      # new-project.sh, update-project.sh, sync-all.sh
├── bin/            # The `touchstone` CLI entry point (installed via brew or PATH)
├── lib/            # Shared bash modules (release, install-hooks, install-skills, touchstone-block, ui, colors, auto-update)
├── completions/    # Shell completion scripts for the touchstone CLI (bash, zsh)
├── audits/         # Dated drift/health reports produced by the touchstone-audit skill (never auto-modified)
├── feedback/       # Dated dogfooding bug reports and usage notes from downstream projects
├── prototypes/     # Throwaway design experiments (e.g. UI banners) — not shipped to projects
└── tests/          # Self-tests for bootstrap and update flows
```

## Key Files

| File | Purpose |
|------|---------|
| `TOUCHSTONE.md` | Canonical steering router — drives CLAUDE.md (@-import) and AGENTS.md/GEMINI.md (managed block) |
| `capabilities.toml` | Scope ledger — every file under `bin/`, `bootstrap/`, `hooks/`, `lib/`, `scripts/` declares which mission job it serves |
| `bootstrap/new-project.sh` | Spin up a new project with all touchstone files |
| `bootstrap/update-project.sh` | Pull latest touchstone files into an existing project |
| `bootstrap/sync-all.sh` | Update all registered projects at once |
| `lib/touchstone-block.sh` | Renders TOUCHSTONE.md into the managed block of AGENTS.md/GEMINI.md |
| `lib/install-skills.sh` | Installs user-scoped skill bundle from `skills/` to `~/.claude/skills/` |
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
2. Run `TOUCHSTONE_NO_AUTO_UPDATE=1 bin/touchstone release --patch` or `--minor` / `--major`. The helper bumps `VERSION` on a `release/vX.Y.Z` branch, ships the bump through the PR merge gate (`scripts/open-pr.sh --auto-merge` — required checks plus exact-head review; never a direct push to `main`), then tags the squash-merged `main` commit, pushes the tag, and runs `gh release create`. If the release PR stalls, the helper stops fail-closed and prints the resume commands (`bash scripts/open-pr.sh --auto-merge` from the release branch, then `bin/touchstone release --finalize vX.Y.Z` once merged).
3. Verify the release PR merged to `origin/main` and the pushed tag points at the squash-merged `main` commit (not the release-branch head).
4. The release-published event triggers `.github/workflows/release.yml`, which calls the shared `homebrew-bump.yml` reusable workflow in `autumngarage/autumn-garage` (pinned `@v1`) to rewrite the tap formula's `url` + `sha256` and commit directly to the tap's `main` — no hand-editing, no local tap clone. Watch with `gh run list --workflow=release.yml --repo autumngarage/touchstone`. Manual escape hatch: `gh workflow run release.yml -f tag_name=vX.Y.Z` re-bumps for an existing tag.
5. Verify the shipped artifact (after the workflow completes, ~30s):
   - `git status --short --branch` is clean and not ahead of `origin/main`
   - `gh release view vX.Y.Z`
   - the Homebrew formula points at `vX.Y.Z` with the expected SHA
   - `brew update && brew upgrade touchstone`
   - `TOUCHSTONE_NO_AUTO_UPDATE=1 touchstone version` reports `touchstone vX.Y.Z`

Required repo secret: `HOMEBREW_TAP_PAT` (classic PAT with `repo` scope on the tap, or fine-grained with `contents:write` on `autumngarage/homebrew-touchstone`).

Do not call a Touchstone release complete until GitHub Releases, the Homebrew formula, `origin/main`, and the local brew install all agree on the same version.

## Current state (read this first)

@.cortex/state.md
