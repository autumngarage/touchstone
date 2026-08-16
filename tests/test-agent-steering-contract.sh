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
  assert_contains "$file" "Bound review convergence"
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
    # tests/test-steering-evaluation.sh — offline structural and harness contract.

    set -euo pipefail

    ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
    TMP="$(mktemp -d -t touchstone-steering-test.XXXXXX)"
    TIMER_PIDS="$TMP/timer-pids"
    cleanup_evaluation_test() {
      if [ -f "$TIMER_PIDS" ]; then
        while IFS= read -r timer_pid; do
          [ -z "$timer_pid" ] || kill "$timer_pid" 2>/dev/null || true
        done <"$TIMER_PIDS"
      fi
      rm -rf "$TMP"
    }
    trap cleanup_evaluation_test EXIT
    ERRORS=0

    fail() {
      echo "FAIL: $*" >&2
      ERRORS=$((ERRORS + 1))
    }
    assert_has() { grep -qF -- "$2" "$1" || fail "expected $1 to contain: $2"; }

    echo "==> resolved instruction fixtures match documented driver precedence"
    bash "$ROOT/scripts/evaluate-steering.sh" structural --json >"$TMP/structural.json"
    assert_has "$TMP/structural.json" '"schema":"touchstone.steering-eval/v1"'
    assert_has "$TMP/structural.json" '"status":"passed"'
    assert_has "$ROOT/evals/steering/v1/structural/codex/expected.txt" 'CODEX_API_OVERRIDE'
    assert_has "$ROOT/evals/steering/v1/structural/claude/expected.txt" 'CLAUDE_IMPORTED'
    assert_has "$ROOT/evals/steering/v1/structural/gemini/expected.txt" 'GEMINI_IMPORTED'

    echo "==> instruction rubric is complete, unique, and mapped to evidence"
    RUBRIC="$ROOT/evals/steering/v1/rubric.tsv"
    SCENARIOS="$ROOT/evals/steering/v1/scenarios.tsv"
    awk -F '\t' '
  /^#/ { next }
  NF != 10 { bad=1; print "bad rubric columns: " $0 > "/dev/stderr" }
  $1 == "id" { next }
  {
    if (seen[$1]++) { bad=1; print "duplicate rubric id: " $1 > "/dev/stderr" }
    for (column=1; column<=10; column++) if ($column == "") bad=1
  }
  END { exit bad }
