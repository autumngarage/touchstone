# Memory hygiene

**Trigger:** you are about to write an agent memory, or you are about to act on
something memory told you.

Agent memory is a cache. Like every cache, its failure mode is not being empty —
it is being confidently wrong. A remembered flag that was removed two releases
ago reads exactly like a flag that still exists.

## Rules

- **Memory is cached guidance, not canonical truth.** Verify a remembered
  command, flag, path, or version against this repo before relying on it.
- **Don't cache what is cheap to derive.** `README.md`, the steering files,
  `VERSION`, `bin/touchstone --help`, and the scripts are all one command away
  and always current. A memory that duplicates them can only go stale.
- **Date and source every claim.** If a memory mentions a command, flag, file
  path, version, or workflow, include the date (`YYYY-MM-DD`) and the canonical
  source you checked. A memory with no date cannot be aged out.
- **The repo wins.** If memory conflicts with the repo, follow the repo and
  propose updating the stale memory in the same turn. Silently working around a
  wrong memory leaves it wrong for the next session.

## What is worth remembering

The test is whether the fact is *derivable*. Structure, past fixes, and git
history are all in the repo — don't restate them. What is not in the repo:

- Preferences and working style the user stated but never wrote down.
- The **why** behind a correction, especially where the obvious approach is the
  wrong one here.
- Constraints on in-flight work that no file records.
- Pointers to external resources (dashboards, tickets, URLs).

## Auditing

Claude Code agents have the `memory-audit` skill for this. Run it when a
remembered command, path, or version turns out to be stale during real work —
one wrong memory usually means a cohort written in the same session is also
wrong.

Related: `principles/documentation-ownership.md` covers the same question for
docs — who owns a fact, and where it should live so it has exactly one home.
