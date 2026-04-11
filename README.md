# toolkit

Shared engineering toolkit — universal principles, reusable scripts, and a Codex pre-push review hook for all your projects.

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

# Set up pre-commit hooks (optional but recommended)
cd ~/Repos/my-new-project
brew install pre-commit
pre-commit install --install-hooks

# Set up Codex pre-push review (optional)
npm install -g @openai/codex && codex login

# Re-run dependency setup later without reinstalling hooks/tools
bash setup.sh --deps-only
```

## Commands

| Command | What it does |
|---------|-------------|
| `toolkit new <dir>` | Bootstrap a new project with principles, scripts, hooks, and templates |
| `toolkit update` | Update the current project's toolkit-owned files to latest |
| `toolkit update --dry-run` | Preview what would change |
| `toolkit sync` | Update all registered projects at once |
| `toolkit sync --pull-first` | Pull latest toolkit first, then sync all projects |
| `toolkit version` | Show installed version and install method |
| `toolkit doctor` | Health check — version, tools, project staleness |

## How it works

### What you get in each project

When you run `toolkit new`, these files get copied into your project:

**Project-owned** (yours to customize, never auto-updated):
- `CLAUDE.md` — AI coding instructions with `{{PLACEHOLDERS}}` to fill in
- `AGENTS.md` — AI reviewer rubric with project-specific priorities
- `.codex-review.toml` — Codex hook config (safe/unsafe paths for auto-fix)
- `.pre-commit-config.yaml` — Pre-commit hooks including Codex review
- `.gitignore` — Sensible defaults
- `.github/pull_request_template.md` — PR checklist

**Toolkit-owned** (auto-updated when you run `toolkit update` or `toolkit sync`):
- `principles/*.md` — Universal engineering principles
- `scripts/codex-review.sh` — Codex pre-push review + auto-fix loop
- `scripts/open-pr.sh` — Push + create PR via `gh`
- `scripts/merge-pr.sh` — Squash-merge + sync main
- `scripts/cleanup-branches.sh` — Safe branch hygiene
- `scripts/run-pytest-in-venv.sh` — Run pytest through `.venv` or `agent/.venv`

`setup.sh` installs Python dependencies into project virtualenvs. It supports `requirements.txt`, `uv.lock`, and `pyproject.toml` at the repo root and under `agent/`.

### Keeping projects up to date

When you improve the toolkit (add a principle, fix a script), run:

```bash
toolkit sync
```

This updates all toolkit-owned files across every registered project. Project-owned files are never touched — you get a hint to review them against the latest templates.

Projects are auto-registered in `~/.toolkit-projects` when you bootstrap them.

### Auto-update

The `toolkit` CLI checks for new versions hourly. When a newer release exists, it auto-upgrades via `brew upgrade toolkit` before running your command. Disable with `TOOLKIT_NO_AUTO_UPDATE=1`.

## What's included

### Principles

Universal engineering standards, extracted and battle-tested from production systems:

- **[engineering-principles.md](principles/engineering-principles.md)** — No band-aids, no silent failures, every fix gets a test, think in invariants, derive don't persist, one code path, audit weak-point classes
- **[pre-implementation-checklist.md](principles/pre-implementation-checklist.md)** — 4 questions to answer before writing any code
- **[audit-weak-points.md](principles/audit-weak-points.md)** — Methodology: find one bug → audit the whole class → ranked fix → guardrail test
- **[documentation-ownership.md](principles/documentation-ownership.md)** — Single canonical owner per volatile fact
- **[git-workflow.md](principles/git-workflow.md)** — Feature branch → pre-push review → PR → squash merge

### Codex pre-push hook

Automatically reviews your code before every `git push`:
- Runs `codex exec --full-auto` against your diff
- Auto-fixes safe issues (typos, missing error logging)
- Blocks the push for unsafe findings (high-scrutiny paths you configure)
- Loops up to N times, gracefully skips if Codex isn't installed

Configure per-project behavior in `.codex-review.toml`. Write your review rubric in `AGENTS.md`. See [hooks/README.md](hooks/README.md) for details.

### Helper scripts

- **open-pr.sh** — `git push` + `gh pr create` with your PR template. Idempotent.
- **merge-pr.sh** — Sanity-check mergeability + squash-merge + delete branch + sync main.
- **cleanup-branches.sh** — Dry-run by default. Never deletes unmerged work.

## Project structure

```
toolkit/
├── bin/             # toolkit CLI entrypoint
├── lib/             # shared libraries (auto-update)
├── principles/      # universal engineering docs
├── templates/       # starter files for new projects
├── hooks/           # Codex pre-push hook
├── scripts/         # helper scripts (open-pr, merge-pr, cleanup)
├── bootstrap/       # new-project.sh, update-project.sh, sync-all.sh
└── tests/           # self-tests
```

## For contributors / friends

Install, bootstrap a project, and start using the principles and scripts. If you have ideas for new principles or improvements to the scripts, PRs welcome.

## License

MIT
