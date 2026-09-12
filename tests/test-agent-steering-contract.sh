#!/usr/bin/env bash
#
# tests/test-agent-steering-contract.sh — guard the interpretability contract
# that lets Claude, Codex, and Gemini act as interchangeable driving CLIs.

set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-agent-steering.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -qF -- "$needle" "$file"; then
    fail "expected $file to contain '$needle'"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -qF -- "$needle" "$file"; then
    fail "expected $file to NOT contain '$needle'"
  fi
}

echo "==> TOUCHSTONE.md and managed AGENTS blocks expose the driver/reviewer contract"
# AGENTS.md and GEMINI.md inline the managed block.
for file in \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md"; do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "PR-visible reviewer"
  assert_contains "$file" "Required Delivery Workflow"
  assert_contains "$file" "Before the first edit"
  assert_contains "$file" "principles/ai-delivery-architecture.md"
  # The mechanics must be stated as raw commands, not delegated to a wrapper.
  # A steering doc that names only a script leaves an agent stranded the moment
  # the script is absent — which is exactly what the strip made true.
  assert_contains "$file" "gh pr create"
  assert_contains "$file" "--match-head-commit"
  # The silent-failure trap: a closing trailer in a commit body does nothing on
  # a squash merge, because GitHub reads the PR body. Nothing warns you.
  assert_contains "$file" "PR body"
  assert_contains "$file" "Answer every piece of PR feedback before merging"
  assert_contains "$file" "Inspect GitHub's complete review surface"
  assert_contains "$file" "principles/git-workflow.md"
  assert_not_contains "$file" "touchstone worker"
  assert_contains "$file" "Claim tracked work before implementation"
  assert_contains "$file" "assign yourself through the Linear MCP"
  assert_contains "$file" "unavailable transport is unverifiable"
  assert_contains "$file" 'Run `git show --stat --oneline HEAD`'
  assert_contains "$file" 'unchanged `HEAD`: do not ship'
  assert_contains "$file" "Reconcile tracked work"
  assert_contains "$file" 'Closes #123'
  assert_contains "$file" 'Fixes AUT-123'
  assert_not_contains "$file" "list every GitHub issue found"
  assert_contains "$file" "Do not infer adoption from this document"
  assert_contains "$file" "a rollout gap, not permission to skip it"
  # A quota notice resolves into a gate-authored verdict; it is neither a
  # blocker nor something to wait out. The contract used to say "keep watching,
  # then use bounded stalled-request recovery", which contradicted the paragraph
  # above it and told every driver to treat a completed review as a stall.
  assert_contains "$file" "not a blocker and not a wait"
  assert_contains "$file" "pinned gate then reviews the head itself"
  assert_contains "$file" 'pr answer --finding'
  assert_not_contains "$file" "Keep watching, then use bounded stalled-request recovery"
  assert_contains "$file" "Keep review subordinate to scope"
  assert_contains "$file" "review cannot amend approved scope"
  assert_contains "$file" "Checkpoint scope expansion before editing"
  assert_contains "$file" "a follow-up approves doing the work, not bundling it"
  assert_contains "$file" "file count alone never decides"
  assert_contains "$file" "A review-fix defect stops patching"
  assert_contains "$file" "A second ends same-shape work"
  # The abstract form of this rule did not land: hesperus#311 spent 27 review
  # requests against a documented cap of three, vesper#1236 spent 23. "A second
  # ends same-shape work" never says count and names no exit, so an agent at
  # round three has no trigger and no move. Pin the countable form and every
  # exit it lists — the next byte-cap squeeze must fail here rather than
  # quietly drop the trigger back to prose.
  assert_contains "$file" "Count fix rounds; at three, take an exit"
  assert_contains "$file" "one push of review-driven change is one round"
  assert_contains "$file" "merge-answered, revert-simplify, split, close-replan"
  assert_contains "$file" "more rounds is not one"
  assert_contains "$file" "Answering is not implementing"
  assert_contains "$file" "answer and route whatever you are not fixing"
  # The bounded-review rule: severity decides what gets implemented, and the
  # loop terminates. Without these an agent treats a reviewer that always has
  # another remark as a finish line.
  assert_contains "$file" "Stop when the task is correct"
  # The pre-PR review contract is routed, not restated; the route must exist
  # in every rendered surface.
  assert_contains "$file" "principles/local-review.md"
  assert_contains "$file" "deterministic gates first"
  assert_contains "$file" "Exact-head review after a fix commit is never skipped"
  assert_contains "$file" "never authorizes mutation past a stop"
  assert_contains "$file" "never reopen the design space"
  # Review is automatic on PR open; a hand-typed request wedges the PR.
  assert_contains "$file" "the exact head and base"
  assert_contains "$file" "Never put the sequencer's marker in a comment you write yourself"
  assert_contains "$file" "Stop widened work"
  assert_contains "$file" "allowed fixes follow the cascade and exact-head rules"
  assert_contains "$file" "follow the capability across replacement PRs"
  assert_contains "$file" "closing or renaming never resets the budget"
  # A parent deleted two clean worktrees while their workers were still live;
  # one lost its final push. Cleanup cannot infer task lifecycle from GitHub or
  # git state, so the terminal-owner precondition must be auto-loaded by every
  # driver rather than left only in the routed workflow.
  assert_contains "$file" "remove one only after final result delivery"
  assert_contains "$file" "or confirmed cancellation"
  assert_contains "$file" "this session created"
  assert_contains "$file" "leave sibling work untouched"
  assert_contains "$file" "its nonzero exit never authorizes deleting another session's work"
  assert_not_contains "$file" "Review is an enforced gate."
done

# A run of findings on one new surface is a design signal, not a work queue.
# The badge governs a single finding and deliberately says nothing about a
# sequence, so the sequence needed its own rule (2026-09-07: ship-pr.sh drew
# three findings inferring a grammar another layer owned, setup.sh drew one per
# round enumerating git's config scopes).
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "When findings cluster, the design is the finding"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "The tell is repetition of shape, not count"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "Should this surface exist at all"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "smaller** than the patch it replaces"
# The diagnostic must never read as licence for routed findings to mutate a
# mergeable head; it informs what is filed and which exit is taken.
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "The signal changes what you file, not what you push"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "repository-scoped, not a session-ownership"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "delete another session's branch or worktree"
assert_contains "$TOUCHSTONE_ROOT/bin/touchstone" \
  "Repository cleanup residue"
assert_not_contains "$TOUCHSTONE_ROOT/bin/touchstone" \
  "What a session left behind"
assert_not_contains "$TOUCHSTONE_ROOT/scripts/touchstone-cleanup.sh" \
  '"I cleaned up" is a verified state'

assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "confirm its task is terminal and the parent"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "either received its final report or acknowledged its cancellation"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "after every prunable worker meets that lifecycle proof"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "only after its task is terminal"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "received its final report or acknowledged cancellation"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "abandonment, and a clean tree are not worker-lifecycle evidence"

echo "==> tiered review keeps a cost-bounded OpenRouter normal lane and Codex serious lane"
for file in \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "$TOUCHSTONE_ROOT/.github/pull_request_template.md"; do
  assert_contains "$file" 'touchstone review check'
  assert_contains "$file" 'touchstone review run'
  assert_contains "$file" 'touchstone review run --base origin/<default>'
  assert_not_contains "$file" 'coderabbit review --agent --uncommitted'
done
for file in \
  "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "$TOUCHSTONE_ROOT/.github/pull_request_template.md"; do
  assert_contains "$file" 'may waive only when Codex and the fallback are both unavailable'
  # A waiver documented without its alternative is how the tier lost its local
  # pass to an exhausted quota in the first place (AUT-1217), so every surface
  # that states the waiver states the fallback beside it.
  assert_contains "$file" 'falls back to the bounded OpenRouter pass'
done
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'touchstone review setup'
assert_not_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  '## The deep review pass'
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" 'OpenRouter'
# Every policy parameter this document states in prose is bound to the JSON
# that actually carries it. It drifted once in both directions at once: the
# sentence claimed 4,096 completion tokens after the config moved to 16,384,
# and it had been claiming a 100,000-byte ceiling against a configured 400,000
# for longer than anyone noticed, with every test green. A fact in two places
# is bound by a test or it is a fact in one place and a rumour in another.
for policy_fact in \
  'qwen/qwen3-coder' \
  '$0.50 per million' \
  '$2.00 per million' \
  '400,000-byte request' \
  '16,384 completion tokens' \
  '300-second request timeout'; do
  assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" "$policy_fact"
done
assert_not_contains "$TOUCHSTONE_ROOT/principles/local-review.md" '4,096 completion tokens'
assert_not_contains "$TOUCHSTONE_ROOT/principles/local-review.md" '100,000-byte'
# The contract version is the fact that drifted furthest: bumping v2 -> v3 moved
# the config and the validator and left the script's own diagnostic and the
# canonical product contract behind, each found one review round at a time.
# Bind every surface that states it, and forbid the superseded string outright
# so the next bump cannot leave a straggler.
assert_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  'REVIEW_POLICY_SCHEMA="touchstone.review/v3"'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"schema": "touchstone.review/v3"'
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  '`touchstone.review/v3`'
for schema_surface in \
  "$TOUCHSTONE_ROOT/config/review-normal.json" \
  "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "$TOUCHSTONE_ROOT/principles/local-review.md"; do
  assert_not_contains "$schema_surface" 'touchstone.review/v2'
done
# The diagnostic must read the constant, not repeat the literal -- repeating it
# is exactly what left an operator pointed at a retired contract.
assert_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  'outside the $REVIEW_POLICY_SCHEMA contract'
# The canonical boundary states the pinned model too, and it is no longer routed.
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  'names one concrete model rather than'
assert_not_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  'Auto Router'
# The staleness claim: `check` makes no provider request, so it cannot detect a
# retired pin. Saying otherwise justified the pin with a mitigation that does
# not exist.
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'Staleness surfaces from `touchstone review run`, not from `check`'
assert_not_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  '`touchstone review check` fails loudly if the model'
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" 'one direct request'
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'No tools or agent loop'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"schema": "touchstone.review/v3"'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"backend": "openrouter-chat-completions"'
# The model is pinned rather than routed. `openrouter/auto` was chosen so no
# model id could ever go stale, and that was the right instinct for the wrong
# cost: the router selects reasoning models, whose thinking is spent from the
# completion budget, and measured on 2026-09-09 that came to ~74 completion
# tokens per line of diff -- a ceiling around 150 lines, below which the
# required local pass simply cannot run on an ordinary change. Disabling
# reasoning is not available: the API answers `reasoning: {enabled: false}`
# with "Reasoning is mandatory for this endpoint and cannot be disabled".
# So the id is pinned, and staleness becomes a thing to notice rather than a
# thing that cannot happen.
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  'openrouter/auto'
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  'costTier'
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"id": "openai/'
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"id": "anthropic/'
# The request must carry no router plugin: a pinned model and a plugin whose
# job is to choose the model are incoherent together.
assert_not_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  'plugins:'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"maxPromptPricePerMillion": 0.5'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"maxCompletionPricePerMillion": 2'
# 4096 was sized for a model that answers without thinking. The auto-router
# selects reasoning models, whose reasoning tokens are spent from this same
# budget: one measured response burned 4323 reasoning tokens against a 4096
# cap and returned no content at all. A 196-line slice failed six consecutive
# passes at 4096 and passed first time at 16384, using 6281 completion tokens.
# The per-million price caps above, not this number, are what bound the cost.
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"maxCompletionTokens": 16384'
# The budget and the wall clock are one setting in two numbers. Raising
# maxCompletionTokens to 16384 without this produced timeouts instead of
# truncations: a reasoning model given four times the budget spends four times
# as long producing it, and 120s stopped being enough. Measured 2026-09-09 --
# three consecutive passes on one change, two of them timeouts at 120s.
# AUT-1500 predicted exactly this ("raising the limit alone is not
# sufficient"); #1178 raised the limit alone and this is the correction.
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"requestTimeoutSeconds": 300'
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  'gpt-5.6-sol'
assert_not_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  'codex exec'
assert_not_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  '--profile'
assert_not_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  'tools:'
assert_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  '-q --config -'
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'A normal-review failure never waives this pass.'
assert_not_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'or the same recorded waiver'
[ ! -e "$TOUCHSTONE_ROOT/.touchstone-review.toml" ] \
  || fail "retired project-level review declaration still exists"
