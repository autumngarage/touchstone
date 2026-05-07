#!/usr/bin/env bash
#
# tests/test-doctor.sh — fixture tests for conductor-review fail-open trends.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone"
TEST_DIR="$(mktemp -d -t touchstone-test-doctor.XXXXXX)"
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

assert_exit() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" -ne "$expected" ]; then
    echo "FAIL: $label exit code: expected $expected, got $actual" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

run_doctor() {
  local fake_home="$1"
  shift
  HOME="$fake_home" \
    NO_COLOR=1 \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" doctor "$@"
}

timestamp_now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

write_row() {
  local file="$1" timestamp="$2" repo="$3" branch="$4" sha="$5" reason="$6" detail="$7"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$repo" "$branch" "$sha" "$reason" "$detail" >> "$file"
}

echo "==> Test: touchstone doctor review-log aggregation"
echo "    Test dir: $TEST_DIR"

FAKE_HOME="$TEST_DIR/home"
mkdir -p "$FAKE_HOME"

# --------------------------------------------------------------------------
# Test 1: help preserves project capability option
# --------------------------------------------------------------------------
echo ""
echo "--- Test 1: help documents project capability option ---"

HELP_OUT="$TEST_DIR/help.out"
set +e
run_doctor "$FAKE_HOME" --help >"$HELP_OUT" 2>&1
HELP_EXIT=$?
set -e

assert_exit "$HELP_EXIT" 0 "help"
assert_contains "$HELP_OUT" "touchstone doctor --require-capability <name>"
assert_contains "$HELP_OUT" "Require a project-local Touchstone workflow capability"

# --------------------------------------------------------------------------
# Test 2: missing log exits 0 with friendly message
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2: missing log ---"

MISSING_OUT="$TEST_DIR/missing.out"
set +e
run_doctor "$FAKE_HOME" --log-path "$TEST_DIR/no-such-log" >"$MISSING_OUT" 2>&1
MISSING_EXIT=$?
set -e

assert_exit "$MISSING_EXIT" 0 "missing log"
assert_contains "$MISSING_OUT" "no review log found; conductor review hasn't run on this machine yet"

# --------------------------------------------------------------------------
# Test 3: empty log exits 0 with the same friendly message
# --------------------------------------------------------------------------
echo ""
echo "--- Test 3: empty log ---"

EMPTY_LOG="$TEST_DIR/empty.log"
: > "$EMPTY_LOG"
EMPTY_OUT="$TEST_DIR/empty.out"
set +e
run_doctor "$FAKE_HOME" --log-path "$EMPTY_LOG" >"$EMPTY_OUT" 2>&1
EMPTY_EXIT=$?
set -e

assert_exit "$EMPTY_EXIT" 0 "empty log"
assert_contains "$EMPTY_OUT" "no review log found; conductor review hasn't run on this machine yet"

# --------------------------------------------------------------------------
# Test 4: no fail-opens reports zero rate and exits 0
# --------------------------------------------------------------------------
echo ""
echo "--- Test 4: no fail-opens ---"

NOW="$(timestamp_now)"
NO_FAIL_LOG="$TEST_DIR/no-fail.log"
write_row "$NO_FAIL_LOG" "$NOW" "/tmp/repo-a" "main" "abc1234" "ran" "clean"
write_row "$NO_FAIL_LOG" "$NOW" "/tmp/repo-b" "feat/x" "def5678" "ran" "clean"

NO_FAIL_OUT="$TEST_DIR/no-fail.out"
set +e
run_doctor "$FAKE_HOME" --log-path "$NO_FAIL_LOG" >"$NO_FAIL_OUT" 2>&1
NO_FAIL_EXIT=$?
set -e

assert_exit "$NO_FAIL_EXIT" 0 "no fail-opens"
assert_contains "$NO_FAIL_OUT" "Last 7 days"
assert_contains "$NO_FAIL_OUT" "total reviews: 2"
assert_contains "$NO_FAIL_OUT" "fail-open: 0 (0.0%)"
assert_contains "$NO_FAIL_OUT" "FAIL_OPEN_TIMEOUT: 0"
assert_contains "$NO_FAIL_OUT" "none recorded"

