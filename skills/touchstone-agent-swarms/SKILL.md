---
name: agent-swarms
description: Use when parallelizing work across multiple agents — applies the four-question gate before fanning out (clean context, different tools, skeptical verifier, parallel work).
---

# Agent Swarms

Coordinate multi-agent work via subagents, worktrees, or shell-out to other CLIs. The default is a single agent; this skill applies when the work is genuinely parallelizable.

## The four-question gate

Before fanning out, at least one of these must be true:

1. **Clean context** — does each agent need an isolated context window? (e.g., independent codebase explorations that would each load 50 files)
2. **Different tool access** — does any agent need tools others shouldn't have? (e.g., a sandboxed test runner separated from a write-capable implementer)
3. **Skeptical verifier** — does the work benefit from a reviewer who doesn't share the implementer's bias? (e.g., a critic agent reviewing a writer agent's output)
4. **Parallel work** — are the tasks file-disjoint and independently shippable? (e.g., three unrelated bug fixes across three different packages)

If none apply, use a single agent. The platform default is not swarms.

## Spawn pattern

Use the explicit contract template:

> *"Spawn one agent per [dimension]. Wait for all of them. Summarize the result for each."*

Each subagent gets a self-contained brief: inputs named, outputs named, files-not-to-touch listed, constraints stated, success criteria stated. Subagents do not see the parent conversation context.

## Constraints

- **Concurrency cap**: 3–5 agents. 6 saturates; 7+ is anti-pattern coordination overhead (incident.io, Addy Osmani 2026).
- **Disjoint file sets only**: two agents touching the same file = merge conflict on N branches. If you can't partition cleanly, sequence instead.
- **Token economics**: cost scales linearly with agent count. Multi-agent beats single by ~90% on breadth-first work but burns ~15× the tokens (Anthropic field report). Only swarm when the value justifies the cost.
- **Trust but verify**: every subagent's summary describes what it intended to do. When the work changes files, check the actual changes before trusting the summary.

## Tool-specific recipes

**Claude Code subagents** — use the `Agent` tool with `isolation: "worktree"` for write-heavy fan-out. The worktree is automatically cleaned up if the agent made no changes. For read-only exploration, use the built-in `Explore` agent.

**Codex CLI shell-out** — use OpenAI's canonical phrasing: `codex exec --full-auto "<self-contained brief>"`. Wait for completion, review output before accepting.

**Worktree fan-out (no subagents)** — `git worktree add ../<project>-<slug> -b <type>/<slug>` for each task, work in parallel, ship via independent PRs. See `principles/git-workflow.md`.

## When NOT to swarm

- Coding work that's deep and narrow (tight feedback loop, shared file surface). Single-agent wins.
- Tasks where one decision constrains the next. Fan-out turns sequential dependencies into N stalled subagents.
- "Almost the same thing N times" — duplicate work; deduplicate the task instead.

The Cognition vs. Anthropic debate (June 2025) is unresolved on whether parallel coding is currently tractable; the working consensus is **swarms win on wide-and-shallow (research, exploration); single agents win on deep-and-narrow (programming, long-form writing)**.