[ ! -e "$TOUCHSTONE_ROOT/principles/local-review-contract.md" ] \
  || fail "retired CodeRabbit prompt contract still exists"

GIT_WORKFLOW_SKILL="$TOUCHSTONE_ROOT/skills/touchstone-git-workflow/SKILL.md"
PRE_IMPL_SKILL="$TOUCHSTONE_ROOT/skills/touchstone-pre-impl/SKILL.md"
echo "==> workflow skills route to canonical procedures instead of copying them"
assert_contains "$GIT_WORKFLOW_SKILL" 'principles/git-workflow.md'
assert_contains "$GIT_WORKFLOW_SKILL" 'principles/local-review.md'
assert_contains "$PRE_IMPL_SKILL" 'principles/pre-implementation-checklist.md'
# These conflicting copies caused AUT-1668. The canonical owners below retain
# the procedure assertions; the activation skills must not restore the copies.
assert_not_contains "$GIT_WORKFLOW_SKILL" 'After the policy-owned exact-head gate succeeds'
assert_not_contains "$PRE_IMPL_SKILL" 'Any "no" answer to a check is a stop signal'
# The CLI contract owns the two notice exceptions previously copied into the
# workflow skill (AUT-1610).
assert_contains "$TOUCHSTONE_ROOT/docs/pr-cli-contract.md" 'While Actions refuses a'
assert_contains "$TOUCHSTONE_ROOT/docs/pr-cli-contract.md" 'GitHub refuses to accept is reported on stderr'

GIT_WORKFLOW_GUIDE="$TOUCHSTONE_ROOT/principles/git-workflow.md"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "Where the repository's effective policy requires \`review-gate\`"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "exact-head review remains mandatory driver procedure"
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  '**`review-gate` enforces the review contract.**'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "Where it exposes the audited"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "do not infer it from this guide"
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  "then an organization admin may use GitHub's PR-only ruleset bypass"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "A live exact-head queue entry ends merge mutation"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "The human must explicitly authorize bypassing normal policy"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "Do not probe the rule by mutation"
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  'Direct pushes to `main` are rejected by the server even for organization admins.'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'touchstone tracker claim <reference>'
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  'gh issue edit <n> --add-assignee'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "grep -F -- \"\$expected\""
assert_contains "$GIT_WORKFLOW_GUIDE" \
  '<configured closing reference, for example: Fixes AUT-123>'
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  "grep -E '(Closes|Fixes|Resolves)"

echo "==> review-request recovery is complete, bounded, and fail-closed"
# PR #827 exposed two weak points: a provider can accept a request and then
# stall, and a clean result can arrive as a conversation comment rather than a
# formal review. The workflow must model both without turning retry into a loop
# or allowing acceptance alone to stand in for exact-head evidence.
# Every agent-facing workflow needs the complete, copyable GitHub path. A
# recovery rule is useless if the driver cannot reliably request, answer,
# bind, and merge the ordinary review first.
assert_contains "$GIT_WORKFLOW_GUIDE" "not by hand"
assert_contains "$GIT_WORKFLOW_GUIDE" "headRefOid"
assert_contains "$GIT_WORKFLOW_GUIDE" "resolveReviewThread"
assert_contains "$GIT_WORKFLOW_GUIDE" "--match-head-commit"
assert_contains "$GIT_WORKFLOW_GUIDE" "submitted, accepted, and completed states"
assert_contains "$GIT_WORKFLOW_GUIDE" "PR conversation comments"
assert_contains "$GIT_WORKFLOW_GUIDE" "accepted but stalled"
assert_contains "$GIT_WORKFLOW_GUIDE" "A quota notice resolves; it is not a blocker and not a wait"
# A Validation row may not assert state the reviewed head cannot have
# produced. #1137 claimed six applied rulesets, none had been applied, and the
# pin it deployed broke every gate in the repository.
assert_contains "$GIT_WORKFLOW_GUIDE" "observed at the reviewed head"
# A closed issue reads as current state. Leaving a claim its own fix
# invalidated is how AUT-1236 sent a later session down four wrong turns.
assert_contains "$GIT_WORKFLOW_GUIDE" "that the change invalidated"
# A worktree's local default branch is routinely stale, and --base picks the
# merge base, so naming the local ref inflates the reviewed slice with merged
# work. Reported 2026-09-05: 35 commits stale, 138 files, size limit blown.
assert_contains "$GIT_WORKFLOW_GUIDE" 'review run --base origin/<default>'
assert_not_contains "$GIT_WORKFLOW_GUIDE" 'review run --base <default>'
assert_contains "$GIT_WORKFLOW_GUIDE" 'Corrected <date>'
assert_contains "$GIT_WORKFLOW_GUIDE" "recorded as pending, never as done"
assert_contains "$GIT_WORKFLOW_GUIDE" "complete review evidence, not a degraded mode"
assert_contains "$GIT_WORKFLOW_GUIDE" 'touchstone pr answer <n> --finding <id>'
assert_not_contains "$GIT_WORKFLOW_GUIDE" "keep watching the complete PR surface through the completion deadline"
assert_contains "$GIT_WORKFLOW_GUIDE" "at least 30 minutes after submission"
assert_contains "$GIT_WORKFLOW_GUIDE" "earliest acceptance signal"
assert_contains "$GIT_WORKFLOW_GUIDE" "immediately before posting"
assert_contains "$GIT_WORKFLOW_GUIDE" 're-run the pinned `review-gate`'
assert_contains "$GIT_WORKFLOW_GUIDE" "still reports no request"
assert_not_contains "$GIT_WORKFLOW_GUIDE" "touchstone/review-request-v1"
assert_contains "$GIT_WORKFLOW_GUIDE" "non-trigger audit note"
assert_contains "$GIT_WORKFLOW_GUIDE" "fall back to the original marker"
assert_contains "$GIT_WORKFLOW_GUIDE" "exactly one replacement trigger"
assert_contains "$GIT_WORKFLOW_GUIDE" "exact head-and-base binding"
assert_contains "$GIT_WORKFLOW_GUIDE" "Four cases permit another request while the head stays unchanged"
assert_contains "$GIT_WORKFLOW_GUIDE" "base ref or base SHA"
assert_contains "$GIT_WORKFLOW_GUIDE" "earlier request is completed or explicitly failed"
assert_contains "$GIT_WORKFLOW_GUIDE" "integrate the current base into the branch"
assert_contains "$GIT_WORKFLOW_GUIDE" "results identify the head"
assert_contains "$GIT_WORKFLOW_GUIDE" "Never manufacture an empty"
assert_contains "$GIT_WORKFLOW_GUIDE" "trusted exact-head review evidence"
assert_contains "$GIT_WORKFLOW_GUIDE" "merge on acceptance alone"
assert_contains "$GIT_WORKFLOW_GUIDE" "do not push a fourth on the same"
assert_contains "$GIT_WORKFLOW_GUIDE" "implementation shape"
assert_contains "$GIT_WORKFLOW_GUIDE" "redesigned attempt"
assert_contains "$GIT_WORKFLOW_GUIDE" "capability"
assert_not_contains "$GIT_WORKFLOW_GUIDE" "retry until review"

echo "==> CLAUDE.md loads the steering router once, not twice"
# `touchstone steering install` writes the TOUCHSTONE.md block into
# ~/.claude/CLAUDE.md, which Claude loads in every session on that machine.
# An @TOUCHSTONE.md import here loaded the identical block a second time
# (about 3,100 tokens per session). CLAUDE.md now names the router and tells
# an agent on an uninstalled machine to read it; it must not import it.
assert_not_contains "$TOUCHSTONE_ROOT/CLAUDE.md" "@TOUCHSTONE.md"
assert_contains "$TOUCHSTONE_ROOT/CLAUDE.md" 'read `TOUCHSTONE.md` before the first edit'
assert_contains "$TOUCHSTONE_ROOT/CLAUDE.md" "touchstone steering install"

echo "==> Gemini entry files name the driving CLI role inline"
# GEMINI.md carries the managed block inline, so the contract phrases must
# appear directly.
for file in "$TOUCHSTONE_ROOT/GEMINI.md" "$TOUCHSTONE_ROOT/AGENTS.md"; do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "PR-visible reviewer"
  assert_contains "$file" "review runs asynchronously against the exact pushed head"
  assert_contains "$file" "Do not infer adoption from this document"
  assert_not_contains "$file" "Review is an enforced gate."
done

echo "==> canonical git workflow describes the PR-visible review loop"
# The branch-rewrite contract earned its way in through a field failure: a
# consumer over-generalized "never force-push" and stalled on a permitted
# amend (vesper PR #888). These assertions keep the rule present, pinned to
# the safe lease form, and ordered rotation-before-rewrite for leaked secrets.
# A claimed item's life after the claim is a behavior contract, so it is
# asserted rather than left to prose drift. Sessions merged the PR and left the
# item In Progress (2026-08-21); the read-back is what catches a closing
# reference that never fired, and neither tracker may be written as the one
# whose mechanism always works.
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Keeping a tracked item current, and closing it"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'The proof is the state'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'explicitly parked state'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'may legitimately stay In Progress across sessions'
# Neither bullet may claim its tracker's mechanism is unconditional: GitHub's
# closing reference does not fire for every PR, and a Linear workspace may or
# may not have the integration that moves a linked issue on merge.
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'Linear — nothing fires'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'Re-read the item first'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'Work still moving stays In Progress'

assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Rewriting an unmerged branch"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" '--force-with-lease="$(git branch --show-current):$EXPECTED"'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" '--force-with-lease="<child-branch>:$EXPECTED"'
# The ancestry guards must fail closed. The rewrite recipe runs its rewrite
# and push only inside the guard's success branch, and the stacked recovery
# exits nonzero -- a print-and-continue guard rewrites over the very
# concurrent push it exists to catch.
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'if git merge-base --is-ancestor "$EXPECTED" HEAD; then'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'reconcile before retargeting" >&2; exit 1; }'
if grep -E 'is-ancestor.*\|\| \{ echo [^}]*>&2; \}$' "$TOUCHSTONE_ROOT/principles/git-workflow.md" >/dev/null; then
  fail "an ancestry guard prints and continues instead of failing closed"
