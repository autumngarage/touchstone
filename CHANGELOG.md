# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.2.0] - 2026-04-09

### Added
- `toolkit` CLI with subcommands: `new`, `update`, `sync`, `version`, `doctor`
- Auto-update: checks for newer versions on every invocation (throttled to 1x/hour), upgrades via brew or git pull
- `toolkit doctor` — health check showing version, tools, registered projects, staleness
- Homebrew tap: `brew tap henrymodisett/toolkit && brew install toolkit`
- MIT license (repo is now public)
- Dogfooding: toolkit uses its own CLAUDE.md, AGENTS.md, principles, and Codex hook

## [0.1.0] - 2026-04-09

### Added
- Initial extraction of universal engineering principles from sigint
- Starter templates: CLAUDE.md, AGENTS.md, PR template, .pre-commit-config, .gitignore
- Generalized Codex pre-push review + auto-fix hook with per-project config
- Helper scripts: open-pr.sh, merge-pr.sh, cleanup-branches.sh
- Bootstrap scripts: new-project.sh, update-project.sh
- Self-tests for bootstrap and update flows
