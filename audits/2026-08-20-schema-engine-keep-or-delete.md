# Declaration schema and validation engine — keep or delete — 2026-08-20

Audit for AUT-323. Applies the AUT-305 exercise to `.touchstone.toml` and the
engine that executes it, before AUT-276 freezes them into a published Homebrew
contract. After publication every removal is a breaking change; today there is
exactly one real declaration in the fleet (this repository's own, 14 lines),
so deletion costs nothing and the record is what matters.

The test for every row, from the issue: name the real observed failure that
demanded the feature, or delete it. Secondary test: what would the simpler
alternative — the pinned central workflow *is* the contract and a consumer
declares only its check commands — fail to cover? "Nothing" is a deletion.

Surface at audit time (`wc -l`, main at `a3ee39b1`):

| Artifact | Lines |
| --- | ---: |
| `scripts/touchstone-run.sh` | 1077 |
| `scripts/touchstone-adopt.sh` + `scripts/lib/*` | 1502 |
| `tests/test-validation-engine.sh` | 2595 |
| `tests/fixtures/` (21 files; 11,836 are one `package-lock.json`) | 15,716 |

Consumers: `touchstone` itself is the only repository with a `.touchstone.toml`.
anima, vesper, arpeggio, convoy, cortex, outrider carry the legacy
`.touchstone-config` and nothing else.

## Verdicts — schema

| Field | Verdict | Evidence | What the simpler alternative misses |
| --- | --- | --- | --- |
| `schema` (integer, 1 and 2) | **Keep** | No incident; it is the compatibility boundary `docs/product-contract.md` promises ("every v3 CLI accepts every valid declaration of both"). #924 proved the gate fails closed on unknown versions. ~10 engine lines. | Without it, the first shape change after the tap publishes is undetectable by an older CLI. |
| `[validation].runtime` | **Delete** | Introduced in #829 as a forward-compatibility slot. Only `bash` is legal; the engine's sole use is to refuse any other value. No failure cited, no consumer needs it. | Nothing. A second runtime would be a schema addition when it arrives, and additions are backward-compatible by contract. |
| `[validation].setup` | **Keep** | No incident for the key itself, but its scope rule carries one: the 2026-08-12 required-check outage (#742, #803, #808) where third-party fetches went red before any test ran. `setup` is the declared, project-owned provisioning step that rule confines. | A multi-task declaration (the npm preset emits up to four) would re-run `npm ci` per task, or collapse to one task and lose per-task accounting. |
| `[[validation.targets]]` | **Delete** (follow-up) | #802 found "a later passing target laundered an earlier failure" — a bug *in* the targets loop, not evidence the loop is needed. Adoption always emits exactly one `root` target; no real monorepo declaration exists. ~85 engine, ~136 test lines. | Nothing: a monorepo task writes `cd packages/x && …`. The stage-aware "directory absent on the runner" preflight (#924) is a consequence of targets and goes with them. |
| `tasks[].name`, `.command` | **Keep** | The entire contract: #802's "`pnpm lint` exiting 3 was reported as skipped with exit 0" is what explicit declared commands replaced. | — |
| `tasks[].required` | **Delete** | Optional tasks descend from the same #802 laundering incident — but the incident was a *hidden* skip. Adoption hardcodes `required = true`; optional tasks exist only in fixtures. | Nothing. A task you do not want enforced is a task you do not declare. With every task required, the skip path and its accounting disappear. |
| `tasks[].target` | **Delete** with targets | See targets. | — |
| `tasks[].stage` (`enforce`/`commit`, schema 2) | **Keep** | Strongest evidence in the inventory: #924 / AUT-306 — vesper's per-commit release-note rule could not be checked until push, leaving history rewrite as the only repair. Decided 2026-08-19. | A commit-time authoring guard that must *not* run in the enforcement check has no other home; each project inventing its own wiring is how vesper got it wrong. |

Recorded gap, not a verdict: no declaration uses `stage` yet, including vesper's.
AUT-303 (vesper migration) is its canary; if vesper does not adopt a commit
stage, this row is re-opened.

## Verdicts — engine

| Feature | Verdict | Evidence | What the simpler alternative misses |
| --- | --- | --- | --- |
| Static command-start classifier (`declared_command_head`, `literal_words`, `declared_command_unrunnable_code`, `/usr/bin/env` option emulation) — ~495 lines, 46% of the engine | **Delete** | Inherited #802 corpus hardening; no failure cited for the static prediction itself. Verified today: both branches call `record_failure` and fail validation — for any command that fails, the classifier only chooses the label `command-not-started` vs `command-failed`. Two things change, and are accepted: (1) a command that itself exits 126/127 after starting can no longer be told apart from one the shell could not start, so the label follows the exit status; (2) a declaration that swallows its own unstartable head (`./script \|\| true`) passes instead of being refused. The contract says the engine executes declarations exactly and never second-guesses them; what a declared command does with its exit status is the project's promise. #802's incident was the *runner* inferring a skip, not a consumer laundering its own command. | A static predictor that decides ahead of the shell is a second interpretation of the command — the class of local adjudication this repository exists to remove. Run the command; derive the label from the real exit status. ~5 lines replace ~495, and the ~325-line test block shrinks to the exit-status cases (AUT-328). |
| "Nothing ran" verdict | **Keep** | #802 "trap 5": a green required check was compatible with nothing having been linted or tested. | The central workflow cannot tell an empty declaration from a passing one. |
| `--check-contract` | **Keep** | #879: adoption must ask "is this declaration valid" without running the project's suite. Sole production consumer: `touchstone-adopt.sh`. | Adoption would execute a consumer's tests to validate a file. |
| `--json` (validate) | **Keep** | No in-repo production consumer; kept as the versioned machine verdict and the oracle the #802 regression corpus asserts against. Defect found: `emit_report` hardcodes `"schema":1` for schema-2 declarations — fix. | Human text as the only oracle would make every regression assertion a prose match. |
| `--stage` | **Keep** with `stage` | #924. | — |
| `--project` / `--config` | **Keep** | #920 / AUT-300 with a reproduced failure: `--project sub` and `cd sub` resolved different roots and reported a present contract as missing. | — |
| Environment hygiene (`clear_git_hook_env`, `env -u GIT_*`) | **Keep** | #209, #216: real nested-hook breakage; #920 extended it. | — |
| Legacy `.touchstone-config` refusal + `touchstone-legacy-config.sh` | **Keep** | Six sister repositories still run on it; #869 encodes the alias-precedence invariant (`validate_full_command` over `validate_command`) vesper depends on. Load-bearing for AUT-303. | — |
| `check-legacy-ci.sh` | **Keep** | AUT-289: default-branch push workflow running `no-commit-to-branch` blocked every deploy. | — |
| Detectors / presets (npm, python, swift, legacy, manual, declared) | **Keep** | Evidence-first corpus (#875, #896, #897); every preset matches at least one fleet repository (anima; arpeggio, cortex, conductor; vesper; convoy, cortex, outrider). | — |
| Plan / apply, clean-branch refusal, HEAD-clean inputs, worktree lock | **Keep** | #903 and #901 review corpora: SIGTERM mid-apply restores original bytes; PID liveness is not ownership. | — |
| `--json` (adopt) | **Keep** | Same rationale as validate `--json`; ~55 lines, versioned envelope `touchstone.adoption/v1`. | — |

## Deletions to ship before the tap publishes

In order, one concern per pull request:

1. **Runtime classifier** — replace the static pre-flight with exit-status
   labelling. Largest win, no schema change.
2. **Schema slimming** — drop `runtime` and `required`; fix the `--json`
   schema number. Update this repository's declaration and the adoption
   renderer in the same change (the only consumer is here).
3. **Targets** — collapse to the repository root; drop `target` from tasks
   and the stage-aware target preflight. Filed as a blocking follow-up of
   AUT-276 rather than shipped here: it is the widest diff and the one most
   worth a fresh review.

Surviving rationale folds into `docs/product-contract.md` under the consumer
boundary. Re-run this audit only on observed breakage, per AUT-326.
