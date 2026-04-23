# Git Workflow

Normal code changes go through a feature branch + PR + merge. Emergency bypasses are allowed only through the documented emergency path below, and must be disclosed in the next recovery PR. This discipline catches bugs before they land on the default branch and creates an audit trail for every change, while leaving a legible escape hatch for production incidents.

## The lifecycle

1. **Pull.** `git pull --rebase` on the default branch before starting work.
2. **Branch.** `git checkout -b <type>/<short-description>` where `<type>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`.
3. **Loop: change → commit → push.** Each meaningful sub-task gets its own commit and push. Stage explicit file paths (not `git add -A`), write a concise message, push to the open branch. Don't batch a session's worth of changes into one commit at the end — see the "Commit and push frequency" section below.
4. **Ship.** `scripts/open-pr.sh --auto-merge` pushes, creates the PR, runs Codex review, squash-merges, deletes the remote branch, and pulls the updated default branch — all in one command. Use `scripts/open-pr.sh` (without `--auto-merge`) if you want to open the PR without merging.
5. **Clean up.** Delete the local feature branch. Run `scripts/cleanup-branches.sh` periodically for batch hygiene.

## Commit discipline

**One concern per commit.** A commit should describe a single logical change — a feature, a fix, a refactor, a doc update — not a multi-day grab bag. The diff might span many files, but it should be one coherent thought. This is the "atomic commit" principle: every commit is a self-contained unit of intent.

**Why it matters.** Atomic commits pay back continuously: they make code review legible (a reviewer can hold one idea at a time), they make `git blame` and `git log` informative ("this line exists because of fix X" beats "this line exists because of giant-batch Y"), they make `git bisect` able to pin a regression to a single change, and they make `git revert` surgical (you can undo the broken thing without losing the four good things shipped alongside).

**Concise commit messages.** Lead with *what* changed in the subject line. Use the body to explain *why* when the why isn't obvious from the diff. The PR description handles the broader narrative; commit messages are the per-step record.

**Stage explicit file paths.** Avoid `git add -A` or `git add .` — they accidentally stage sensitive files (`.env`, credentials) or large binaries. Naming files makes intent visible at the staging step.

## Commit and push frequency

**Commit at every clear stopping point.** A sub-task is complete and its tests pass — that's a commit boundary. Don't wait until "the whole feature is done." Holding hours of work in an uncommitted working tree creates four problems: (1) reviewers eventually face one giant diff instead of a sequence they can read, (2) any single mistake can lose all of it, (3) other branches can't pull your in-flight work, and (4) you lose the per-step `git log` story that future-you will rely on when debugging months later.

**Push after every commit.** Local commits are not durable. Pushing to the remote (or a personal fork) means your work survives a laptop dying or a `git reset --hard` finger-slip. On a PR branch, pushing also surfaces incremental progress to reviewers, who can comment on individual commits rather than waiting for a final blob.

**Cadence guidance.** A useful rhythm for a focused work session is something like one commit per 30–60 minutes — about as often as you'd take a sip of water. If a session goes longer than that without a commit, ask whether you've passed a clean stopping point and didn't notice. If you can describe what you just finished in one sentence, that's a commit.

**When *not* to commit.** Two cases: (1) a half-finished thought where the code is in a deliberately-broken intermediate state — squash that into a single sensible commit before pushing, or use `git stash` to set it aside; (2) actively-iterating exploration where commits would just be noise — fine to keep working, but reset the timer once you've found the right shape and start committing as you build out from there.

**Why this needs to be a rule, not a vibe.** Without an explicit cadence, "I'll commit when there's something worth committing" reliably becomes "I'll commit at the end of the day," and end-of-day commits are the ones that ship as one fat unreviewable blob. The cadence is the discipline; the discipline is what produces the legible history.

## Background reading

