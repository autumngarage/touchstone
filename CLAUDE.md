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
- **Self-tests are mandatory.** Run `bash tests/test-bootstrap.sh && bash tests/test-update.sh` before pushing. These validate the bootstrap and update flows end-to-end.
- **Version bump on meaningful changes.** Update `VERSION` and `CHANGELOG.md` when cutting a release. Tag with `git tag vX.Y.Z`.

## Testing

```bash
# Before any push
bash tests/test-bootstrap.sh && bash tests/test-update.sh
```

Both tests must pass. They exercise the full bootstrap and update flows against temp directories.

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
| `VERSION` | Current semver version |
| `CHANGELOG.md` | Release history |
| `~/.toolkit-projects` | Registry of all bootstrapped projects |

## Deployment

No deployment — the toolkit is cloned to `~/Repos/toolkit` and used locally. Projects are updated via `sync-all.sh`. Future: Homebrew tap for `brew install toolkit`.
