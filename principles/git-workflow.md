# Git Workflow

Normal code changes go through a feature branch + PR + merge. Emergency bypasses are allowed only through the documented emergency path below, and must be disclosed in the next recovery PR. This discipline catches bugs before they land on the default branch and creates an audit trail for every change, while leaving a legible escape hatch for production incidents.

## The lifecycle

1. **Pull.** `git pull --rebase` on the default branch before starting work.
2. **Branch.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`.
3. **Change + commit.** Make the code change, stage explicit file paths (not `git add -A`), commit with a concise message.
4. **Ship.** `scripts/open-pr.sh --auto-merge` pushes, creates the PR, runs Codex review, squash-merges, deletes the remote branch, and pulls the updated default branch — all in one command. Use `scripts/open-pr.sh` (without `--auto-merge`) if you want to open the PR without merging.
5. **Clean up.** Delete the local feature branch. Run `scripts/cleanup-branches.sh` periodically for batch hygiene.

## Commit discipline

- Concise commit messages. Lead with what changed, not why (the PR description has the why).
- Logically grouped changes. One concern per commit where practical.
- Stage explicit file paths, not `git add -A` or `git add .` — this prevents accidentally staging sensitive files (.env, credentials) or large binaries.

## Codex merge review (optional, recommended)

If the project has Codex review configured (see `.codex-review.toml` for policy and the `codex-review` hook in `.pre-commit-config.yaml` for the entry point), a pre-push hook gates default-branch pushes (including squash-merges via `merge-pr.sh`). The mechanism is `stages: [pre-push]` in `.pre-commit-config.yaml`; it skips feature-branch pushes and only activates when the push target is the default branch. Behavior:
- Runs `codex exec --full-auto` against the diff vs the default branch
- Auto-fixes only mechanical or low-risk findings (typos, whitespace, trivial doc drift); behavior changes — including added logging, error handling, or retry logic — stay in the PR for human review
- Blocks the push for unsafe findings (high-scrutiny paths)
- Loops up to `max_iterations` times (default 3)
- Gracefully skips if the Codex CLI isn't installed, printing a visible "review skipped" line so the missing safety boundary isn't silent

## Periodic branch hygiene

```bash
scripts/cleanup-branches.sh              # dry-run first
scripts/cleanup-branches.sh --execute    # actually delete merged branches
```

The cleanup script never deletes the default branch, the current branch, branches checked out in worktrees, or branches with unique unmerged commits. It uses `git branch -d` (not `-D`) as defense in depth.

## Emergency path

If a production bug requires immediate action and can't wait for the PR cycle, push directly with `git push --no-verify`. The next PR must include an "Emergency-bypass disclosure" section explaining what was bypassed and why. The convention — not the tooling — is what keeps the discipline.
