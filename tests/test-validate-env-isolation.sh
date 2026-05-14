#!/usr/bin/env bash
#
# tests/test-validate-env-isolation.sh — pre-push Git env must not steer validate.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-validate-env.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to contain '$needle'" >&2
    echo "  ---- file content ----" >&2
    sed 's/^/    /' "$file" >&2 || true
    echo "  ----------------------" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_exists() {
  if [ -e "$1" ]; then
    echo "FAIL: expected '$1' to not exist" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

OUTER_REPO="$TEST_DIR/outer-repo"
VALIDATE_PROJECT="$TEST_DIR/validate-project"
mkdir -p "$OUTER_REPO" "$VALIDATE_PROJECT"
git -C "$OUTER_REPO" init -q
git -C "$VALIDATE_PROJECT" init -q
VALIDATE_PROJECT_PWD="$(cd "$VALIDATE_PROJECT" && pwd -P)"

cat >"$VALIDATE_PROJECT/.touchstone-config" <<EOF_CONFIG
validate_command=bash validate.sh
EOF_CONFIG

cat >"$VALIDATE_PROJECT/validate.sh" <<'EOF_VALIDATE'
set -e
printf 'validate-project-pwd=%s\n' "$PWD"
printf 'review-with=%s\n' "${TOUCHSTONE_CONDUCTOR_WITH:-}"
printf 'review-mode=%s\n' "${CODEX_REVIEW_MODE:-}"
printf 'review-timeout=%s\n' "${CODEX_REVIEW_TIMEOUT:-}"
printf 'review-diagnostics=%s\n' "${CODEX_REVIEW_DIAGNOSTICS_FILE:-}"
git init nested >/dev/null
test -d nested/.git
test "$(git -C nested rev-parse --is-bare-repository)" = "false"
test -z "${TOUCHSTONE_CONDUCTOR_WITH:-}"
test -z "${CODEX_REVIEW_MODE:-}"
test -z "${CODEX_REVIEW_TIMEOUT:-}"
test -z "${CODEX_REVIEW_DIAGNOSTICS_FILE:-}"
EOF_VALIDATE

echo "==> Test: validate ignores Git hook environment from another repo"

VALIDATE_OUT="$TEST_DIR/validate.out"
(
  cd "$VALIDATE_PROJECT"
  GIT_DIR="$OUTER_REPO/.git" \
    GIT_WORK_TREE="$OUTER_REPO" \
    GIT_INDEX_FILE="$OUTER_REPO/.git/index" \
    GIT_OBJECT_DIRECTORY="$OUTER_REPO/.git/objects" \
    GIT_COMMON_DIR="$OUTER_REPO/.git" \
    GIT_NAMESPACE=touchstone-test \
    GIT_PREFIX=from-hook/ \
    GIT_INTERNAL_GETTEXT_SH_SCHEME=fallthrough \
    TOUCHSTONE_CONDUCTOR_WITH=deepseek-reasoner \
    CODEX_REVIEW_MODE=diff-only \
    CODEX_REVIEW_TIMEOUT=7 \
    CODEX_REVIEW_DIAGNOSTICS_FILE="$TEST_DIR/outer-diagnostics.jsonl" \
    bash "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" validate
) >"$VALIDATE_OUT" 2>&1

assert_contains "$VALIDATE_OUT" 'validate.sh'
assert_contains "$VALIDATE_OUT" "validate-project-pwd=$VALIDATE_PROJECT_PWD"
assert_contains "$VALIDATE_OUT" 'review-with=$'
assert_contains "$VALIDATE_OUT" 'review-mode=$'
assert_contains "$VALIDATE_OUT" 'review-timeout=$'
assert_contains "$VALIDATE_OUT" 'review-diagnostics=$'
assert_not_exists "$OUTER_REPO/nested"

if [ "$ERRORS" -ne 0 ]; then
  exit 1
fi

echo "PASS: validate clears hook Git and review environment before dispatch"
