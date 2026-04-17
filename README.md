```text
 _               _       _
| |_ ___ _  _ __| |_  __| |_ ___ _ _  ___
|  _/ _ \ || / _| ' \(_-<  _/ _ \ ' \/ -_)
 \__\___/\_,_\__|_||_/__/\__\___/_||_\___|
```

# Touchstone

Touchstone is a command-line starter kit for AI-assisted projects. It helps you start a project folder, add the same useful project files every time, and keep those shared files updated later without copy-pasting between projects.

It gives you:
- starter instructions for Claude, Codex, and other AI coding tools
- review rules so AI reviewers know what matters in your project
- helper scripts for opening pull requests (PRs), merging PRs, cleaning branches, and running checks
- a single setup command for dev tools, Git safety checks, and project dependencies
- optional AI review before changes get merged into your main branch

You do not need to understand the internals to use it. Install it, run `touchstone new` or `touchstone init`, then follow the next steps printed in your terminal.

## Install

Run this once in Terminal. This uses Homebrew, the Mac package manager. If `brew` is not found, install Homebrew first from https://brew.sh.

```bash
brew tap autumngarage/touchstone
brew install touchstone
```

Requires `git` and `gh`, the GitHub command-line tool. Homebrew installs them automatically as dependencies.

Check that it worked:

```bash
touchstone version
```

## Start Here

### Create a new project

```bash
touchstone new ~/Repos/my-new-project
cd ~/Repos/my-new-project
bash setup.sh
```

Then open `CLAUDE.md` and `AGENTS.md` in your editor and fill in the placeholders. These files tell AI coding tools what your project is, what matters, and what to be careful with.

### Add touchstone to an existing project

```bash
cd ~/Repos/my-existing-project
touchstone init
```

If you want setup to happen later:

```bash
touchstone init --no-setup
bash setup.sh
```

### Turn on AI review

When you run `touchstone new` or `touchstone init`, Touchstone asks whether you want AI review and how it should be routed. You can choose a hosted reviewer for every change, a local model for every change, a hybrid setup where small diffs go local and larger diffs go to a hosted reviewer, or no AI review.

If you choose Codex and it is not installed yet:

```bash
npm install -g @openai/codex && codex login
```

For local models, choose `local` during the interactive setup and enter a command that reads the review prompt from stdin, such as an Ollama or LM Studio wrapper. For scripted setup, pass `--local-review-command '<command>'` with `--reviewer local`. You can keep using Touchstone without any AI reviewer; the hook skips itself when review is disabled or no configured reviewer is available.

For a hybrid setup, use `small-local`: small changes try your local model first, with a hosted fallback; larger changes go straight to the hosted reviewer.

Useful shortcuts:

```bash
# Add Touchstone with AI review disabled
touchstone init --no-ai-review

# Add Touchstone and use a local reviewer command
touchstone init --reviewer local --local-review-command 'ollama run MODEL'

# Use local review for small changes and Codex for larger changes
touchstone init --review-routing small-local --reviewer codex --local-review-command 'ollama run MODEL'
```

### Choose a Git workflow

Touchstone defaults to plain Git because it is the simplest path for new projects. During interactive setup, you can also choose GitButler if you want stacked branches, parallel work, undo history, and AI-agent savepoints.

If you choose GitButler, `setup.sh` checks for the `but` CLI, shows the official installer command if it is missing, and asks before running `but setup` or adding the GitButler MCP server to Claude Code.

## Everyday Commands

```bash
# Run the project's normal checks
touchstone run validate

# See whether this project needs newer Touchstone files
touchstone update --check

# Create a branch + commit with the Touchstone update
touchstone update

# See all registered projects
touchstone status

# Re-run dependency setup later without reinstalling hooks/tools
bash setup.sh --deps-only
```

## Commands