# --------------------------------------------------------------------------
# Test 5: mixed rows count fail-open codes and ignore disabled/skipped rows
# --------------------------------------------------------------------------
echo ""
echo "--- Test 5: mixed events ---"

MIXED_LOG="$TEST_DIR/mixed.log"
write_row "$MIXED_LOG" "2000-01-01T00:00:00+0000" "/tmp/old" "main" "0000000" "FAIL_OPEN_TIMEOUT" "too-old"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-a" "main" "1111111" "ran" "clean"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-b" "feat/a" "2222222" "FAIL_OPEN_TIMEOUT" "fail-open:timeout"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-c" "feat/b" "3333333" "FAIL_OPEN_PARSE_ERROR" "fail-open:malformed sentinel"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-d" "feat/c" "4444444" "config-disabled" "disabled"

MIXED_OUT="$TEST_DIR/mixed.out"
set +e
run_doctor "$FAKE_HOME" --log-path "$MIXED_LOG" --threshold 80 >"$MIXED_OUT" 2>&1
MIXED_EXIT=$?
set -e

assert_exit "$MIXED_EXIT" 0 "mixed events under threshold"
assert_contains "$MIXED_OUT" "total reviews: 3"
assert_contains "$MIXED_OUT" "fail-open: 2 (66.7%)"
assert_contains "$MIXED_OUT" "FAIL_OPEN_TIMEOUT: 1"
assert_contains "$MIXED_OUT" "FAIL_OPEN_PARSE_ERROR: 1"
assert_contains "$MIXED_OUT" "repo: /tmp/repo-c"
assert_contains "$MIXED_OUT" "detail: fail-open:malformed sentinel"

# --------------------------------------------------------------------------
# Test 6: threshold warning exits 2
# --------------------------------------------------------------------------
echo ""
echo "--- Test 6: threshold warning ---"

THRESHOLD_LOG="$TEST_DIR/threshold.log"
write_row "$THRESHOLD_LOG" "$NOW" "/tmp/repo-a" "main" "aaaaaaa" "ran" "clean"
write_row "$THRESHOLD_LOG" "$NOW" "/tmp/repo-b" "feat/a" "bbbbbbb" "FAIL_OPEN_REVIEWER_ERROR" "fail-open:reviewer"

THRESHOLD_OUT="$TEST_DIR/threshold.out"
set +e
run_doctor "$FAKE_HOME" --log-path "$THRESHOLD_LOG" >"$THRESHOLD_OUT" 2>&1
THRESHOLD_EXIT=$?
set -e

assert_exit "$THRESHOLD_EXIT" 2 "threshold warning"
assert_contains "$THRESHOLD_OUT" "fail-open: 1 (50.0%)"
assert_contains "$THRESHOLD_OUT" "FAIL_OPEN_REVIEWER_ERROR: 1"
assert_contains "$THRESHOLD_OUT" "exceeds 25%"

# --------------------------------------------------------------------------
# Test 7: TOUCHSTONE_REVIEW_LOG env override is honored and read-only
# --------------------------------------------------------------------------
echo ""
echo "--- Test 7: env override and read-only behavior ---"

ENV_LOG="$TEST_DIR/env.log"
write_row "$ENV_LOG" "$NOW" "/tmp/repo-env" "main" "eeeeeee" "ran" "clean"
BEFORE_SUM="$(cksum "$ENV_LOG")"

ENV_OUT="$TEST_DIR/env.out"
set +e
TOUCHSTONE_REVIEW_LOG="$ENV_LOG" run_doctor "$FAKE_HOME" >"$ENV_OUT" 2>&1
ENV_EXIT=$?
set -e
AFTER_SUM="$(cksum "$ENV_LOG")"

assert_exit "$ENV_EXIT" 0 "env override"
assert_contains "$ENV_OUT" "log: $ENV_LOG"
if [ "$BEFORE_SUM" != "$AFTER_SUM" ]; then
  echo "FAIL: doctor modified the review log fixture" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -ne 0 ]; then
  echo ""
  echo "FAILED: $ERRORS error(s)" >&2
  exit 1
fi

echo ""
echo "PASS: touchstone doctor tests"
