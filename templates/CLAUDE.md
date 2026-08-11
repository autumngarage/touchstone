# {{PROJECT_NAME}} — Claude Code Instructions

## Who You Are on This Project

{{PROJECT_DESCRIPTION — describe the project's purpose, your role, and what "good" looks like for this codebase. Be specific about the domain.}}

Codex and other AGENTS.md-native tools read `AGENTS.md`; Gemini CLI reads `GEMINI.md`. Keep `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` aligned when project workflow, architecture, or hard-won lessons change.

## Agent Roles And Fallbacks

Claude Code is a **driving CLI** in this repo: it owns file edits, git state, tests, commits, PR creation, PR comment triage, fix commits, approval tracking, and merge. Codex and Gemini CLI are equivalent fallback drivers because all three load the same managed principles and delivery workflow.

Semantic review is PR-visible and asynchronous. The driving CLI remains
responsible for addressing review findings, validating each revised head, and
merging only after the required GitHub review and checks approve.

## Universal steering

@TOUCHSTONE.md

The block above is the canonical universal contract: agent roles, the 14 daily-reminder engineering principles, the never-commit-on-main rule, the required delivery workflow, and a routing table that points to deeper docs rather than inlining them (`principles/git-workflow.md`, `principles/memory-hygiene.md`, `principles/pre-implementation-checklist.md`, `.cortex/protocol.md`, etc.). Codex and Gemini agents read the same content via the `<!-- touchstone:steering -->` managed block in `AGENTS.md` / `GEMINI.md`.

The `~/.claude/skills/touchstone-*` skills (installed by `touchstone init`) provide the same routing surface as the table above, with descriptions in your session header.

## Testing

```bash
# Reinstall dependencies without rerunning the full machine setup
bash setup.sh --deps-only

# Before any push — uses .touchstone-config profile defaults and command overrides
bash scripts/touchstone-run.sh validate
```

Fix failing tests before pushing.

## Release & Distribution

{{RELEASE_AND_DISTRIBUTION — how is this project shipped? Include the release command, package registry or deployment target, required version bump, post-release verification, and rollback path. Examples: Homebrew tap, npm package, Docker image, Vercel/Railway deploy, app store build.}}

After merging release-affecting changes, verify the shipped artifact or deployed environment matches the pushed code.

## Architecture

{{ARCHITECTURE — describe key packages, their responsibilities, and how data flows between them. Keep it high-level.}}

## Key Files

| File | Purpose |
|------|---------|
| {{key files and their purposes}} | |

## State & Config

{{STATE_AND_CONFIG — where does mutable state live? What's gitignored? Where's the config template?}}

## Hard-Won Lessons

{{HARD_WON_LESSONS — bugs that cost real time or money. Each should teach a generalizable lesson. Format: what happened, what was the root cause, what's the fix/guard now in place.}}
