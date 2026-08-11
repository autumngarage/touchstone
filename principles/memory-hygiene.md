# Memory hygiene

**Trigger:** you are about to write an agent memory, or you are about to act on
something memory told you.

Agent memory is a cache. Like every cache, its failure mode is not being empty —
it is being confidently wrong. A remembered flag that was removed two releases
ago reads exactly like a flag that still exists.

## Rules

- **Memory is cached guidance, not canonical truth.** Verify a remembered
  command, flag, path, or version against this repo before relying on it.
- **Don't cache what is cheap to derive.** This project's own README, steering
  files, version file, `--help` output, and scripts are one command away. A
  memory that duplicates them can only go stale.
- **Date and source every claim.** If a memory mentions a command, flag, file
  path, version, or workflow, include the date (`YYYY-MM-DD`) and the canonical
  source you checked. A memory with no date cannot be aged out.
- **Check the fact's owner, not the nearest document.** Repositories routinely
  carry contradictory checked-in prose, so "the repo" is not a single voice. A
  flag is settled by `--help` or the parser; a version by the version file; a
  command by the script that runs it. Prose describing any of those is a
  secondary source and can itself be the stale party.
- **The owner wins.** Where memory conflicts with the canonical source, follow
  the source and propose updating the stale memory in the same turn. Silently
  working around a wrong memory leaves it wrong for the next session. Where
  memory conflicts with prose that the canonical source contradicts, the prose
  is the bug — fix it, or file it.

## What is worth remembering

The test is whether the fact is *derivable*. Structure, past fixes, and git
history are all in the repo — don't restate them. What is not in the repo:

- Preferences and working style the user stated but never wrote down.
- Pointers to external resources (dashboards, tickets, URLs).
- The **why** behind a correction — but only as a pointer. Drivers are
  interchangeable, so a rationale living solely in one driver's private memory
  is invisible to the next session and to every other CLI, and the decision
  gets relitigated by an agent that cannot see it. Shared engineering decisions
  belong in a repository-owned record — the issue, the PR, an ADR, or a journal
  entry — with memory holding only the pointer to it.

**Constraints on in-flight work are the exception.** Do not let memory be their
only copy. Drivers are interchangeable — a fresh session, or a different CLI
picking the work up, cannot read your memory, and will proceed in violation of
a constraint it has no way to see.

Record the constraint somewhere authored and durable: the issue, the pull
request, a plan, or a journal entry. Then let memory hold only a pointer to it.
Do not write it into generated state — a file rebuilt from other sources will
erase hand-authored text that is not inside an explicitly protected region, and
the constraint disappears with no trace that it ever existed.

## Auditing

Claude Code agents have the `memory-audit` skill for this. Run it when a
remembered command, path, or version turns out to be stale during real work —
one wrong memory usually means a cohort written in the same session is also
wrong.

Deleting memory is a destructive action on user-owned content, so it follows
the same rule as any other: **ask before removing, and leave a way back.** Take
a timestamped backup of what you are about to change and get explicit approval
for the deletions, whether you are running the skill or auditing by hand. A
memory that is merely *stale* is corrected in place with a fresh date and
source; deletion is for memory that was wrong to record at all. Drivers without
the skill owe the same consent and backup, not a faster path.

Related: `principles/documentation-ownership.md` covers the same question for
docs — who owns a fact, and where it should live so it has exactly one home.