fi
# No executable bare lease may survive anywhere in the workflow guide: a bare
# lease trusts a remote-tracking ref that any background fetch refreshes.
if grep -E '^[[:space:]]*git push --force-with-lease[[:space:]]*$' "$TOUCHSTONE_ROOT/principles/git-workflow.md" >/dev/null; then
  fail "principles/git-workflow.md contains an executable bare --force-with-lease"
fi
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Rotate or revoke the credential first"
assert_contains "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "rewriting your own unmerged branch is fine"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Agentic PR Review Loop"
# The canonical doc must carry the portable recovery mechanism: how to open
# the PR, how to bind the review to the head being merged, and how to resolve a
# thread. These are the four gaps that made the prose unusable without a wrapper.
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "gh pr create"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "@codex review"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "--match-head-commit"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "resolveReviewThread"
# An answer's disposition is part of that recovery: a guide that still teaches
# the optional --fix-commit sends agents into a refused command, and its raw
# reply would be rejected by the gate for carrying no disposition (AUT-800).
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "--no-code-change"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "<!-- touchstone:review-answer v=1 id=<comment-id> disposition=fixed fix=<40-hex> -->"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "<!-- touchstone:review-answer v=1 id=<comment-id> disposition=no-code-change -->"
if grep -qF -- "--body-file <reply.md> [--fix-commit <sha>]" "$TOUCHSTONE_ROOT/principles/git-workflow.md"; then
  fail "principles/git-workflow.md still documents --fix-commit as optional"
fi
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "gh api graphql --paginate"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'reviewThreads(first:100, after:$endCursor)'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "pageInfo { hasNextPage endCursor }"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "(.comments.nodes[0].databaseId | tostring)"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Replies are deliberately omitted"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'comments/<id>/replies -F'
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'comments/<id>/replies -f'

echo "==> PR babysitting preserves approved scope"
# PR #829 showed how individually reasonable findings can turn an exact-head
# review loop into product expansion. The canonical workflow must make the
# approved issue/plan the scope boundary and treat repeated widening as a design
# signal, while retaining the exact-head review requirement.
assert_contains "$GIT_WORKFLOW_GUIDE" "Freeze the scope before the first review request"
assert_contains "$GIT_WORKFLOW_GUIDE" "map it to a recorded acceptance criterion or invariant"
assert_contains "$GIT_WORKFLOW_GUIDE" "that the diff created the defect"
assert_contains "$GIT_WORKFLOW_GUIDE" "A plausible bug"
assert_contains "$GIT_WORKFLOW_GUIDE" "not automatically this"
assert_contains "$GIT_WORKFLOW_GUIDE" "PR's bug"
assert_contains "$GIT_WORKFLOW_GUIDE" "A scope"
assert_contains "$GIT_WORKFLOW_GUIDE" "never permits the PR to ship a **P0/P1** regression"
assert_contains "$GIT_WORKFLOW_GUIDE" "Repeated widening is a design signal"
assert_contains "$GIT_WORKFLOW_GUIDE" "A review-fix regression is a stop signal"
assert_contains "$GIT_WORKFLOW_GUIDE" "At the first defect created by the"
assert_contains "$GIT_WORKFLOW_GUIDE" "second fix-created defect"
assert_contains "$GIT_WORKFLOW_GUIDE" "regression test"
assert_contains "$GIT_WORKFLOW_GUIDE" "does not justify retaining the failed fix"
assert_contains "$GIT_WORKFLOW_GUIDE" "only when no known P0/P1 defect remains"
assert_contains "$GIT_WORKFLOW_GUIDE" "authorize further mutation after this stop signal"
assert_contains "$GIT_WORKFLOW_GUIDE" "Do not grow the current PR one"
assert_contains "$GIT_WORKFLOW_GUIDE" "scope containment is never permission to skip review"
assert_contains "$GIT_WORKFLOW_GUIDE" "do not push a fourth on the same"
assert_contains "$GIT_WORKFLOW_GUIDE" "implementation shape"
assert_contains "$GIT_WORKFLOW_GUIDE" "split or close the"
assert_contains "$GIT_WORKFLOW_GUIDE" "capability"
assert_contains "$GIT_WORKFLOW_GUIDE" "per capability"
assert_contains "$GIT_WORKFLOW_GUIDE" "does not reset its count"
assert_contains "$GIT_WORKFLOW_GUIDE" "mechanical split is not budget laundering"
# The steering lists the exits by label only; this is the file its routing table
# sends the agent to for what each one means, so all four labels must be defined
# here. A label named in the block and absent here is four bare words at the
# moment the budget runs out.
assert_contains "$GIT_WORKFLOW_GUIDE" "**\`merge-answered\`**"
assert_contains "$GIT_WORKFLOW_GUIDE" "**\`revert-simplify\`**"
assert_contains "$GIT_WORKFLOW_GUIDE" "**\`split\`**"
assert_contains "$GIT_WORKFLOW_GUIDE" "**\`close-replan\`**"
# Three surfaces state this exit set: the steering block lists it, the guide
# defines each one, and the PR body's ledger row accepts it as an enum. They
# drifted apart once already — the guide listed three exits under prose names
# while the row and the block carried four slugs — so bind the row too.
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "exit=<continue|merge-answered|revert-simplify|split|close-replan>"
assert_contains "$GIT_WORKFLOW_GUIDE" "gets one validation round"
assert_contains "$GIT_WORKFLOW_GUIDE" "Exact-head review makes moving stacks multiply work"
assert_contains "$GIT_WORKFLOW_GUIDE" "Do not open dependent"
assert_contains "$GIT_WORKFLOW_GUIDE" "while a parent is still finding-bearing"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "- Review budget: v2 capability="
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "the budget ledger; nothing else records"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'prior_fix_rounds'
# the row is the ledger: this PR's own fix rounds are recorded, not inferred
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'fix_rounds=<fix rounds spent on this PR>'
assert_contains "$GIT_WORKFLOW_GUIDE" "The row is the ledger; history is not."
# v1 stays parseable; the rename note is the compatibility record
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'prior_hosted_rounds'

echo "==> scope expansion checkpoints before independent edits"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "A follow-up request approves doing the work"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "automatically make"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "Before the first edit for a follow-up"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "checkpoint each accepted stable concern"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "Size is evidence to inspect, never the decision"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "website compatibility has several independent invariants"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "generated release update"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "invalid intermediate state"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  '"Ship it all" means deliver every approved'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "Use one PR when commits share an invariant"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "Independent units use separate PRs"
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  'When the user says "ship it all," default to one PR'

echo "==> adjacent review guidance cannot reopen a fix-created cascade"
assert_contains "$TOUCHSTONE_ROOT/principles/engineering-principles.md" \
  "Every retained fix gets a test"
assert_contains "$TOUCHSTONE_ROOT/principles/engineering-principles.md" \
  "does not justify retaining a review fix"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "does not earn another local review loop"
assert_not_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "run another only if a fix materially changed the risk surface"
assert_contains "$TOUCHSTONE_ROOT/principles/audit-weak-points.md" \
  "search and classify the weak-point class before further edits"
assert_contains "$TOUCHSTONE_ROOT/skills/touchstone-audit-weak-points/SKILL.md" \
  "This audit is not permission to patch the failed implementation forward"

echo "==> tier-required local review hands off once to hosted exact-head review"
for file in \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md"; do
  assert_contains "$file" \
    "Run at most one tier-required local AI pass per coherent unit"
  assert_contains "$file" "none for trivial work"
  assert_contains "$file" \
    'waiving only if both are gone; never record the base'
  assert_contains "$file" \
    'Codex first, bounded fallback on any non-success'
  assert_contains "$file" \
    'record `<reviewer> on <head-sha>: <n> findings, <disposition>`'
  assert_contains "$file" \
    "Hosted review owns exact heads"
  assert_contains "$file" "never rerun to confirm fixes"
done
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "A tier-required local AI pass runs at most once per coherent review unit"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "the hosted PR reviewer owns exact-head review for every pushed head"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "runs at most once before its first push"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "pass is neither required nor authorized"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'reviewed_head="$(git rev-parse HEAD)"'
assert_contains "$TOUCHSTONE_ROOT/.github/pull_request_template.md" \
  'begin serious with `<reviewer> on <captured-head-sha>: <n> findings, <disposition>`'

echo "==> dirty PR recovery preserves authored work and re-ships the new head"
assert_contains "$GIT_WORKFLOW_GUIDE" '## Recovering a `DIRTY` PR'
assert_contains "$GIT_WORKFLOW_GUIDE" 'With a verified merge queue'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'Without one, a base advance uses the sequence'
assert_contains "$GIT_WORKFLOW_GUIDE" "PR's base repository"
assert_contains "$GIT_WORKFLOW_GUIDE" '`baseRefOid`'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'unless `FETCH_HEAD` equals the recorded `baseRefOid`'
assert_contains "$GIT_WORKFLOW_GUIDE" 'with the same `--base`'
assert_contains "$GIT_WORKFLOW_GUIDE" '`--ours` and'
assert_contains "$GIT_WORKFLOW_GUIDE" '`--theirs` are whole-file operations'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'git diff <pre-merge-head> HEAD -- <file...>'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'the pushed head still requires exact-head review'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'started before the exact-head review completed'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "re-run the project's PR-open"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'fragments per commit'

echo "==> compiler scope and fixtures come from authoritative evidence"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "Bind that enumeration to a versioned source of truth"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "check in the supported inventory"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "Inputs absent from that source take the"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "explicit/manual path"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "captured real artifact"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "cannot define npm"
assert_contains "$TOUCHSTONE_ROOT/AGENTS.md" "Portfolio scope is checked-in data"

CORPUS_ROOT="$TOUCHSTONE_ROOT/tests/fixtures/adoption-v1"
assert_contains "$CORPUS_ROOT/cases.tsv" $'none\tmanual\t-'
assert_contains "$CORPUS_ROOT/cases.tsv" $'competing\tmanual\tanima:package.json,arpeggio:pyproject.toml'
artifact_count=0
while IFS=$'\t' read -r repository snapshot artifact expected_blob; do
  case "$repository" in \#* | '') continue ;; esac
  fixture="$CORPUS_ROOT/repositories/$repository/$artifact"
  if [ ! -f "$fixture" ] || [ ! -s "$fixture" ]; then
    fail "portfolio artifact is missing or empty: $repository/$artifact"
    continue
  fi
  actual_blob="$(git hash-object "$fixture")"
  if [ "$actual_blob" != "$expected_blob" ]; then
    fail "portfolio artifact drifted from $snapshot: $repository/$artifact"
  fi
  artifact_count=$((artifact_count + 1))
done <"$CORPUS_ROOT/blobs.tsv"
[ "$artifact_count" -eq 17 ] || fail "expected 17 frozen portfolio artifacts, found $artifact_count"
# #801 review: this doc promised the gate emits `review_requested` and
# `review_result` events and that review latency is measurable from them.
# lib/events.sh and every emit call were deleted in #737, so the promise became
# false in a doc that ships to every project. A shipped principle may not
# describe a mechanism no shipped code provides — assert the absence, because
# nothing else notices when a capability is cut and its documentation is not.
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "review_requested"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "review_result"
if grep -rn "review_requested\|review_result" "$TOUCHSTONE_ROOT/principles/" >/dev/null 2>&1; then
  echo "FAIL: principles/ still promises review telemetry events that no shipped code emits" >&2
  grep -rn "review_requested\|review_result" "$TOUCHSTONE_ROOT/principles/" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Codex merge review"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "codex exec --full-auto"

