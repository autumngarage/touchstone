# Local Review — Slice, Tier, Then Ship

You are preparing changes for a clean pull request. The priority is small,
coherent, testable changes with minimal review churn. AI review is never an
excuse to expand scope, refactor adjacent systems, or iterate indefinitely.

This document owns the pre-PR side: work slicing, the review tier, and the
bounded local review. The GitHub side — answering findings, thread resolution,
the round budget, merge — lives in `principles/git-workflow.md` and is not
restated here.

**The tier routes the review invocation — deterministically.** Classify the
change, and the classification picks the review shape; no judgment is left in
the loop:

| Tier | Local pass | Command |
|---|---|---|
| trivial | none | — |
| normal | one direct, cost-bounded OpenRouter review of the staged slice | `touchstone review run` |
| serious | one review of the committed branch, pre-push | `touchstone review run --base <default>` |

The `touchstone review` command is the stable normal-review interface. Its
versioned policy selects the backend and owns the cost limits, so the backend
and routing strategy can evolve without changing the delivery workflow. The v2
backend makes one OpenRouter Chat Completions request using Auto Router's
low-cost tier and absolute prompt/completion price ceilings. It names no
concrete review model; OpenRouter selects for the review prompt and the
command reports what actually ran. The serious pass still prefers Codex: `--base` runs
`codex review` first and falls back to the same bounded request over the branch
range when Codex is unavailable, so an exhausted quota degrades that review
instead of removing it. The PR-side reviewer runs on open regardless and
remains the merge authority.

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

## Scope-expansion checkpoint

A follow-up request approves doing the work; it does not automatically make
that work part of the current review unit. A review unit is one behavioral
invariant with one validation story, not everything accumulated in one
conversation, branch, or eventual "ship everything" request.

Before the first edit for a follow-up that can be reviewed independently:

1. checkpoint the current coherent unit with its commit and PR/tracker context;
2. put the addition in a sequential branch/PR or its own tracked item; or
3. record why the addition is required to make the *same* invariant correct
   and retain the integrated unit.

During exploratory UI work, checkpoint each accepted stable concern instead
of waiting for a final shipping request to create all commits. Where the
project has a release-note contract, decide note or no-note for each unit when
writing its PR context, before commit.

Size is evidence to inspect, never the decision. A theme-picker change that
grows into onboarding, a Metal renderer, command behavior, settings migrations,
and website compatibility has several independent invariants and validation
stories: checkpoint and separate them while that is cheap. A large icon
migration, generated release update, or schema transition stays atomic when
its source, generated artifacts, and callers must land together to avoid an
invalid intermediate state.

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
- Local review: <normal: openrouter on the staged slice (review-normal): <n> findings, <disposition>; serious: codex on <captured-head-sha>: <n> findings, <disposition>; or n/a — <reason>>
- Review budget: v2 capability=<tracker ref> local_rounds=<local review passes> fix_rounds=<fix rounds spent on this PR> prior_fix_rounds=<fix rounds on this capability's replaced PRs> reviewed_head=<40-character SHA or none> cascade=<true|false> exit=<continue|merge-answered|revert-simplify|split|close-replan>

## Out of scope
<intentionally excluded related work>

## Review tier
<trivial | normal | serious>

