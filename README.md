```text
   __              ____   _ __
  / /_____  ____  / / /__(_) /_
 / __/ __ \/ __ \/ / //_/ / __/
/ /_/ /_/ / /_/ / / ,< / / /_
\__/\____/\____/_/_/|_/_/\__/
```

# toolkit

Shared engineering toolkit — universal principles, project bootstrap, profile-aware commands, atomic updates, and AI review gates for every repo you care about.

## Install

```bash
brew tap henrymodisett/toolkit
brew install toolkit
```

Requires `git` and `gh` (installed automatically as brew dependencies).

## Quick start

```bash
# Create a new project with all the toolkit goodies
toolkit new ~/Repos/my-new-project

# Fill in the placeholders
$EDITOR ~/Repos/my-new-project/CLAUDE.md
$EDITOR ~/Repos/my-new-project/AGENTS.md

# Set up dev tools, hooks, and project dependencies
cd ~/Repos/my-new-project
bash setup.sh

# Log in to the default AI reviewer before merging to main
codex login

# Re-run dependency setup later without reinstalling hooks/tools
bash setup.sh --deps-only
```

## Commands

| Command | What it does |
|---------|-------------|
| `toolkit init [--no-setup]` | Add toolkit to the current project |
| `toolkit new <dir>` | Bootstrap a new project with principles, scripts, hooks, and templates |
| `toolkit new <dir> --type node` | Bootstrap with an explicit Node/TypeScript, Swift, Rust, Go, Python, or generic profile |
| `toolkit detect` | Show the detected project profile for the current repo |
| `toolkit run <task>` | Run profile-aware `lint`, `typecheck`, `build`, `test`, or `validate` |
| `toolkit update` | Create a branch and commit that updates the current project's toolkit-owned files |
| `toolkit update --dry-run` | Preview what would change |
| `toolkit update --check` | Report whether the current project needs an update |
| `toolkit sync` | Update all registered projects at once |
| `toolkit sync --check` | Report which registered projects need sync |
| `toolkit sync --pull-first` | Pull latest toolkit first, then sync all projects |
| `toolkit diff` | Compare core project-owned files against the latest templates |
| `toolkit adr "Title"` | Create an Architecture Decision Record |
| `toolkit adr list` | List project ADRs |
| `toolkit list` | Show registered projects |
| `toolkit status` | Dashboard of registered project health |
| `toolkit version` | Show installed version and install method |
| `toolkit changelog [N]` | Show the last N GitHub releases |
| `toolkit doctor` | Health check — version, tools, project staleness |

## How it works

### What you get in each project

When you run `toolkit new`, these files get created in your project:

**Project-owned** (yours to customize, never auto-updated):
- `CLAUDE.md` — AI coding instructions with `{{PLACEHOLDERS}}` to fill in
- `AGENTS.md` — AI reviewer rubric with project-specific priorities
- `.codex-review.toml` — AI review hook config (reviewers, modes, safe/unsafe paths)
- `.toolkit-config` — Project profile and optional lint/test/build command overrides
- `.pre-commit-config.yaml` — Pre-commit hooks including the default-branch AI review gate
- `.gitignore` — Sensible defaults
- `.github/pull_request_template.md` — PR checklist
- `setup.sh` — One-command setup for dev tools, hooks, and project dependencies

**Toolkit-owned** (auto-updated when you run `toolkit update` or `toolkit sync`):
- `.toolkit-version` — The toolkit revision this project has applied
- `.toolkit-manifest` — The visible list of toolkit-managed paths
- `principles/*.md` — Universal engineering principles
- `scripts/codex-review.sh` — AI merge/default-branch review + auto-fix loop
- `scripts/toolkit-run.sh` — Profile-aware runner for Node/TypeScript, Swift, Rust, Python, Go, and monorepos
- `scripts/open-pr.sh` — Push + create PR via `gh`
- `scripts/merge-pr.sh` — AI review + squash-merge + sync main
- `scripts/cleanup-branches.sh` — Safe branch hygiene
- `scripts/run-pytest-in-venv.sh` — Legacy Python helper copied for Python profiles

`setup.sh` installs dependencies for the detected project profile. It supports Node package managers, SwiftPM, Cargo, Go modules, and Python `requirements.txt`/`uv.lock`/`pyproject.toml` at the repo root and under `agent/`. `toolkit run validate` uses `.toolkit-config` to run profile-aware lint/typecheck/test commands.

### Keeping projects up to date

When you improve the toolkit (add a principle, fix a script), run:

```bash
toolkit sync
```

This updates toolkit-owned files across registered projects by creating reviewable update branches and commits. For one project, run `toolkit update --dry-run` to preview, `toolkit update --check` to check staleness, and `toolkit update` from a clean git worktree to create a `chore/toolkit-*` branch with the update committed. Project-owned files are never touched by `toolkit update`; use `toolkit diff` to review the core project-owned files against the latest templates.

Projects are auto-registered in `~/.toolkit-projects` when you bootstrap them.

### Auto-update

The `toolkit` CLI checks for new versions hourly. When a newer release exists, it upgrades with `brew upgrade toolkit` for Homebrew installs or `git pull --rebase` for git-clone installs before running your command. Disable with `TOOLKIT_NO_AUTO_UPDATE=1`.

## What's included

### Principles

Universal engineering standards, extracted and battle-tested from production systems:

- **[engineering-principles.md](principles/engineering-principles.md)** — No band-aids, no silent failures, every fix gets a test, think in invariants, derive don't persist, one code path, audit weak-point classes
- **[pre-implementation-checklist.md](principles/pre-implementation-checklist.md)** — 4 questions to answer before writing any code
- **[audit-weak-points.md](principles/audit-weak-points.md)** — Methodology: find one bug → audit the whole class → ranked fix → guardrail test
- **[documentation-ownership.md](principles/documentation-ownership.md)** — Single canonical owner per volatile fact
- **[git-workflow.md](principles/git-workflow.md)** — Feature branch → PR → AI merge review → squash merge

### AI Review Gate

Automatically reviews code before it reaches the default branch:
- Uses the configured reviewer cascade: Codex by default, with optional Claude and Gemini reviewers
- Auto-fixes safe issues when the review mode allows edits
- Lets the primary reviewer request one focused peer second opinion when `[review.assist]` is enabled
- Blocks the merge or direct default-branch push for findings that should not be auto-fixed
- Runs from `scripts/merge-pr.sh`, and from the pre-push hook only when pushing directly to the default branch
- Loops up to N times, gracefully skips when no configured reviewer is available

Configure per-project behavior in `.codex-review.toml`. Write your review rubric in `AGENTS.md`. See [hooks/README.md](hooks/README.md) for reviewer modes, peer assistance, caching, and fail-open behavior.

### Helper scripts

- **open-pr.sh** — `git push` + `gh pr create` with your PR template. Idempotent.
- **merge-pr.sh** — Sanity-check mergeability + AI review + squash-merge + delete branch + sync main.
- **cleanup-branches.sh** — Dry-run by default. Never deletes unmerged work.

## Project structure

```
toolkit/
├── bin/             # toolkit CLI entrypoint
├── lib/             # shared libraries
├── principles/      # universal engineering docs
├── templates/       # starter files for new projects
├── hooks/           # AI review hook
├── scripts/         # helper scripts (open-pr, merge-pr, cleanup)
├── bootstrap/       # new-project.sh, update-project.sh, sync-all.sh
└── tests/           # self-tests
```

## For contributors / friends

Install, bootstrap a project, and start using the principles and scripts. If you have ideas for new principles or improvements to the scripts, PRs welcome.

## License

MIT
