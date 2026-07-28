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
  assert_contains "$file" 'touchstone worker ship --worktree "$PWD" --detach --review-fix'
  assert_contains "$file" 'touchstone worker status --worktree "$PWD" --show-log'
  assert_contains "$file" 'touchstone worker takeover --worktree "$PWD"'
  assert_contains "$file" "bash scripts/open-pr.sh --auto-merge"
  assert_contains "$file" "only for foreground debugging"
  assert_contains "$file" "Claim issues before implementation"
  assert_contains "$file" "bash scripts/claim-issue.sh <n>"
  assert_contains "$file" "Reconcile issues"
  assert_contains "$file" "Do not leave fixed issues open silently"
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
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'touchstone worker ship --worktree "$PWD" --detach --review-fix'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "detached and foreground modes share the"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Codex merge review"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "codex exec --full-auto"

echo "==> canonical AI delivery architecture describes the PR review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Agentic PR Review Loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "PR creation is not completion"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Merge is allowed only after PR-visible review and check approval"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Parallel file-writing agents use worktrees by default"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" 'touchstone worker ship --detach --review-fix'
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "direct \`open-pr.sh\` remains the foreground diagnostic mode"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Durable status and takeover"

echo "==> dogfood harness validates every machine-check field"
GOOD_RESPONSE="$TEST_DIR/good-response.txt"
cat >"$GOOD_RESPONSE" <<'EOF'
TOUCHSTONE_DOGFOOD_RESULT: PASS
BRANCH_BEFORE_EDIT: yes
FEATURE_BRANCH_COMMAND: git checkout -b fix/log-swallowed-exception
PR_CREATED: yes
PR_REVIEW_SURFACE_USED: yes
DRIVER_CAN_START_DISJOINT_BATCH: yes
MERGE_AFTER_APPROVAL: yes
DETACHED_SHIP_COMMAND: touchstone worker ship --worktree "$PWD" --detach --review-fix
STATUS_COMMAND: touchstone worker status --worktree "$PWD" --show-log
TAKEOVER_COMMAND: touchstone worker takeover --worktree "$PWD"
FOREGROUND_MODE_SUPPORTED: yes
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
DRIVER_CAN_START_DISJOINT_BATCH: yes
MERGE_AFTER_APPROVAL: yes
DETACHED_SHIP_COMMAND: touchstone worker ship --worktree "$PWD" --detach --review-fix
STATUS_COMMAND: touchstone worker status --worktree "$PWD" --show-log
TAKEOVER_COMMAND: touchstone worker takeover --worktree "$PWD"
FOREGROUND_MODE_SUPPORTED: yes
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
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "DRIVER_CAN_START_DISJOINT_BATCH"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "MERGE_AFTER_APPROVAL"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "DETACHED_SHIP_COMMAND"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "STATUS_COMMAND"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "TAKEOVER_COMMAND"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "FOREGROUND_MODE_SUPPORTED"
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "CONDUCTOR_PROVIDER_FALLBACK"

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"
