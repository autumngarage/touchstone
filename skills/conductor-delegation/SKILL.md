---
name: conductor-delegation
description: Use when delegating to Conductor — picking a provider, writing a brief, choosing --kind / --effort, routing by capability tags, or hitting OAuth contention from inside an agent loop.
---

# Conductor Delegation

Conductor exposes other LLMs behind a uniform CLI. Delegate when the task fits another model better — long-context reading, web search, cheap second opinions, privacy-sensitive offline work — but not for mid-conversation reasoning where you hold active context.

## When to invoke

- About to call `conductor ask`, `conductor call`, `conductor exec`, or `conductor review`
- Choosing `--kind` (research/code/review/council) and `--effort` (minimal/low/medium/high)
- Selecting a provider explicitly (`--with kimi/gemini/codex/claude/ollama/openrouter`)
- Authoring a brief — Conductor doesn't inherit your conversation context
- Hit OAuth contention errors (e.g. "no_initial_provider_output_within_45s" inside Claude Code)
- Need long-context summarization, fresh web information, or a multi-model council

For the full delegation guide: read **`~/.conductor/delegation-guidance.md`** now.

## Default to semantic routing

Pick `--kind` and `--effort`; let Conductor's auto-router choose providers. Avoid `--with <provider>` unless the user asks for a specific one or the semantic API doesn't fit.

```bash
conductor ask --kind research --effort medium --brief-file /tmp/brief.md
conductor ask --kind code --effort high --brief-file /tmp/brief.md
conductor ask --kind review --base origin/main --brief-file /tmp/review.md
```

## OAuth contention warning

When delegating from inside a Claude Code or Codex session, prefer **env-var-auth providers** (`openrouter`, `kimi`, `deepseek`, `gemini`) for headless paths. The OAuth-CLI providers (`claude`, `codex`) hold a per-process session lock — a second invocation from the same session contends with the parent and stalls at first_output (~300s timeout) before failing.

## Briefs

Conductor doesn't see your conversation. Every brief should include: goal, context, scope, constraints, expected output, and validation. For nontrivial multi-turn work, prefer `--brief-file` so the handoff is durable and not squeezed through shell quoting.

## Council mode

Use `--kind council` when the user wants multiple perspectives. Council always routes through OpenRouter and asks multiple models independently before a synthesis pass. Do not route council to Codex, Claude, Gemini CLI, or Ollama.

## Ollama is offline-only by default

The auto-router excludes Ollama when online. To force it: `--with ollama`, `--auto --tags ollama`, or `--offline`.