| Command | What it does |
|---------|-------------|
| `touchstone init [--no-setup]` | Add touchstone to the current project |
| `touchstone init --reviewer local --local-review-command '<command>'` | Add touchstone with a local reviewer command |
| `touchstone init --review-routing small-local --reviewer codex --local-review-command '<command>'` | Use local review for small diffs and a hosted reviewer for larger diffs |
| `touchstone init --no-ai-review` | Add touchstone with AI review disabled |
| `touchstone init --gitbutler` | Add touchstone with optional GitButler workflow setup |
| `touchstone new <dir>` | Bootstrap a new project with principles, scripts, hooks, and templates |
| `touchstone new <dir> --type node` | Bootstrap with an explicit Node/TypeScript, Swift, Rust, Go, Python, or generic profile |
| `touchstone new <dir> --reviewer local --local-review-command '<command>'` | Bootstrap a new project with a local reviewer command |
| `touchstone new <dir> --review-routing small-local --reviewer codex --local-review-command '<command>'` | Bootstrap with hybrid local/hosted review routing |
| `touchstone new <dir> --no-ai-review` | Bootstrap a new project with AI review disabled |
| `touchstone new <dir> --gitbutler` | Bootstrap with optional GitButler workflow setup |
| `touchstone detect` | Show the detected project profile for the current repo |
| `touchstone run <task>` | Run profile-aware `lint`, `typecheck`, `build`, `test`, or `validate` |
| `touchstone update` | Create a branch and commit that updates the current project's touchstone-owned files |
| `touchstone update --dry-run` | Preview what would change |
| `touchstone update --check` | Report whether the current project needs an update |
| `touchstone sync` | Update all registered projects at once |
| `touchstone sync --check` | Report which registered projects need sync |
| `touchstone sync --pull-first` | Pull latest touchstone first, then sync all projects |
| `touchstone diff` | Compare core project-owned files against the latest templates |
| `touchstone adr "Title"` | Create an Architecture Decision Record |
| `touchstone adr list` | List project ADRs |
| `touchstone list` | Show registered projects |
| `touchstone unregister <name>` | Remove a project from the registry |
| `touchstone status` | Dashboard of registered project health |
| `touchstone version` | Show installed version and install method |
| `touchstone changelog [N]` | Show the last N GitHub releases |
| `touchstone doctor` | Health check — version, tools, project staleness |
| `touchstone skills` | List Claude Code skills visible to the current repo and user |
| `touchstone skills check` | Validate Claude Code skill frontmatter |
| `touchstone release [--patch]` | Cut a Touchstone release; maintainers only |

## How it works

### What you get in each project

When you run `touchstone new`, these files get created in your project:

**Project-owned** (yours to customize, never auto-updated):
- `CLAUDE.md` — AI coding instructions with `{{PLACEHOLDERS}}` to fill in
- `AGENTS.md` — AI reviewer rubric with project-specific priorities
- `.codex-review.toml` — AI review hook config (reviewers, modes, safe/unsafe paths)
- `.touchstone-config` — Project profile, workflow choices, and optional lint/test/build command overrides
- `.pre-commit-config.yaml` — Pre-commit hooks including the default-branch AI review gate
- `.gitignore` — Sensible defaults
- `.github/pull_request_template.md` — PR checklist
- `setup.sh` — One-command setup for dev tools, hooks, and project dependencies

**Touchstone-owned** (auto-updated when you run `touchstone update` or `touchstone sync`):
- `.touchstone-version` — The touchstone revision this project has applied
- `.touchstone-manifest` — The visible list of touchstone-managed paths
- `principles/*.md` — Universal engineering principles
- `scripts/codex-review.sh` — AI merge/default-branch review + auto-fix loop
- `scripts/touchstone-run.sh` — Profile-aware runner for Node/TypeScript, Swift, Rust, Python, Go, and monorepos
- `scripts/open-pr.sh` — Push + create PR via `gh`
- `scripts/merge-pr.sh` — AI review + squash-merge + sync main
- `scripts/cleanup-branches.sh` — Safe branch hygiene
- `scripts/run-pytest-in-venv.sh` — Legacy Python helper copied for Python profiles

`setup.sh` installs dependencies for the detected project profile. It supports Node package managers, SwiftPM, Cargo, Go modules, and Python `requirements.txt`/`uv.lock`/`pyproject.toml` at the repo root and under `agent/`. `touchstone run validate` uses `.touchstone-config` to run profile-aware lint/typecheck/test commands.