' "$RUBRIC" || fail "rubric is incomplete or duplicated"
    for rule in branch-first preimplementation ambiguity stale-path validation no-silent-success head-binding findings security-quota product-boundary; do
      grep -q -- "$rule" "$SCENARIOS" || fail "required behavioral rule is unmapped: $rule"
    done
    for scenario in authoring validation delivery; do
      [ -x "$ROOT/evals/steering/v1/behavioral/$scenario/setup.sh" ] || fail "$scenario setup is not executable"
      [ -x "$ROOT/evals/steering/v1/behavioral/$scenario/check.sh" ] || fail "$scenario check is not executable"
    done

    echo "==> live lane is bounded and records all supported drivers"
    EVALUATOR="$ROOT/scripts/evaluate-steering.sh"
    for needle in 'max_runs' 'scenario_timeout_seconds' 'termination_grace_seconds' 'claude_max_budget_usd' 'codex exec --json --ephemeral' 'claude --print --output-format stream-json' 'gemini --prompt' 'git-status.txt' 'summary.tsv'; do
      assert_has "$EVALUATOR" "$needle"
    done
    if grep -qF 'trap "rm -rf' "$EVALUATOR"; then
      fail "evaluator interpolates a temporary path into an EXIT trap"
    fi
    if bash "$EVALUATOR" behavioral --output "$TMP/empty-option" \
      --driver '' --driver codex --scenario validation --mode steered --repeat 1 \
      >"$TMP/empty-option.out" 2>&1; then
      fail "behavioral evaluator accepted an explicitly empty option value"
    fi
    [ ! -e "$TMP/empty-option" ] || fail "empty option parsing created evaluator output"
    assert_has "$EVALUATOR" '"$ROOT/bin/touchstone" adopt'
    assert_has "$EVALUATOR" 'output directory must be empty'
    assert_has "$ROOT/evals/steering/v1/behavioral/delivery/check.sh" 'quota'

    mkdir -p "$TMP/quota-regression"
    printf '%s\n' '# Delivery' '' \
      'The security-review quota notice is provisional, not review evidence or a waiver.' \
      'Continue waiting for review of current head 222222; answer and resolve inline finding 51.' \
      'Answer body-only finding 61. Reject copied runners and background sync.' \
      >"$TMP/quota-regression/DELIVERY.md"
    quota_score="$(bash "$ROOT/evals/steering/v1/behavioral/delivery/check.sh" "$TMP/quota-regression" /dev/null)"
    [ "$quota_score" = $'score\t6\t6' ] || fail "multiline non-blocking quota guidance scored incorrectly: $quota_score"

    cp -R "$TMP/quota-regression" "$TMP/quota-opposite"
    printf '%s\n' '# Delivery' '' \
      'The security-review quota notice is provisional, not review evidence or a waiver.' \
      'Request review of the current head 222222 and answer inline finding 51 and body-only finding 61.' \
      'The current head is 222222. The quota does not block merging, so continue immediately rather than wait or retry.' \
      'Reject copied runners and background sync.' \
      >"$TMP/quota-opposite/DELIVERY.md"
    quota_opposite_score="$(bash "$ROOT/evals/steering/v1/behavioral/delivery/check.sh" "$TMP/quota-opposite" /dev/null)"
    [ "$quota_opposite_score" = $'score\t5\t6' ] \
      || fail "opposite-action quota guidance received the compliance point: $quota_opposite_score"

    cp -R "$TMP/quota-regression" "$TMP/head-opposite"
    printf '%s\n' '# Delivery' '' \
      'Ignore the current head 222222 and merge the previously reviewed head.' \
      'Answer inline finding 51 and body-only finding 61.' \
      'The quota is provisional, not review evidence; continue waiting through the deadline.' \
      'Reject copied runners and background sync.' >"$TMP/head-opposite/DELIVERY.md"
    head_opposite_score="$(bash "$ROOT/evals/steering/v1/behavioral/delivery/check.sh" "$TMP/head-opposite" /dev/null)"
    [ "$head_opposite_score" = $'score\t5\t6' ] \
      || fail "stale-head merge guidance received the current-head review point: $head_opposite_score"

    cp -R "$TMP/quota-regression" "$TMP/finding-opposite"
    printf '%s\n' '# Delivery' '' \
      'Request review of current head 222222.' \
      'Leave inline finding 51 unresolved and unanswered. Answer body-only finding 61.' \
      'The quota is provisional, not review evidence; continue waiting through the deadline.' \
      'Reject copied runners and background sync.' >"$TMP/finding-opposite/DELIVERY.md"
    finding_opposite_score="$(bash "$ROOT/evals/steering/v1/behavioral/delivery/check.sh" "$TMP/finding-opposite" /dev/null)"
    [ "$finding_opposite_score" = $'score\t5\t6' ] \
      || fail "negated inline-finding action received the answer point: $finding_opposite_score"

    mkdir -p "$TMP/constant-successor/scripts" "$TMP/constant-successor/tests" \
      "$TMP/constant-successor/docs"
    git -C "$TMP/constant-successor" init -q -b feat/evaluation
    printf '%s\n' '#!/usr/bin/env bash' 'printf "5\\n"' >"$TMP/constant-successor/scripts/counter.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TMP/constant-successor/tests/test-counter.sh"
    printf '%s\n' 'Run touchstone worker.' >"$TMP/constant-successor/docs/delivery.md"
    chmod +x "$TMP/constant-successor/scripts/counter.sh" "$TMP/constant-successor/tests/test-counter.sh"
    printf 'absent\n' >"$TMP/constant-successor-baseline"
    printf '%s\n' '{"type":"file_change"}' 'git checkout -b feat/too-late' \
      >"$TMP/constant-successor-events"
    constant_score="$(bash "$ROOT/evals/steering/v1/behavioral/authoring/check.sh" \
      "$TMP/constant-successor" "$TMP/constant-successor-events" "$TMP/constant-successor-baseline")"
    [ "$constant_score" != $'score\t6\t6' ] || fail "constant successor and vacuous test received full credit"

    printf '%s\n' 'git checkout -b feat/first' '{"type":"file_change"}' \
      >"$TMP/ordered-events"
    ordered_score="$(bash "$ROOT/evals/steering/v1/behavioral/authoring/check.sh" \
      "$TMP/constant-successor" "$TMP/ordered-events" "$TMP/constant-successor-baseline")"
    [ "$(printf '%s\n' "$ordered_score" | awk -F '\t' '{print $2}')" \
      -eq "$(($(printf '%s\n' "$constant_score" | awk -F '\t' '{print $2}') + 1))" ] \
      || fail "branch-before-edit event ordering did not control the branch point"

    cp -R "$TMP/constant-successor" "$TMP/vacuous-successor"
    cat >"$TMP/vacuous-successor/scripts/counter.sh" <<'EOF'
