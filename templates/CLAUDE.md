# {{PROJECT_NAME}} — Claude Code Instructions

## Who You Are on This Project

{{PROJECT_DESCRIPTION — describe the project's purpose, your role, and what "good" looks like for this codebase. Be specific about the domain.}}

## Engineering Principles

@principles/engineering-principles.md
@principles/pre-implementation-checklist.md
@principles/audit-weak-points.md
@principles/documentation-ownership.md

## Git Workflow

@principles/git-workflow.md

### The lifecycle (drive this automatically, do not ask the user for permission at each step)

1. **Pull.** `git pull --rebase` on the default branch before starting work.
2. **Branch.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`.
3. **Change + commit.** Make the code change, stage explicit file paths, commit with a concise message.
4. **Push.** `bash scripts/open-pr.sh` (which pushes + creates the PR). The pre-push hook runs Codex review if configured.
5. **Merge.** `bash scripts/merge-pr.sh <pr-number>` — squash-merge, delete branch, sync default branch.
6. **Clean up.** `git branch -D <feature-branch>` if it still exists locally.

### Housekeeping

- Concise commit messages. Logically grouped changes.
- Run `/compact` at ~50% context. Start fresh sessions for unrelated work.

## Testing

```bash
# Before any push — replace with your project's test command
{{TEST_COMMAND — e.g., scripts/run-pytest-in-venv.sh tests/ -v --timeout=60 -x}}
```

Fix failing tests before pushing.

## Architecture

{{ARCHITECTURE — describe key packages, their responsibilities, and how data flows between them. Keep it high-level.}}

## Key Files

| File | Purpose |
|------|---------|
| {{key files and their purposes}} | |

## State & Config

{{STATE_AND_CONFIG — where does mutable state live? What's gitignored? Where's the config template?}}

## Deployment

{{DEPLOYMENT — how and where does this project deploy?}}

## Hard-Won Lessons

{{HARD_WON_LESSONS — bugs that cost real time or money. Each should teach a generalizable lesson. Format: what happened, what was the root cause, what's the fix/guard now in place.}}
