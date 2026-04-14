# Feedback — Claude Code auto-memory hygiene

**Date**: 2026-04-14
**Source**: Came up while dogfooding Sentinel on its own repo. Surfaced a recurring
pain that is not Sentinel's problem to solve.

## What we noticed

Claude Code's user-level auto-memory (`~/.claude/projects/.../memory/`) has no
maintenance discipline. In a single conversation this session we hit:

- A stale memory entry claiming `sentinel cycle` was the primary command. Current
  truth: `sentinel work` is primary, `cycle` is a hidden legacy alias. The memory
  was written when the design was different, never refreshed, and nearly caused
  me to recommend the wrong command.
- No obvious mechanism for the assistant to notice rot before acting on it.

This is the "persisted derived state goes stale silently" failure mode — exactly
what `engineering-principles.md` ("Derive, don't persist") warns about, applied
to the assistant's own memory layer.

## Why this is toolkit's problem, not Sentinel's

- **Scope mismatch.** Sentinel runs per-repo. Auto-memory is per-user, spans every
  project. A Sentinel cycle in one repo has no business pruning memory entries
  about a different project.
- **Design conflict.** Sentinel explicitly has no memory module. Bolting
  "manage the user's memory" onto Sentinel contradicts its own "derive, don't
  persist" ethos.
- **Toolkit already propagates per-user concerns.** Principles, hooks, and
  scripts in toolkit already sync to every project. Claude-Code-level guidance
  (how the assistant should behave across projects) is a natural fit.

## Two places this could land

1. **Prompt-level fix (cheaper).** Tighten the auto-memory write instructions so
   entries are cleaner at the source — e.g., require a date stamp on any memory
   referencing a command name, CLI flag, file path, or version. Addresses dirty
   writes. Does not address rot over time.

2. **On-demand skill (`/memory-audit`).** A toolkit-owned skill that scans
   `MEMORY.md` + memory files for staleness signals (dead file paths, outdated
   dates, duplicates, superseded facts), produces a ranked punch-list, and lets
   the user approve edits. Mirrors how `toolkit-audit` works against toolkit
   itself. Addresses rot. Does not address dirty writes.

These are complementary, not alternatives. If you can only do one, start with
whichever pain is larger — dirty writes or rot. Needs a quick diagnosis pass
over the current memory files before picking.

## Open question for the team

Is there appetite for toolkit to own a small set of Claude-Code-harness-level
skills (memory hygiene, prompt audit, context-engineering review) in addition
to the current per-repo engineering skills? If yes, this would be the first
entry in that category and probably wants a sibling directory like
`templates/.claude/skills/harness/` to keep it separate from project skills.

## What I'd like back

- Yes/no on whether toolkit is the right home for this.
- If yes: preference between prompt-level fix vs skill vs both.
- If no: where should it live instead?