- [Commit Often, Perfect Later, Publish Once — Git Best Practices](https://sethrobertson.github.io/GitBestPractices/) (Seth Robertson) — the canonical "commit early, commit often" essay.
- [Trunk-Based Development](https://trunkbaseddevelopment.com/) — the practice that frequent small commits enable at scale (Google, Facebook, et al.).
- The autumn-garage convention is closer to "tiny PRs to main" than "long-lived feature branches" — short branches, frequent commits, fast review.

## Codex merge review (optional, recommended)

If the project has Codex review configured (see `.codex-review.toml` for policy and the `codex-review` hook in `.pre-commit-config.yaml` for the entry point), a pre-push hook gates default-branch pushes (including squash-merges via `merge-pr.sh`). The mechanism is `stages: [pre-push]` in `.pre-commit-config.yaml`; it skips feature-branch pushes and only activates when the push target is the default branch. **The reviewer is the merge gate** — `scripts/open-pr.sh --auto-merge` is the standard ship path: open PR → reviewer runs → squash-merge → branch deleted, all in one command, no extra approval step.

Behavior:
- Runs `codex exec --full-auto` against the diff vs the default branch
- Auto-fixes only low-risk findings (typos, missing imports, missing null checks, adding logging to empty exception handlers, named constants for unexplained magic numbers); anything that changes business logic or retry/error-handling semantics is reported as a finding for the author to address in another commit before merge
- Blocks the push for unsafe findings (high-scrutiny paths)
- Loops up to `max_iterations` times (default 3)
- Gracefully skips if the Codex CLI isn't installed, printing a visible "review skipped" line so the missing safety boundary isn't silent

## Periodic branch hygiene

```bash
scripts/cleanup-branches.sh              # dry-run first
scripts/cleanup-branches.sh --execute    # actually delete merged branches
```

The cleanup script never deletes the default branch, the current branch, branches checked out in worktrees, or branches with unique unmerged commits. Ancestor-merged branches are deleted with `git branch -d` as defense in depth (git refuses unmerged work). Squash-merged branches — the common case with `open-pr.sh --auto-merge`, where the commits on your feature branch aren't ancestors of the default branch but their changes are already applied — are detected via tree equivalence: every file the branch changed relative to the merge-base must match the default branch's current content. This uniformly handles squash, rebase, and cherry-pick shapes, and correctly rejects the add-then-revert case (where history-based patch-id lookups would false-positive on the add commit). Once equivalence is confirmed, the branch is force-deleted with `git branch -D`.

## Stacked PRs (and why they usually aren't worth it)

A stacked PR is a PR whose base branch is another open PR's branch instead of the default branch. The goal: split a large change into a chain where each step is reviewable on its own, with the child's diff narrowed to "only the new commits on top of the parent." `open-pr.sh --base <parent-branch>` opens one.

**The gotcha that orphans them.** `gh pr merge --squash` (the `--auto-merge` default) rewrites the parent's history into a single squash commit on the default branch — which means the child branch no longer traces to anything upstream. GitHub notices the orphan and **closes the child PR** instead of rebasing it onto the new default branch. The child's code is not lost (the branch still exists on remote), but the PR is marked closed-without-merge and any review discussion on it is effectively abandoned. You've seen this fire before (sentinel PRs #49/#50/#51 on 2026-04-16).

**What to do.**

- **First preference: bundle.** When the user says "ship it all," default to one PR with all the commits. Reviewers prefer one coherent story over a chain; mergers prefer one squash over orchestrating a chain in order.
- **If you must stack:** drop `--auto-merge` on the whole chain. Merge each PR by hand in order, using **merge commit** or **rebase merge** (never squash) for the parent so the child's branch still traces to something on main. `open-pr.sh` will warn if you pass `--base <branch>` + `--auto-merge` together — take the warning seriously.
- **Recover an orphaned child**: re-open the work as a fresh PR against current `main` (the lineage is lost but the diff usually still applies). If the parent's squashed content is already on main, the child's diff is just the child-only changes — which is usually what you wanted anyway.

## Emergency path

If a production bug requires immediate action and can't wait for the PR cycle, push directly with `git push --no-verify`. The next PR must include an "Emergency-bypass disclosure" section explaining what was bypassed and why. The convention — not the tooling — is what keeps the discipline.