echo "==> branch guard does not feed grep -q from a pipe under pipefail"
# A producer that receives SIGPIPE after grep finds an early match can make a
# successful match report 141 under pipefail. In a branch guard that wrong
# boolean fails open. Keep every guarded predicate on an already-materialized
# value so grep alone owns the status.
pipefail_grep_hits="$(
  grep -nE '\|[[:space:]]*grep[[:space:]]+-[^|]*q' \
    "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" || true
)"
if [ -n "$pipefail_grep_hits" ]; then
  printf '%s\n' "$pipefail_grep_hits" >&2
  fail "branch-guard.sh pipes a producer into grep -q under pipefail"
fi

# Exercise the hardened path with input much larger than a typical pipe
# buffer. The fake jq consumes stdin fully before returning deterministic
# fields, so this test adds no jq dependency to the offline required suite.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
case "${2:-}" in
  '.tool_input.command // ""') printf '%s\n' 'git commit' ;;
  '.cwd // ""') printf '%s\n' "$FAKE_JQ_CWD" ;;
  '.tool_input.workdir // ""') printf '\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_BIN/jq"

GUARD_REPO="$TEST_DIR/branch-guard-repo"
mkdir -p "$GUARD_REPO"
git -C "$GUARD_REPO" init -q
git -C "$GUARD_REPO" symbolic-ref HEAD refs/heads/main
set +e
{
  printf '{"tool_name":"Bash","tool_input":{"command":"git commit '
  awk 'BEGIN { for (i = 0; i < 1048576; i++) printf "x" }'
  printf '"}}'
} | PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  FAKE_JQ_CWD="$GUARD_REPO" \
  bash "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" \
  >"$TEST_DIR/branch-guard.out" 2>"$TEST_DIR/branch-guard.err"
guard_status=$?
set -e
if [ "$guard_status" -ne 2 ]; then
  sed -n '1,20p' "$TEST_DIR/branch-guard.err" >&2
  fail "large git commit input on main must be blocked (status $guard_status)"
fi

echo "==> branch guard fails closed when jq is missing"
# The old guard exited 0 with a stderr note when jq was absent. On PreToolUse,
# exit-0 stderr is debug output, so the bypass was invisible and a commit on
# main carried the hook's implied approval. Build a PATH with every tool the
# guard needs except jq; the guarded commit must be refused, not waved through.
NOJQ_BIN="$TEST_DIR/bin-nojq"
mkdir -p "$NOJQ_BIN"
for tool in bash grep sed tr cat git awk; do
  ln -s "$(command -v "$tool")" "$NOJQ_BIN/$tool"
done
set +e
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$GUARD_REPO" \
  | PATH="$NOJQ_BIN" bash "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" \
    >"$TEST_DIR/branch-guard-nojq.out" 2>"$TEST_DIR/branch-guard-nojq.err"
nojq_status=$?
set -e
if [ "$nojq_status" -ne 2 ]; then
  sed -n '1,5p' "$TEST_DIR/branch-guard-nojq.err" >&2
  fail "guarded commit without jq must be refused with exit 2 (status $nojq_status)"
fi
if ! grep -q 'jq is not installed' "$TEST_DIR/branch-guard-nojq.err"; then
  fail "guarded commit without jq must name the missing dependency"
fi

echo "==> stacked-PR recovery uses the retained remote parent ref"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'child local until its parent merges'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'Recover an inherited open stack; do not create another one.'
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'touchstone pr open --base <parent-branch>'
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'deliberately modeled open stack'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'git fetch origin'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'git rebase --onto "origin/$DEFAULT" "origin/<parent-branch>" <child-branch>'
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'git rebase --onto "$DEFAULT" <parent-branch> <child-branch>'

# Prove the documented old-base anchor works in the exact recovery state: the
# child exists, the local parent is gone, local main is stale, and the two
# remote-tracking refs hold the authoritative old and new bases.
STACK_REPO="$TEST_DIR/stacked-recovery-repo"
mkdir -p "$STACK_REPO"
git -C "$STACK_REPO" init -q
git -C "$STACK_REPO" config user.email "test@touchstone.invalid"
git -C "$STACK_REPO" config user.name "Touchstone Test"
printf 'base\n' >"$STACK_REPO/base.txt"
git -C "$STACK_REPO" add base.txt
git -C "$STACK_REPO" commit -qm "base"
git -C "$STACK_REPO" branch -M main
base_oid="$(git -C "$STACK_REPO" rev-parse HEAD)"
git -C "$STACK_REPO" checkout -qb parent
printf 'parent\n' >"$STACK_REPO/parent.txt"
git -C "$STACK_REPO" add parent.txt
git -C "$STACK_REPO" commit -qm "parent"
parent_oid="$(git -C "$STACK_REPO" rev-parse HEAD)"
git -C "$STACK_REPO" update-ref refs/remotes/origin/parent "$parent_oid"
git -C "$STACK_REPO" checkout -qb child
printf 'child\n' >"$STACK_REPO/child.txt"
git -C "$STACK_REPO" add child.txt
git -C "$STACK_REPO" commit -qm "child"
git -C "$STACK_REPO" checkout -q main
git -C "$STACK_REPO" cherry-pick "$parent_oid" >/dev/null
merged_main_oid="$(git -C "$STACK_REPO" rev-parse HEAD)"
git -C "$STACK_REPO" update-ref refs/remotes/origin/main "$merged_main_oid"
git -C "$STACK_REPO" checkout -q child
git -C "$STACK_REPO" branch -f main "$base_oid"
git -C "$STACK_REPO" branch -D parent >/dev/null
git -C "$STACK_REPO" rebase --onto origin/main origin/parent child >/dev/null 2>&1
if git -C "$STACK_REPO" show-ref --verify --quiet refs/heads/parent; then
  fail "stacked recovery fixture must not retain a local parent branch"
fi
if ! git -C "$STACK_REPO" show-ref --verify --quiet refs/remotes/origin/parent; then
  fail "stacked recovery fixture lost the retained remote parent ref"
fi
if [ ! -f "$STACK_REPO/child.txt" ] || [ ! -f "$STACK_REPO/parent.txt" ]; then
  fail "remote-anchor rebase did not preserve merged parent and child content"
fi
if ! git -C "$STACK_REPO" merge-base --is-ancestor origin/main child; then
  fail "stacked child was not rebased onto the fetched remote default branch"
fi

echo "==> canonical AI delivery architecture describes the PR review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Agentic PR Review Loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "PR creation is not completion"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Merge is allowed only after PR-visible review and check approval"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "project-documented executable merge boundary"
assert_not_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "It is the whole mechanism"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Use worktrees for file-writing parallel agents"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "only model-routing decision"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "OpenRouter Auto Router"

echo "==> active product surfaces do not reintroduce the retired model router"
# The two compatibility helpers may name retired paths solely to back them up
# and remove them; every executable/guidance surface remains prohibited.
active_router_refs="$(grep -Rin "conductor" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/README.md" \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/hooks" \
  "$TOUCHSTONE_ROOT/principles" \
  "$TOUCHSTONE_ROOT/scripts" \
  "$TOUCHSTONE_ROOT/skills" \
  "$TOUCHSTONE_ROOT/templates" 2>/dev/null \
  || true)"
if [ -n "$active_router_refs" ]; then
  printf '%s\n' "$active_router_refs" >&2
  fail "retired model-router reference found on an active product surface"
fi

echo "==> Pre-implementation gate covers migration-state enumeration (issue #558)"
# The canonical checklist owns the subsystem-removal gate: states derive from
# the subsystem's persistence boundary (not a fixed global matrix), each supported state names
# its source of truth and fail-closed behavior, and shims are explicitly
# inert and time-bounded.
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "removing or replacing a subsystem"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "persistence boundary"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "source of truth"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "fail-closed"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "before the first review request"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "time-bounded migration shims"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "unmatched"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "reviewable unit with adversarial boundary coverage"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "serial test discovery"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "effective"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "where applicable"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "domain can express"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "non-filesystem"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "symlink"
assert_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" "malformed"
assert_not_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "migration-state matrix"
# The principle syncs into downstream projects, where Touchstone-local PR and
# issue numbers are meaningless or point at unrelated work.
assert_not_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "PR #554"
assert_not_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "issue #558"

# Memory hygiene moved out of TOUCHSTONE.md into a routed principle to buy
# header room. Routing content out is only safe if the route itself is pinned:
# without these assertions the row, the file, or the copy in the managed blocks
# could each disappear while the whole suite stayed green, and every driver
# would silently lose the guidance.
echo "==> memory hygiene is routed, not inlined, and the route is intact"
assert_contains "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "principles/memory-hygiene.md"
for file in "$TOUCHSTONE_ROOT/AGENTS.md" "$TOUCHSTONE_ROOT/GEMINI.md"; do
  assert_contains "$file" "principles/memory-hygiene.md"
done
# The index downstream projects receive must list it, or they get an
# incomplete catalog immediately after bootstrap.
assert_contains "$TOUCHSTONE_ROOT/principles/README.md" "memory-hygiene.md"
# The routed doc has to actually carry the rules the router promises.
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "cached guidance, not canonical truth"
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "YYYY-MM-DD"
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "canonical owner"
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "timestamped backup"

# The purpose statement is the contract's thesis; if it is ever reduced back to
# a vague "reviewed and tested" line, the division of labour that every other
# rule depends on stops being stated anywhere.
echo "==> the three-role purpose is stated in every driver's contract"
for file in "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md"; do
  assert_contains "$file" "Humans approve plans"
  assert_contains "$file" "GitHub reviews code"
  # The adopted gate's conditions are load-bearing, but universal steering may
  # not claim a repository has adopted them without inspecting effective rules.
  assert_contains "$file" "GitHub's effective repository policy is the enforcement authority"
  assert_contains "$file" "every thread must be resolved"
  assert_contains "$file" "inspect the repository's effective rules"
  assert_contains "$file" 'required `review-gate` workflow'
done

# Touchstone's product strategy must guide this repository without leaking
# into the universal steering copied to consumer projects. Consumer agents own
# their project's product scope; they must not be routed into our portfolio plan.
echo "==> product strategy stays project-owned"
# (Previously also asserted on the templates/ copies; templates are deleted.)
assert_not_contains "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "product-contract.md"
assert_not_contains "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "Adoption is set-and-forget"
for file in "$TOUCHSTONE_ROOT/AGENTS.md" "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md"; do
  assert_contains "$file" "docs/product-contract.md"
done
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "An adopted repository remains correct if Touchstone never rewrites it again"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "not universal engineering guidance"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Adoption is compilation"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Explicit non-goals"
# The behavioral proof lane was deleted with Milestone 6; its assertions go
# with it. What survives is the honesty limit -- phrase presence is not
# compliance evidence -- which the contract must keep stating.
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "presence alone is not compliance evidence"
assert_not_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Live-provider trials"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "versioned operator journeys"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "not merely when its"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "organization ruleset required workflow"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "A consumer PR cannot"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "each run evaluates once and never waits"
assert_not_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "A small workflow calls"

