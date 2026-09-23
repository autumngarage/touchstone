# Before the PR — Slice, Tier, Then Ship

You are preparing changes for a clean pull request. The priority is small,
coherent, testable changes with minimal review churn. Review is never an
excuse to expand scope, refactor adjacent systems, or iterate indefinitely.

This document owns the pre-PR side: work slicing, the review tier, and the
evidence the PR body carries. The GitHub side — answering findings, thread
resolution, the round budget, merge — lives in `principles/git-workflow.md`
and is not restated here.

**No AI review runs before the PR, in any tier.** The local pass this
document used to own is retired (AUT-1962). Review is the hosted
`review-gate`'s, on the exact head GitHub merges: where the primary reviewer
is at capacity, the pinned gate reviews the head itself. The file keeps its
name because the `delivery-evidence` gate and consumer PR templates route here.

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

## Exploration and shipping

Start shipping preparation when the user says the unit is ready to ship,
wrap up, or create a PR. A general implementation request, a passing check,
a pause in conversation, or the end of an agent turn is not that decision.
An explicit instruction to implement and ship already authorizes the
transition once the requested work is complete; do not ask again.

While iterating, defer test authoring and scaffolding, final documentation,
release notes, broad validation runs, and PR preparation and creation. Use
the smallest manual check or existing test that answers the current
uncertainty. Repeat a check only when relevant code or inputs change, it
fails, or new evidence warrants it. Keep necessary correctness decisions and
recovery notes as you work. Explicit requests for tests, documentation, or
test-first development take precedence.

Once the user ends iteration, complete the required coverage, documentation,
and validation before pushing and creating the PR. Then drive the authorized
delivery lifecycle without asking at each step. If iteration resumes, defer
unfinished shipping preparation again and revalidate affected behavior when
the unit is ready. Required checks and
exact-head review remain mandatory for every head that ships.

## Cadence

Commits and PRs have different costs, so they get different rhythms.

Preserve coherent local checkpoints during iteration; a checkpoint does not
trigger shipping preparation, a push, or a PR. Keep the branch and tracked
scope legible so another session can resume it.

A PR carries fixed overhead regardless of size: the evidence body, the
hosted gate run, and a merge-queue entry. Spend it once per complete
invariant after the shipping decision and validation. Do not open one per
commit — a PR that ships half an invariant pays the overhead twice and
reviews a state nothing can validate.

If work outlives the session, leave a checkpoint and the remaining scope.
A session ending or another PR merging does not authorize shipping.

## Scope-expansion checkpoint

A follow-up request approves doing the work; it does not automatically make
that work part of the current review unit. A review unit is one behavioral
invariant with one validation story, not everything accumulated in one
conversation, branch, or eventual "ship everything" request.

Before the first edit for a follow-up that can be reviewed independently:

1. checkpoint the current coherent unit with its commit and tracker context;
2. put the addition in a sequential branch/PR or its own tracked item; or
3. record why the addition is required to make the *same* invariant correct
   and retain the integrated unit.

During exploratory UI work, checkpoint each accepted stable concern. Prepare
its PR context and any required release notes after the shipping decision.

Size is evidence to inspect, never the decision. A theme-picker change that
grows into onboarding, a Metal renderer, command behavior, settings migrations,
and website compatibility has several independent invariants and validation
stories: checkpoint and separate them while that is cheap. A large icon
migration, generated release update, or schema transition stays atomic when
its source, generated artifacts, and callers must land together to avoid an
invalid intermediate state.

## Required PR context

Use the concise-writing guidance in `principles/git-workflow.md`.
Write the context before the shipping commit, not for exploratory checkpoints.

```markdown
## Intent
<the exact user-visible or system behavior this change creates or fixes>

## Invariants
<conditions that must remain true>

## Validation
- Build: <exact command and result>
- Automated tests: <exact command and result>
- Manual validation: <specific scenario and result>
- Review budget: v2 capability=<tracker ref> fix_rounds=<fix rounds spent on this PR> prior_fix_rounds=<fix rounds on this capability's replaced PRs> reviewed_head=<40-character SHA or none> cascade=<true|false> exit=<continue|merge-answered|revert-simplify|split|close-replan>

## Review tier
<trivial | normal | serious>

## Why this tier
<one or two concrete sentences from the rules below>
```

Never claim a build, test, or manual validation happened unless it actually
ran. There is no `- Local review:` row: `delivery-evidence` no longer requires
one and ignores one that is present.

The versioned `Review budget` row **is** the budget ledger; nothing else records
what has been spent. `fix_rounds` counts the fix rounds spent on this PR and is
incremented as each one is pushed, and `prior_fix_rounds` carries those already
spent on this capability's replaced PRs. The count is written here rather than
inferred from history because amend, squash, and rebase rewrite commit
boundaries and lose push grouping (`principles/git-workflow.md`). Update the
row as each fix round is pushed, and carry the current count into
`prior_fix_rounds` when replacing a PR; a provider retry on the same
head is not a round, and neither is an attest request, because a fix round is a
push of review-driven change (`principles/git-workflow.md`). Row version 2
renamed `prior_hosted_rounds` to `prior_fix_rounds` when the budget moved from
counting requests to counting mutation. A `v1` count is **not** convertible:
it counted finding-bearing rounds including answer-only ones, so reading it as
fix rounds overstates the spend and can exhaust a replacement PR's budget
against work that never spent it. Treat a `v1` count as unknown, or
reconstruct the fix rounds from the replaced PR's pushed heads.
`reviewed_head` records the head the latest hosted review round covered
(`none` before the first), `cascade=true` means a review fix created another
defect, and `exit` records the chosen stop path. A v2 row written before
AUT-1962 may also carry `local_rounds`, and its `reviewed_head` names the head
the retired local pass saw; neither changes how the fix-round counts read. A
missing row is compatible with older PRs but reports unknown cross-PR history;
it never waives the required exact-head PR review.

