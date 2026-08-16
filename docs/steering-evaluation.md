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

Run the live, manual lane outside the repository checkout:

```bash
evidence_dir="$(mktemp -d -t touchstone-steering-evidence.XXXXXX)"
bash scripts/evaluate-steering.sh behavioral --output "$evidence_dir"
```

The lane runs Codex, Claude, and Gemini against the same three versioned
scenarios in both steered and unsteered-control repositories. Each pair has the
same commit topology and the same tree except for the active driver's root
entry file. `pairing.tsv` records that comparison. `config.tsv` owns models,
run limits, timeouts, confidence thresholds, cost bounds, and evidence expiry;
`--config FILE` permits a separately captured configuration without changing
the scenario definitions.

Behavioral credit comes only from harness-owned machine state:

- exact repository state, a harness-installed checkout hook, and executable
  regression tests for authoring;
- PATH-observed `git` and `touchstone` invocations for sequencing and exit
  status;
- a small stateful PR simulator for exact-head review, inline and body
  findings, provisional security-review quota, and routed scope expansion;
- strict, enumerated `RESULT.tsv` claims checked against the observed state.

Provider output is retained only as diagnostic evidence. The evaluator never
parses provider event schemas or English narration for a score. This boundary
prevents a model from earning credit by describing an action it did not take
and keeps provider output-format changes from breaking the evaluator.

The output contains a versioned manifest, paired-repository evidence, per-run
action logs, scores, committed and worktree diffs, final git state, and a
summary report with pass rates, driver/model/version, latency, bounded or
reported cost, variance, and expiry. A nonzero driver exit, a steered mean
below the configured threshold, or an insufficient control delta makes the
command fail.

This lane is deliberately absent from required CI: it uses live providers and
quota. CI runs the deterministic structural lane and offline fake-driver
regressions only. A security-review quota notice inside the delivery scenario
is provisional evidence to wait or recover; it never blocks or terminates the
review workflow.
