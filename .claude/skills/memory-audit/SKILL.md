---
name: memory-audit
description: Audit Claude Code memory for stale, duplicated, or unsourced facts. Use when the user asks to inspect, clean, prune, verify, or repair Claude memory; when remembered commands, file paths, flags, versions, or project facts seem stale; or when dogfooding exposes a memory entry that conflicts with the current repo.
---

# Memory Audit

Audit Claude Code memory as derived operational state, not as a source of truth. The goal is to find stale or risky memory entries, rank them, and get explicit user approval before editing anything.

## Scope

Default scope:
- Current repo guidance: `CLAUDE.md`, `AGENTS.md`, `README.md`, `principles/`, and obvious CLI/script help.
- Current repo memory: `MEMORY.md` if present.
- Claude Code user memory under `~/.claude/projects/**/memory/` only when readable.

Do not inspect unrelated project memory unless the user asks for a user-wide audit.

## Audit Workflow

1. Identify candidate memory files with `find` or `rg --files`. Prefer narrow paths over reading all of `~/.claude`.
2. Build current truth from canonical files and commands in the repo before judging memory.
3. Check each memory entry for staleness signals:
   - Mentions a command, flag, file path, version, release name, workflow, or "primary/current" fact without a date or source.
   - References a path that no longer exists.
   - Names a command or flag that no longer appears in CLI help, docs, or scripts.
   - Duplicates another memory entry with different wording or a conflicting fact.
   - States derived state that should be read from the repo, release metadata, or tool output.
4. Produce a ranked report. Put confirmed stale facts first, then likely stale, then uncertain.
5. Ask for approval before editing memory files.

## Report Format

Use this structure:

```markdown
## Memory Audit

### Confirmed stale
- path:line — remembered fact
  - current truth:
  - source checked:
  - proposed action:

### Likely stale or risky
- path:line — issue and why it is risky

### Duplicates
- paths/lines — keep X, remove or rewrite Y

### Needs user decision
- question:
```

If there are no findings, say which memory paths you checked and that no stale entries were found.

## Editing Rules

Edit only after explicit approval. When approved:
- Make targeted edits only; do not wholesale rewrite memory.
- Back up each edited file next to the original as `<name>.bak.<YYYYMMDD-HHMMSS>`.
- Prefer deleting stale derived facts over rewriting them.
- If rewriting a fact about a command, flag, path, version, or workflow, include a date and source pointer.
- Never replace canonical docs with memory. Memory should point to canonical docs when possible.

## Memory Write Hygiene

For new memory entries:
- Do not store facts that are cheap to derive from the repo.
- Include `YYYY-MM-DD` for facts likely to rot.
- Include the canonical source, such as `README.md`, `CLAUDE.md`, `bin/toolkit --help`, or a file path.
- Avoid unqualified words like "current", "primary", "always", or "never" unless paired with a date and source.