### Keeping projects up to date

When you improve Touchstone (add a principle, fix a script), run:

```bash
touchstone sync
```

This updates touchstone-owned files across registered projects by creating reviewable update branches and commits. For one project, run `touchstone update --dry-run` to preview, `touchstone update --check` to check staleness, and `touchstone update` from a clean git worktree to create a `chore/touchstone-*` branch with the update committed. Project-owned files are never touched by `touchstone update`; use `touchstone diff` to review the core project-owned files against the latest templates.

Projects are auto-registered in `~/.touchstone-projects` when you bootstrap them.

### Auto-update

The `touchstone` CLI checks for new versions hourly. When a newer release exists, it upgrades with `brew upgrade touchstone` for Homebrew installs or `git pull --rebase` for git-clone installs before running your command. Disable with `TOUCHSTONE_NO_AUTO_UPDATE=1`.

## What's included

### Principles

Universal engineering standards, extracted and battle-tested from production systems:

- **[engineering-principles.md](principles/engineering-principles.md)** — No band-aids, narrow interfaces, no silent failures, every fix gets a test, derive don't persist, one code path, version data boundaries, separate behavior from tidying, recoverable irreversibles, compatibility at boundaries, audit weak-point classes
- **[pre-implementation-checklist.md](principles/pre-implementation-checklist.md)** — Pre-flight questions that route back to the canonical principles
- **[audit-weak-points.md](principles/audit-weak-points.md)** — Methodology: find one bug → audit the whole class → ranked fix → guardrail test
- **[documentation-ownership.md](principles/documentation-ownership.md)** — Single canonical owner per volatile fact
- **[git-workflow.md](principles/git-workflow.md)** — Feature branch → PR → AI merge review → squash merge

### AI Review Gate

Automatically reviews code before it reaches the default branch:
- Uses the configured reviewer cascade: Codex by default, with optional Claude and Gemini reviewers
- Can use a local model through `[review.local].command`
- Can route small diffs to a local model and larger diffs to a hosted reviewer through `[review.routing]`
- Auto-fixes safe issues when the review mode allows edits
- Lets the primary reviewer request one focused peer second opinion when `[review.assist]` is enabled
- Blocks the merge or direct default-branch push for findings that should not be auto-fixed
- Runs from `scripts/merge-pr.sh`, and from the pre-push hook only when pushing directly to the default branch
- Loops up to N times, gracefully skips when no configured reviewer is available

Configure per-project behavior in `.codex-review.toml`. Write your review rubric in `AGENTS.md`. See [hooks/README.md](hooks/README.md) for reviewer modes, peer assistance, caching, and fail-open behavior.

### Claude Code Skills

Touchstone owns Claude Code project skills under `.claude/skills/` for Touchstone maintenance work. These are part of this repo, not files that Touchstone copies into every downstream project:
- `touchstone-audit` — audits Touchstone itself against its principles and current AI-tooling practices.
- `memory-audit` — checks Claude Code memory for stale commands, dead paths, duplicate facts, and unsourced volatile guidance.

Run `touchstone skills` to list visible project and user skills, and `touchstone skills check` to validate their frontmatter.

### Helper scripts

- **open-pr.sh** — `git push` + `gh pr create` with your PR template. Idempotent.
- **merge-pr.sh** — Sanity-check mergeability + AI review + squash-merge + delete branch + sync main.
- **cleanup-branches.sh** — Dry-run by default. Never deletes unmerged work.

## Project structure

```
touchstone/
├── .claude/        # Claude Code project skills for Touchstone maintenance
├── bin/             # touchstone CLI entrypoint
├── lib/             # shared libraries
├── principles/      # universal engineering docs
├── templates/       # starter files for new projects
├── hooks/           # AI review hook
├── scripts/         # helper scripts (open-pr, merge-pr, cleanup)
├── bootstrap/       # new-project.sh, update-project.sh, sync-all.sh
└── tests/           # self-tests
```

## Contributors

Install Touchstone, bootstrap a project, and open a PR for improvements to principles, templates, scripts, hooks, or skills.

## License

MIT
