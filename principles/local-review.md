# Local Review — Slice, Tier, Then Ship

You are preparing changes for a clean pull request. The priority is small,
coherent, testable changes with minimal review churn. AI review is never an
excuse to expand scope, refactor adjacent systems, or iterate indefinitely.

This document owns the pre-PR side: work slicing, the review tier, and the
bounded local review. The GitHub side — answering findings, thread resolution,
the round budget, merge — lives in `principles/git-workflow.md` and is not
restated here.

**The tier routes the Codex invocation — deterministically.** Classify the
change, and the classification picks the review shape; no judgment is left in
the loop:

| Tier | Local pass | Command |
|---|---|---|
| trivial | none | — |
| normal | one Codex pass of the staged slice, through Touchstone's lower-cost `review-normal` profile | `touchstone review run` |
| serious | one Codex review of the branch, pre-push | `codex review --base <default>` |

One harness keeps the procedure stable. Touchstone owns the normal profile as
a machine-wide cost boundary: it routes the bounded local pass through
OpenRouter's Pareto Code router at medium reasoning, while the serious pass and
PR-side reviewer remain on the default Codex path. The PR-side reviewer runs on
open regardless and remains the merge authority.

Local Codex reads `AGENTS.md` and applies its rules as review authority —
observed citing this repository's own rule lines in findings — so durable
review rules belong there, not in per-run prompts. (Its CLI accepts either
`--base` or a custom prompt, not both, which makes `AGENTS.md` the only
reliable channel for standing instructions.)

## Work slicing

Before editing, identify the smallest independently reviewable unit.

A good slice has one behavioral goal, changes one subsystem or one well-defined
interface boundary, can be validated with a focused build, test, or manual
scenario, and is small enough to understand from the description and diff.

Split before committing if any are true:

- The change affects more than one unrelated behavior.
- A behavior change is mixed with a broad refactor, rename, or formatting
  sweep (`Separate behavior changes from tidying`, in the engineering
  principles, is the standing rule).
- Generated files or lockfiles ride along with substantive code — **unless**
  the generated output is required to stay in sync with the source changed in
  the same slice (rendered steering surfaces, compiled schemas). Those land
  together; splitting them ships a broken intermediate state.
- The change cannot be explained in two sentences.
- Validation requires multiple independent scenarios.
- A public-interface change plus its call-site migration obscures the intended
  behavioral change.

Prefer several coherent slices over one mixed change — but never split an
atomic correctness change merely to reduce line count. A migration, API
change, or invariant change stays one slice when its pieces must land
together.

## Required PR context

Write the context before committing. The `Local review` row is the one
field that cannot be truthful yet: fill it after the tier's pass has run
(normal: before the commit; serious: after it, before the push) and before
the PR is opened.

```markdown
## Intent
<the exact user-visible or system behavior this change creates or fixes>

## Invariants
<conditions that must remain true>

## Risk areas
<only real risks introduced by this change>

## Validation
- Build: <exact command and result>
- Automated tests: <exact command and result>
- Manual validation: <specific scenario and result>
- Local review: <codex on <target>: <n> findings, <disposition> — or n/a — <reason>>

## Out of scope
<intentionally excluded related work>

## Review tier
<trivial | normal | serious>

## Why this tier
<one or two concrete sentences from the rules below>
```

Never claim a build, test, or manual validation happened unless it actually
ran.

## Tier classification

Deterministic rules; classify every change.

**Trivial** — *inert* documentation, comments, or formatting-only;
generated-file-only or lockfile-only; a low-risk mechanical rename with no
behavior change; or a change fully covered by deterministic checks with no
logic or interface risk. Path: deterministic checks only. No initiated review.

Documentation is not automatically inert. A change to steering, policy, or any
prompt that directs how agents work — `TOUCHSTONE.md`, `AGENTS.md`,
`CLAUDE.md`, `GEMINI.md`, the routed principles, repository policy — alters how
every consumer project ships. Tier those by the blast radius of the behavior
they change, never as trivial.

