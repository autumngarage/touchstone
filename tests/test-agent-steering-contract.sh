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
# inline its content via lib/touchstone-block.sh after `touchstone update`.
for file in \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md"; do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "PR-visible reviewer"
  assert_contains "$file" "Required Delivery Workflow"
  assert_contains "$file" "Before the first edit"
  assert_contains "$file" "principles/ai-delivery-architecture.md"
  assert_contains "$file" "watch the review loop"
  assert_contains "$file" "bash scripts/open-pr.sh --auto-merge"
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
  assert_contains "$file" "PR-visible reviewer"
  assert_contains "$file" "review runs asynchronously against the exact pushed head"
done

echo "==> canonical git workflow describes the PR-visible review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Agentic PR Review Loop"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "The driving CLI watches the PR"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "scripts/open-pr.sh --auto-merge"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Codex merge review"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "codex exec --full-auto"

echo "==> canonical AI delivery architecture describes the PR review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Agentic PR Review Loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "PR creation is not completion"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Merge is allowed only after PR-visible review and check approval"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Parallel file-writing agents use worktrees by default"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Touchstone does not invoke a local semantic reviewer or model router"

echo "==> pre-implementation guidance requires a bounded migration-state matrix"
PRE_IMPL="$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md"
assert_contains "$PRE_IMPL" "migration-state matrix"
assert_contains "$PRE_IMPL" "public or persisted boundary"
assert_contains "$PRE_IMPL" "persisted or managed state"
assert_contains "$PRE_IMPL" "pre-edit planning artifact"
assert_contains "$PRE_IMPL" "body must copy or link the matrix"
assert_contains "$PRE_IMPL" "Absent / fresh"
assert_contains "$PRE_IMPL" "Preserve intentional absence"
assert_contains "$PRE_IMPL" "Legacy only"
assert_contains "$PRE_IMPL" "every distinct legacy layout"
assert_contains "$PRE_IMPL" "Canonical only"
assert_contains "$PRE_IMPL" "non-default valid canonical state"
assert_contains "$PRE_IMPL" "Both / partially migrated"
assert_contains "$PRE_IMPL" "separate fixtures"
assert_contains "$PRE_IMPL" "partial canonical write"
assert_contains "$PRE_IMPL" "Invalid / dirty overlap"
assert_contains "$PRE_IMPL" "active compatibility"
assert_contains "$PRE_IMPL" "inert, time-bounded"
assert_contains "$PRE_IMPL" "Before the first PR review request"

PRE_IMPL_SKILL="$TOUCHSTONE_ROOT/skills/touchstone-pre-impl/SKILL.md"
assert_contains "$PRE_IMPL_SKILL" "canonical migration-state"
assert_contains "$PRE_IMPL_SKILL" "public or persisted boundary"
assert_contains "$PRE_IMPL_SKILL" "persisted or managed state"
assert_contains "$PRE_IMPL_SKILL" "pre-edit planning artifact"
assert_contains "$PRE_IMPL_SKILL" "every supported legacy layout"
assert_contains "$PRE_IMPL_SKILL" "absent"
assert_contains "$PRE_IMPL_SKILL" "canonical-only"
assert_contains "$PRE_IMPL_SKILL" "completed-both"
assert_contains "$PRE_IMPL_SKILL" "interrupted-partial"
assert_contains "$PRE_IMPL_SKILL" "invalid"
assert_contains "$PRE_IMPL_SKILL" "active compatibility"
assert_contains "$PRE_IMPL_SKILL" "inert, time-bounded"

echo "==> active product surfaces do not reintroduce the retired model router"
active_router_refs="$(grep -Rin "conductor" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/README.md" \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/bin" \
  "$TOUCHSTONE_ROOT/bootstrap" \
  "$TOUCHSTONE_ROOT/completions" \
  "$TOUCHSTONE_ROOT/hooks" \
  "$TOUCHSTONE_ROOT/lib" \
  "$TOUCHSTONE_ROOT/principles" \
  "$TOUCHSTONE_ROOT/scripts" \
  "$TOUCHSTONE_ROOT/skills" \
  "$TOUCHSTONE_ROOT/templates" 2>/dev/null \
  | grep -v 'bootstrap/update-project.sh:.*scripts/conductor-review.sh' \
  | grep -v 'lib/sync-discipline.sh:.*scripts/conductor-review.sh' \
  | grep -v 'lib/install-skills.sh:.*conductor-delegation' \
  | grep -v 'scripts/conductor-review.sh:' \
  || true)"
if [ -n "$active_router_refs" ]; then
  printf '%s\n' "$active_router_refs" >&2
  fail "retired model-router reference found on an active product surface"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"