# Behavior-driving guidance must name invariants, not inventories. The line
# these assertions replaced listed four downstream projects as frozen on the
# old scripts; three had adopted Touchstone 3, so it told agents not to touch
# live consumers, and it read as current until an audit. The same review
# caught the replacement naming the wrong authority: policy/github/consumers/
# holds a file only where a repository varies from the canonical policy, so a
# consumer's absence there proves nothing about adoption.
echo "==> project guidance names invariants, not inventories"
for file in "$TOUCHSTONE_ROOT/AGENTS.md" "$TOUCHSTONE_ROOT/CLAUDE.md"; do
  assert_contains "$file" "Never restate a volatile inventory"
  assert_contains "$file" "not fixed from here, whatever its state"
  assert_contains "$file" "touchstone policy status"
  assert_contains "$file" "varies from the canonical one"
  assert_not_contains "$file" "anima, vesper, arpeggio, and convoy"
done

# The consumer boundary owns what a project-owned file may say about
# Touchstone, and what a consumer that vendors a Touchstone artifact needs
# published. Both were added after an adopted consumer drifted on each.
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "cite the owner, not its contents"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "never restate an argument list"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "vendors a Touchstone artifact"

# Linear owns volatile implementation order. The durable README may link to
# that plan, but naming its current issue decomposition duplicates state and
# becomes stale when work is split or reordered.
echo "==> durable overview does not duplicate Linear issue mappings"
assert_contains "$TOUCHSTONE_ROOT/README.md" "canonical Linear execution plan"
assert_not_contains "$TOUCHSTONE_ROOT/README.md" "AUT-282"
assert_not_contains "$TOUCHSTONE_ROOT/README.md" "AUT-283"
assert_not_contains "$TOUCHSTONE_ROOT/README.md" "Nothing here opens a PR or merges"
assert_not_contains "$TOUCHSTONE_ROOT/README.md" "There is no CLI"
assert_not_contains "$TOUCHSTONE_ROOT/docs/tracker-contract.md" 'future `touchstone pr`'

# PR #818's late exact-head review found a surviving architectural claim about
# a deleted merge helper. The path-integrity test cannot catch prose-only names,
# so pin the semantic correction directly.
echo "==> active architecture names the real review-evidence consumer"
assert_not_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "merge helper can verify"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "review-gate"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "can evaluate from GitHub"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "when the repository's effective policy requires them"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "missing server-side constraints are a rollout gap"
assert_not_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  'The required `review-gate` workflow'

# Every surface that describes the merge gate must name the server-side review
# binding now that the previously documented gap is closed.
GATE_FILES="
$TOUCHSTONE_ROOT/TOUCHSTONE.md
$TOUCHSTONE_ROOT/AGENTS.md
$TOUCHSTONE_ROOT/GEMINI.md
$TOUCHSTONE_ROOT/README.md
$TOUCHSTONE_ROOT/principles/git-workflow.md
$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md
"

echo "==> every gate description names enforced exact-head review binding"
for file in $GATE_FILES; do
  [ -f "$file" ] || continue
  if ! grep -Fq 'review-gate' "$file"; then
    fail "$(basename "$file") describes the merge gate without naming review-gate"
  fi
done

echo "==> no gate description retains the superseded unenforced-review caveat"
for file in $GATE_FILES; do
  [ -f "$file" ] || continue
  hits="$(grep -inEi 'not an enforced gate|not currently enforce|nothing currently enforces|review enforcement is advisory|required but unenforced' "$file" || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "$(basename "$file") retains the superseded unenforced-review caveat"
  fi
done

echo "==> direct OpenRouter review is bounded, staged-only, and offline-testable"
FAKE_SECURITY="$TEST_DIR/security"
FAKE_KEYCHAIN_DIR="$TEST_DIR/keychain"
FAKE_KEYCHAIN_LOG="$TEST_DIR/keychain-log"
cat >"$FAKE_SECURITY" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
account=""
args=("$@")
index=0
while [ "$index" -lt "${#args[@]}" ]; do
  if [ "${args[$index]}" = -a ]; then
    index=$((index + 1))
    account="${args[$index]}"
    break
  fi
  index=$((index + 1))
done
[ -n "$account" ] || exit 2
key_id="$(printf '%s' "$account" | cksum | awk '{print $1}')"
state="$TOUCHSTONE_FAKE_KEYCHAIN_DIR/$key_id"
mkdir -p "$TOUCHSTONE_FAKE_KEYCHAIN_DIR"
case "${1:-}" in
  find-generic-password)
    [ "${TOUCHSTONE_FAKE_READBACK_FAIL:-false}" != true ] || exit 45
    [ -f "$state" ] || exit 44
    [ "${TOUCHSTONE_FAKE_EMPTY_KEY:-false}" != true ] || exit 0
    if [ "${TOUCHSTONE_FAKE_UNSAFE_KEY:-false}" = true ]; then
      printf 'unsafe"key\n'
    else
      printf 'sk-or-v1-dummy-token\n'
    fi
    ;;
  add-generic-password)
    printf 'add\n' >>"$TOUCHSTONE_FAKE_KEYCHAIN_LOG"
    : >"$state"
    ;;
  delete-generic-password)
    [ "${TOUCHSTONE_FAKE_DELETE_FAIL:-false}" != true ] || exit 46
    printf 'delete\n' >>"$TOUCHSTONE_FAKE_KEYCHAIN_LOG"
    rm -f "$state"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_SECURITY"

FAKE_CURL="$TEST_DIR/curl"
FAKE_CURL_LOG="$TEST_DIR/curl-log"
FAKE_CURL_CAPTURE="$TEST_DIR/request.json"
FAKE_RESPONSE="$TEST_DIR/response.json"
REVIEW_CONTENT='{"summary":"One concrete defect.","findings":[{"severity":"P2","file":"staged.txt","line":1,"title":"Wrong value","body":"The staged value breaks the fixture invariant."}]}'
jq -n --arg content "$REVIEW_CONTENT" '{
  model: "qwen/qwen3-coder-next",
  usage: {prompt_tokens: 321, completion_tokens: 45, cost: 0.00042},
  choices: [{finish_reason: "stop", message: {content: $content}}]
}' >"$FAKE_RESPONSE"
cat >"$FAKE_CURL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
case "$config" in
  *'Authorization: Bearer sk-or-v1-dummy-token'*) ;;
  *) echo "missing safe authorization config" >&2; exit 97 ;;
esac
printf 'call\n' >>"$TOUCHSTONE_FAKE_CURL_LOG"
output=""
request=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --data-binary)
      request="${2#@}"
      shift 2
      ;;
    *) shift ;;
  esac
done
[ -n "$output" ] && [ -n "$request" ] || exit 96
cp "$request" "$TOUCHSTONE_FAKE_CURL_CAPTURE"
[ "${TOUCHSTONE_FAKE_CURL_STATUS:-0}" -eq 0 ] \
  || exit "$TOUCHSTONE_FAKE_CURL_STATUS"
cp "$TOUCHSTONE_FAKE_REVIEW_RESPONSE" "$output"
printf '%s' "${TOUCHSTONE_FAKE_HTTP_STATUS:-200}"
EOF
chmod +x "$FAKE_CURL"

review_command() {
  TOUCHSTONE_REVIEW_PLATFORM=Darwin \
    TOUCHSTONE_REVIEW_SECURITY_BIN="$FAKE_SECURITY" \
    TOUCHSTONE_REVIEW_CURL_BIN="$FAKE_CURL" \
    TOUCHSTONE_REVIEW_CODEX_BIN="${TOUCHSTONE_REVIEW_CODEX_BIN:-$TEST_DIR/absent-codex}" \
    TOUCHSTONE_FAKE_KEYCHAIN_DIR="$FAKE_KEYCHAIN_DIR" \
    TOUCHSTONE_FAKE_KEYCHAIN_LOG="$FAKE_KEYCHAIN_LOG" \
    TOUCHSTONE_FAKE_READBACK_FAIL="${TOUCHSTONE_FAKE_READBACK_FAIL:-false}" \
    TOUCHSTONE_FAKE_EMPTY_KEY="${TOUCHSTONE_FAKE_EMPTY_KEY:-false}" \
    TOUCHSTONE_FAKE_UNSAFE_KEY="${TOUCHSTONE_FAKE_UNSAFE_KEY:-false}" \
    TOUCHSTONE_FAKE_DELETE_FAIL="${TOUCHSTONE_FAKE_DELETE_FAIL:-false}" \
    TOUCHSTONE_FAKE_CURL_LOG="$FAKE_CURL_LOG" \
    TOUCHSTONE_FAKE_CURL_CAPTURE="$FAKE_CURL_CAPTURE" \
    TOUCHSTONE_FAKE_CURL_STATUS="${TOUCHSTONE_FAKE_CURL_STATUS:-0}" \
    TOUCHSTONE_FAKE_HTTP_STATUS="${TOUCHSTONE_FAKE_HTTP_STATUS:-200}" \
    TOUCHSTONE_FAKE_REVIEW_RESPONSE="${TOUCHSTONE_FAKE_REVIEW_RESPONSE:-$FAKE_RESPONSE}" \
    bash "$TOUCHSTONE_ROOT/bin/touchstone" review "$@"
}

fake_key_path() {
  local key_id
  key_id="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s/%s\n' "$FAKE_KEYCHAIN_DIR" "$key_id"
}

REVIEW_HOME="$TEST_DIR/review-credential-scope"
review_command setup --codex-home "$REVIEW_HOME" >"$TEST_DIR/review-setup.out" 2>&1 \
  || fail "normal-review setup failed: $(cat "$TEST_DIR/review-setup.out")"
assert_not_contains "$TEST_DIR/review-setup.out" 'sk-or-v1-dummy-token'
NON_REPOSITORY_REVIEW_DIR="$TEST_DIR/review-machine-check"
mkdir -p "$NON_REPOSITORY_REVIEW_DIR"
(
  cd "$NON_REPOSITORY_REVIEW_DIR"
  review_command credential-check --codex-home "$REVIEW_HOME" >/dev/null 2>&1
) || fail "machine-level review credential check required repository context"
assert_contains "$TOUCHSTONE_ROOT/scripts/touchstone-steering-install.sh" \
  'touchstone-review.sh" credential-check'
[ ! -e "$TOUCHSTONE_ROOT/scripts/touchstone-review-setup.sh" ] \
  || fail "retired Codex review launcher remains"
[ ! -e "$TOUCHSTONE_ROOT/scripts/lib/touchstone-review-codex.sh" ] \
  || fail "retired Codex review library remains"
[ ! -e "$TOUCHSTONE_ROOT/config/review-normal.config.toml" ] \
  || fail "retired Codex review profile remains"