**Normal** — ordinary contained work: small bug fixes, isolated application
logic, localized implementation changes, safe refactors preserving a clearly
testable behavior, anything with a focused validation path and no serious
trigger. Path: deterministic checks, the readable-profile preflight, then
**one** local Codex pass once the change is coherent, one bounded fix pass,
commit, open the PR.

**Serious** — any of: networked or distributed state (RPCs, replication,
client/server authority, prediction); concurrency (async handoff, scheduling,
locks, races, ownership, lifetimes, unsafe callbacks); persistence
(serialization, migrations, backward compatibility, irreversible transitions,
data-loss risk); security (authentication, authorization, secrets, user data,
payments, exposed APIs); public interfaces used by multiple subsystems;
performance-critical paths; broad agent-generated or cross-system diffs that
one focused scenario cannot validate; anything expensive to diagnose or roll
back after merge. Path: deterministic checks, then one local Codex review of
the branch before push — the only review a driver *initiates* for this tier.
The deep review of the stable PR is the PR-side review that repository policy
runs on open; it is the merge authority, not a second request, and a fix
commit takes its one exact-head re-review per `principles/git-workflow.md` —
never one per push.

When torn between normal and serious, pick serious only for genuinely high
blast radius. Many lines is not a trigger.

## Deterministic checks first

Before any AI review: `git diff --check`, formatter/linter, targeted build,
targeted tests, static analysis where available, and a focused manual test for
what automation does not cover. Projects with a schema-2 declaration run
`touchstone validate --stage commit`. AI review complements these; it never
replaces them.

A check that does not apply is recorded as `n/a` with the reason — a
documentation-only change has no targeted build. Recording `n/a` is honest;
claiming a check ran is not, and the two must never be confused.

## The local review pass

Once per coherent normal change, after deterministic checks pass. Stage only
the intended slice; exclude unrelated files, accidental formatting, and any
generated artifact that is not required to land with this change. State the
intent and risks. Codex's `--uncommitted` mode sees staged, unstaged, and
untracked changes, so isolate the slice before running it; do not let unrelated
dirty state ride along.

The normal credential is configured once per machine with:

```bash
touchstone review setup
```

On macOS, setup securely prompts for a dedicated OpenRouter key and saves it in
Keychain. For each run, the launcher stages the canonical profile in a
disposable Codex home, passes the key only to that Codex parent process, and
removes it from model-issued subprocess environments. Already-running Claude,
Codex, and Gemini sessions need no environment refresh, and future reviews need
no approval prompt. `touchstone steering install` offers this setup during
interactive onboarding. The shipped config shape is owned by
`config/review-normal.config.toml`; credentials never appear in it.

Check the complete boundary before invocation because Codex 0.149 falls back
silently when a named profile file is absent (AUT-500), and an unavailable
credential fails later with less useful context:

```bash
touchstone review check
touchstone review run
```

If the check fails, do not invoke Codex: record a reasoned `n/a` waiver naming
its concise cause. If the configured-profile command exits nonzero, record its
concise cause as the waiver and stop. Never fall back silently to the default
profile: doing so defeats the cost boundary and misstates which review ran.
Do not retry or inspect credentials; the operator recovery is `touchstone
review setup` for a missing boundary or `touchstone review rotate` for a
rejected credential. The serious pass remains `codex review --base <default>`
after the branch is committed.

**Local passes and PR-side reviews can share one metered pool**, depending on
the provider's plan. A driver that re-runs locally after every edit is then
spending the budget the merge gate depends on — a second reason the rules
above allow one pass per coherent slice and no confirming re-run. When a
quota is exhausted, the tier's local obligation is **satisfied by its
deterministic checks plus recording the exhaustion** in the validation block
— the same rule as a machine where Codex is unavailable. Do not wait for quota
to run an initiated pass; the PR-visible review is the authority either way.

