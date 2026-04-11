# Toolkit — Claude Code Instructions

## Who You Are on This Project

You are maintaining a shared engineering platform that provides universal principles, reusable scripts, and a Codex merge/default-branch review hook for all of Henry's projects. Changes here propagate to every downstream project via `sync-all.sh`. Quality matters doubly: a bug in the toolkit is a bug in every project that uses it.

## Engineering Principles

@principles/engineering-principles.md
@principles/pre-implementation-checklist.md
@principles/audit-weak-points.md
@principles/documentation-ownership.md

## Git Workflow

@principles/git-workflow.md

### The lifecycle (drive this automatically, do not ask the user for permission at each step)

1. **Pull.** `git pull --rebase` on main before starting work.
2. **Branch.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`.
3. **Change + commit.** Make the code change, stage explicit file paths, commit with a concise message.
4. **Push.** `bash scripts/open-pr.sh` (which pushes + creates the PR). Feature-branch pushes stay fast.
5. **Merge.** `bash scripts/merge-pr.sh <pr-number>` — Codex review, squash-merge, delete branch, sync main.
6. **Clean up.** `git branch -D <feature-branch>` if it still exists locally.

### Housekeeping

- Concise commit messages. Logically grouped changes.
- Run `/compact` at ~50% context. Start fresh sessions for unrelated work.

## Toolkit-Specific Principles

- **Changes propagate.** Every file in `principles/`, `hooks/`, and `scripts/` gets copied into downstream projects by `update-project.sh`. Test changes here before syncing.
- **Templates are starting points.** Files in `templates/` are copied once at bootstrap time and then owned by the project. Changes to templates only affect *new* projects.
- **Self-tests are mandatory.** Run every `tests/test-*.sh` script before pushing. These validate the bootstrap, update, hook, merge, and helper flows end-to-end.
- **Release completeness.** A toolkit release is not done until GitHub Releases, the Homebrew tap, `origin/main`, and the locally installed brew package all agree on the same version.

## Testing

```bash
# Before any push
for test in tests/test-*.sh; do bash "$test"; done
```

All tests must pass. The bootstrap and update tests exercise the full propagation flow against temp directories.

## Architecture

```
toolkit/
├── principles/     # Universal docs (toolkit-owned, synced to all projects)
├── templates/      # Starter files (copied once at bootstrap, then project-owned)
├── hooks/          # Reusable git hooks (toolkit-owned, synced)
├── scripts/        # Helper scripts (toolkit-owned, synced)
├── bootstrap/      # new-project.sh, update-project.sh, sync-all.sh
└── tests/          # Self-tests for bootstrap and update flows
```

## Key Files

| File | Purpose |
|------|---------|
| `bootstrap/new-project.sh` | Spin up a new project with all toolkit files |
| `bootstrap/update-project.sh` | Pull latest toolkit files into an existing project |
| `bootstrap/sync-all.sh` | Update all registered projects at once |
| `hooks/codex-review.sh` | Generalized Codex merge/default-branch review + auto-fix hook |
| `lib/release.sh` | Release automation for GitHub Releases and the Homebrew tap |
| `VERSION` | Current semver version |
| `CHANGELOG.md` | Release history |
| `~/.toolkit-projects` | Registry of all bootstrapped projects |

## Release & Distribution

Toolkit ships through GitHub Releases and the `henrymodisett/homebrew-toolkit` tap.

Release flow:

1. Merge code to `main`.
2. Run `TOOLKIT_NO_AUTO_UPDATE=1 bin/toolkit release --patch` or `--minor` / `--major`.
3. Verify the release helper pushed the release commit to `origin/main` and pushed the matching tag.
4. Verify the shipped artifact:
   - `git status --short --branch` is clean and not ahead of `origin/main`
   - `gh release view vX.Y.Z`
   - the Homebrew formula points at `vX.Y.Z` with the expected SHA
   - `brew update && brew upgrade toolkit`
   - `TOOLKIT_NO_AUTO_UPDATE=1 toolkit version` reports `toolkit vX.Y.Z`

Do not call a toolkit release complete until GitHub Releases, the Homebrew formula, `origin/main`, and the local brew install all agree on the same version.