## Why this tier
<one or two concrete sentences from the rules below>
```

Never claim a build, test, or manual validation happened unless it actually
ran.

The versioned `Review budget` row **is** the budget ledger; nothing else records
what has been spent. `fix_rounds` counts the fix rounds spent on this PR and is
incremented as each one is pushed, `prior_fix_rounds` carries those already spent
on this capability's replaced PRs, and `local_rounds` counts local review passes.
The count is written here rather than inferred from history because amend,
squash, and rebase rewrite commit boundaries and lose push grouping
(`principles/git-workflow.md`). Update the row after the local pass and as each
fix round is pushed, and carry the current count into `prior_fix_rounds` when
replacing a PR; a provider retry on the same
head is not a round, and neither is an attest request, because a fix round is a
push of review-driven change (`principles/git-workflow.md`). Row version 2
renamed `prior_hosted_rounds` to `prior_fix_rounds` when the budget moved from
counting requests to counting mutation. A `v1` count is **not** convertible:
it counted finding-bearing rounds including answer-only ones, so reading it as
fix rounds overstates the spend and can exhaust a replacement PR's budget
against work that never spent it. Treat a `v1` count as unknown, or
reconstruct the fix rounds from the replaced PR's pushed heads. `reviewed_head` records the exact head the local pass
saw, `cascade=true` means a review fix created another defect, and `exit`
records the chosen stop path. A missing row is compatible with older PRs but
reports unknown cross-PR history; it never waives the required exact-head PR
review.

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
trigger. Path: deterministic checks, the offline policy/credential preflight,
then **one** direct OpenRouter pass once the staged change is coherent, one
bounded fix pass, commit, open the PR.

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

At most once per coherent normal change, after deterministic checks pass. Stage
only the intended slice; unstaged and untracked files are deliberately excluded.
The command fails before credential lookup or network access when the staged
diff is empty or the request exceeds the configured input limit.

The normal credential is configured once per machine with:

```bash
touchstone review setup
```

On macOS, setup securely prompts for a dedicated OpenRouter key and saves it in
Keychain. Use a key dedicated to review and set its monthly spending limit in
OpenRouter. Already-running Claude, Codex, and Gemini sessions need no
environment refresh, and future reviews need no approval prompt. `touchstone
steering install` offers this setup during interactive onboarding.

The versioned non-secret policy is `config/review-normal.json`; the review
instructions are `config/review-normal-prompt.md`. The current policy uses
`openrouter/auto` with Auto Router's low-cost tier, provider price ceilings of
$0.50 per million prompt tokens and $2.00 per million
completion tokens, a 100,000-byte request ceiling, and 4,096 completion tokens.
Changing those parameters or adding a backend is a reviewable policy/adapter
change behind the same command.

Check the complete local boundary without making a provider request, then run:

```bash
touchstone review check
touchstone review run
```

The v1 backend sends the staged diff as untrusted data in one direct request.
No tools or agent loop are present, and no repository command can be issued by
the model. The request requires structured JSON, filters providers above the
absolute price ceilings, and prints the selected model, prompt/completion
tokens, exact reported cost, findings, and evidence prefix. Provider, timeout,
malformed-output, and truncation failures stop without retrying.

If the check or run fails, record a reasoned normal-tier `n/a` waiver naming its
concise cause and stop; never fall back to an unbounded model path. Do not retry
or inspect credentials. Use `touchstone review setup` for a missing credential
or `touchstone review rotate` for a rejected one. For the serious pass, capture
`reviewed_head="$(git rev-parse HEAD)"` immediately before
`touchstone review run --base <default>` after the branch is committed. It runs Codex and falls back to the bounded OpenRouter pass over the same branch on any Codex non-success, including an exhausted quota. Which one
ran is in its output; record that reviewer. The captured current head is the
immutable revision the pass reviews; `<default>` is only its comparison
boundary. Record the captured head, never the symbolic base.
The pass runs at most once before its first push.
After allowed local findings are fixed, deterministic checks run again and the
hosted PR reviewer owns exact-head review for every pushed head; another local
pass is neither required nor authorized.

The one-request rule limits accidental spend and makes permanent provider
failures terminal instead of retry loops. When a quota or key limit is
exhausted, the normal tier's local obligation is satisfied by deterministic
checks plus recording that failure in the validation block; the serious tier
falls back first, and waives only if the fallback is also unavailable. The
PR-visible review is the authority either way.

Afterwards: triage each finding as valid, false positive, duplicate, or out of
scope; apply valid **P0/P1** fixes and answer-and-route every valid P2 and P3,
exactly as the delivery contract does on the PR side; do not
re-run the pass to confirm the reviewer is now quiet; never expand the slice
to address adjacent or pre-existing findings. If a review fix creates another
defect, stop patching forward and follow the review-fix cascade rule in
`principles/git-workflow.md`.

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
- Local review: openrouter on abc1234: 2 findings, 1 fixed, 1 routed to AUT-n — codex is out of credits.
- Local review: openrouter on the staged slice (review-normal): 0 findings.
- Local review: n/a — `touchstone review check` reports that the OpenRouter credential is not configured.
- Local review: n/a — the gate is on its fallback reviewer, which shares the OpenRouter account with the local pass.
- Local review: openrouter on abc1234: 0 findings.   # a normal change reviewed with --base
```

