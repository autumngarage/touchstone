# Local Review — Slice, Tier, Then Ship

You are preparing changes for a clean pull request. The priority is small,
coherent, testable changes with minimal review churn. AI review is never an
excuse to expand scope, refactor adjacent systems, or iterate indefinitely.

This document owns the pre-PR side: work slicing, the review tier, and the
bounded local review. The GitHub side — answering findings, thread resolution,
the round budget, merge — lives in `principles/git-workflow.md` and is not
restated here.

**Reviewer vendors are named once, here.** The local reviewer is the CodeRabbit
CLI; the PR deep reviewer is Codex. Swapping either changes this paragraph and
nothing else.

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
- Generated files or lockfiles ride along with substantive code.
- The change cannot be explained in two sentences.
- Validation requires multiple independent scenarios.
- A public-interface change plus its call-site migration obscures the intended
  behavioral change.

Prefer several coherent slices over one mixed change — but never split an
atomic correctness change merely to reduce line count. A migration, API
change, or invariant change stays one slice when its pieces must land
together.

## Required PR context

Write this before committing or opening the PR:

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
trigger. Path: deterministic checks, then **one** local-reviewer pass once the
change is coherent, one bounded fix pass, commit, open the PR.

**Serious** — any of: networked or distributed state (RPCs, replication,
client/server authority, prediction); concurrency (async handoff, scheduling,
locks, races, ownership, lifetimes, unsafe callbacks); persistence
(serialization, migrations, backward compatibility, irreversible transitions,
data-loss risk); security (authentication, authorization, secrets, user data,
payments, exposed APIs); public interfaces used by multiple subsystems;
performance-critical paths; broad agent-generated or cross-system diffs that
one focused scenario cannot validate; anything expensive to diagnose or roll
back after merge. Path: deterministic checks, optionally one local pass for
obvious current-diff defects, make the PR coherent and stable, then **one**
deep review on the stable PR before merge — never on every push.

When torn between normal and serious, pick serious only for genuinely high
blast radius. Many lines is not a trigger.

## Deterministic checks first

Before any AI review: `git diff --check`, formatter/linter, targeted build,
targeted tests, static analysis where available, and a focused manual test for
what automation does not cover. Projects with a schema-2 declaration run
`touchstone validate --stage commit`. AI review complements these; it never
replaces them.

## The local review pass

Once per coherent normal change, after deterministic checks pass. Stage only
the intended slice; exclude unrelated files, generated artifacts, and
accidental formatting. State the intent and risks. Use this contract:

> Review only the staged diff against the stated intent and invariants.
> Report at most 3 high-confidence, actionable defects introduced by this
> change. Prioritize crashes, incorrect behavior, data loss, security issues,
> broken contracts, unsafe lifetimes, concurrency failures, compatibility
> breaks, and meaningful performance regressions. For every finding: cite the
> exact file and code path, explain the concrete failure scenario, propose the
> minimal local fix. Do not report style, naming, formatting, comments,
> refactors, cleanup, architecture proposals, pre-existing issues, speculative
> concerns, or anything outside the stated scope. If no high-confidence issue
> exists, say: "No high-confidence defects introduced by this diff."

Afterwards: triage each finding as valid, false positive, duplicate, or out of
scope; apply only valid fixes; never re-run until the reviewer says nothing;
never expand the slice to address adjacent or pre-existing findings.

## The deep review pass

Only for a stable serious PR — never while the implementation is still moving.
Give the reviewer the full PR context block above. Use this contract:

> You are the final reviewer for this serious pull request. Report at most 3
> high-confidence, merge-blocking findings introduced by this PR that violate
> its stated intent or invariants. Prioritize crashes, corruption, data loss,
> irreversible bad state, incorrect distributed-state behavior, concurrency
> races, invalid lifetimes, serialization or compatibility breakage, security
> failures, public-contract breaks, and hot-path performance regressions. For
> every finding: exact location, the concrete execution or state-transition
> failure path, why this PR caused it, and the minimal fix. Do not report
> style, refactors, architectural alternatives, pre-existing defects, or
> low-confidence concerns; report a missing test only when the changed
> behavior cannot be safely validated without it and you can name the concrete
> failure it would catch. If there are no merge-blocking issues, respond
> exactly: "No merge-blocking findings."

## Repository policy still runs

Tiers govern review **you initiate**. A repository's configured reviewers run
on PR open regardless of tier, and their findings are answered under
`principles/git-workflow.md` — classified against the severity bar, fixed or
routed, threads resolved. A trivial tier is not an exemption from the merge
gate; it only means you request nothing extra.

## Stop conditions

Review is complete when deterministic checks pass, the intended validation
scenario passes, the tier's one review has run, valid findings are handled,
and no merge-blocking finding remains.

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
