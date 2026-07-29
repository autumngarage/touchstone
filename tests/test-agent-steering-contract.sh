#!/usr/bin/env bash
#
# tests/test-agent-steering-contract.sh — guard the interpretability contract
# that lets Claude, Codex, and Gemini act as interchangeable driving CLIs while
# Conductor remains the worker/reviewer router.

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
# inline its content via lib/touchstone-block.sh after `touchstone update`.
for file in \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md"; do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "Conductor worker/reviewer"
  assert_contains "$file" "Required Delivery Workflow"
  assert_contains "$file" "Before the first edit"
  assert_contains "$file" "principles/ai-delivery-architecture.md"
  assert_contains "$file" "agentic review loop"
  assert_contains "$file" "bash scripts/open-pr.sh --auto-merge"
  assert_contains "$file" "Claim issues before implementation"
  assert_contains "$file" "bash scripts/claim-issue.sh <n>"
  assert_contains "$file" "Reconcile issues"
  assert_contains "$file" "Do not leave fixed issues open silently"
  assert_contains "$file" "Driving CLI circuit breaker"
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
# via lib/touchstone-block.sh, so the contract phrases must appear directly.
for file in \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "Conductor worker/reviewer router"
  assert_contains "$file" "branch → PR → agentic review loop → approved merge workflow"
done

echo "==> canonical git workflow describes the PR-visible review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Agentic PR Review Loop"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "The driving CLI watches the PR"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "scripts/open-pr.sh --auto-merge"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Driving CLI review-loop stop"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "only edits allowed"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" '"Ship it all" defines the queue'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "separate orchestration enforcement"
assert_contains "$TOUCHSTONE_ROOT/principles/engineering-principles.md" "## Bound driving-CLI review loops"
assert_contains "$TOUCHSTONE_ROOT/AGENTS.md" "If the driving CLI circuit breaker fires"
assert_contains "$TOUCHSTONE_ROOT/templates/AGENTS.md" "If the driving CLI circuit breaker fires"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Codex merge review"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "codex exec --full-auto"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" '"ship it all," default to one PR'

echo "==> canonical AI delivery architecture describes the PR review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Agentic PR Review Loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "PR creation is not completion"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Merge is allowed only after PR-visible review and check approval"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Parallel file-writing agents use worktrees by default"

echo "==> dogfood harness validates every machine-check field"
GOOD_RESPONSE="$TEST_DIR/good-response.txt"
cat >"$GOOD_RESPONSE" <<'EOF'
TOUCHSTONE_DOGFOOD_RESULT: PASS
BRANCH_BEFORE_EDIT: yes
FEATURE_BRANCH_COMMAND: git checkout -b fix/log-swallowed-exception
PR_CREATED: yes
PR_REVIEW_SURFACE_USED: yes
DRIVER_WATCHES_PR_COMMENTS: yes
MERGE_AFTER_APPROVAL: yes
AUTO_MERGE_COMMAND: bash scripts/open-pr.sh --auto-merge
PRINCIPLES_APPLIED: yes
NO_SILENT_FAILURES_TESTED: yes
DIRECT_MAIN_PUSH_ALLOWED: no
DRIVING_CLI_OWNS_REPO_WORKFLOW: yes
CONDUCTOR_IS_WORKER_OR_REVIEWER: yes
DRIVER_FALLBACK_SHARED_CONTRACT: yes
CONDUCTOR_PROVIDER_FALLBACK: yes
EOF
"$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" --validate-response "$GOOD_RESPONSE" >/dev/null

BAD_RESPONSE="$TEST_DIR/bad-response.txt"
cat >"$BAD_RESPONSE" <<'EOF'
TOUCHSTONE_DOGFOOD_RESULT: PASS
BRANCH_BEFORE_EDIT: yes
FEATURE_BRANCH_COMMAND: git checkout -b fix/log-swallowed-exception
PR_CREATED: yes
PR_REVIEW_SURFACE_USED: yes
DRIVER_WATCHES_PR_COMMENTS: yes
MERGE_AFTER_APPROVAL: yes
AUTO_MERGE_COMMAND: bash scripts/open-pr.sh --auto-merge
PRINCIPLES_APPLIED: yes
NO_SILENT_FAILURES_TESTED: yes
DIRECT_MAIN_PUSH_ALLOWED: no
DRIVING_CLI_OWNS_REPO_WORKFLOW: no
CONDUCTOR_IS_WORKER_OR_REVIEWER: yes
DRIVER_FALLBACK_SHARED_CONTRACT: yes
CONDUCTOR_PROVIDER_FALLBACK: yes
EOF
if "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" --validate-response "$BAD_RESPONSE" >/dev/null 2>&1; then
  fail "dogfood response validator accepted a response where the driving CLI does not own repo workflow"
fi

echo "==> dogfood harness documents its offline validator"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "--validate-response FILE"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "DRIVING_CLI_OWNS_REPO_WORKFLOW"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "DRIVER_WATCHES_PR_COMMENTS"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "MERGE_AFTER_APPROVAL"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "CONDUCTOR_PROVIDER_FALLBACK"

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"