Afterwards: triage each finding as valid, false positive, duplicate, or out of
scope; apply valid **high-severity** fixes and answer-and-route valid findings
below the bar, exactly as the delivery contract does on the PR side; do not
re-run the pass to confirm the reviewer is now quiet; never expand the slice
to address adjacent or pre-existing findings.

## Repository policy still runs

Tiers govern review **you initiate**. A repository's configured reviewers run
on PR open regardless of tier, and their findings are answered under
`principles/git-workflow.md` — classified against the severity bar, fixed or
routed, threads resolved. A trivial tier is not an exemption from the merge
gate; it only means you request nothing extra.

## Evidence

The local pass is the one step of the delivery contract that no gate
witnesses on its own: hooks gate commits, `delivery-evidence` gates the PR
body, `review-gate` gates the PR review, the ruleset gates thread
resolution. On 2026-08-21 an agent shipped four PRs with the tier declared
in each body and never ran the pass; when it finally did, `codex review
--base main` returned seven findings the PR-side reviewer had missed across
three rounds (AUT-443). So the pass leaves evidence where the gate reads:
the PR body's Validation block carries

```markdown
- Local review: codex on abc1234: 3 findings, 2 fixed, 1 routed to AUT-n.
- Local review: codex on the staged slice (review-normal): 0 findings.
- Local review: n/a — `touchstone review check` reports that the OpenRouter credential is not configured.
```

The row *begins* with `codex on <target>: <n> findings` — prose and
dispositions go after the count; backticks around a SHA are fine — and
`delivery-evidence` refuses a normal or serious PR whose row is missing, a bare
`n/a`, a serious reviewer other than Codex, a serious target without the
reviewed revision, a normal target that is a bare revision, or a waiver without
a reason.
When the row is present but unreadable it says so and quotes the line.
The gate checks shape, not truth — it cannot see a terminal — but it can
refuse silence, and silence was the failure. For normal, a waiver is only the
managed profile check failing, its configured run exiting nonzero, or Codex being
absent, unauthenticated, or out of quota. Serious may waive only when Codex is unavailable.
Unavailable means absent, unauthenticated, or out of quota; either waiver says which.

## Stop conditions

Review is complete when deterministic checks pass (or are recorded as not
applicable), the intended validation scenario passes, valid findings are
handled, no merge-blocking finding remains, and the tier's review obligation
is met:

- **trivial** — no initiated review; deterministic checks alone complete it.
- **normal** — one local pass has run and its findings are triaged, **or**
  the recorded waiver applies (the normal profile check fails, its configured
  pass exits nonzero, or Codex is unavailable — recorded in the validation
  block).
- **serious** — the pre-push local pass ran or its Codex-unavailable waiver is
  recorded, and the PR-side review evidence covers the head that merges (the
  gate enforces the latter). A normal-profile failure never waives this pass.

After a bounded pass, fix the valid findings, **re-run every applicable
deterministic check and the intended validation scenario** — a valid fix can
break what already passed — and stop. Do not run a
confirming local pass to see whether the reviewer is satisfied; run another
only if a fix materially changed the risk surface — a new serialization
format, ownership or threading change, security boundary, or public
contract.

**A fix commit moves the head, and exact-head review of the merged head is
never optional.** What this document bounds is how much you *implement* and
how many *initiated* passes you run — never whether the head that merges was
reviewed. After a fix commit, follow `principles/git-workflow.md`: batch every
fix into one commit, push once, and take one review for that head. Do not run
an extra initiated pass merely because the previous round found something;
that is a different thing from the exact-head review the gate requires.

## Commit discipline

Each commit builds (or is a stated atomic sequence that builds at its end),
has one purpose, carries no unrelated formatting or generated artifacts,
includes tests with the behavior change when practical, and describes the
behavioral change rather than implementation churn. Before committing,
summarize: files changed, behavioral intent, validation completed, tier and
rationale, and whether the local reviewer ran with the disposition of its
findings.
