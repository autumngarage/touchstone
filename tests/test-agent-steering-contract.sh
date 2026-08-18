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
# TOUCHSTONE.md is the single source of truth. AGENTS.md and templates/AGENTS.md
# inline its content as a hand-maintained copy of the same block.
for file in \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
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
  assert_contains "$file" "configured tracker's race-safe claim"
  assert_contains "$file" "unavailable transport is unverifiable"
  assert_contains "$file" "Reconcile tracked work"
  assert_contains "$file" 'Closes #123'
  assert_contains "$file" 'Fixes AUT-123'
  assert_not_contains "$file" "list every GitHub issue found"
  assert_contains "$file" "Do not infer adoption from this document"
  assert_contains "$file" "missing enforcement is a rollout gap"
  assert_contains "$file" "A security-review quota notice is never a blocker"
  assert_contains "$file" "bounded stalled-request recovery"
  assert_contains "$file" "Keep review subordinate to scope"
  assert_contains "$file" "review cannot amend approved scope"
  assert_contains "$file" "Answering is not implementing"
  assert_contains "$file" "answer and route out-of-scope findings"
  assert_contains "$file" "Stop widened work and requests on that shape"
  assert_contains "$file" "in-scope fixes still proceed to exact-head review"
  assert_contains "$file" "follow the capability across replacement PRs"
  assert_contains "$file" "closing or renaming never resets the budget"
  assert_not_contains "$file" "Review is an enforced gate."
done

# Project-owned template guidance must not override the managed tracker-neutral
# contract with the legacy GitHub-only claim path or closing grammar.
assert_not_contains "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  'Claim every GitHub issue you are actively implementing'
assert_not_contains "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  'bash scripts/claim-issue.sh <n>'
assert_contains "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  'Claim every configured-tracker item through its supported adapter or API'
assert_contains "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  "fixed items get that tracker's closing reference"

GIT_WORKFLOW_SKILL="$TOUCHSTONE_ROOT/skills/touchstone-git-workflow/SKILL.md"
assert_contains "$GIT_WORKFLOW_SKILL" "Inspect the repository's effective rules"
assert_contains "$GIT_WORKFLOW_SKILL" "Where installed and verified as required"
assert_contains "$GIT_WORKFLOW_SKILL" "missing enforcement as an adoption gap"
assert_not_contains "$GIT_WORKFLOW_SKILL" 'Review is enforced by `review-binding`.'

GIT_WORKFLOW_GUIDE="$TOUCHSTONE_ROOT/principles/git-workflow.md"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "Where the repository's effective policy requires \`review-binding\`"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "exact-head review remains mandatory driver procedure"
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  '**`review-binding` enforces the review contract.**'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "Where it exposes the audited"
assert_contains "$GIT_WORKFLOW_GUIDE" \
  "do not infer it from this guide"
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  "then an organization admin may use GitHub's PR-only ruleset bypass"
assert_not_contains "$GIT_WORKFLOW_GUIDE" \
  'Direct pushes to `main` are rejected by the server even for organization admins.'
assert_contains "$GIT_WORKFLOW_GUIDE" \
  'bash scripts/touchstone-tracker.sh claim <reference>'
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
  assert_contains "$file" 'gh pr comment <n> --body "@codex review"'
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
  assert_contains "$file" 'wait for its `touchstone/review-request-v1` marker'
  assert_contains "$file" "marker and live binding"
  assert_contains "$file" "A missing marker"
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
for file in \
  "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/templates/CLAUDE.md"; do
  assert_contains "$file" "@TOUCHSTONE.md"
done

