# Engineering Principles

Universal engineering standards that apply to all projects. These are imported by each project's `CLAUDE.md` via `@principles/*.md`.

| File | Summary |
|------|---------|
| [engineering-principles.md](engineering-principles.md) | Hard requirements: no band-aids, narrow interfaces, no silent failures, every fix gets a test, recoverable irreversibles, compatibility at boundaries |
| [pre-implementation-checklist.md](pre-implementation-checklist.md) | Pre-flight questions that route back to the canonical principles |
| [audit-weak-points.md](audit-weak-points.md) | Methodology for auditing structural bug patterns |
| [memory-hygiene.md](memory-hygiene.md) | Agent memory is a cache: verify against the fact's canonical owner, date every claim, and get consent plus a backup before editing it |
| [documentation-ownership.md](documentation-ownership.md) | Single canonical owner per volatile fact |
| [git-workflow.md](git-workflow.md) | Feature branch lifecycle with PR-visible review and merge |
| [agent-swarms.md](agent-swarms.md) | Worktree-isolated parallel agent workflow, slice manifests, and cleanup rules |
