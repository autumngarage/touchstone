# Steering Evaluation Contract

This document owns the evidence boundary for Touchstone's agent instructions.
Phrase-presence tests are necessary but insufficient: the evaluation must also
prove each driver's resolved instruction set and measure behavior against a
weakened control.

## Versioned inputs

`evals/steering/v1/` is the source of truth:

- `config.tsv` fixes repetition, confidence, run, timeout, budget, and expiry
  limits;
- `structural/` carries positive load-order/import fixtures, exact expected
  resolved text, and broken/conflicting negative fixtures;
- `scenarios.tsv` maps every behavioral scenario to load-bearing rules and its
  deterministic scorer;
- `behavioral/` creates disposable repositories for small, typical, and
  adversarial tasks; and
- `rubric.tsv` records every instruction's product job, earning failure,
  owner, enforcement layer, trigger, duplication, context cost, evidence, and
  keep/rewrite/route/delete verdict.

Changing fixture meaning requires a new version directory. Adding scenarios or
rubric rows within v1 is compatible.

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

Run live agents manually from a trusted machine:

```bash
bash scripts/evaluate-steering.sh behavioral \
  --output /tmp/touchstone-steering-evidence \
  --driver all --scenario all --mode both --repeat 1
```

The harness runs the installed Codex, Claude Code, and Gemini CLIs in disposable
repositories. Every steered run has a paired control with the project steering
removed while machine-global configuration remains constant. The task prompt
does not repeat the rule being tested. The scenarios cover default-branch
editing, pre-implementation routing, ambiguous adoption, stale commands,
nothing-ran validation, moved review heads, inline and body-only findings,
security quota, and requests for copied/background-sync machinery.

Steered fixtures invoke the real `touchstone adopt` compiler; the evaluation
does not carry a second steering renderer. The explicit output directory must
be absent or empty so a run cannot overwrite earlier evidence.

Each run records the exact CLI version, UTC date, mode, scenario, repetition,
exit status, duration, deterministic score, raw JSONL event stream, final git
state, and git log. Claude additionally has a per-run dollar ceiling; all
drivers have a hard wall-clock timeout and the entire matrix has a maximum run
count. Authentication or eligibility failures are classified as
`infrastructure-unavailable`, preserved as behavioral results, and excluded
from compliance percentages rather than misreported as agent behavior. Raw
evidence may contain model output and remains in the explicit output directory;
the dated audit commits the compact results and conclusions.

The agreed confidence threshold is the steered aggregate in `config.tsv`.
Controls establish attribution but are not expected to fail every item—some
safe behavior follows from the task itself. Report the absolute control delta,
per-driver variance, latency, and provider-reported token/cost data. A failure
changes the authoritative instruction, routing, or enforcement mechanism and
adds a class-level fixture; it does not add scenario-specific prompt hints.

## Evidence lifetime

Structural results are proof for the exact checked-in fixtures and driver load
contracts. Behavioral results are probabilistic evidence for the recorded
driver/model versions. They expire after the configured number of days or
immediately when a supported driver's instruction-loading semantics, default
model, or major version changes. Expired evidence blocks claims of behavioral
confidence, not ordinary development or security review; rerun the bounded
manual lane and publish a new dated audit.
