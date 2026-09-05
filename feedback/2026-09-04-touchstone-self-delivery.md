# Dogfood: shipping Touchstone with Touchstone, 3.10.2 → 3.10.7

**From:** Claude Code (Opus 5), one continuous session delivering twelve pull requests across three repositories
**Touchstone version:** 3.10.2 at the start (brew), 3.10.7 at the end
**Platform:** macOS 26 (Darwin 25.5.0, arm64)
**Date:** 2026-09-04 / 05
**Conditions:** the primary reviewer (Codex) was quota-exhausted for the entire session, 09-03 through 09-06, so **every** `pr open` ran on the gate's own fallback

---

## Summary

The headline finding is not any one bug. It is that **five separate components each reported local success while nothing had been delivered**, and every one of them was caught only by checking the artifact rather than believing the report.

| Component | What it said | What was true |
| -- | -- | -- |
| `tests/test-github-policy.sh` | pin bump valid | the pinned workflow had never executed and aborted on every run |
| touchstone#1137's PR body | "effective rulesets on all six repositories read `46efeaad` after apply" | nothing had been applied anywhere |
| `brew upgrade` + `touchstone upgrade` | "already installed", "already current" | the CLI was a release behind and steering was stale |
| `skills/touchstone-git-workflow/SKILL.md` | read `"Review fallback in effect"` | that string had been replaced hours earlier |
| this session's own reports (twice) | work complete / a solved problem is a risk | neither was true |

Three of the five I caused or missed myself. That matters for the conclusion: the failure mode is not carelessness, because ordinary care did not catch it. What caught it every time was grepping the installed file, fetching the historical artifact, or reading `--help`.

## 1. A required workflow was pinned without ever having executed

`touchstone-workflows` `46efeaa` assigned `touchstone_revision` in one `run:` block and consumed it in the next. Each block is its own shell, so under `set -u` every `delivery-evidence` run died with

```
line 14: touchstone_revision: unbound variable
```