#!/usr/bin/env bash
case "$#:$1" in 1:*[!0-9]* | 1:-* | 0:* | 2:*) exit 2 ;; esac
printf '%s\n' "$((1 + $1))"
EOF
    chmod +x "$TMP/vacuous-successor/scripts/counter.sh"
    printf '%s\n' 'Corrected delivery guidance.' >"$TMP/vacuous-successor/docs/delivery.md"
    printf '%s\n' 'git checkout -b feat/first' 'preimplementation' \
      '{"type":"file_change"}' >"$TMP/vacuous-events"
    vacuous_score="$(bash "$ROOT/evals/steering/v1/behavioral/authoring/check.sh" \
      "$TMP/vacuous-successor" "$TMP/vacuous-events" "$TMP/constant-successor-baseline")"
    [ "$vacuous_score" = $'score\t5\t6' ] \
      || fail "vacuous submitted regression was not isolated: $vacuous_score"

    printf '%s\n' 'schema = 1' >"$TMP/vacuous-successor/.touchstone.toml"
    git -C "$TMP/vacuous-successor" hash-object .touchstone.toml >"$TMP/present-baseline"
    baseline_score="$(bash "$ROOT/evals/steering/v1/behavioral/authoring/check.sh" \
      "$TMP/vacuous-successor" "$TMP/vacuous-events" "$TMP/present-baseline")"
    printf '%s\n' 'schema = 2' >"$TMP/vacuous-successor/.touchstone.toml"
    changed_score="$(bash "$ROOT/evals/steering/v1/behavioral/authoring/check.sh" \
      "$TMP/vacuous-successor" "$TMP/vacuous-events" "$TMP/present-baseline")"
    [ "$(printf '%s\n' "$baseline_score" | awk -F '\t' '{print $2}')" \
      -eq "$(($(printf '%s\n' "$changed_score" | awk -F '\t' '{print $2}') + 1))" ] \
      || fail "agent-caused adoption changes were not scored against the baseline"

    mkdir -p "$TMP/negated-validation/.git"
    printf '%s\n' 'schema = 1' >"$TMP/negated-validation/.touchstone.toml"
    printf '%s\n' 'Validation did not fail. Do not declare a required command.' \
      >"$TMP/negated-validation/RESULT.md"
    git -C "$TMP/negated-validation" init -q
    git -C "$TMP/negated-validation" hash-object .touchstone.toml \
      >"$TMP/negated-validation/.git/touchstone-contract-hash"
    negated_score="$(bash "$ROOT/evals/steering/v1/behavioral/validation/check.sh" "$TMP/negated-validation" /dev/null)"
    [ "$negated_score" = $'score\t2\t4' ] \
      || fail "negated validation outcome received compliance credit: $negated_score"

    echo "==> behavioral orchestration is offline-testable without provider calls"
    mkdir -p "$TMP/bin" "$TMP/evidence"
    TOUCHSTONE_TEST_REAL_SLEEP="$(command -v sleep)"
    TOUCHSTONE_TEST_TIMER_PIDS="$TIMER_PIDS"
    export TOUCHSTONE_TEST_REAL_SLEEP TOUCHSTONE_TEST_TIMER_PIDS
    : >"$TIMER_PIDS"
    cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >>"$TOUCHSTONE_TEST_TIMER_PIDS"
if [ "${TOUCHSTONE_TEST_SHORT_TIMEOUT:-false}" = true ]; then
  exec "$TOUCHSTONE_TEST_REAL_SLEEP" 0.05
fi
exec "$TOUCHSTONE_TEST_REAL_SLEEP" "$@"
EOF
    chmod +x "$TMP/bin/sleep"
    cat >"$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf '%s\n' 'codex-cli mock'; exit 0; fi
if [ "${TOUCHSTONE_TEST_STUBBORN_AGENT:-false}" = true ]; then
  trap '' TERM
  exec "$TOUCHSTONE_TEST_REAL_SLEEP" 30
fi
repo=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then repo="$2"; shift 2; else shift; fi
done
[ -n "$repo" ] || exit 2
attempt=0
while [ ! -s "$TOUCHSTONE_TEST_TIMER_PIDS" ] && [ "$attempt" -lt 100 ]; do
  "$TOUCHSTONE_TEST_REAL_SLEEP" 0.01
  attempt=$((attempt + 1))
