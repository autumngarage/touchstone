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
  assert_contains "$file" "A security-review quota notice is never a blocker"
  assert_contains "$file" "bounded stalled-request recovery"
  assert_contains "$file" "Keep review subordinate to scope"
  assert_contains "$file" "review cannot amend approved scope"
  assert_contains "$file" "Checkpoint scope expansion before editing"
  assert_contains "$file" "a follow-up approves doing the work, not bundling it"
  assert_contains "$file" "file count alone never decides"
  assert_contains "$file" "A review-fix defect stops patching"
  assert_contains "$file" "A second ends same-shape work"
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
  # driver rather than left only in the routed swarm guide.
  assert_contains "$file" "remove one only after final result delivery"
  assert_contains "$file" "or confirmed cancellation"
  assert_contains "$file" "this session created"
  assert_contains "$file" "leave sibling work untouched"
  assert_contains "$file" "its nonzero exit never authorizes deleting another session's work"
  assert_not_contains "$file" "Review is an enforced gate."
done

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

assert_contains "$TOUCHSTONE_ROOT/principles/agent-swarms.md" \
  "acknowledged its cancellation; an open"
assert_contains "$TOUCHSTONE_ROOT/principles/agent-swarms.md" \
  "merged PR and a clean worktree prove"
assert_contains "$TOUCHSTONE_ROOT/principles/agent-swarms.md" \
  "interrupt or cancel it, confirm that it is"
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
  "$TOUCHSTONE_ROOT/skills/touchstone-git-workflow/SKILL.md" \
  "$TOUCHSTONE_ROOT/.github/pull_request_template.md"; do
  assert_contains "$file" 'touchstone review check'
  assert_contains "$file" 'touchstone review run'
  assert_contains "$file" 'codex review --base <default>'
  assert_not_contains "$file" 'coderabbit review --agent --uncommitted'
done
for file in \
  "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "$TOUCHSTONE_ROOT/skills/touchstone-git-workflow/SKILL.md" \
  "$TOUCHSTONE_ROOT/.github/pull_request_template.md"; do
  assert_contains "$file" 'may waive only when Codex is unavailable'
done
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'touchstone review setup'
assert_not_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  '## The deep review pass'
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" 'OpenRouter'
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" 'one direct request'
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'No tools or agent loop'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"schema": "touchstone.review/v2"'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"backend": "openrouter-chat-completions"'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"model": "openrouter/auto"'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"costTier": "low"'
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"model": "openai/'
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"model": "anthropic/'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"maxPromptPricePerMillion": 0.5'
assert_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  '"maxCompletionPricePerMillion": 2'
assert_not_contains "$TOUCHSTONE_ROOT/config/review-normal.json" \
  'gpt-5.6-sol'
assert_not_contains "$TOUCHSTONE_ROOT/scripts/touchstone-review.sh" \
  'codex review'
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
assert_contains "$GIT_WORKFLOW_SKILL" "Inspect the repository's effective rules"
assert_contains "$GIT_WORKFLOW_SKILL" "Where installed and verified as required"
assert_contains "$GIT_WORKFLOW_SKILL" "missing enforcement as an adoption gap"
assert_not_contains "$GIT_WORKFLOW_SKILL" 'Review is enforced by `review-gate`.'

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
assert_contains "$GIT_WORKFLOW_SKILL" \
  "A live exact-head queue entry receives zero more merge mutations"
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
for file in "$GIT_WORKFLOW_GUIDE" "$GIT_WORKFLOW_SKILL"; do
  # Every agent-facing workflow needs the complete, copyable GitHub path. A
  # recovery rule is useless if the driver cannot reliably request, answer,
  # bind, and merge the ordinary review first.
  assert_contains "$file" "not by hand"
  assert_contains "$file" "headRefOid"
  assert_contains "$file" "resolveReviewThread"
  assert_contains "$file" "--match-head-commit"
  assert_contains "$file" "submitted, accepted, and completed states"
  assert_contains "$file" "PR conversation comments"
  assert_contains "$file" "accepted but stalled"
  assert_contains "$file" "Provisional quota signal"
  assert_contains "$file" "never a blocker or a terminal review result"
  assert_contains "$file" "at least 30 minutes after submission"
  assert_contains "$file" "earliest acceptance signal"
  assert_contains "$file" "immediately before posting"
  assert_contains "$file" 're-run the pinned `review-gate`'
  assert_contains "$file" "still reports no request"
  assert_not_contains "$file" "touchstone/review-request-v1"
  assert_contains "$file" "non-trigger audit note"
  assert_contains "$file" "fall back to the original marker"
  assert_contains "$file" "exactly one replacement trigger"
  assert_contains "$file" "exact head-and-base binding"
  assert_contains "$file" "Three cases permit another request while the head stays unchanged"
  assert_contains "$file" "base ref or base SHA"
  assert_contains "$file" "earlier request is completed or explicitly failed"
  assert_contains "$file" "integrate the current base into the branch"
  assert_contains "$file" "results identify the head"
  assert_contains "$file" "Never manufacture an empty"
  assert_contains "$file" "trusted exact-head review evidence"
  assert_contains "$file" "merge on acceptance alone"
  assert_contains "$file" "do not post a fourth request on the same"
  assert_contains "$file" "implementation shape"
  assert_contains "$file" "redesigned attempt"
  assert_contains "$file" "capability"
  assert_not_contains "$file" "retry until review"