REVIEW_REPOSITORY="$TEST_DIR/review-repository"
mkdir -p "$REVIEW_REPOSITORY"
git init -q "$REVIEW_REPOSITORY"
printf 'baseline\n' >"$REVIEW_REPOSITORY/staged.txt"
printf 'baseline\n' >"$REVIEW_REPOSITORY/unstaged.txt"
git -C "$REVIEW_REPOSITORY" add staged.txt unstaged.txt
git -C "$REVIEW_REPOSITORY" \
  -c user.name=Touchstone -c user.email=touchstone@example.invalid \
  commit -qm initial
printf 'reviewed value\n' >"$REVIEW_REPOSITORY/staged.txt"
git -C "$REVIEW_REPOSITORY" add staged.txt
printf 'must not be reviewed\n' >"$REVIEW_REPOSITORY/unstaged.txt"
printf 'also excluded\n' >"$REVIEW_REPOSITORY/untracked.txt"

(
  cd "$REVIEW_REPOSITORY"
  review_command check --codex-home "$REVIEW_HOME" >"$TEST_DIR/review-check.out" 2>&1
) || fail "offline normal-review check failed: $(cat "$TEST_DIR/review-check.out")"
[ ! -e "$FAKE_CURL_LOG" ] \
  || fail "normal-review check made a network request"
(
  cd "$REVIEW_REPOSITORY"
  review_command run --codex-home "$REVIEW_HOME" >"$TEST_DIR/review-run.out" 2>&1
) || fail "direct OpenRouter review failed: $(cat "$TEST_DIR/review-run.out")"
[ "$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')" = 1 ] \
  || fail "one review did not make exactly one OpenRouter request"
for expected in \
  'OpenRouter review' \
  'Model: qwen/qwen3-coder-next' \
  'Cost: $0.00042' \
  'Tokens: prompt=321 completion=45' \
  'P2 staged.txt:1 Wrong value' \
  'Evidence: openrouter on the staged slice (review-normal): 1 findings'; do
  assert_contains "$TEST_DIR/review-run.out" "$expected"
done
assert_not_contains "$TEST_DIR/review-run.out" 'sk-or-v1-dummy-token'
jq -e '
  .model == "qwen/qwen3-coder" and
  (has("plugins") | not) and
  .provider.require_parameters == true and
  .provider.max_price.prompt == 0.5 and
  .provider.max_price.completion == 2 and
  .max_tokens == 16384 and
  .usage.include == true and
  .response_format.type == "json_schema" and
  (.tools == null)
' "$FAKE_CURL_CAPTURE" >/dev/null \
  || fail "OpenRouter request lost its model, price, output, or no-tools boundary: $(jq -c '{model, max_tokens, plugins, provider}' "$FAKE_CURL_CAPTURE" 2>&1)"
assert_contains "$FAKE_CURL_CAPTURE" 'reviewed value'
assert_not_contains "$FAKE_CURL_CAPTURE" 'must not be reviewed'
assert_not_contains "$FAKE_CURL_CAPTURE" 'also excluded'
assert_not_contains "$FAKE_CURL_CAPTURE" 'sk-or-v1-dummy-token'

echo "==> empty and oversized staged slices fail before credentials or network"
git -C "$REVIEW_REPOSITORY" restore --staged --worktree staged.txt
EMPTY_REVIEW_HOME="$TEST_DIR/empty-review-scope"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_REPOSITORY"
  review_command run --codex-home "$EMPTY_REVIEW_HOME"
) >"$TEST_DIR/empty-review.out" 2>&1; then
  fail "normal review accepted an empty staged slice"
elif ! grep -qF 'no staged changes' "$TEST_DIR/empty-review.out"; then
  fail "empty staged slice reached credential lookup: $(cat "$TEST_DIR/empty-review.out")"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] || fail "empty staged slice reached OpenRouter"

REVIEW_FSMONITOR="$TEST_DIR/review-fsmonitor"
REVIEW_FSMONITOR_MARKER="$TEST_DIR/review-fsmonitor-ran"
cat >"$REVIEW_FSMONITOR" <<EOF
#!/usr/bin/env bash
printf 'invoked\n' >"$REVIEW_FSMONITOR_MARKER"
EOF
chmod +x "$REVIEW_FSMONITOR"
git -C "$REVIEW_REPOSITORY" config core.fsmonitor "$REVIEW_FSMONITOR"
if (
  cd "$REVIEW_REPOSITORY"
  review_command run --codex-home "$EMPTY_REVIEW_HOME"
) >/dev/null 2>&1; then
  fail "empty review unexpectedly passed with a configured fsmonitor"
fi
[ ! -e "$REVIEW_FSMONITOR_MARKER" ] \
  || fail "normal-review diff discovery executed repository-configured fsmonitor"
git -C "$REVIEW_REPOSITORY" config --unset core.fsmonitor

printf 'reviewed value\n' >"$REVIEW_REPOSITORY/staged.txt"
git -C "$REVIEW_REPOSITORY" add staged.txt
SMALL_POLICY="$TEST_DIR/review-small-policy.json"
jq '.limits.maxInputBytes = 100' \
  "$TOUCHSTONE_ROOT/config/review-normal.json" >"$SMALL_POLICY"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_REPOSITORY"
  TOUCHSTONE_REVIEW_POLICY_FILE="$SMALL_POLICY" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/small-limit.out" 2>&1; then
  fail "normal review accepted a request above its configured byte limit"
elif ! grep -qF 'configured limit is 100 bytes' "$TEST_DIR/small-limit.out"; then
  fail "input limit failure was not actionable: $(cat "$TEST_DIR/small-limit.out")"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] || fail "oversized review reached OpenRouter"

awk 'BEGIN { for (i = 0; i < 405000; i++) printf "x"; printf "\n" }' \
  >"$REVIEW_REPOSITORY/staged.txt"
git -C "$REVIEW_REPOSITORY" add staged.txt
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_REPOSITORY"
  review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/large-input.out" 2>&1; then
  fail "normal review accepted a large request above the shipped limit"
elif ! grep -qF 'configured limit is 400000 bytes' "$TEST_DIR/large-input.out"; then
  fail "the shipped large-input limit was not enforced"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] || fail "large review reached OpenRouter"

echo "==> deleted and vendored files are named, not sent"
# A deletion's removed lines and a linguist-vendored tree have no line-level
# review value and used to blow the byte ceiling, which agents then recorded
# as an unavailable reviewer (vesper #1154, #1157, #1160). The request must
# carry the change's own diff, name the excluded paths, and leave their
# bodies out.
STUB_REPOSITORY="$TEST_DIR/review-stub-repository"
mkdir -p "$STUB_REPOSITORY/vendor/lib"
stub_git() {
  git -C "$STUB_REPOSITORY" \
    -c user.name=Touchstone -c user.email=touchstone@example.invalid "$@"
}
git init -q "$STUB_REPOSITORY"
printf 'vendor/** linguist-vendored\n' >"$STUB_REPOSITORY/.gitattributes"
printf 'DELETED_BODY_MARKER\n' >"$STUB_REPOSITORY/old.txt"
printf 'vendored baseline\n' >"$STUB_REPOSITORY/vendor/lib/dep.js"
printf 'own baseline\n' >"$STUB_REPOSITORY/own.txt"
stub_git add .gitattributes old.txt vendor/lib/dep.js own.txt
stub_git commit -qm initial
stub_git rm -q old.txt
printf 'VENDORED_BODY_MARKER\n' >"$STUB_REPOSITORY/vendor/lib/dep.js"
printf 'OWN_CHANGE_MARKER\n' >"$STUB_REPOSITORY/own.txt"
stub_git add vendor/lib/dep.js own.txt
(
  cd "$STUB_REPOSITORY"
  review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/stub-review.out" 2>&1 \
  || fail "review with deleted and vendored files failed: $(cat "$TEST_DIR/stub-review.out")"
assert_contains "$FAKE_CURL_CAPTURE" 'OWN_CHANGE_MARKER'
assert_not_contains "$FAKE_CURL_CAPTURE" 'DELETED_BODY_MARKER'
assert_not_contains "$FAKE_CURL_CAPTURE" 'VENDORED_BODY_MARKER'
assert_contains "$FAKE_CURL_CAPTURE" 'deleted: old.txt'
assert_contains "$FAKE_CURL_CAPTURE" 'linguist-vendored: vendor/lib/dep.js'

echo "==> --base reviews the committed branch range, not the index"
# The serious tier's fallback: Codex reads the committed branch, so the
# stand-in must read the same revisions -- not the index the normal tier
# reviews, and not work that landed on the base after branching (AUT-1217).
RANGE_REPOSITORY="$TEST_DIR/review-range-repository"
mkdir -p "$RANGE_REPOSITORY"
git init -q -b main "$RANGE_REPOSITORY"
range_git() {
  git -C "$RANGE_REPOSITORY" \
    -c user.name=Touchstone -c user.email=touchstone@example.invalid "$@"
}
printf 'baseline\n' >"$RANGE_REPOSITORY/tracked.txt"
range_git add tracked.txt
range_git commit -qm initial
range_git checkout -qb feature
printf 'committed on the branch\n' >"$RANGE_REPOSITORY/tracked.txt"
range_git add tracked.txt
range_git commit -qm "branch work"
range_git checkout -q main
printf 'landed on the base after branching\n' >"$RANGE_REPOSITORY/base-only.txt"
range_git add base-only.txt
range_git commit -qm "base work"
range_git checkout -q feature
printf 'staged after the commit\n' >"$RANGE_REPOSITORY/tracked.txt"
range_git add tracked.txt
printf 'never reviewed\n' >"$RANGE_REPOSITORY/untracked.txt"
RANGE_HEAD="$(range_git rev-parse HEAD)"
(
  cd "$RANGE_REPOSITORY"
  review_command run --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/range-review.out" 2>&1 \
  || fail "range review failed: $(cat "$TEST_DIR/range-review.out")"
assert_contains "$FAKE_CURL_CAPTURE" 'committed on the branch'
assert_not_contains "$FAKE_CURL_CAPTURE" 'staged after the commit'
assert_not_contains "$FAKE_CURL_CAPTURE" 'landed on the base after branching'
assert_not_contains "$FAKE_CURL_CAPTURE" 'never reviewed'
assert_contains "$FAKE_CURL_CAPTURE" 'Review only this Git branch diff'
assert_not_contains "$FAKE_CURL_CAPTURE" 'staged Git diff'
# The evidence target is the reviewed revision, which is the shape
# delivery-evidence requires of a serious row.
assert_contains "$TEST_DIR/range-review.out" "Evidence: openrouter on $RANGE_HEAD:"

echo "==> the range scope carries its own ceiling and its own empty case"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$RANGE_REPOSITORY"
  review_command run --base feature --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/range-empty.out" 2>&1; then
  fail "range review accepted a branch with no commits beyond its base"
elif ! grep -qF 'no changes between' "$TEST_DIR/range-empty.out"; then
  fail "empty range was not actionable: $(cat "$TEST_DIR/range-empty.out")"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] || fail "an empty range reached OpenRouter"

# One ceiling bounds both scopes, and fires before the network either way.
SMALL_RANGE_POLICY="$TEST_DIR/review-small-range-policy.json"
jq '.limits.maxInputBytes = 100' \
  "$TOUCHSTONE_ROOT/config/review-normal.json" >"$SMALL_RANGE_POLICY"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$RANGE_REPOSITORY"
  TOUCHSTONE_REVIEW_POLICY_FILE="$SMALL_RANGE_POLICY" \
    review_command run --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/range-limit.out" 2>&1; then
  fail "range review accepted a request above the configured limit"
elif ! grep -qF 'configured limit is 100 bytes' "$TEST_DIR/range-limit.out"; then
  fail "the range limit failure was not actionable: $(cat "$TEST_DIR/range-limit.out")"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] || fail "an oversized range reached OpenRouter"