A normal change may record the range pass (`touchstone review run --base
<default>`, which names the revision it reviewed) instead of the staged
slice: it reviews the whole committed branch, so it is more evidence, and the
gate accepts it. The reverse is not true — a serious change must record the
revision it reviewed, never a staged slice.

While the pinned gate is reviewing heads itself (the primary reviewer is out
of quota or down), waive the local pass with that last reason: the local pass
and the gate draw on one OpenRouter account, and a local pass that starves
the gate delays the review that counts. The exact-head gate is the review.

The row begins with `openrouter on the staged slice (review-normal): <n> findings`
for normal, or `<reviewer> on <captured-head-sha>: <n> findings` for serious,
where the reviewer is whichever one the command reported. Prose and
dispositions go after the count; backticks around a SHA are fine — and
`delivery-evidence` refuses a normal or serious PR whose row is missing, a bare
`n/a`, a serious reviewer that is neither, a serious target without the
reviewed revision, a normal target that is a bare revision, or a waiver without
a reason. The target shape, not the reviewer name, keeps the tiers apart:
serious names a revision, normal names a slice.
When the row is present but unreadable it says so and quotes the line.
The gate checks shape, not truth — it cannot see a terminal — but it can
refuse silence, and silence was the failure. For normal, a waiver is only the configured check or run failing.
Serious may waive only when Codex and the fallback are both unavailable.
Either waiver says which concrete boundary failed.

## Stop conditions

Review is complete when deterministic checks pass (or are recorded as not
applicable), the intended validation scenario passes, valid findings are
handled, no merge-blocking finding remains, and the tier's review obligation
is met:

- **trivial** — no initiated review; deterministic checks alone complete it.
- **normal** — one local pass has run and its findings are triaged, **or**
  the recorded waiver applies (the configured check or run fails — recorded in
  the validation block).
- **serious** — the pre-push local pass ran, under whichever reviewer the
  command reached, or the waiver for both being unavailable is recorded, and
  the PR-side review evidence covers the head that merges (the gate enforces
  the latter). A normal-review failure never waives this pass.

After a bounded pass, fix the valid findings, **re-run every applicable
deterministic check and the intended validation scenario** — a valid fix can
break what already passed — and stop. Do not run a
confirming local pass to see whether the reviewer is satisfied. If a fix
materially changes the risk surface — a new serialization format, ownership or
threading change, security boundary, or public contract — stop and replan; it
does not earn another local review loop.

**A fix commit moves the head, and exact-head review of the merged head is
never optional.** What this document bounds is how much you *implement* and
how many *initiated* passes you run — never whether the head that merges was
reviewed. After a fix commit, follow `principles/git-workflow.md`: batch every
allowed fix into one commit, push once, and take one review for that head. Do not run
an extra initiated pass merely because the previous round found something;
that is a different thing from the exact-head review the gate requires, and
exact-head review does not authorize another mutation after a cascade stop.

## Commit discipline

Each commit builds (or is a stated atomic sequence that builds at its end),
has one purpose, carries no unrelated formatting or generated artifacts,
includes tests with the behavior change when practical, and describes the
behavioral change rather than implementation churn. Before committing,
summarize: files changed, behavioral intent, validation completed, tier and
rationale, and whether the local reviewer ran with the disposition of its
findings.