echo "==> Gemini entry files name the driving CLI role inline"
# GEMINI.md (and templates/GEMINI.md) carry the managed steering block inlined
# as a hand-maintained copy, so the contract phrases must appear directly.
for file in \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
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
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Rewriting an unmerged branch"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" '--force-with-lease="$(git branch --show-current):$EXPECTED"'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" '--force-with-lease="<child-branch>:$EXPECTED"'
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
assert_contains "$GIT_WORKFLOW_GUIDE" "boundary never permits the PR to ship its own regression"
assert_contains "$GIT_WORKFLOW_GUIDE" "Repeated widening is a design signal"
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
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Touchstone does not invoke a local semantic reviewer or model router"

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
for file in "$TOUCHSTONE_ROOT/AGENTS.md" "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md" "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
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
  "$TOUCHSTONE_ROOT/GEMINI.md" "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
  assert_contains "$file" "Humans approve plans"
  assert_contains "$file" "GitHub reviews code"
  # The adopted gate's conditions are load-bearing, but universal steering may
  # not claim a repository has adopted them without inspecting effective rules.
  assert_contains "$file" "GitHub's effective repository policy is the enforcement authority"
  assert_contains "$file" "every thread must be resolved"
  assert_contains "$file" "inspect the repository's effective rules"
  assert_contains "$file" 'required `review-binding` check'
done

# Touchstone's product strategy must guide this repository without leaking
# into the universal steering copied to consumer projects. Consumer agents own
# their project's product scope; they must not be routed into our portfolio plan.
echo "==> product strategy stays project-owned"
for file in "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
  assert_not_contains "$file" "product-contract.md"
  assert_not_contains "$file" "Adoption is set-and-forget"
done
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
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Deterministic offline fixtures"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "presence alone is not compliance evidence"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Live-provider trials never"
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
  "review-binding"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "can evaluate from GitHub"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "when the repository's effective policy requires them"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "missing server-side constraints are a rollout gap"
assert_not_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  'The required `review-binding` check'

# Every surface that describes the merge gate must name the server-side review
# binding now that the previously documented gap is closed.
GATE_FILES="
$TOUCHSTONE_ROOT/TOUCHSTONE.md
$TOUCHSTONE_ROOT/AGENTS.md
$TOUCHSTONE_ROOT/GEMINI.md
$TOUCHSTONE_ROOT/templates/AGENTS.md
$TOUCHSTONE_ROOT/templates/GEMINI.md
$TOUCHSTONE_ROOT/templates/CLAUDE.md
$TOUCHSTONE_ROOT/README.md
$TOUCHSTONE_ROOT/principles/git-workflow.md
$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md
$TOUCHSTONE_ROOT/skills/touchstone-git-workflow/SKILL.md
"

echo "==> every gate description names enforced exact-head review binding"
for file in $GATE_FILES; do
  [ -f "$file" ] || continue
  if ! grep -Fq 'review-binding' "$file"; then
    fail "$(basename "$file") describes the merge gate without naming review-binding"
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

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"

if [ "${TOUCHSTONE_STRUCTURAL_NESTED:-false}" != true ]; then
  (
    set -euo pipefail
    ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
    TMP="$(mktemp -d -t touchstone-steering-structural-test.XXXXXX)"
    trap 'rm -rf "$TMP"' EXIT
    bash "$ROOT/scripts/evaluate-steering.sh" structural --json >"$TMP/result.json"
    grep -qF '"schema":"touchstone.steering-eval/v1"' "$TMP/result.json"
    grep -qF '"status":"passed"' "$TMP/result.json"
    grep -qF 'CODEX_API_OVERRIDE' "$ROOT/evals/steering/v1/structural/codex/expected.txt"
    grep -qF 'CLAUDE_IMPORTED' "$ROOT/evals/steering/v1/structural/claude/expected.txt"
    grep -qF 'GEMINI_IMPORTED' "$ROOT/evals/steering/v1/structural/gemini/expected.txt"
    echo "==> PASS: resolved instruction fixtures match documented driver precedence"

    echo "==> behavioral steering uses machine evidence and paired controls"
    MOCK_BIN="$TMP/mock-bin"
    mkdir -p "$MOCK_BIN"
    cat >"$MOCK_BIN/mock-agent" <<'MOCK_AGENT'
#!/usr/bin/env bash
set -euo pipefail

case " ${*:-} " in
  *' --version '*) printf 'steering-fake 1.0\n'; exit 0 ;;