done

assert_contains "$GIT_WORKFLOW_SKILL" "Review cannot amend the approved scope"
assert_contains "$GIT_WORKFLOW_SKILL" "answering is not implementing"
assert_contains "$GIT_WORKFLOW_SKILL" "Stop only widened work and requests on that shape"
assert_contains "$GIT_WORKFLOW_SKILL" "in-scope fixes continue to exact-head review"

echo "==> Claude entry files import the TOUCHSTONE.md steering router"
# CLAUDE.md uses @TOUCHSTONE.md (Claude Code resolves @-imports transitively),
# so the contract phrases are inlined into agent context via TOUCHSTONE.md
# rather than literally appearing in CLAUDE.md. Asserting the import is the
# verification contract.
assert_contains "$TOUCHSTONE_ROOT/CLAUDE.md" "@TOUCHSTONE.md"

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
assert_contains "$GIT_WORKFLOW_GUIDE" "do not post a fourth request on the same"
assert_contains "$GIT_WORKFLOW_GUIDE" "implementation shape"
assert_contains "$GIT_WORKFLOW_GUIDE" "split or close the"
assert_contains "$GIT_WORKFLOW_GUIDE" "capability"
assert_contains "$GIT_WORKFLOW_GUIDE" "per capability"
assert_contains "$GIT_WORKFLOW_GUIDE" "does not reset its count"
assert_contains "$GIT_WORKFLOW_GUIDE" "mechanical split is not budget laundering"
assert_contains "$GIT_WORKFLOW_GUIDE" "gets one validation round"
assert_contains "$GIT_WORKFLOW_GUIDE" "Exact-head review makes moving stacks multiply work"
assert_contains "$GIT_WORKFLOW_GUIDE" "Do not open dependent"
assert_contains "$GIT_WORKFLOW_GUIDE" "while a parent is still finding-bearing"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "- Review budget: v1 capability="
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "hosted rounds on"
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
assert_contains "$GIT_WORKFLOW_SKILL" "A review-fix regression is a stop signal"
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
    'or Codex-unavailable waiver; never record the base'
  assert_contains "$file" \
    'record `codex on <head-sha>: <n> findings, <disposition>`'
  assert_contains "$file" \
    "Hosted review owns exact heads"
  assert_contains "$file" "never rerun to confirm fixes"
done
for file in \
  "$GIT_WORKFLOW_GUIDE" \
  "$GIT_WORKFLOW_SKILL"; do
  assert_contains "$file" \
    "A tier-required local AI pass runs at most once per coherent review unit"
  assert_contains "$file" \
    "the hosted PR reviewer owns exact-head review for every pushed head"
done
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "runs at most once before its first push"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  "pass is neither required nor authorized"
assert_contains "$TOUCHSTONE_ROOT/principles/local-review.md" \
  'reviewed_head="$(git rev-parse HEAD)"'
