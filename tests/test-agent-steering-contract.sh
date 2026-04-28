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

echo "==> managed AGENTS block exposes the driver/reviewer contract"
for file in \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  "$TOUCHSTONE_ROOT/lib/agents-principles-block.sh"
do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "Conductor worker/reviewer"
  assert_contains "$file" "Required Delivery Workflow"
  assert_contains "$file" "Before the first edit"
  assert_contains "$file" "CODEX_REVIEW_FORCE=1 bash scripts/codex-review.sh"
  assert_contains "$file" "bash scripts/open-pr.sh --auto-merge"
done

echo "==> Claude and Gemini entry files name the driving CLI role"
for file in \
  "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/templates/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"
do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "driving CLI"
  assert_contains "$file" "worker/reviewer router"
  assert_contains "$file" "branch → PR → review → automerge workflow"
done

echo "==> canonical git workflow describes Conductor as the merge gate"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Conductor merge review"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "conductor exec"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "scripts/open-pr.sh --auto-merge"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Codex merge review"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "codex exec --full-auto"

echo "==> dogfood harness validates every machine-check field"
GOOD_RESPONSE="$TEST_DIR/good-response.txt"
cat > "$GOOD_RESPONSE" <<'EOF'
TOUCHSTONE_DOGFOOD_RESULT: PASS
BRANCH_BEFORE_EDIT: yes
FEATURE_BRANCH_COMMAND: git checkout -b fix/log-swallowed-exception
PR_CREATED: yes
CONDUCTOR_REVIEW_BEFORE_MERGE: yes
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
cat > "$BAD_RESPONSE" <<'EOF'
TOUCHSTONE_DOGFOOD_RESULT: PASS
BRANCH_BEFORE_EDIT: yes
FEATURE_BRANCH_COMMAND: git checkout -b fix/log-swallowed-exception
PR_CREATED: yes
CONDUCTOR_REVIEW_BEFORE_MERGE: yes
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
assert_contains "$TOUCHSTONE_ROOT/scripts/dogfood-agent-steering.sh" "CONDUCTOR_PROVIDER_FALLBACK"

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"
