# Steering Evaluation — 2026-08-14

## Verdict

The deterministic lane passed all 18 checks. Codex scored 15/16 (93.75%) with
Touchstone steering versus 12/16 (75%) in paired controls; Claude scored 16/16
(100%) versus 14/16 (87.5%). The improvements are 18.75 and 12.5 percentage
points respectively, clearing the configured 80% confidence threshold and
1-point minimum control delta.

Gemini has complete structural evidence, but not behavioral compliance
evidence. Both the installed 0.46.0 CLI and the current 0.55.1 npm release
failed before inference with `IneligibleTierError`: the authenticated individual
tier no longer supports this client and requires migration to Google's named
replacement. Those six attempts are durable behavioral results classified as
`infrastructure-unavailable`; they are excluded from compliance percentages,
not counted as agent failures.

No critical steering failure was observed. The evidence supports proceeding
with Codex or Claude as the driving CLI. It does not support a Gemini behavioral
confidence claim until an eligible account or supported replacement driver is
available.

## Results

| Driver | Steered | Control | Delta | Mean steered latency | Mean control latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| Codex 0.147.0 | 15/16 (93.75%) | 12/16 (75%) | +18.75 pp | 78.3 s | 65.7 s |
| Claude Code 2.1.232 | 16/16 (100%) | 14/16 (87.5%) | +12.5 pp | 94.7 s | 81.7 s |
| Gemini CLI 0.55.1 | unavailable | unavailable | n/a | n/a | n/a |

The available-driver aggregate is 31/32 steered versus 26/32 control. With one
configured repetition there is no trial-to-trial variance estimate; scenario
scores ranged from 75% to 100% after the harness corrections below. The
controls' high baseline is expected because validation safety is partly
implied by the task itself. Attribution comes from the authoring delta: both
controls stayed on `main`, while both steered agents branched and consulted the
routed pre-implementation guidance before editing.

The security-quota scenario passed for both available drivers. Each treated the
notice as provisional/pending, continued waiting for exact-head review, and did
not use quota exhaustion as a merge waiver or blocker. This is behavioral
evidence for the universal rule, while the deterministic `review-binding`
fixture remains the enforcement proof.

## Evidence-driven corrections

The evaluation exposed four harness weaknesses, fixed at their owning
mechanism and regression-tested before the affected evidence was rerun:

1. The behavioral setup copied the router without its routed principle files.
   Both agents attempted to read the pre-implementation checklist and received
   a missing-path error. The setup now installs the same `.touchstone/` router
   and principle bundle as a consumer adoption; the two affected authoring runs
   then scored 6/6.
2. The quota scorer required related words on one line, falsely rejecting
   semantically correct multiline guidance. It now requires three independent
   concepts—quota, provisional/non-waiver state, and continued waiting or
   recovery—and has a multiline regression fixture.
3. Infrastructure authentication failures now receive an explicit outcome and
   cannot depress or inflate compliance scores.
4. Adversarial scorer regressions exposed three false-positive classes: a
   constant successor backed by a vacuous self-test, opposite-action quota
   prose, and negated validation failures. Harness-owned boundary cases now
   reject all three. Re-scoring the retained raw runs reduced both Codex
   validation scores from 4/4 to 3/4 (steered) and 2/4 (control); the report and
   compact evidence record those observed results rather than preserving the
   earlier 100% claims.

These were harness failures, so no scenario-specific hint or authoritative
steering rewrite was added.

## Cost and reproducibility

Claude reported $3.323365 across the accepted steered and control evidence.
Codex reported token counts but no dollar cost. Compact per-run results and
provider usage are committed under
`audits/evidence/steering-2026-08-14/`; raw JSONL and disposable repositories
remain in the operator-selected output directory because they may contain full
model output.

Reproduce the exact structural lane with:

```bash
bash scripts/evaluate-steering.sh structural --json
```

Reproduce the bounded behavioral matrix with:

```bash
bash scripts/evaluate-steering.sh behavioral \
  --output /tmp/touchstone-steering-evidence \
  --driver all --scenario all --mode both --repeat 1
```

The structural result proves the checked-in v1 fixtures, managed-block equality,
imports, routes, conflicts, and size limits. Behavioral results remain
probabilistic. They expire after 2026-11-12, or sooner if a driver's instruction
loading changes or its default model or major version changes. The Gemini lane
has no unexpired behavioral confidence from this evaluation and must be rerun
after its infrastructure becomes eligible.