assert_contains "$TOUCHSTONE_ROOT/.github/pull_request_template.md" \
  'begin serious with `codex on <captured-head-sha>: <n> findings, <disposition>`'

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
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Parallel file-writing agents use worktrees by default"
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
# The canonical checklist and its user-scoped skill must stay in sync on the
# subsystem-removal gate: states are derived from the subsystem's own
# persistence boundary (not a fixed global matrix), each supported state names
# its source of truth and fail-closed behavior, and shims are explicitly
# inert and time-bounded.
for file in \
  "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "$TOUCHSTONE_ROOT/skills/touchstone-pre-impl/SKILL.md"; do
  assert_contains "$file" "removing or replacing a subsystem"
  assert_contains "$file" "persistence boundary"
  assert_contains "$file" "source of truth"
  assert_contains "$file" "fail-closed"
  assert_contains "$file" "before the first review request"
  assert_contains "$file" "time-bounded migration shims"
  assert_contains "$file" "unmatched"
done
assert_contains "$TOUCHSTONE_ROOT/skills/touchstone-pre-impl/SKILL.md" \
  "The seven questions"
assert_not_contains "$TOUCHSTONE_ROOT/skills/touchstone-pre-impl/SKILL.md" \
  "The six questions"
for file in \
  "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "$TOUCHSTONE_ROOT/skills/touchstone-pre-impl/SKILL.md"; do
  assert_contains "$file" "reviewable unit with adversarial boundary coverage"
  assert_contains "$file" "serial test discovery"
  assert_contains "$file" "effective"
  assert_contains "$file" "where applicable"
  assert_contains "$file" "domain can express"
  assert_contains "$file" "non-filesystem"
  assert_contains "$file" "symlink"
  assert_contains "$file" "malformed"
done
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
  "resolution alone cannot satisfy"
assert_not_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "A small workflow calls"

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
$TOUCHSTONE_ROOT/skills/touchstone-git-workflow/SKILL.md
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
  .model == "openrouter/auto" and
  .plugins == [{id: "auto-router", cost_tier: "low"}] and
  .provider.require_parameters == true and
  .provider.max_price.prompt == 0.5 and
  .provider.max_price.completion == 2 and
  .max_completion_tokens == 4096 and
  .usage.include == true and
  .response_format.type == "json_schema" and
  (.tools == null)
' "$FAKE_CURL_CAPTURE" >/dev/null \
  || fail "OpenRouter request lost its router, price, output, or no-tools boundary"
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

awk 'BEGIN { for (i = 0; i < 105000; i++) printf "x"; printf "\n" }' \
  >"$REVIEW_REPOSITORY/staged.txt"
git -C "$REVIEW_REPOSITORY" add staged.txt
before_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
if (
  cd "$REVIEW_REPOSITORY"
  review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/large-input.out" 2>&1; then
  fail "normal review accepted a large request above the shipped limit"
elif ! grep -qF 'configured limit is 100000 bytes' "$TEST_DIR/large-input.out"; then
  fail "the shipped large-input limit was not enforced"
fi
after_calls="$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')"
[ "$before_calls" = "$after_calls" ] || fail "large review reached OpenRouter"

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
TRUNCATED_RESPONSE="$TEST_DIR/truncated-response.json"
jq '.choices[0].finish_reason = "length"' "$FAKE_RESPONSE" >"$TRUNCATED_RESPONSE"
if (
  cd "$REVIEW_WORKTREE"
  TOUCHSTONE_FAKE_REVIEW_RESPONSE="$TRUNCATED_RESPONSE" \
    review_command run --codex-home "$REVIEW_HOME"
) >"$TEST_DIR/truncated-response.out" 2>&1; then
  fail "truncated OpenRouter response was accepted"
elif ! grep -qF 'truncated the review' "$TEST_DIR/truncated-response.out"; then
  fail "truncated OpenRouter response lost its diagnostic"
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
jq '.schema = "touchstone.review/v3"' \
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
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'otherwise run the complete'
assert_contains "$TOUCHSTONE_ROOT/.touchstone.toml" 'for test in tests/test-*.sh'

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"
