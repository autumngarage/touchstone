# Steering Evaluation Contract

This document owns the deterministic evidence boundary for Touchstone's agent
instructions. Phrase-presence tests are necessary but insufficient: the
structural lane proves each driver's resolved instruction set.

## Versioned inputs

`evals/steering/v1/structural/` is the source of truth. It carries positive
load-order/import fixtures, exact expected resolved text, and
broken/conflicting negative fixtures. Changing fixture meaning requires a new
version directory.

## Structural lane

Run:

```bash
bash scripts/evaluate-steering.sh structural --json
```

The offline lane resolves and byte-compares these documented behaviors:

- Codex loads one instruction file per directory from repository root to the
  working directory; `AGENTS.override.md` wins within its directory. Codex's
  default project-instruction limit is 32 KiB, so Touchstone keeps each driver
  entry below 24 KiB and its universal router below 9.5 KiB. See the
  [Codex AGENTS.md documentation](https://developers.openai.com/codex/guides/agents-md/).
- Claude loads ancestor `CLAUDE.md` files broad-to-specific, discovers nested
  files when working there, and expands relative `@file` imports to five
  levels. Touchstone's Claude entry imports the universal router. See the
  [Claude Code memory documentation](https://code.claude.com/docs/en/memory).
- Gemini combines global, workspace/ancestor, and just-in-time nested context
  and expands relative `@file.md` imports. See the
  [Gemini CLI GEMINI.md documentation](https://geminicli.com/docs/cli/gemini-md/).

It also proves all four hand-maintained managed blocks resolve to the canonical
`TOUCHSTONE.md`, Claude imports exist, size caps hold, routed paths resolve,
unsupported subcommands are absent, missing imports fail, and conflicting rule
IDs are detected. The required CI invokes only this lane; it is deterministic,
offline, and uses no provider quota.

## Behavioral lane

Behavioral evaluation is the separate follow-up lane in AUT-284. It consumes
these versioned structural fixtures, but live-agent orchestration, controls,
scoring, budgets, and evidence expiry are outside this deterministic boundary.

## Behavioral scoring boundary

`evals/steering/v1/normalize-events.sh` converts Codex, Claude, and Gemini
JSONL into provider-neutral action facts. Scenario scorers consume only those
facts plus final repository artifacts. Reads and mutations must correlate with
successful results before they earn credit. A validation invocation instead
requires a terminal result because its expected no-task verdict is nonzero;
an uncompleted request earns nothing. Action order is preserved even when a
shell command contains both actions.

`rubric.tsv` records the content-quality judgment for every instruction, and
`scenarios.tsv` maps each load-bearing behavioral rule to its scorer. A
conjunctive point requires independent evidence for every required action.
Success/error, omission, opposite-action, and within-command-order fixtures
run offline in the required suite.

Live-agent execution, control construction, budgets, and dated evidence are a
separate orchestration boundary and are not implemented by these scorers.