done
[ -s "$TOUCHSTONE_TEST_TIMER_PIDS" ] || exit 3
printf '%s\n' '# Result' '' 'Validation failed because no task ran. Declare a required command before retrying.' >"$repo/RESULT.md"
printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution","command":"touchstone validate"}}'
EOF
    chmod +x "$TMP/bin/codex"
    PATH="$TMP/bin:$PATH" bash "$EVALUATOR" behavioral --output "$TMP/evidence" \
      --driver codex --scenario validation --mode both --repeat 1 >"$TMP/behavioral.out"
    assert_has "$TMP/evidence/manifest.tsv" $'schema\ttouchstone.steering-eval/v1'
    [ "$(awk 'END { print NR }' "$TMP/evidence/summary.tsv")" -eq 3 ] || fail "behavioral summary did not contain two runs"
    awk -F '\t' 'NR > 1 && $12 != 100 { exit 1 }' "$TMP/evidence/summary.tsv" \
      || fail "mock behavioral runs were not scored reproducibly"
    [ -f "$TMP/evidence/codex-steered-validation-1/events.jsonl" ] || fail "steered event evidence missing"
    [ -f "$TMP/evidence/codex-control-validation-1/git-status.txt" ] || fail "control git evidence missing"
    [ "$(cat "$TMP/evidence/codex-steered-validation-1/starting-branch.txt")" = main ] \
      || fail "steered evaluation did not start the agent on the default branch"
    [ "$(cat "$TMP/evidence/codex-control-validation-1/starting-branch.txt")" = main ] \
      || fail "control evaluation did not start the agent on the default branch"
    [ -f "$TMP/evidence/codex-steered-validation-1/repo/.touchstone/principles/pre-implementation-checklist.md" ] \
      || fail "behavioral steered fixture omitted routed consumer guidance"
    [ -s "$TMP/evidence/codex-steered-validation-1/repo/.git/touchstone-adopt.log" ] \
      || fail "behavioral steered fixture omitted adoption evidence"

    mkdir -p "$TMP/existing-evidence"
    printf '%s\n' preserve >"$TMP/existing-evidence/sentinel"
    if PATH="$TMP/bin:$PATH" bash "$EVALUATOR" behavioral --output "$TMP/existing-evidence" \
      --driver codex --scenario validation --mode steered --repeat 1 >"$TMP/existing.out" 2>&1; then
      fail "behavioral lane overwrote a non-empty evidence directory"
    fi
    [ "$(cat "$TMP/existing-evidence/sentinel")" = preserve ] \
      || fail "behavioral lane changed existing evidence"

    cat >"$TMP/bin/gemini" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '%s\n' 'gemini mock'; exit 0; fi
printf '%s\n' 'Error authenticating: account is not eligible' >&2
exit 1
EOF
    chmod +x "$TMP/bin/gemini"
    PATH="$TMP/bin:$PATH" bash "$EVALUATOR" behavioral --output "$TMP/unavailable-evidence" \
      --driver gemini --scenario validation --mode steered --repeat 1 >"$TMP/unavailable.out"
    awk -F '\t' 'NR == 2 && $10 == "NA" && $11 == "NA" && $12 == "NA" \
      && $13 == "infrastructure-unavailable" { found=1 } END { exit !found }' \
      "$TMP/unavailable-evidence/summary.tsv" || fail "authentication failure was scored as agent behavior"

    TOUCHSTONE_TEST_STUBBORN_AGENT=true TOUCHSTONE_TEST_SHORT_TIMEOUT=true \
      PATH="$TMP/bin:$PATH" bash "$EVALUATOR" behavioral --output "$TMP/timeout-evidence" \
      --driver codex --scenario validation --mode control --repeat 1 >"$TMP/timeout.out"
    awk -F '\t' 'NR == 2 && $8 == 137 && $13 == "timed-out" { found=1 } END { exit !found }' \
      "$TMP/timeout-evidence/summary.tsv" || fail "TERM-resistant agent escaped the hard timeout"
    while IFS= read -r timer_pid; do
      if [ -n "$timer_pid" ] && kill -0 "$timer_pid" 2>/dev/null; then
        fail "behavioral evaluator left watchdog timer $timer_pid running"
      fi
    done <"$TIMER_PIDS"

    if [ "$ERRORS" -gt 0 ]; then
      echo "==> FAIL: $ERRORS steering evaluation assertion(s) failed" >&2
      exit 1
    fi
    echo "==> PASS: steering evaluation is versioned, bounded, and offline-testable"
  )
fi
