```text
 _____                _         _
|_   _|__  _   _  ___| |__  ___| |_ ___  _ __   ___
  | |/ _ \| | | |/ __| '_ \/ __| __/ _ \| '_ \ / _ \
  | | (_) | |_| | (__| | | \__ \ || (_) | | | |  __/
  |_|\___/ \__,_|\___|_| |_|___/\__\___/|_| |_|\___|
```

[![Release](https://img.shields.io/github/v/release/autumngarage/touchstone?label=release&color=informational)](https://github.com/autumngarage/touchstone/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Homebrew](https://img.shields.io/badge/brew-autumngarage%2Ftouchstone-orange)](https://github.com/autumngarage/homebrew-touchstone)

> **Scaffolding + pre-push AI review for AI-assisted projects.**
>
> *The ground* of the **[Autumn Garage](https://github.com/autumngarage/autumn-garage)** quartet, alongside [Cortex](https://github.com/autumngarage/cortex) · [Sentinel](https://github.com/autumngarage/sentinel) · [Conductor](https://github.com/autumngarage/conductor).

# Touchstone

Touchstone is a command-line starter kit for AI-assisted projects. It scaffolds a project folder with the same useful files every time, keeps those shared files up to date across projects without copy-paste, and runs an AI review gate before changes reach your default branch.

What you get:

- Starter instructions for Claude, Codex, and Gemini-style coding assistants
- A review rubric so AI reviewers know what matters in your project
- Helper scripts for opening PRs, merging PRs, cleaning branches, and running checks
- A single setup command for dev tools, Git safety hooks, and project dependencies
- Optional AI review on every PR and direct-to-default-branch push, via [Conductor](https://github.com/autumngarage/conductor)

You do not need to understand the internals to use it — install, run `touchstone new` or `touchstone init`, and follow the next steps printed in your terminal.

## Install

```bash
brew install autumngarage/touchstone/touchstone
```

Requires `git` and `gh` (Homebrew installs them as dependencies). If `brew` is missing, install Homebrew from [brew.sh](https://brew.sh) first.

Check it worked:

```bash
touchstone version
```

## Quickstart

Create a new project:

```bash
touchstone new ~/Repos/my-new-project
cd ~/Repos/my-new-project
bash setup.sh
```

Then open `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` and fill in the placeholders — these steer Claude Code, Codex/AGENTS.md-native tools, and Gemini CLI respectively, and contain the AI review rubric.

Add Touchstone to an existing project:

```bash
cd ~/Repos/my-existing-project
touchstone init
```

## Turn on AI review

Touchstone delegates all LLM access to [Conductor](https://github.com/autumngarage/conductor). Install it once and every Touchstone-protected repo shares the same provider auth:

```bash
brew install autumngarage/conductor/conductor
conductor init   # walks through each provider, one at a time
```

When you run `touchstone new` or `touchstone init`, Touchstone asks whether you want AI review. If you say yes, the scaffold adds a `[review.conductor]` block with `prefer = "best"` and `effort = "high"` — frontier-tier review with a bounded reasoning budget. Per-push overrides:

```bash
# Pin a specific provider for one push
TOUCHSTONE_CONDUCTOR_WITH=claude git push

# Cheaper preference for this push
TOUCHSTONE_CONDUCTOR_PREFER=cheapest git push

# Maximum-effort scrutiny for release-level pushes
TOUCHSTONE_CONDUCTOR_EFFORT=max git push
```

Full config reference: [`hooks/conductor-review.config.example.toml`](hooks/conductor-review.config.example.toml). Legacy `.codex-review.toml` files still work; new projects use `.touchstone-review.toml`.

You can keep using Touchstone without Conductor installed — the hook skips itself gracefully and prints install instructions.

## Everyday commands

```bash
# Run the project's normal checks
touchstone run validate

# See whether this project needs newer Touchstone files
touchstone update --check

# Create a branch + commit with the Touchstone update
touchstone update

# Update all registered projects
touchstone update-all

# Re-run dependency setup later without reinstalling hooks/tools
bash setup.sh --deps-only
```

## Commands

| Command | What it does |
|---------|-------------|
| `touchstone new <dir>` | Bootstrap a new project with principles, scripts, hooks, and templates |
| `touchstone new <dir> --type node` | Bootstrap with an explicit Node/TypeScript, Swift, Rust, Go, Python, or generic profile |
| `touchstone new <dir> --no-ai-review` | Bootstrap with AI review disabled |
| `touchstone new <dir> --gitbutler` | Bootstrap with optional GitButler workflow setup |
| `touchstone new <dir> --ci github` | Bootstrap with the GitHub Actions validate workflow |
| `touchstone new <dir> --scaffold-tests` | Bootstrap with a placeholder smoke test (Python, Node, Go) |
| `touchstone init [--no-setup]` | Add Touchstone to the current project |
| `touchstone init --reviewer claude` | Pin Conductor to a specific underlying provider (codex / claude / gemini / openrouter / local) |
| `touchstone init --review-routing all-local` | Use offline Ollama review instead of hosted Conductor review |
| `touchstone init --no-ai-review` | Add Touchstone with AI review disabled |
| `touchstone migrate-from-toolkit` | Migrate a project from the legacy `.toolkit-*` files before re-running `touchstone init` |
| `touchstone detect` | Show the detected project profile for the current repo |
| `touchstone run <task>` | Run profile-aware `lint`, `typecheck`, `build`, `test`, or `validate` |
| `touchstone update` | Create a branch and commit that updates the current project's Touchstone-owned files |
| `touchstone update --in-place` | Commit the update on the current branch instead of a chore branch |
| `touchstone update --dry-run` | Preview what would change |
| `touchstone update --check` | Report whether the current project needs an update |
| `touchstone update --ship` | Push, open a PR, run the final AI review, and auto-merge when clean |
| `touchstone update-all` | Update all registered projects at once |
| `touchstone update-all --check` | Report which registered projects need update |
| `touchstone diff` | Compare core project-owned files against the latest templates |
| `touchstone adr "Title"` | Create an Architecture Decision Record |
| `touchstone list` | Show registered projects |
| `touchstone status` | Dashboard of registered project health |
| `touchstone version` | Show installed version and install method |
| `touchstone changelog [N]` | Show the last N GitHub releases |
| `touchstone doctor` | Health check — version, tools, project staleness |
| `touchstone review [--dry-run]` | Run the Conductor review without pushing, or preview routing |
| `touchstone review-stats` | Report Conductor-review fail-open trends from the local review log |
| `touchstone skills` | List Claude Code skills visible to the current repo and user |
| `touchstone release [--major\|--minor\|--patch]` | Cut a Touchstone release (maintainers only) |

## How it works

### Files in each project

When you run `touchstone new`, these files are created:

**Project-owned** (yours to customize, never auto-updated):
- `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` — agent instructions plus the AI review rubric, with `{{PLACEHOLDERS}}` to fill in
- `.touchstone-review.toml` — Conductor review config (reviewers, modes, safe/unsafe paths)
- `.touchstone-config` — Project profile, workflow choices, optional lint/test/build overrides
- `.pre-commit-config.yaml` — Pre-commit hooks including fast branch checks and direct default-branch guardrails
- `.gitignore` — Sensible defaults
- `.github/pull_request_template.md` — PR checklist
- `setup.sh` — One-command setup for dev tools, hooks, and project dependencies

**Touchstone-owned** (auto-updated when you run `touchstone update` or `touchstone update-all`):
- `.touchstone-version`, `.touchstone-manifest` — applied revision and managed-paths list
- `principles/*.md` — Universal engineering principles
- `scripts/conductor-review.sh`, `scripts/codex-review.sh` — AI merge/default-branch review + auto-fix loop (legacy alias preserved)
- `scripts/touchstone-run.sh` — Profile-aware runner for Node/TypeScript, Swift, Rust, Python, Go, and monorepos
- `scripts/open-pr.sh`, `scripts/merge-pr.sh`, `scripts/cleanup-branches.sh` — PR + branch hygiene helpers

### What the gates enforce

Touchstone enforces a test **runner**, not a test **suite**. The pre-push hook invokes `scripts/touchstone-run.sh validate`, which dispatches lint/typecheck/build/test per profile — but every profile silently skips when the underlying tool or test file is absent (fresh scaffolds shouldn't reject pushes just because the first test hasn't been written yet).

`touchstone doctor` is where those gaps become visible. It reports per-profile test presence, profile-specific linter availability, pre-push hook integrity, and unknown profile values. Use `touchstone init --scaffold-tests` to seed a placeholder smoke test and `touchstone init --ci github` to add a GitHub Actions workflow that runs the same `validate` path CI-side.

### Auto-update

The `touchstone` CLI checks for new versions hourly. When a newer release exists, it upgrades with `brew upgrade touchstone` (Homebrew installs) or `git pull --rebase` (git-clone installs) before running your command. Disable with `TOUCHSTONE_NO_AUTO_UPDATE=1`.

### Principles

Universal engineering standards, battle-tested from production systems:

- **[engineering-principles.md](principles/engineering-principles.md)** — No band-aids, narrow interfaces, no silent failures, every fix gets a test, derive don't persist, one code path, audit weak-point classes
- **[pre-implementation-checklist.md](principles/pre-implementation-checklist.md)** — Pre-flight questions that route back to the canonical principles
- **[audit-weak-points.md](principles/audit-weak-points.md)** — Methodology: find one bug → audit the whole class → ranked fix → guardrail test
- **[ai-delivery-architecture.md](principles/ai-delivery-architecture.md)** — Human request → driver AI → PR → deterministic checks → Conductor review/fix → merge
- **[git-workflow.md](principles/git-workflow.md)** — Feature branch → PR → merge gate → squash merge

### AI review gate

Reviews code before it reaches the default branch. All LLM access routes through [Conductor](https://github.com/autumngarage/conductor):

- One reviewer — `conductor` — uses Conductor's semantic review path for read-only review with hosted fallback.
- Quality-tier-aware routing (`prefer = "best"` picks the frontier-tier provider).
- Per-push env-var preferences: `TOUCHSTONE_CONDUCTOR_WITH`, `TOUCHSTONE_CONDUCTOR_PREFER`, `TOUCHSTONE_CONDUCTOR_EFFORT`.
- Size-based routing — small diffs can use `prefer = "cheapest"`, large diffs use `prefer = "best"` + max effort — via `[review.routing]`.
- Graceful fallback: on 5xx / rate-limit / timeout, Conductor tries the next code-review provider.
- Auto-fixes safe issues through a second edit-capable pass after read-only review.
- Blocks the merge or direct default-branch push for findings that should not be auto-fixed.
- Runs from `scripts/merge-pr.sh`, and from the pre-push hook only when pushing directly to the default branch.

Configure per-project behavior in `.touchstone-review.toml`. See [hooks/README.md](hooks/README.md) for reviewer modes, caching, and fail-open behavior.

## The quartet

Touchstone is the ground every other tool sits on:

- **Touchstone** *(this tool)* — scaffolding + pre-push AI review gate. *The ground.*
- **[Cortex](https://github.com/autumngarage/cortex)** — portable file-format protocol for project memory. *The spine.*
- **[Sentinel](https://github.com/autumngarage/sentinel)** — autonomous assess→plan→delegate→review loop. *The hands.*
- **[Conductor](https://github.com/autumngarage/conductor)** — capability-aware router across LLM providers. *The voice.*

Each tool installs independently and composes through **file contracts, never code imports**. Together they form the workflow this tool was designed to fit into. See [autumn-garage](https://github.com/autumngarage/autumn-garage) for the coordination repo.

## Status

Production-ready and shipped via Homebrew. Latest release: [GitHub Releases](https://github.com/autumngarage/touchstone/releases). Run `touchstone version` to see the installed build and install method.

## Documentation

- [`docs/`](docs/) — design docs, ADRs, and audits
- [`hooks/README.md`](hooks/README.md) — AI review hook reference
- [`principles/`](principles/) — the engineering principles shipped to every Touchstone project
- [GitHub Releases](https://github.com/autumngarage/touchstone/releases) — release notes for every version

## Contributing

Install Touchstone, bootstrap a project, and open a PR for improvements to principles, templates, scripts, hooks, or skills.

## License

MIT