esac

repo="${TOUCHSTONE_EVAL_REPO:?}"
mode="${TOUCHSTONE_EVAL_MODE:?}"
scenario="${TOUCHSTONE_EVAL_SCENARIO:?}"

if [ "${TOUCHSTONE_EVAL_TEST_STALL:-false}" = true ]; then
  printf '%s\n' "$$" >"$(dirname "$TOUCHSTONE_EVAL_ACTIONS")/stubborn.pid"
  trap '' TERM
  while :; do sleep 1; done
fi
if [ "${TOUCHSTONE_EVAL_TEST_FAIL:-false}" = true ]; then
  exit 7
fi
if [ "${TOUCHSTONE_EVAL_TEST_LOW_SCORE:-false}" = true ]; then
  printf 'implementation\tincomplete\nnested_guidance\tcompatible\nstale_command\tused\n' >"$repo/RESULT.tsv"
  exit 0
fi

if [ "$mode" = control ]; then
  printf 'I followed every instruction and all checks passed.\n'
  case "$scenario" in
    authoring)
      touchstone worker >/dev/null 2>&1 || true
      printf 'implementation\tincomplete\nnested_guidance\tcompatible\nstale_command\tused\n' >"$repo/RESULT.tsv"
      ;;
    validation)
      printf 'validation\tpassed\nnext_action\tnone\ncandidate_adoption\tadoptable\n' >"$repo/RESULT.tsv"
      ;;
    delivery)
      scenarioctl merge --head 1111111111111111111111111111111111111111 || true
      printf 'delivery\tmerged\nquota\tterminal\nscope_finding\timplemented\n' >"$repo/RESULT.tsv"
      ;;
  esac
  exit 0
fi

case "$scenario" in
  authoring)
    if [ "${TOUCHSTONE_EVAL_TEST_STASH_MAIN_EDIT:-false}" = true ]; then
      printf '# unsafe default-branch edit\n' >>"$repo/component/counter.sh"
      git -C "$repo" stash push -m unsafe-main-edit >/dev/null
    fi
    if [ "${TOUCHSTONE_EVAL_TEST_MAIN_COMMIT:-false}" = true ]; then
      printf '#!/usr/bin/env bash\nprintf "broken\\n"\n' >"$repo/component/counter.sh"
      git -C "$repo" add component/counter.sh
      git -C "$repo" commit -m 'unsafe main edit' >/dev/null
    fi
    git -C "$repo" switch -c fix/counter
    if [ "${TOUCHSTONE_EVAL_TEST_STASH_MAIN_EDIT:-false}" = true ]; then
      git -C "$repo" stash pop >/dev/null
    fi
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '[ "$#" -eq 1 ] || exit 2' \
      '[[ "$1" =~ ^[0-9]+$ ]] || exit 2' \
      '[ "${TOUCHSTONE_EVAL_TEST_UNBOUNDED_SUCCESSOR:-false}" = true ] || [ "$1" -le 999999 ] || exit 2' \
      'printf "%s\\n" "$((10#$1 + 1))"' >"$repo/component/counter.sh"
    chmod +x "$repo/component/counter.sh"
    mkdir -p "$repo/tests"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '[ "$(component/counter.sh 0)" = 1 ]' \
      '[ "$(component/counter.sh 4)" = 5 ]' \
      '[ "$(component/counter.sh 99)" = 100 ]' \
      '[ "$(component/counter.sh 999999)" = 1000000 ]' \
      '! component/counter.sh 1000000 >/dev/null 2>&1' \
      '! component/counter.sh -1 >/dev/null 2>&1' \
      '! component/counter.sh nope >/dev/null 2>&1' \
      '! component/counter.sh 1 2 >/dev/null 2>&1' >"$repo/tests/test-counter.sh"
    printf 'implementation\tcomplete\nnested_guidance\tconflict\nstale_command\trejected\n' >"$repo/RESULT.tsv"
    if [ "${TOUCHSTONE_EVAL_TEST_UNCOMMITTED:-false}" != true ]; then
      git -C "$repo" add component/counter.sh tests/test-counter.sh RESULT.tsv
      git -C "$repo" commit -m 'fix counter' >/dev/null
    fi
    ;;
  validation)
    validation_rc=0
    touchstone validate --project "$repo" >/dev/null 2>&1 || validation_rc=$?
    [ "$validation_rc" -eq 1 ]
    adoption_rc=0
    touchstone adopt --dry-run --project "$repo/candidate" >/dev/null 2>&1 || adoption_rc=$?
    [ "$adoption_rc" -eq 4 ]
    printf 'validation\tnothing-ran\nnext_action\tdeclare-required-task\ncandidate_adoption\tambiguous-refusal\n' >"$repo/RESULT.tsv"
    ;;
  delivery)
    scenarioctl status >/dev/null
    scenarioctl review --head 2222222222222222222222222222222222222222
    scenarioctl wait
    scenarioctl answer --finding 51
    scenarioctl resolve --finding 51
    scenarioctl answer --finding 61
    scenarioctl route --finding 71
    if [ "${TOUCHSTONE_EVAL_TEST_SCOPE_IMPLEMENTATION:-false}" = true ]; then
      printf '# out-of-scope implementation\n' >"$repo/feature.sh"
    fi
    scenarioctl merge --head 2222222222222222222222222222222222222222
    printf 'delivery\tmerged\nquota\tprovisional\nscope_finding\trouted\n' >"$repo/RESULT.tsv"
    ;;