echo "==> the byte ceiling names a slicing error, never a waiver"
assert_contains "$TEST_DIR/small-limit.out" 'not a waiver'
assert_contains "$TEST_DIR/range-limit.out" 'not a waiver'

echo "==> --base runs codex first, and falls back on every non-success"
# The fallback is the script's decision, not the driver's. An agent that has to
# notice the quota ran out is the same weak link that shipped four PRs with no
# local pass at all (AUT-443, AUT-1217), so the sequence is exercised here.
FAKE_CODEX="$TEST_DIR/codex"
FAKE_CODEX_LOG="$TEST_DIR/codex-log"
cat >"$FAKE_CODEX" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TOUCHSTONE_FAKE_CODEX_LOG"
printf 'codex review output\n'
exit "${TOUCHSTONE_FAKE_CODEX_STATUS:-0}"
EOF
chmod +x "$FAKE_CODEX"

serious_command() {
  TOUCHSTONE_REVIEW_CODEX_BIN="$FAKE_CODEX" \
    TOUCHSTONE_FAKE_CODEX_LOG="$FAKE_CODEX_LOG" \
    TOUCHSTONE_FAKE_CODEX_STATUS="${TOUCHSTONE_FAKE_CODEX_STATUS:-0}" \
    review_command "$@"
}

: >"$FAKE_CODEX_LOG"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
(
  cd "$RANGE_REPOSITORY"
  serious_command run --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/serious-ok.out" 2>&1 \
  || fail "serious review failed while codex succeeded: $(cat "$TEST_DIR/serious-ok.out")"
assert_contains "$FAKE_CODEX_LOG" 'review --base main'
assert_contains "$TEST_DIR/serious-ok.out" 'codex review output'
assert_contains "$TEST_DIR/serious-ok.out" "Evidence: codex on $RANGE_HEAD:"
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] \
  || fail "a successful codex review still spent an OpenRouter request"

echo "==> a base behind its upstream is refused before any reviewer runs"
# A stale base fills the slice with already-merged work, so the reviewer
# rejects it as wrong rather than large (AUT-1287). The tier allows one pass,
# so the refusal has to land before a reviewer is spent -- the first version of
# this check sat in the request path and fired only after codex had run.
# Its own repository: mutating a shared fixture's branch would leak into the
# cases below.
STALE_REPO="$TEST_DIR/stale-base-repository"
STALE_ORIGIN="$TEST_DIR/stale-base-origin.git"
git init -q --bare "$STALE_ORIGIN"
git init -q -b main "$STALE_REPO"
stale_git() { git -C "$STALE_REPO" -c user.email=t@t -c user.name=t "$@"; }
printf 'one\n' >"$STALE_REPO/f.txt"
stale_git add f.txt
stale_git commit -qm one
stale_git remote add origin "$STALE_ORIGIN"
stale_git push -q -u origin main
printf 'two\n' >>"$STALE_REPO/f.txt"
stale_git commit -qam two
stale_git push -q origin main
stale_git reset -q --hard HEAD~1
stale_git checkout -qb feature
printf 'three\n' >>"$STALE_REPO/f.txt"
stale_git commit -qam three
: >"$FAKE_CODEX_LOG"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$STALE_REPO"
  serious_command run --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/serious-stale.out" 2>&1; then
  fail "a base behind its upstream was accepted: $(cat "$TEST_DIR/serious-stale.out")"
fi
assert_contains "$TEST_DIR/serious-stale.out" "behind 'origin/main'"
assert_contains "$TEST_DIR/serious-stale.out" "already merged"
[ ! -s "$FAKE_CODEX_LOG" ] \
  || fail "a stale base spent a codex review before being refused: $(cat "$FAKE_CODEX_LOG")"
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] \
  || fail "a stale base spent an OpenRouter request before being refused"

