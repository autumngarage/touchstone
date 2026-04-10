# toolkit

Private engineering toolkit — universal principles, reusable scripts, and a Codex pre-push review hook for all projects.

## What this is

A single source of truth for engineering standards and tooling that can be bootstrapped into any project. After bootstrap, each project is self-contained — no runtime dependency on this repo.

## Install

```bash
# Clone once per machine
gh repo clone henrymodisett/toolkit ~/Repos/toolkit
```

## Usage

### New project

```bash
~/Repos/toolkit/bootstrap/new-project.sh my-new-project
```

This copies templates, principles, hooks, and scripts into the new project directory. Fill in the `{{PLACEHOLDERS}}` in `CLAUDE.md` and `AGENTS.md` with project-specific context.

### Update an existing project

```bash
cd ~/Repos/my-existing-project
~/Repos/toolkit/bootstrap/update-project.sh
```

Updates toolkit-owned files (principles, scripts, hooks). Never touches project-owned files (CLAUDE.md, AGENTS.md, .codex-review.toml). Creates `.bak` backups of any locally-modified toolkit files before overwriting.

### Update all projects at once

```bash
~/Repos/toolkit/bootstrap/sync-all.sh --pull-first
```

Pulls the latest toolkit, then runs `update-project.sh` on every project registered in `~/.toolkit-projects`. Projects are auto-registered when you bootstrap them.

For fully automated sync (e.g., every Monday at 9am):

```bash
crontab -e
# Add:
0 9 * * 1  cd ~/Repos/toolkit && git pull && ~/Repos/toolkit/bootstrap/sync-all.sh
```

### Update the toolkit itself

```bash
cd ~/Repos/toolkit && git pull
```

## What's included

### Principles (`principles/`)

Universal engineering principles extracted and generalized from production systems. These get copied into each project so `CLAUDE.md` can reference them via `@principles/*.md`.

- **engineering-principles.md** — Hard requirements: no band-aids, no silent failures, every fix gets a test, think in invariants, derive don't persist
- **pre-implementation-checklist.md** — 4 questions to answer before writing code
- **audit-weak-points.md** — Methodology for auditing structural bug patterns across a codebase
- **documentation-ownership.md** — Single canonical owner per volatile fact
- **git-workflow.md** — Feature branch lifecycle with pre-push review

### Templates (`templates/`)

Starter files for new projects with placeholders for project-specific context.

- **CLAUDE.md** — Thin starter that imports principles and provides structure for project context
- **AGENTS.md** — AI reviewer rubric skeleton
- **pull_request_template.md** — PR checklist
- **pre-commit-config.yaml** — Pre-commit hooks including Codex review
- **gitignore** — Sensible defaults

### Hooks (`hooks/`)

- **codex-review.sh** — Pre-push Codex review + auto-fix loop. Configurable via `.codex-review.toml` in the project root. Gracefully skips if Codex CLI isn't installed.

### Scripts (`scripts/`)

- **open-pr.sh** — Push + create PR via `gh`. Idempotent.
- **merge-pr.sh** — Sanity-check + squash-merge + sync main.
- **cleanup-branches.sh** — Safe branch cleanup with dry-run default.

## Project structure

```
toolkit/
├── principles/          # Universal engineering docs
├── templates/           # Starter files for new projects
├── hooks/               # Reusable git hooks
├── scripts/             # Reusable helper scripts
├── bootstrap/           # new-project.sh + update-project.sh
└── tests/               # Self-tests
```

## Future: Homebrew distribution

Once the content stabilizes, this will be packaged as a private Homebrew tap for `brew install toolkit` convenience. The current `gh clone` + scripts approach is intentional for the iteration phase.