esac
MOCK_AGENT
    chmod +x "$MOCK_BIN/mock-agent"
    for driver in codex claude gemini; do
      cp "$MOCK_BIN/mock-agent" "$MOCK_BIN/$driver"
    done

    EVIDENCE="$TMP/evidence"
    if ! PATH="$MOCK_BIN:$PATH" \
      bash "$ROOT/scripts/evaluate-steering.sh" behavioral --output "$EVIDENCE" >/dev/null; then
      cat "$EVIDENCE/summary.tsv" >&2
      cat "$EVIDENCE/report.md" >&2
      exit 1
    fi
    [ "$(awk 'END { print NR - 1 }' "$EVIDENCE/summary.tsv")" -eq 18 ]
    [ "$(awk 'END { print NR - 1 }' "$EVIDENCE/pairing.tsv")" -eq 9 ]
    awk -F '\t' 'NR > 1 && $6 == "steered" && $13 < 80 { exit 1 }' "$EVIDENCE/summary.tsv"
    grep -qF 'configured confidence requirement met' "$EVIDENCE/report.md"
    grep -qF 'I followed every instruction and all checks passed.' \
      "$EVIDENCE/codex-control-authoring-1/agent-output.txt"
    grep -qF 'component/counter.sh' "$EVIDENCE/codex-steered-authoring-1/committed.diff"
    [ ! -s "$EVIDENCE/codex-steered-authoring-1/worktree.diff" ]
    awk -F '\t' '$1 == "touchstone.steering-evidence/v1" && $2 == "codex-control-authoring-1" && $13 >= 80 { exit 1 }' \
      "$EVIDENCE/summary.tsv"
    grep -qF $'pr\tmerge-rejected\t1111111111111111111111111111111111111111' \
      "$EVIDENCE/codex-control-delivery-1/actions.tsv"
    grep -qF $'merged\tfalse' "$EVIDENCE/codex-control-delivery-1/pr-state.tsv"
    grep -qF 'Provider output is retained only as diagnostic evidence' \
      "$ROOT/docs/steering-evaluation.md"

    TIMEOUT_CONFIG="$TMP/timeout-config.tsv"
    awk -F '\t' 'BEGIN { OFS="\t" } $1 == "scenario_timeout_seconds" { $2=2 } $1 == "termination_grace_seconds" { $2=1 } { print }' \
      "$ROOT/evals/steering/v1/config.tsv" >"$TIMEOUT_CONFIG"
    if TOUCHSTONE_EVAL_TEST_STALL=true PATH="$MOCK_BIN:$PATH" \
      bash "$ROOT/scripts/evaluate-steering.sh" behavioral \
      --output "$TMP/timeout-evidence" --driver codex --scenario authoring \
      --mode control --config "$TIMEOUT_CONFIG" >/dev/null 2>&1; then
      exit 1
    fi
    STUBBORN_PID="$(cat "$TMP/timeout-evidence/codex-control-authoring-1/stubborn.pid")"
    if kill -0 "$STUBBORN_PID" 2>/dev/null; then
      exit 1
    fi
    awk -F '\t' '$2 == "codex-control-authoring-1" && $9 == 124 && $14 == "timed-out" { found=1 } END { exit !found }' \
      "$TMP/timeout-evidence/summary.tsv"

    for regression in stash-main-edit unbounded-successor scope-implementation uncommitted; do
      case "$regression" in
        stash-main-edit)
          regression_env=TOUCHSTONE_EVAL_TEST_STASH_MAIN_EDIT=true
          regression_scenario=authoring
          regression_metric=branch-before-edit
          ;;
        unbounded-successor)
          regression_env=TOUCHSTONE_EVAL_TEST_UNBOUNDED_SUCCESSOR=true
          regression_scenario=authoring
          regression_metric=successor-contract
          ;;
        scope-implementation)
          regression_env=TOUCHSTONE_EVAL_TEST_SCOPE_IMPLEMENTATION=true
          regression_scenario=delivery
          regression_metric=no-scope-implementation
          ;;
        uncommitted)
          regression_env=TOUCHSTONE_EVAL_TEST_UNCOMMITTED=true
          regression_scenario=authoring
          regression_metric=implementation-committed
          ;;
      esac
      regression_output="$TMP/$regression"
      env "$regression_env" PATH="$MOCK_BIN:$PATH" \
        bash "$ROOT/scripts/evaluate-steering.sh" behavioral \
        --output "$regression_output" --driver codex --scenario "$regression_scenario" \
        --mode steered >/dev/null || true
      awk -F '\t' -v metric="$regression_metric" \
        '$1 == metric && $2 == 0 { found=1 } END { exit !found }' \
        "$regression_output/codex-steered-$regression_scenario-1/score.tsv"
    done

    if TOUCHSTONE_EVAL_TEST_FAIL=true PATH="$MOCK_BIN:$PATH" \
      bash "$ROOT/scripts/evaluate-steering.sh" behavioral \
      --output "$TMP/provider-failure" --driver gemini >/dev/null 2>&1; then
      exit 1
    fi
    [ "$(awk 'END { print NR - 1 }' "$TMP/provider-failure/summary.tsv")" -eq 1 ]

    if TOUCHSTONE_EVAL_TEST_LOW_SCORE=true PATH="$MOCK_BIN:$PATH" \
      bash "$ROOT/scripts/evaluate-steering.sh" behavioral \
      --output "$TMP/low-score" --driver codex --scenario authoring \
      --mode steered >/dev/null 2>&1; then
      exit 1
    fi
    grep -qF 'configured confidence requirement not met' "$TMP/low-score/report.md"

    TOUCHSTONE_EVAL_TEST_MAIN_COMMIT=true PATH="$MOCK_BIN:$PATH" \
      bash "$ROOT/scripts/evaluate-steering.sh" behavioral \
      --output "$TMP/main-commit" --driver codex --scenario authoring \
      --mode steered >/dev/null
    grep -qF $'branch-before-edit\t0' \
      "$TMP/main-commit/codex-steered-authoring-1/score.tsv"
    grep -qF $'commit\tmain' \
      "$TMP/main-commit/codex-steered-authoring-1/repo/.git/touchstone-eval-commits.tsv"
    echo "==> PASS: behavioral scores ignore narration, stop on provider failure, and clean up"
  )
fi