## Tier classification

Deterministic rules; classify every change. The tier selects no review —
every tier gets the same hosted exact-head review. It states the change's
blast radius where the reviewer and the reader see it, and it sets the evidence
bar `delivery-evidence` checks: every tier records its intent, validation, and
why the tier applies; normal and serious also state their invariants.

**Trivial** — *inert* documentation, comments, or formatting-only;
generated-file-only or lockfile-only; a low-risk mechanical rename with no
behavior change; or a change fully covered by deterministic checks with no
logic or interface risk. Path: deterministic checks, then the PR.

Documentation is not automatically inert. A change to steering, policy, or any
prompt that directs how agents work — `TOUCHSTONE.md`, `AGENTS.md`,
`CLAUDE.md`, `GEMINI.md`, the routed principles, repository policy — alters how
every consumer project ships. Tier those by the blast radius of the behavior
they change, never as trivial.

**Normal** — ordinary contained work: small bug fixes, isolated application
logic, localized implementation changes, safe refactors preserving a clearly
testable behavior, anything with a focused validation path and no serious
trigger. Path: deterministic checks and the focused validation scenario, then
the PR with its invariants stated.

**Serious** — any of: networked or distributed state (RPCs, replication,
client/server authority, prediction); concurrency (async handoff, scheduling,
locks, races, ownership, lifetimes, unsafe callbacks); persistence
(serialization, migrations, backward compatibility, irreversible transitions,
data-loss risk); security (authentication, authorization, secrets, user data,
payments, exposed APIs); public interfaces used by multiple subsystems;
performance-critical paths; broad agent-generated or cross-system diffs that
one focused scenario cannot validate; anything expensive to diagnose or roll
back after merge. Path: deterministic checks and a validation scenario for
each trigger the change touches, then the PR with its invariants stated. The
hosted review of the stable PR is the deep review and the merge authority; a
fix commit takes its one exact-head re-review per `principles/git-workflow.md`
— never one per push.

When torn between normal and serious, pick serious only for genuinely high
blast radius. Many lines is not a trigger.

## Deterministic checks

Before the shipping push: `git diff --check`, formatter/linter, targeted
build, targeted tests, static analysis where available, and a focused manual
test for what automation does not cover. Projects with a schema-2 declaration
run `touchstone validate --stage commit`. These are the author's focused
feedback, not the gate. Where the repository's effective policy runs a
protected validation workflow, that run on GitHub is the complete proof: do
not repeat the complete suite locally as confirmation. Where it does not, run
the complete suite locally and track the rollout gap.

Select checks by the contracts the changed files participate in, not just
their extensions. Include existing size, generated-file consistency, and
instruction-contract checks when those surfaces change. Run each applicable
check once on the ready-to-ship change; repeat only after relevant changes,
a failure, or new evidence that invalidates the result.

A check that does not apply is recorded as `n/a` with the reason — a
documentation-only change has no targeted build. Recording `n/a` is honest;
claiming a check ran is not, and the two must never be confused.

## Repository policy still runs

The tier governs evidence, not whether review happens. A repository's
configured reviewers run on PR open for every tier, and their findings are
answered under `principles/git-workflow.md` — classified against the severity
bar, fixed or routed, threads resolved. A trivial tier is not an exemption
from the merge gate. When the pinned gate reviews a head itself because the
primary is at capacity, that verdict is complete review evidence, answered the
same way.

## Stop conditions

Preparation is complete when deterministic checks pass (or are recorded as not
applicable), the intended validation scenario passes, and the PR context is
written. No tier owes a local review.

After a hosted review round, fix the valid findings, **re-run every applicable
deterministic check and the intended validation scenario** — a valid fix can
break what already passed — and stop. If a fix materially changes the risk
surface — a new serialization format, ownership or threading change, security
boundary, or public contract — stop and replan; it does not earn another
review loop.

**A fix commit moves the head, and exact-head review of the merged head is
never optional.** What this document bounds is how much you *implement* —
never whether the head that merges was reviewed. After a fix commit, follow
`principles/git-workflow.md`: batch every allowed fix into one commit, push
once, and take one review for that head. Exact-head review does not authorize
another mutation after a cascade stop.

## Commit discipline

Each commit builds (or is a stated atomic sequence that builds at its end),
has one purpose, carries no unrelated formatting or generated artifacts,
includes tests with the behavior change when practical, and describes the
behavioral change rather than implementation churn. Before committing,
summarize: files changed, behavioral intent, validation completed, and tier
and rationale.
