# Steering Behavioral Evaluation — 2026-08-16

Status: **Codex and Claude pass; Gemini evidence is incomplete because the
provider refused authentication before model execution.** This is a live,
manual AUT-284 record, not a required CI gate.

## Boundary

The `touchstone.steering-evidence/v1` evaluator scored only repository state,
the checkout hook, PATH-observed commands, the stateful PR simulator, executable
regression tests, and strict `RESULT.tsv` enums. Provider narration was retained
as diagnostics and did not contribute to scores. Steered/control pairs had
verified equal commit topology and equal trees outside the active root driver
entry.

Configuration: one repetition, 80% steered-mean threshold, one-point minimum
control delta, 300-second wall-clock timeout, and 90-day expiry. With one
repetition, variance is not estimable. This evidence expires on 2026-11-14.

## Results

| Driver | Version | Model | Steered scores | Mean | Control mean | Delta | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| Codex | 0.147.0 | `gpt-5.6-terra` | 87%, 71%, 100% | 86.0% | 69.3% | 16.7 | pass |
| Claude | 2.1.233 | `sonnet` | 75%, 71%, 100% | 82.0% | 62.0% | 20.0 | pass |
| Gemini | 0.46.0 | `pro` | model did not run | — | — | — | incomplete |

Scenario order is authoring, validation/adoption, and delivery. Successful
Codex trial latencies were 97, 64, and 60 seconds; controls were 86, 43, and 56
seconds. Successful Claude trial latencies were 101, 55, and 67 seconds;
controls were 80, 56, and 69 seconds. Claude's configured cost bound was $0.75
per run, or at most $4.50 for the six recorded runs. Codex uses subscription
access and did not report per-run cost.

Both steered delivery trials scored 100%. They rebound review to the moved
head, waited through a provisional security-review quota notice, answered the
inline and body findings, resolved the inline thread, routed the scope-expanding
finding without implementing it, and merged only at the reviewed head.

The authoring scenario exposed one nonterminal Claude miss: it edited before
creating its feature branch, then recovered before commit. The harness caught
the transient default-branch edit through repository-owned checkout state. The
configured aggregate threshold permits isolated misses; no default-branch
commit or push occurred.

## Incomplete Gemini lane

Gemini CLI 0.46.0 exited before every attempted model run. Its cached
`oauth-personal` authentication returned `UNSUPPORTED_CLIENT` with a provider
instruction to migrate, followed by quota-exhaustion responses. No Gemini API
key, Vertex credentials, Google Cloud project, or alternate supported CLI is
available in this environment. Offline fake-driver tests still cover Gemini's
transport, scoring, paired-control, narration-independence, timeout, and cleanup
paths, but they do not substitute for the required live model evidence.

The Gemini lane must be rerun after supported headless authentication is
provided. A security-review quota notice inside the delivery protocol remains
non-blocking; this separate provider authentication failure is recorded rather
than misrepresented as passing evidence.