# Any non-success is unavailability: the reason is not parsed out of a
# third-party CLI's stderr, it is simply not Codex's verdict.
: >"$FAKE_CODEX_LOG"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
(
  cd "$RANGE_REPOSITORY"
  TOUCHSTONE_FAKE_CODEX_STATUS=1 \
    serious_command run --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/serious-fallback.out" 2>&1 \
  || fail "a failed codex review was not covered by the fallback: $(cat "$TEST_DIR/serious-fallback.out")"
assert_contains "$FAKE_CODEX_LOG" 'review --base main'
assert_contains "$TEST_DIR/serious-fallback.out" 'codex review exited 1'
assert_contains "$TEST_DIR/serious-fallback.out" "Evidence: openrouter on $RANGE_HEAD:"
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" != "$after_calls" ] \
  || fail "the fallback never reached OpenRouter"
# The fallback reviews the branch Codex would have read, not the index.
assert_contains "$FAKE_CURL_CAPTURE" 'committed on the branch'
assert_not_contains "$FAKE_CURL_CAPTURE" 'staged after the commit'

# An absent CLI is the same path as a failed one.
: >"$FAKE_CODEX_LOG"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
(
  cd "$RANGE_REPOSITORY"
  TOUCHSTONE_REVIEW_CODEX_BIN="$TEST_DIR/no-such-codex" \
    review_command run --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/serious-absent.out" 2>&1 \
  || fail "an absent codex was not covered by the fallback: $(cat "$TEST_DIR/serious-absent.out")"
assert_contains "$TEST_DIR/serious-absent.out" 'codex is not installed'
assert_contains "$TEST_DIR/serious-absent.out" "Evidence: openrouter on $RANGE_HEAD:"
[ ! -s "$FAKE_CODEX_LOG" ] || fail "an absent codex path still invoked a CLI"
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" != "$after_calls" ] \
  || fail "the absent-codex fallback never reached OpenRouter"

# A broken policy must stop before the expensive reviewer, not after it.
SERIOUS_BAD_POLICY="$TEST_DIR/review-serious-bad-policy.json"
# A version far enough ahead that bumping the real schema cannot quietly turn
# this fixture into a valid policy -- which is exactly what happened when the
# sentinel was the next version number and the schema moved to it.
jq '.schema = "touchstone.review/v99"' \
  "$TOUCHSTONE_ROOT/config/review-normal.json" >"$SERIOUS_BAD_POLICY"
: >"$FAKE_CODEX_LOG"
if (
  cd "$RANGE_REPOSITORY"
  TOUCHSTONE_REVIEW_POLICY_FILE="$SERIOUS_BAD_POLICY" \
    serious_command run --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/serious-policy.out" 2>&1; then
  fail "serious review ran with an unsupported policy"
elif ! grep -qF 'malformed or unsupported' "$TEST_DIR/serious-policy.out"; then
  fail "the serious policy fault was not actionable: $(cat "$TEST_DIR/serious-policy.out")"
fi
[ ! -s "$FAKE_CODEX_LOG" ] \
  || fail "a broken policy spent a codex run before failing"

# The normal tier is the same command without --base, and it never reaches
# Codex even when a Codex binary is right there.
: >"$FAKE_CODEX_LOG"
(
  cd "$RANGE_REPOSITORY"
  serious_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/staged-no-codex.out" 2>&1 \
  || fail "staged review failed with a codex binary present: $(cat "$TEST_DIR/staged-no-codex.out")"
[ ! -s "$FAKE_CODEX_LOG" ] || fail "a staged review invoked codex"

echo "==> --base belongs to run alone and needs a revision"
if (
  cd "$RANGE_REPOSITORY"
  review_command check --base main --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/range-check.out" 2>&1; then
  fail "check accepted --base, which selects a scope it never reads"
elif ! grep -qF 'only valid for' "$TEST_DIR/range-check.out"; then
  fail "the misplaced --base was not explained: $(cat "$TEST_DIR/range-check.out")"
fi
if (
  cd "$RANGE_REPOSITORY"
  review_command run --base --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/range-bare.out" 2>&1; then
  fail "--base accepted a following flag as its revision"
fi

echo "==> linked worktrees use their own staged index"
REVIEW_WORKTREE="$TEST_DIR/review-linked-worktree"
git -C "$REVIEW_REPOSITORY" restore --staged --worktree staged.txt
git -C "$REVIEW_REPOSITORY" worktree add --detach "$REVIEW_WORKTREE" HEAD >/dev/null
printf 'linked staged value\n' >"$REVIEW_WORKTREE/staged.txt"
git -C "$REVIEW_WORKTREE" add staged.txt
(
  cd "$REVIEW_WORKTREE"
  review_command run --codex-home "$REVIEW_HOME" >/dev/null 2>&1
) || fail "normal review could not read a linked worktree's staged diff"
assert_contains "$FAKE_CURL_CAPTURE" 'linked staged value'

echo "==> provider and transport failures make one request and fail closed"
for status_and_text in \
  '401|rejected the credential' \
  '402|billing or the API-key spending limit' \
  '403|dedicated key permissions' \
  '429|request was not retried'; do
  http_status="${status_and_text%%|*}"
  expected_text="${status_and_text#*|}"
  before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
  if (
    cd "$REVIEW_WORKTREE"
    TOUCHSTONE_FAKE_HTTP_STATUS="$http_status" \
      review_command run --codex-home "$REVIEW_HOME"
  ) >"$TEST_DIR/http-$http_status.out" 2>&1; then
    fail "HTTP $http_status review failure was accepted"
  elif ! grep -qF "$expected_text" "$TEST_DIR/http-$http_status.out"; then
    fail "HTTP $http_status review failure was not actionable"
  fi
  after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
  [ $((after_calls - before_calls)) -eq 1 ] \
    || fail "HTTP $http_status review was retried"
done
PRICE_CAP_RESPONSE="$TEST_DIR/price-cap-response.json"
jq -n '{error: {message: "No endpoints found that satisfy the max price for this request"}}' \
  >"$PRICE_CAP_RESPONSE"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_HTTP_STATUS=404 \
    TOUCHSTONE_FAKE_REVIEW_RESPONSE="$PRICE_CAP_RESPONSE" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/http-price-cap.out" 2>&1; then
  fail "OpenRouter price-cap failure was accepted"
elif ! grep -qF 'no model within the configured price ceilings' \
  "$TEST_DIR/http-price-cap.out"; then
  fail "OpenRouter price-cap failure was not actionable"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ $((after_calls - before_calls)) -eq 1 ] \
  || fail "OpenRouter price-cap failure was retried"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_CURL_STATUS=28 \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/review-timeout.out" 2>&1; then
  fail "OpenRouter timeout was accepted"
elif ! grep -qF 'timed out' "$TEST_DIR/review-timeout.out"; then
  fail "OpenRouter timeout lost its diagnostic"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ $((after_calls - before_calls)) -eq 1 ] || fail "OpenRouter timeout was retried"

echo "==> malformed, truncated, unsafe, and unsupported boundaries fail closed"
MALFORMED_RESPONSE="$TEST_DIR/malformed-response.json"
printf '{"not":"a completion"}\n' >"$MALFORMED_RESPONSE"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_REVIEW_RESPONSE="$MALFORMED_RESPONSE" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/malformed-response.out" 2>&1; then
  fail "malformed OpenRouter response was accepted"
elif ! grep -qF 'malformed review response' "$TEST_DIR/malformed-response.out"; then
  fail "malformed OpenRouter response lost its diagnostic"
fi
if ! grep -qF 'unusable: model, usage.prompt_tokens' \
  "$TEST_DIR/malformed-response.out"; then
  fail "malformed OpenRouter response did not name its unusable fields"
fi

# A response failing exactly one condition must name exactly that condition.
# The seven-condition compound check this replaced exited through one generic
# sentence, so a null cost read the same as an auth page, and the EXIT trap
# deleted the only body that could have told them apart.
NULL_COST_RESPONSE="$TEST_DIR/null-cost-response.json"
jq '.usage.cost = null' "$FAKE_RESPONSE" >"$NULL_COST_RESPONSE"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_REVIEW_RESPONSE="$NULL_COST_RESPONSE" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/null-cost-response.out" 2>&1; then
  fail "OpenRouter response with an unusable cost was accepted"
elif ! grep -qF 'unusable: usage.cost; model:' "$TEST_DIR/null-cost-response.out"; then
  fail "single-field OpenRouter failure did not name exactly that field"
fi
REVIEW_KEPT_RESPONSE="$(sed -n 's/.*response kept at //p' \
  "$TEST_DIR/null-cost-response.out" | head -1)"
[ -n "$REVIEW_KEPT_RESPONSE" ] \
  || fail "malformed OpenRouter response named no preserved body"
[ -s "$REVIEW_KEPT_RESPONSE" ] \
  || fail "preserved OpenRouter response is missing or empty: $REVIEW_KEPT_RESPONSE"
jq -e '.usage.cost == null' "$REVIEW_KEPT_RESPONSE" >/dev/null \
  || fail "preserved OpenRouter response is not the body that failed"
rm -f "$REVIEW_KEPT_RESPONSE"

# A 200 carrying a provider error and no choices is a transport failure, not a
# malformed review. Verified live on the gate side before being fixed there.
PROVIDER_ERROR_RESPONSE="$TEST_DIR/provider-error-response.json"
jq -n '{error: {message: "temporarily rate-limited upstream. Please retry shortly"}}' \
  >"$PROVIDER_ERROR_RESPONSE"
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_REVIEW_RESPONSE="$PROVIDER_ERROR_RESPONSE" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/provider-error.out" 2>&1; then
  fail "HTTP 200 carrying a provider error was accepted"
elif ! grep -qF 'HTTP 200 with a provider error' "$TEST_DIR/provider-error.out"; then
  fail "HTTP 200 provider error was not distinguished from a malformed review"
elif ! grep -qF 'temporarily rate-limited upstream' "$TEST_DIR/provider-error.out"; then
  fail "HTTP 200 provider error did not carry the provider's own message"
elif ! grep -qF 'not retried' "$TEST_DIR/provider-error.out"; then
  fail "HTTP 200 provider error did not say the request was not retried"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ $((after_calls - before_calls)) -eq 1 ] \
  || fail "HTTP 200 provider error was retried"
REVIEW_KEPT_RESPONSE="$(sed -n 's/.*response kept at //p' \
  "$TEST_DIR/provider-error.out" | head -1)"
[ -z "$REVIEW_KEPT_RESPONSE" ] || rm -f "$REVIEW_KEPT_RESPONSE"
TRUNCATED_RESPONSE="$TEST_DIR/truncated-response.json"
jq '.choices[0].finish_reason = "length"' "$FAKE_RESPONSE" >"$TRUNCATED_RESPONSE"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_REVIEW_RESPONSE="$TRUNCATED_RESPONSE" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/truncated-response.out" 2>&1; then
  fail "truncated OpenRouter response was accepted"
elif ! grep -qF 'stopped at the configured completion limit' "$TEST_DIR/truncated-response.out"; then
  fail "budget-exhausted OpenRouter response lost its diagnostic"
# The remedy matters as much as the diagnosis. "split the change" sent an agent
# to re-slice a diff that was never too big, and principles/local-review.md
# forbids waiving a size refusal -- so the pair deadlocked a small change with
# no legal move. The message must name the budget and refuse the waiver.
elif ! grep -qF 'not evidence that the change is too large' "$TEST_DIR/truncated-response.out"; then
  fail "budget diagnostic still blames the size of the change"
# The one-request rule is the other half: principles/local-review.md makes
# truncation failures terminal ("stop without retrying", "the pass runs at most
# once"). A diagnostic that tells the agent to run the pass again instructs a
# contract violation, however reasonable the retry looks in the moment.
elif ! grep -qF 'Stop without retrying' "$TEST_DIR/truncated-response.out"; then
  fail "budget diagnostic does not stop the pass"
elif grep -qiE 'Re-run the pass|try again' "$TEST_DIR/truncated-response.out"; then
  fail "budget diagnostic instructs a second pass, against the one-request rule"
fi
FILTERED_RESPONSE="$TEST_DIR/filtered-response.json"
jq '.choices[0].finish_reason = "content_filter"' \
  "$FAKE_RESPONSE" >"$FILTERED_RESPONSE"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_REVIEW_RESPONSE="$FILTERED_RESPONSE" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/filtered-response.out" 2>&1; then
  fail "non-success OpenRouter finish reason was accepted"
elif ! grep -qF 'did not complete the review' "$TEST_DIR/filtered-response.out"; then
  fail "non-success OpenRouter finish reason lost its fail-closed diagnostic"
fi
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_UNSAFE_KEY=true \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/unsafe-key.out" 2>&1; then
  fail "unsafe Keychain bytes reached curl configuration"
elif ! grep -qF 'unsupported characters' "$TEST_DIR/unsafe-key.out"; then
  fail "unsafe Keychain bytes lost their diagnostic"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] || fail "unsafe Keychain bytes reached curl"
UNSUPPORTED_POLICY="$TEST_DIR/review-unsupported-policy.json"
# A version far enough ahead that bumping the real schema cannot quietly turn
# this fixture into a valid policy -- which is exactly what happened when the
# sentinel was the next version number and the schema moved to it.
jq '.schema = "touchstone.review/v99"' \
  "$TOUCHSTONE_ROOT/config/review-normal.json" >"$UNSUPPORTED_POLICY"
if TOUCHSTONE_REVIEW_POLICY_FILE="$UNSUPPORTED_POLICY" \
  review_command check --codex-home "$EMPTY_REVIEW_HOME" \
  >"$TEST_DIR/unsupported-policy.out" 2>&1; then
  fail "unsupported review policy was accepted"
elif ! grep -qF 'malformed or unsupported' "$TEST_DIR/unsupported-policy.out"; then
  fail "unsupported review policy reached credential lookup"
fi

echo "==> credential lifecycle remains isolated and recoverable"
review_command setup --codex-home "$REVIEW_HOME" >/dev/null 2>&1 \
  || fail "idempotent setup failed"
[ "$(grep -c '^add$' "$FAKE_KEYCHAIN_LOG" || true)" = 1 ] \
  || fail "idempotent setup prompted more than once"
review_command rotate --codex-home "$REVIEW_HOME" >/dev/null 2>&1 \
  || fail "normal-review credential rotation failed"
[ "$(grep -c '^add$' "$FAKE_KEYCHAIN_LOG" || true)" = 2 ] \
  || fail "rotation did not replace the credential"
if review_command rotate --codex-home "$REVIEW_HOME" --dry-run >/dev/null 2>&1; then
  fail "credential rotation accepted --dry-run"
fi
SECOND_REVIEW_HOME="$TEST_DIR/review-second-scope"
review_command setup --codex-home "$SECOND_REVIEW_HOME" >/dev/null 2>&1 \
  || fail "a second credential scope could not configure its own key"
review_command uninstall --codex-home "$SECOND_REVIEW_HOME" >/dev/null 2>&1 \
  || fail "the second credential scope could not uninstall"
[ -e "$(fake_key_path "$REVIEW_HOME")" ] \
  || fail "uninstalling one credential scope deleted another"
if TOUCHSTONE_FAKE_READBACK_FAIL=true \
  review_command setup --codex-home "$TEST_DIR/readback-failure" >/dev/null 2>&1; then
  fail "operational Keychain failure was treated as absence"
fi
if TOUCHSTONE_FAKE_EMPTY_KEY=true \
  review_command check --codex-home "$REVIEW_HOME" >/dev/null 2>&1; then
  fail "normal-review check accepted an empty Keychain credential"
fi
review_command uninstall --codex-home "$REVIEW_HOME" >/dev/null 2>&1 \
  || fail "normal-review uninstall failed"
[ ! -e "$(fake_key_path "$REVIEW_HOME")" ] \
  || fail "uninstall left the managed credential behind"
DRY_REVIEW_HOME="$TEST_DIR/review-dry-scope"
review_command setup --codex-home "$DRY_REVIEW_HOME" --dry-run >/dev/null 2>&1 \
  || fail "normal-review setup dry run failed"
[ ! -e "$DRY_REVIEW_HOME" ] \
  || fail "normal-review setup dry run mutated its credential scope"
if TOUCHSTONE_REVIEW_PLATFORM=Linux \
  TOUCHSTONE_REVIEW_SECURITY_BIN="$FAKE_SECURITY" \
  bash "$TOUCHSTONE_ROOT/bin/touchstone" review check \
  --codex-home "$REVIEW_HOME" >/dev/null 2>&1; then
  fail "automatic Keychain setup claimed support on a non-macOS platform"
fi
assert_contains "$TOUCHSTONE_ROOT/scripts/touchstone-steering-install.sh" \
  'Set up lower-cost normal reviews through OpenRouter now?'
assert_contains "$TOUCHSTONE_ROOT/bin/touchstone" \
  'touchstone review setup|check|run|rotate|uninstall'

echo "==> Touchstone keeps one complete-suite boundary"
assert_not_contains "$TOUCHSTONE_ROOT/.pre-commit-config.yaml" 'touchstone-validate'
assert_not_contains "$TOUCHSTONE_ROOT/.pre-commit-config.yaml" 'scripts/touchstone-run.sh validate'
assert_contains "$TOUCHSTONE_ROOT/AGENTS.md" 'Do not rerun'
assert_contains "$TOUCHSTONE_ROOT/AGENTS.md" 'protected hosted workflow'
assert_contains "$TOUCHSTONE_ROOT/AGENTS.md" 'If it is absent, run the complete suite locally'
assert_contains "$TOUCHSTONE_ROOT/CLAUDE.md" 'protected hosted workflow owns the complete suite'
# The Claude testing guidance is a path-scoped rule so docs-only sessions do
# not pay for it; it must still say what the hosted gate owns.
assert_contains "$TOUCHSTONE_ROOT/.claude/rules/testing.md" 'protected'
assert_contains "$TOUCHSTONE_ROOT/.claude/rules/testing.md" 'run the complete suite locally'
assert_contains "$TOUCHSTONE_ROOT/.claude/rules/testing.md" 'paths:'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'otherwise run the complete'
assert_contains "$TOUCHSTONE_ROOT/.touchstone.toml" 'for test in tests/test-*.sh'

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"
