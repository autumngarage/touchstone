# Memory hygiene

AI agents accumulate memory across sessions — Claude Code's `memory/` directory, `MEMORY.md` indexes, whatever your driver persists. That memory is **cached guidance, not canonical truth.** It reflects what was true when it was written, and the repo has moved since.

This matters more here than in a normal codebase, because Touchstone's whole purpose is that machines are the quality bar. A stale remembered flag that no longer exists doesn't produce a compile error — it produces a confidently wrong action.

## The rules

- **Treat memory as a cache.** Verify a remembered command, flag, path, or version against this repo before relying on it.
- **Don't memorize what's cheap to derive.** `README.md`, the steering files, `VERSION`, `bin/touchstone --help`, and the scripts themselves are all one command away. Memory that duplicates them goes stale silently and buys nothing.
- **Date every claim about the repo.** If a memory mentions a command, flag, file path, version, or workflow, include the date (`YYYY-MM-DD`) and the canonical source you checked.
- **The repo wins.** If memory conflicts with the repo, follow the repo and propose updating the stale memory in the same turn — don't leave a known-wrong memory in place for the next session to trip over.

## What memory is actually for

Memory earns its keep on things the repo *cannot* tell you:

- **Preferences and working style** — how the human wants to be involved, what they've corrected before, what they consider out of scope.
- **Decisions and their reasons** — why a path was rejected, so it isn't relitigated every month.
- **Pointers** — issue numbers, dashboards, external URLs that are tedious to rediscover.

None of those are derivable from the code. All of them decay if the reason isn't written down alongside the fact, so write the *why*, not just the conclusion.

## What memory is not for

- Code structure, function names, file layouts — read the code.
- Past fixes and git history — read `git log`.
- Anything already stated in `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, or `TOUCHSTONE.md` — those load every session anyway, so a memory copy is pure drift risk.
- Facts that only mattered inside one conversation.

## Auditing

Claude Code agents have the `memory-audit` skill for a periodic sweep: find memories that name things which no longer exist, undated claims about the repo, and duplicates of steering content. Other drivers do the same pass by hand — read each memory, check whether the file, flag, or command it names still exists, and delete what doesn't.

A memory that turns out to be wrong gets **deleted**, not annotated. A corrected memory that still carries the wrong version of the fact is worse than no memory at all.
