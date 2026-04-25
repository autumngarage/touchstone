# Guidance Effectiveness Plan

**Date:** 2026-04-24
**Status:** Phase 1 (verification primitive) shipped on `main` (PR #61); Phases 2–7 sequenced below.

## TL;DR

Touchstone ships engineering guidance. Today there is no feedback loop confirming the guidance actually shapes Claude's or Codex's behavior — rules can decay silently as files bloat or wording rots. This plan adds a layered enforcement stack (Claude hooks > git hooks > CLAUDE.md > skills), each layer paired with a matching verification approach (hook unit tests for deterministic layers, behavior probes for probabilistic layers). Probes are Touchstone-internal QA, not propagated to downstream projects. The result, when complete: hard rules become walls (Claude hooks); methodologies become on-demand skills; behavioral preferences become persisted answers loaded every session; CLAUDE.md drops from ~250 lines of imported essays to ~150 of named rules + links. Each phase is independently shippable, gated on its own measured success criteria.

## Goal

Make Touchstone's guidance demonstrably affect the driving LLM, not just live in the repo. Today there is zero feedback loop on whether any principle, workflow, or skill is actually applied — guidance can decay silently as files bloat, wording rots, or model behavior shifts. Every architectural decision below is downstream of this. The vehicle a piece of guidance ships in is selected by *required enforcement strength*, and each layer has a matching verification approach.

## What we learned from building Phase 1

Built `tests/test-guidance-probes.sh` — three positive probes (no-silent-failures, every-fix-gets-a-test, no-band-aids) and one negative control. All four pass in ~27s. Concrete findings:

1. **The probe primitive works.** A leading-but-natural prompt + a concept-token OR-regex reliably detects whether a rule fired. Claude cited "No silent failures" by name, "every fix" verbatim, "band-aid" verbatim — the rules in `principles/engineering-principles.md` are visibly shaping responses today.
2. **Concept-tokens, not exact phrases.** Claude paraphrases. Detection regexes must be lists of synonyms; single-phrase matching is brittle.
3. **Negative controls catch overbroad regexes.** First draft included bare `log` — would have matched any response mentioning logging at all. Tightened to `log the|should log`. The 2+2 negative probe is cheap insurance against false confidence.
4. **Cost is real but tolerable.** ~7s per probe. Twelve probes = ~85s. Acceptable for Touchstone's own pre-push and release gate; not acceptable for downstream projects (see propagation reframe below).
5. **Pre-push wiring is automatic.** `validate_command` in `.touchstone-config` already globs `tests/test-*.sh`. New probe files are picked up with zero config change.
6. **Probes test the *combination* of CLAUDE.md + principles/ + Claude's training.** They cannot isolate which piece is doing the work — but for refactor verification, the combination is exactly what matters.
7. **Asymmetry to flag.** Probes verify Claude *cites or applies* a rule when prompted with a violation. They do NOT verify Claude wouldn't *itself* violate the rule when writing code unprompted. That's the v2 code-output probe shape; out of scope for v1.

## Reframe: probes are Touchstone-internal QA

Probes are not a downstream feature. A user whose project regresses a probe can't easily fix it — they don't own Touchstone's principles. Failure UX would be hostile: "your push is blocked because of someone else's wording change."

So probes are reframed as a *developer Q&A tool* — an internal regression catcher for the maintainer iterating on guidance. They run in Touchstone's own pre-push and release flow. They **do not propagate** via `update-project.sh`. The downstream UX stays "install once, update, ignore"; correctness is upstream's responsibility.

The probes' real job: when slimming CLAUDE.md, converting a principle to a skill, or rewording an essay, the probes confirm in 27 seconds whether the change preserved behavior. Without them, regressions surface a month later in a downstream project.

## The vehicle hierarchy

Decision rule, in priority order:

1. **Mechanically enforceable at a Claude tool boundary** → Claude hook (`.claude/settings.json` PreToolUse/PostToolUse).
2. **Mechanically enforceable at a git boundary** → git hook.
3. **Claude silently fails when the rule is missing** → CLAUDE.md (always loaded, kept short).
4. **Activates on a specific task type** → skill (model-invocable).
5. **Side-effecting procedure needing explicit invocation** → skill with `disable-model-invocation: true`.

Each vehicle has a matching test shape:

| Vehicle | Test shape | Cost | Determinism |
|---|---|---|---|
| Claude hook | Hook unit test: run triggering command, assert exit 2 | Fast | Deterministic |
| Git hook | Existing `tests/` patterns | Fast | Deterministic |
| CLAUDE.md (always-loaded principle) | Pushback probe (`claude -p` + concept-token regex) | ~7s/probe | Probabilistic |
| Skill | Skill-activation probe (trigger phrase → detect side effect) | ~7s/probe | Probabilistic |

The two probabilistic test shapes are what `tests/test-guidance-probes.sh` exists for. The deterministic shapes (hook unit tests) are different: cheap, reliable, runnable anywhere — including downstream.

## Persistent preferences (the "install once, ignore" piece)

Without persisted answers, the user re-onboards Claude every session ("be terse", "we use pnpm", "auto-merge PRs"). That's not "ignore" — that's "re-onboard daily." The fix is `bin/touchstone init` becoming interactive, with answers fanning out to homes by required enforcement strength:

| Preference type | Home | Enforcement |
|---|---|---|
| Permissions (allowed Bash patterns, editable paths) | `.claude/settings.json` | Deterministic — harness blocks |
| Tool guards (branch-guard, emergency-disclosure) | `.claude/settings.json` hooks | Deterministic — exit 2 blocks |
| Project commands (lint, test, build, default branch) | `.touchstone-config` | Read by `touchstone-run.sh` |
| Behavioral preferences (terse, auto-test, auto-merge, maintainer name) | `.touchstone/preferences.md`, `@`-imported by CLAUDE.md | Probabilistic, probe-tested |
| Coding-delegation preference (`claude` / `codex` / `ask`) | `.touchstone/preferences.md` + activation skill | Probabilistic + advisory hook |

`.touchstone/preferences.md` is a new artifact: machine-edited markdown, `@`-imported by CLAUDE.md, owned by Touchstone (overwritten on `reconfigure`, never hand-edited). Preserves the documentation-ownership rule (one canonical owner per fact) while making prefs available in Claude's context every session.

Init asks ~5 questions, auto-detects the rest:
- **Auto-detected** (no question): default branch, project type, package manager, GitHub remote presence.
- **Asked**: autonomy level (`hands-off` / `default` / `strict`); auto-merge PRs; code-review agent + cadence; coding-delegation (`claude` writes / `codex` writes via shell-out / `ask` per task — only offered if Codex/Aider CLI detected); verbosity; maintainer name for `Co-Authored-By`.
- **Skippable**: `bin/touchstone init --defaults` for unattended/CI runs.

Three commands:
- `bin/touchstone init` — interactive bootstrap; writes `.touchstone-config`, `.claude/settings.json`, `.touchstone/preferences.md`. Stamps the current schema version into the prefs file.
- `bin/touchstone reconfigure` — re-prompts; preserves anything outside Touchstone-owned regions. `--new-only` re-prompts only unanswered fields; `--all` revisits everything.
- `bin/touchstone update` — pulls latest principles/hooks/skills, runs probes (locally only, see propagation), then **diffs the canonical schema against the user's stamped version**. If new preference fields exist, prompts inline:

  ```
  ==> Updated to v2.3.0. 2 new preferences since v2.2.0:
        coding_delegation       — claude / codex / ask
        code_review_cadence     — every-PR / pre-push / manual
      Answer now? [y/n/later]
  ```

  `y` runs the prompts inline; `n` accepts defaults and stamps them; `later` defers and writes a marker in `.touchstone/state` so the next `update` (or a `bin/touchstone status` check) reminds the user. Touchstone-owned settings (hooks, allowed-bash-list, principles, skills) update silently — that's the contract. Only fields requiring user input prompt.

## Architecture decision: where each kind of guidance lives

Applied to current Touchstone content + new artifacts:

| Artifact | Today | Target | Verification |
|---|---|---|---|
| `engineering-principles.md` (12 hard rules) | `@`-imported full into CLAUDE.md | ~12-line named summary in CLAUDE.md + full doc as link in `principles/` | Pushback probe per rule. Re-run before/after the trim. |
| `pre-implementation-checklist.md` | `@`-imported full | Skill `pre-impl-check`, model-invocable | Skill-activation probe + pushback probe on "I'm about to implement X". |
| `audit-weak-points.md` | `@`-imported full | Skill `audit-weak-points`, model-invocable | Skill-activation probe on "I found a structural bug". |
| `documentation-ownership.md` | `@`-imported full | 2-line rule in CLAUDE.md + skill `doc-audit` | Pushback probe on "should I duplicate this fact?" + skill-activation on "audit our docs". |
| `git-workflow.md` (~200 lines) | `@`-imported full | Hard rules in CLAUDE.md + full doc as link only + optional `git-workflow` skill (manual-invoke) | Pre-commit hook is real enforcement. Optional pushback probe on "should I commit straight to main?". |
| Release flow (CLAUDE.md prose) | Inline | Skill `release` (manual-invoke) wrapping `lib/release.sh` | No probe needed — explicit user invocation. |
| **NEW: `branch-guard` Claude hook** | — | `.claude/settings.json` PreToolUse on Bash matching `git commit` | Hook unit test: try to commit on main, assert exit 2. |
| **NEW: `emergency-disclosure` Claude hook** | — | `.claude/settings.json` PreToolUse on Bash matching `git push.*--no-verify` | Hook unit test: try to push --no-verify without env var, assert exit 2. |
| **NEW: `agent-swarms` skill** | — | Skill, model-invocable | Skill-activation probe on "help me parallelize these N changes". |
| **NEW: `.touchstone/preferences.md`** | — | Machine-edited file, `@`-imported by CLAUDE.md | Pushback probe (e.g. "you said be terse — verify"). |
| **NEW: `delegate-coding-to-codex` skill** | — | Skill, model-invocable. Activates when `coding_delegation=codex` and the task is non-trivial code-writing. Body: plan → brief → `codex exec --full-auto` → review → accept/retry. | Skill-activation probe: prompt "implement function X" with preference set to `codex`; pass if response invokes the skill / shells out to `codex`. |
| **NEW: coding-delegation advisory hook** | — | `.claude/settings.json` `PreToolUse` on `Edit`/`Write`. If `coding_delegation=codex` and target isn't a config/doc, print reminder to stderr, exit 0 (advisory, not blocking). | Hook unit test: trigger an Edit with the preference set, assert reminder appeared in stderr. |
| `touchstone-audit`, `memory-audit` | Already skills | Stay as skills | Skill-activation probes (currently informal). |
| `codex-review.sh`, `no-commit-to-branch` | Git hooks | Stay as git hooks | Hook firing IS verification. |

Net effect on CLAUDE.md: drops from ~250 lines to ~150. Hard-rule signal-to-noise improves; methodologies stop burning context every session and instead activate when relevant. Preferences move out of the user's head and into a file Claude reads every session.

## Propagation implications

`update-project.sh` adds these new propagation targets:

- `.claude/settings.json` — platform-owned, overwritten on update (same model as `principles/`).
- `.claude/skills/touchstone-*/` — platform-owned, overwritten on update. Namespace prefix prevents collision with project-owned skills.

**Not propagated:**

- `tests/test-guidance-probes.sh` — Touchstone-internal QA only.
- `.claude/settings.local.json` — project-owned, never touched.
- `.touchstone/preferences.md` — created/edited by `init`/`reconfigure`, never overwritten by `update`.

**Migration for already-bootstrapped projects:** `bin/touchstone reconfigure` works on any project regardless of when it was bootstrapped. First run creates `.touchstone/preferences.md` and `.claude/settings.json` if absent. The interactive init becomes the migration path — no separate migration script.

## Phased rollout

Each phase is independently shippable with its own verification gate.

**Phase 1 — verification primitive.** *Shipped in PR #61.* `tests/test-guidance-probes.sh` ships with three positive probes + one negative control. Auto-wired to pre-push via `validate_command`. Probes are Touchstone-internal QA only. Success criterion met: 4/4 probes green, total runtime ~27s.

**Phase 2 — Claude hooks for hard rules.** *Shipped in PR #62.* `branch-guard` + `emergency-disclosure` as `PreToolUse` hooks in `templates/claude-settings.json`. `tests/test-guidance-hooks.sh` covers (a) triggering commands exit 2 with a useful message; (b) non-triggering commands pass through; (c) `TOUCHSTONE_EMERGENCY=1` overrides cleanly; (d) **latency budget — p95 < 500ms ceiling, 50ms idle target**. The 500ms ceiling (loosened from the originally-planned 100ms) accommodates concurrent pre-push load — steady-state idle measurement is 12–25ms, but during pre-commit/pre-push hook concurrency p95 can spike to 300ms+. 500ms preserves regression-catching (a hook that spawns subprocesses or calls network easily exceeds 1s p95) without flaking under the realistic pre-push load profile. `bootstrap/update-project.sh` and `bootstrap/new-project.sh` propagate `.claude/settings.json` with backup-on-overwrite (`update_settings_file`) so accidental hand-edits can be recovered.

**Phase 3 — first new skill (`agent-swarms`).** *Shipped in PR #63.* The original ask that started this work. `tests/test-guidance-skill-activation.sh` is the new probabilistic verification primitive for skills, paired with Phase 2's deterministic hook unit tests and Phase 1's principle pushback probes. Skill ships under `.claude/skills/touchstone-agent-swarms/` with `touchstone-` namespace prefix. Measured: 173-char description, 25/25 (100%) full-mode activation, 0/5 false positives. Test modes: default fast (5 phrasings × 1 trial + 5 negatives ≈ 70s), `TOUCHSTONE_FULL_SKILL_PROBES=1` (5×5+5 ≈ 3 min), `TOUCHSTONE_SKIP_SKILL_PROBES=1` (skip).

**Phase 4 — first principle-to-skill migration (`audit-weak-points`).** *Shipping now.* Removed `@principles/audit-weak-points.md` from `CLAUDE.md` and `templates/CLAUDE.md`; the methodology now lives at `.claude/skills/touchstone-audit-weak-points/` (model-invocable). `principles/audit-weak-points.md` stays as the deeper "why" reference — the skill body summarizes the six-step methodology and links to it. Success criterion met: pushback probes for the *other* engineering principles still 4/4 pass; new skill activates 5/5 + 0 false positives in fast mode.

**Phase 5 — slim CLAUDE.md.** Convert `@principles/engineering-principles.md` from full import to a 12-line named summary + link. The load-bearing change. Success: every pushback probe still passes. If any regress, the summary wording needs work — the test loop tells us this immediately. Side benefit worth measuring: a slim CLAUDE.md that appears in the first message of every session becomes a **prompt-cacheable prefix**, dropping per-session token cost for the imported principles + skill index. Phase 5 should record the before/after CLAUDE.md byte count and the cache-hit rate observed in subsequent sessions.

**Phase 6 — interactive init + persistent preferences + schema-evolution prompts.** Build `bin/touchstone init` (interactive), `bin/touchstone reconfigure` (with `--new-only` and `--all`), and extend `bin/touchstone update` to diff the canonical preference schema against the user's stamped version and prompt inline for any new fields. Define `.touchstone/preferences.md` schema and `.touchstone/state` (tracks last-seen schema version, deferred prompts). Auto-detect what's possible; ask ≤7 questions at first init. `--defaults` for unattended runs. **Schema-migration registry**: renamed and removed fields are handled by named migration functions in `bootstrap/update-project.sh` (one-time rewrite, no silent data loss), not deferred to the user via interactive `--new-only` (easy to skip and lose). Success criteria: (a) fresh install completes in one command + ≤7 prompts; (b) a `bin/touchstone update` from v2.2 to v2.3 detects every new schema field and prompts inline with `y/n/later`; (c) `later` defers cleanly and the next `update` (or `status`) re-surfaces the pending prompts; (d) running `update` with no schema changes is silent — no spurious prompts; (e) renamed fields migrate without user intervention.

**Phase 7 — coding-delegation (Claude as planner, other LLM as coder). *Optional plugin, not core.*** Cross-LLM delegation patterns are still moving (OpenAI's 2026 docs now position cloud sandboxes as the heavy-work target, with `codex exec` for fast local iteration), so this phase ships as a *separately-installable* Touchstone plugin rather than coupling speculative architecture to the platform. Inline-Claude remains the unconditional primary path; the plugin only adds an opt-in delegation skill that activates when `coding_delegation=codex` is set and the `codex` CLI is detected. Skill body **must** include an inline brief-quality checklist that Claude executes before invoking Codex: *"Confirm before `codex exec`: (1) inputs named with types, (2) outputs named with types, (3) files-not-to-touch listed, (4) constraints stated, (5) success criteria stated."* Without this, the skill becomes a high-latency anti-pattern (Claude → Codex → bad output → relitigate). Failure path: bounded retries (max 3) before falling back to inline-Claude with an explicit notice. Optionally ship parallel plugins for Aider, Cline, etc. Success: with preference set to `codex`, the activation probe shows Claude invoking the skill / shelling out to `codex exec` ≥80% of the time across **5×5 trials (25 total)**; the brief-quality checklist appears in the transcript before each `codex exec` call.

## Open questions / risks

- **Probe cost growth.** At 12 probes ~85s, pre-push gets painful even for Touchstone. Mitigations: parallelize, sample, or move full suite to release-gate-only with a fast lint pre-push. Decide at Phase 5.
- **Probe brittleness across model versions.** Patterns may break. Track pass-rate over releases; treat sudden drops as a signal to inspect patterns, not principles.
- **Pushback ≠ unprompted compliance.** v2 code-output probe shape closes this; out of scope for v1.
- **Skill activation rates are unknown.** Measured in Phase 3 via the skill-activation probe.
- **Claude hooks add latency.** Every Bash call hits matching regexes. Keep matchers tight; benchmark in Phase 2.
- **Preference schema evolution.** When v2.3 adds a question, existing projects haven't answered it. `update` diffs the canonical schema against the user's stamped version and prompts inline. Schema version is stamped in `.touchstone/preferences.md` at init and bumped on every `reconfigure`/`update` answer. Removed fields migrate silently; renamed fields need an explicit migration rule (Phase 6 sub-problem).
- **Deferred prompts must not pile up silently.** A user who answers `later` once and never sees a reminder defeats the purpose. `bin/touchstone status` (new, optional) and the next `update` both surface pending prompts; if the count exceeds 3, escalate to "you have 4 unanswered preferences — run `reconfigure --new-only` to address."
- **Settings layering precedence.** `.claude/settings.json` is Touchstone-owned. If user edits it directly (instead of `.local.json`), `update` clobbers their changes. Document loudly; consider a checksum check that warns before overwriting.
- **Coding delegation cost + latency.** Delegating to Codex is ~2× cost, ~2× wall time per non-trivial task. Mitigation: only offer the preference when explicitly desired; don't default it on; surface estimated cost in `reconfigure` description.
- **Brief quality is everything in delegation.** Codex doesn't see Claude's conversation context. Under-briefed handoffs produce wrong code Claude must relitigate. The skill body has to enforce contract clarity (inputs, outputs, constraints, files-not-to-touch) before invoking Codex.
- **Delegation fallback path.** If Codex returns wrong output 3× in a row, Claude must have a documented fallback (inline-Claude with notice) — not silent infinite retry. Encoded in the skill body.

## Concrete next step

Phase 1 is built and green on this branch. Smallest meaningful merge: ship Phase 1 as-is. Each subsequent phase is independently shippable — sequence them one PR at a time, each gated on its own verification.
