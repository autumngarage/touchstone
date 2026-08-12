```text
 _____                _         _
|_   _|__  _   _  ___| |__  ___| |_ ___  _ __   ___
  | |/ _ \| | | |/ __| '_ \/ __| __/ _ \| '_ \ / _ \
  | | (_) | |_| | (__| | | \__ \ || (_) | | | |  __/
  |_|\___/ \__,_|\___|_| |_|___/\__\___/|_| |_|\___|
```

> *Scaffolding + PR-visible agentic review for AI-assisted projects.*
>
> by **[Autumn Garage](https://github.com/autumngarage/autumn-garage)** · alongside [Cortex](https://github.com/autumngarage/cortex) · [Sentinel](https://github.com/autumngarage/sentinel) · [Alchemist](https://github.com/autumngarage/alchemist) — issue-driven transmuter — open issue in, reviewed PR out.

# Touchstone

**Touchstone makes sure AI-written code actually gets reviewed and tested before it lands — in any project you install it into.**

It does not review your code; GitHub and whatever reviewer you have configured do that. Touchstone is what makes the loop close: it stops the agent committing to your default branch, runs your local tests before anything merges, and refuses to merge while a review thread is unresolved, a review requests changes, or a required check is failing. Whether the review comes from a hosted AI reviewer, a bot, or a colleague, the rule is the same — respond to every comment, resolve its thread, then merge.

(The enforced signals are GitHub's own: unresolved review threads, the review decision, and required status checks. A comment left somewhere GitHub does not track as a thread — a plain issue comment, say — is not something any tool can verify you answered.)

It also helps you start a project folder, add the same useful project files every time, and keep those shared files updated later without copy-pasting between projects.

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

Then open `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` in your editor and fill in the placeholders. `CLAUDE.md` steers Claude Code. `AGENTS.md` steers Codex and other AGENTS.md-native tools, and also contains the AI review rubric. `GEMINI.md` steers Gemini CLI back to the same workflow.

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

### PR review

Touchstone requests GitHub Codex review automatically for every ready PR head
that enters final shipping. Draft PRs remain review-free coordination surfaces.
The merge helper waits for trusted exact-head review, deterministic preflight,
required checks, and resolved review threads before merging. No local model
router or API key is required. Clean results are persisted on their full
reviewed SHA for fail-closed recovery after a later rebase; see the
[Review Evidence Contract](principles/review-evidence.md).

Routine shipping is one command:

```bash
bash scripts/open-pr.sh --auto-merge
```

It opens the PR, requests review, and merges once the gate passes. If it stops, it names the blocking condition — fix that and run it again.

See [hooks/README.md](hooks/README.md) for the review contract.

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

# Commit the Touchstone update on your current task branch
touchstone update --in-place

# Update all registered projects
touchstone update-all

# Re-run dependency setup later without reinstalling hooks/tools
bash setup.sh --deps-only
```

## Commands

| Command | What it does |
|---------|-------------|
| `touchstone init [--no-setup]` | Add touchstone to the current project |
| `touchstone migrate-from-toolkit` | Migrate a project from the legacy `.toolkit-*` files before re-running `touchstone init` |
| `touchstone init --gitbutler` | Add touchstone with optional GitButler workflow setup |
| `touchstone init --ci github` | Add `.github/workflows/validate.yml` that runs pre-commit hygiene and `touchstone run validate` on every PR |
| `touchstone init --scaffold-tests` | Write one placeholder smoke test for Python, Node, or Go projects (Rust and Swift already ship scaffolds via `cargo init` / `swift package init`) |
| `touchstone new <dir>` | Bootstrap a new project with principles, scripts, hooks, and templates |
| `touchstone new <dir> --type node` | Bootstrap with an explicit Node/TypeScript, Swift, Rust, Go, Python, or generic profile |
| `touchstone new <dir> --gitbutler` | Bootstrap with optional GitButler workflow setup |
| `touchstone new <dir> --ci github` | Bootstrap with the opt-in GitHub Actions validate workflow |
| `touchstone new <dir> --scaffold-tests` | Bootstrap with a placeholder smoke test for Python, Node, or Go projects |
| `touchstone detect` | Show the detected project profile for the current repo |
| `touchstone run <task>` | Run profile-aware `lint`, `typecheck`, `build`, `test`, or `validate` |
| `touchstone update` | Create a branch and commit that updates the current project's touchstone-owned files |
| `touchstone update --in-place` | Commit the update on the current branch instead of creating a chore branch |
| `touchstone update --dry-run` | Preview what would change |
| `touchstone update --check` | Report whether the current project needs an update |
| `touchstone update --ship` | Push, open a PR, run the merge automation, and merge when clean |
| `touchstone update-all` | Update all registered projects at once |
| `touchstone update-all --check` | Report which registered projects need update |
| `touchstone update-all --pull-first` | Pull latest touchstone first, then update all projects |
| `touchstone sync` | Deprecated alias for `touchstone update-all` |
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
| `touchstone release [--major\|--minor\|--patch]` | Cut a Touchstone release; maintainers only |

## How it works

### What you get in each project

When you run `touchstone new`, these files get created in your project:

**Project-owned** (yours to customize, never auto-updated):
- `CLAUDE.md` — Claude Code instructions with `{{PLACEHOLDERS}}` to fill in
- `AGENTS.md` — Codex/agent instructions plus the AI review rubric with project-specific priorities
- `GEMINI.md` — Gemini CLI instructions that point at the shared authoring/review workflow
- `.touchstone-review.toml` — required PR-visible review policy
- `.touchstone-config` — Declared lint/typecheck/build/test/validate commands, project profile, and workflow choices
- `.pre-commit-config.yaml` — Pre-commit hooks including fast branch checks and direct default-branch guardrails
- `.gitignore` — Sensible defaults
- `.worktreeinclude.example` — Starter allowlist for ignored local files to copy into spawned worktrees
- `.github/pull_request_template.md` — PR checklist
- `setup.sh` — One-command setup for dev tools, hooks, and project dependencies

**Touchstone-owned** (auto-updated when you run `touchstone update` or `touchstone update-all`):
- `.touchstone-version` — The touchstone revision this project has applied
- `.touchstone-manifest` — The visible list of touchstone-managed paths
- `principles/*.md` — Universal engineering principles
- `scripts/touchstone-run.sh` — Task runner for the commands declared in `.touchstone-config`, with deprecated repo-layout detection as the fallback
- `scripts/open-pr.sh` — Push + create PR via `gh`
- `scripts/merge-pr.sh` — exact-head review gate + deterministic preflight + squash-merge + sync main
- `scripts/cleanup-branches.sh` — Safe branch hygiene
- `scripts/run-pytest-in-venv.sh` — Legacy Python helper copied for Python profiles

`setup.sh` installs dependencies for the detected project profile. It supports Node package managers, SwiftPM, Cargo, Go modules, and Python `requirements.txt`/`uv.lock`/`pyproject.toml` at the repo root and under `agent/`. `touchstone run validate` uses `.touchstone-config` to run profile-aware lint/typecheck/test commands.

### What the gates actually enforce

Touchstone enforces a test **runner**, not a test **suite**. The pre-push hook invokes `scripts/touchstone-run.sh validate`, which runs the commands declared in `.touchstone-config` — a declared command runs and its exit code is the verdict, including a missing binary. A project that declares nothing falls back to deprecated repo-layout detection, which skips when the underlying tool or test file is absent (a fresh scaffold shouldn't reject pushes just because the first test hasn't been written yet). Every skip is reported as `SKIP` and each run ends with a `ran=/skipped=/failed=` verdict, so a repo with zero test files still passes the gate but can no longer look like it ran something. Set `require_declared=true` in `.touchstone-config` to make that a failure once `validate` is a required check.

`touchstone doctor` is where those gaps become visible. It reports per-profile test presence, profile-specific linter availability (`ruff`, `swift-format`), pre-push hook integrity, and unknown profile values — in lock-step with the runner's dispatcher so doctor never claims more coverage than `validate` actually runs. Use `touchstone init --scaffold-tests` to seed a placeholder smoke test (Python, Node, and Go; Rust and Swift already get tests from `cargo init` / `swift package init`) and `touchstone init --ci github` to add a GitHub Actions workflow that runs the same `validate` path CI-side.

### Keeping projects up to date

When you improve Touchstone (add a principle, fix a script), run:

```bash
touchstone update-all
```

This updates touchstone-owned files across registered projects by creating reviewable update branches and commits. For one project, run `touchstone update --dry-run` to preview, `touchstone update --check` to check staleness, and `touchstone update` from a clean git worktree to create a `chore/touchstone-*` branch with the update committed. If a driving CLI already created a task branch, use `touchstone update --in-place` to commit the Touchstone update there. Project-owned files are never touched by `touchstone update`; use `touchstone diff` to review the core project-owned files against the latest templates.

`touchstone sync` still works as a deprecated alias for `touchstone update-all`.

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
- **[ai-delivery-architecture.md](principles/ai-delivery-architecture.md)** — Human request → driver AI → PR → agentic review loop → approved merge
- **[review-evidence.md](principles/review-evidence.md)** — Full-SHA clean-result evidence, trust checks, and rebase compatibility
- **[git-workflow.md](principles/git-workflow.md)** — Feature branch → PR → review comments/checks → squash merge

### AI Review Gate

Every ready PR head that enters final shipping receives a GitHub Codex review
request. Draft heads remain review-free until final shipping explicitly marks
the PR ready. Touchstone binds the request and accepted result to the full head
and base revisions, rejects stale reviews and unresolved threads, runs
deterministic preflight, and revalidates authorization immediately before
merge.

Touchstone does not run a hidden local semantic reviewer, route model calls, or
apply reviewer-authored edits. The driving CLI addresses findings with normal
commits, which trigger a new exact-head review.

Configure timeouts and trusted GitHub review authors in
`.touchstone-review.toml`. Write the project review rubric in `AGENTS.md`. See
[hooks/README.md](hooks/README.md) for the complete contract.

### Agent Steering Contract

The static steering contract runs in the normal self-test suite:

```bash
bash tests/test-agent-steering-contract.sh
```

That test guards the interpretability contract without spending model quota:
Claude, Codex, and Gemini are interchangeable driving CLIs, and all drivers
must converge on the same managed principles and branch → PR → review →
approved merge lifecycle.

Maintainer self-tests are split into a fast default tier and a slow opt-in tier. The fast tier is the pre-push contract and must not call live model/provider CLIs:

```bash
for test in tests/test-*.sh; do
  bash "$test" || exit 1
done
```

Live guidance probes live under `tests/slow-*.sh` and are run explicitly when changing model-steering behavior or before release-level confidence checks.

### Claude Code Skills

Touchstone owns Claude Code project skills under `.claude/skills/` for Touchstone maintenance work. These are part of this repo, not files that Touchstone copies into every downstream project:
- `touchstone-audit` — audits Touchstone itself against its principles and current AI-tooling practices.
- `memory-audit` — checks Claude Code memory for stale commands, dead paths, duplicate facts, and unsourced volatile guidance.

Run `touchstone skills` to list visible project and user skills, and `touchstone skills check` to validate their frontmatter.

### Helper scripts

- **open-pr.sh** — `git push` + `gh pr create` with your PR template. Idempotent.
- **merge-pr.sh** — Sanity-check mergeability, block unresolved PR feedback, run AI review, squash-merge, delete branch, and sync main.
- **cleanup-branches.sh** — Dry-run by default. Never deletes unmerged work.

## Project structure

```
touchstone/
├── .claude/         # Claude Code project skills for Touchstone maintenance
├── principles/      # universal engineering docs
├── skills/          # Claude Code skill definitions
├── templates/       # starter files for new projects
├── hooks/           # AI review hook
├── scripts/         # helper scripts (open-pr, merge-pr, cleanup)
├── bootstrap/       # new-project.sh, update-project.sh, sync-all.sh
├── bin/             # touchstone CLI entry point
├── lib/             # shared bash helpers (toml.sh, preflight.sh, etc.)
├── completions/     # shell completion scripts
├── docs/            # design docs and ADRs
├── audits/          # periodic codebase audits
├── feedback/        # operator-captured incident notes
├── prototypes/      # speculative scripts not yet promoted to scripts/
└── tests/           # self-tests
```

## Contributors

Install Touchstone, bootstrap a project, and open a PR for improvements to principles, templates, scripts, hooks, or skills.

## License

MIT
