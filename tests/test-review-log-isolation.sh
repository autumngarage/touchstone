#!/usr/bin/env bash
#
# tests/test-review-log-isolation.sh — guard user review audit state from tests.

set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-review-log-isolation.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
RELEVANT_TESTS="
tests/test-review-dry-run.sh
tests/test-migrate-review-config.sh
tests/test-events-json.sh
"

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

run_relevant_suite() {
  local fake_home="$1"
  local mode="$2"
  local test_path output

  for test_path in $RELEVANT_TESTS; do
    output="$TEST_DIR/${mode}-$(basename "$test_path").out"
    if ! HOME="$fake_home" bash "$TOUCHSTONE_ROOT/$test_path" >"$output" 2>&1; then
      fail "$test_path failed under isolated HOME ($mode)"
      cat "$output" >&2
    fi
  done
}

echo "==> Test: review and merge fixture class declares isolated audit state"
for test_path in "$TOUCHSTONE_ROOT"/tests/test-*.sh; do
  [ "$(basename "$test_path")" = "test-review-log-isolation.sh" ] && continue

  invokes_real_review=0
  if grep -qF 'cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh"' "$test_path" \
    || grep -qF 'bash "$TOUCHSTONE_ROOT/scripts/codex-review.sh"' "$test_path" \
    || grep -qF 'bash "$TOUCHSTONE_ROOT/scripts/conductor-review.sh"' "$test_path" \
    || grep -qF 'bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh"' "$test_path" \
    || grep -qF 'bash "$TOUCHSTONE_ROOT/hooks/conductor-review.sh"' "$test_path" \
    || grep -qF 'bash "$TOUCHSTONE_ROOT/bin/touchstone" review' "$test_path" \
    || grep -qF 'bash "$TOUCHSTONE_BIN" review' "$test_path"; then
    invokes_real_review=1
  fi

  if [ "$invokes_real_review" -eq 1 ] \
    && ! grep -q 'TOUCHSTONE_REVIEW_LOG=' "$test_path" \
    && ! grep -q 'touchstone_isolate_review_log ' "$test_path"; then
    fail "$(basename "$test_path") invokes a real review/merge path without isolated audit state"
  fi
done

echo "==> Test: isolated suite cannot create the default user review log"
EMPTY_HOME="$TEST_DIR/empty-home"
mkdir -p "$EMPTY_HOME"
run_relevant_suite "$EMPTY_HOME" empty
if [ -e "$EMPTY_HOME/.touchstone-review-log" ]; then
  fail "relevant suite created the default review log in an empty HOME"
fi

echo "==> Test: isolated suite cannot change existing user review state"
EXISTING_HOME="$TEST_DIR/existing-home"
EXISTING_LOG="$EXISTING_HOME/.touchstone-review-log"
mkdir -p "$EXISTING_HOME"
printf 'production-review-evidence-must-survive\n' >"$EXISTING_LOG"
before="$(shasum "$EXISTING_LOG" | awk '{print $1}')"
run_relevant_suite "$EXISTING_HOME" existing
after="$(shasum "$EXISTING_LOG" | awk '{print $1}')"
if [ "$before" != "$after" ]; then
  fail "relevant suite changed the preexisting default review log"
fi

if [ "$ERRORS" -ne 0 ]; then
  echo "FAIL: $ERRORS review-log isolation assertion(s) failed" >&2
  exit 1
fi

echo "PASS: review tests cannot mutate default user review state"