**before reading any PR body.** I merged the pin (#1137, pre-existing), ran `github-policy.sh apply`, and took all delivery in `autumngarage/touchstone` down. Job `101197996712`.

The static suite in `touchstone-workflows/tests/test-workflow.sh` — 1,230 lines as it stood before `#41` added to it — could not see this, and no stronger pattern would have: the name is present and correctly spelled in both blocks, and only the scope between them is wrong. **Static text cannot show scope.**

Fixed: `touchstone-workflows#40` ($GITHUB_ENV), `#41` (a cross-step scope guardrail proven against `46efeaa` itself), touchstone#1141 (repin). Tracked as AUT-1263.

**Worth recording:** my first version of that guardrail produced **79 false positives** on `main`, almost all `$var` references inside `review-gate.yml`'s embedded jq programs. A guardrail that cries wolf in a 47 KB file of jq would have been worse than none. The shipped version only suspects a name some `run:` block actually assigns as a shell variable.

## 2. The measurement that explains the whole session

Two classes of duplicated fact, counted on 2026-09-04:

| Fact | Copies | Drift |
| -- | -- | -- |
| The pinned workflow revision | **7 files** | **none, ever** |
| How the serious tier's local review falls back | **9 documents** | 3 stale, 2 self-contradicting |

Seven copies of the pin have never drifted, because a test asserts they are identical. Nine copies of the fallback rotted because nothing asserts agreement.

That is Touchstone's own principle — *derive, don't persist; persist derived state only with a documented invalidation path* — being honoured for one class of fact and not the other. The pin's invalidation path is a test. Prose's was "someone remembers."

Concretely, in one session:

- `docs/product-contract.md` asserted the serious path was unchanged at line 62 and described how it had changed at line 70 — one section contradicting itself, and a top-down reader takes the first claim.
- `TOUCHSTONE.md` said the pinned gate reviews the head itself, then told the driver to *"Keep watching, then use bounded stalled-request recovery"* — installed machine-wide on every driver.
- `principles/ai-delivery-architecture.md` stated the behavior-v2 answer gate as an unconditional merge rule, and claimed the serious tier was Codex-only.
- The git-workflow skill pointed agents at two output strings #1143 had replaced — **in a file #1143 itself edited.**

Fixed reactively, one assertion per fact, in #1143, #1145 and #1148. Tracked as AUT-1272 for the systematic pass.

## 3. Stale tracker text is more expensive than stale code

AUT-1236 said *"a false positive P1 has no answer-and-resolve path (the gate is read-only)"*. True when written on 09-03. Invalidated hours later by #1123, #1128 and #1135 — `touchstone pr answer --finding`. The issue was closed for its own scope; the sentence was never corrected.

I then, over several hours:

1. argued the gate reviewing the head itself was a layering violation — that a deliberately chosen design was a defect;
2. filed AUT-1266 on that premise (cancelled);
3. rewrote it on a second false premise (cancelled again);
4. filed AUT-1260, duplicating a fix that shipped in #1136 **five hours before I filed it** (cancelled);
5. told the product owner a solved problem was an unresolved risk.

**#1135 was the HEAD commit of the repository when the session began.** Every one of those four turns was avoidable by running `respond-review.sh --help`.

A *negative* claim is the most dangerous kind of stale, because it stops the reader looking. "Check the code before trusting an issue" was already the instinct and it failed anyway, four times, because a detailed issue body outweighs a flag in help text. Fixed as a contract rule in #1150: correcting a closed item's body is part of closing it. Tracked as AUT-1271.

## 4. A release is not a deployment

`TOUCHSTONE.md`, `principles/`, and the Claude skills are installed **machine-wide by the tool**. Merging a contract fix to `main` reaches nobody.

Worse, `brew upgrade touchstone` refreshes the CLI and deliberately leaves steering alone — and its caveat said *"brew upgrade updates this tool only; it never modifies a repository."* True, reassuring, and silent about the thing that matters. I read that line, reported the upgrade complete, and left every agent on the machine reading a contract three releases old — including the self-contradicting quota paragraph the release existed to remove.

Then `touchstone upgrade` itself no-opped against cached tap metadata and reported *"already current: machine-level steering matches the contract"* while the CLI stayed at 3.10.5 and v3.10.6 was already published.

The verification that works, and the only one I now trust:

```sh
brew update && touchstone upgrade
grep -c "<a phrase from the change>" ~/.codex/AGENTS.md   # verify, do not infer
```

Fixed: `homebrew-touchstone#4` (the caveat names the skew), touchstone#1147 (`brew update` first), #1151 (report the version transition, and run `steering check` afterwards so install's "nothing to do" is verified rather than trusted). Tracked as AUT-1270.

## What the contract got right

Recording this because a dogfood note that only complains is not evidence.

- **The sequencer turned a silent failure loud.** `shfmt` rejected a subshell's spacing, the pre-commit hook ate the commit, and the push pushed nothing. `pr open` refused with *"No commits between main and …"* rather than proceeding. Without that refusal I would have reported a shipped fix that did not exist.
- **The waiver worked as designed.** A local OpenRouter pass timed out (`curl 28`) on #1151. The tier permits one pass and the error says the request was not retried, so I recorded the waiver instead of re-rolling for a clean result. I read the evaluator to get the accepted waiver shape rather than guessing.
- **The gate fallback held under exactly the conditions it was built for.** Codex was out for the whole session. `delivery-evidence` and `review-gate` both passed on `pull_request` **and** `merge_group` runs with the primary unavailable — which is AUT-1234's precise failure condition, now closed.
- **The local pass earned its cost.** On #1145 it caught a real contradiction my own fix had introduced (`ai-delivery-architecture.md:81` claiming a Codex-only serious tier). It named the wrong line — 85 rather than 81 — but the claim was real, and routing it would have shipped the defect the PR existed to remove.
- **`apply` regenerating invalidated evidence** meant a policy change mid-flight re-triggered the affected PRs automatically instead of stranding them.

## The one thing I would change about the contract itself

Every defect above is a component reporting *local* success. Each was individually honest. Nothing composed them, so nothing could answer "is this actually deployed?" — and the answer was no, five times.

I do not think the fix is a `doctor` command; that is the accretion this repository explicitly warns about, and it would serve the agent rather than constrain it. The fix is the cheaper one: **a claim of delivery must name the artifact it verified.** #1148 now says a `Validation` row records what was observed at the reviewed head, and that a post-merge step is recorded as pending, never as done. That rule, applied honestly, would have caught #1137 — the one false claim that started the outage.

## Filed from this session

`AUT-1263` (pin executed before it can be required — half fixed, one decision open) · `AUT-1270` (upgrade verifies what it delivered — fixed) · `AUT-1271` (correct a closed item's body — fixed) · `AUT-1272` (bind or delete every duplicated fact — open, the class fix) · `AUT-1268` (54 stale branches from earlier sessions, routed not deleted)

Cancelled from this session, and why they are listed: `AUT-1266` ×2 and `AUT-1260` were mine, all three wrong, all three from stale tracker text. They are the evidence for AUT-1271.
