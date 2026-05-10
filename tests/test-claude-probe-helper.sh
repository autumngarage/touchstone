#!/usr/bin/env bash
#
# tests/test-claude-probe-helper.sh — verify Claude probe helper process control.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-claude-probe.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=tests/claude-probe-helper.sh
source "$TOUCHSTONE_ROOT/tests/claude-probe-helper.sh"

ERRORS=0

assert_contains_text() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s' "$haystack" | grep -q "$needle"; then
    echo "FAIL: expected output to contain '$needle'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $label: expected '$expected', got '$actual'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
printf 'fast response for: %s\n' "$*"
FAKECLAUDE
chmod +x "$FAKE_BIN/claude"

echo "==> Claude probe helper returns promptly after successful probe"
SECONDS=0
response="$(PATH="$FAKE_BIN:$PATH" TOUCHSTONE_CLAUDE_PROBE_TIMEOUT=5 run_claude_probe "hello")"
elapsed="$SECONDS"

assert_contains_text "$response" 'fast response'
if [ "$elapsed" -ge 3 ]; then
  echo "FAIL: successful probe waited ${elapsed}s despite fast claude stub" >&2
  ERRORS=$((ERRORS + 1))
fi

cat >"$FAKE_BIN/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
echo "You've hit your limit · resets May 11 at 9pm (America/New_York)"
exit 1
FAKECLAUDE
chmod +x "$FAKE_BIN/claude"

echo "==> Claude probe helper classifies quota exhaustion distinctly"
set +e
response="$(PATH="$FAKE_BIN:$PATH" TOUCHSTONE_CLAUDE_PROBE_TIMEOUT=5 run_claude_probe "hello")"
rc=$?
set -e

assert_equals "$rc" "125" "quota-limited claude probe return code"
assert_contains_text "$response" "You've hit your limit"

cat >"$FAKE_BIN/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
count_file="${TOUCHSTONE_FAKE_CLAUDE_COUNT:?}"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
echo "You've hit your limit · resets May 11 at 9pm (America/New_York)"
exit 1
FAKECLAUDE
chmod +x "$FAKE_BIN/claude"

echo "==> Slow guidance probes skip once on provider quota exhaustion"
count_file="$TEST_DIR/claude-count"
set +e
response="$(PATH="$FAKE_BIN:$PATH" \
  TOUCHSTONE_FAKE_CLAUDE_COUNT="$count_file" \
  TOUCHSTONE_CLAUDE_PROBE_TIMEOUT=5 \
  bash "$TOUCHSTONE_ROOT/tests/slow-guidance-probes.sh" 2>&1)"
rc=$?
set -e

assert_equals "$rc" "0" "quota-limited slow guidance exit code"
assert_contains_text "$response" "SKIP: Claude provider unavailable"
count_value="$(cat "$count_file" 2>/dev/null || echo 0)"
assert_equals "$count_value" "1" "slow guidance quota call count"

cat >"$FAKE_BIN/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
count_file="${TOUCHSTONE_FAKE_CLAUDE_COUNT:?}"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "$count" -eq 1 ]; then
  echo "plain response without guidance markers"
  exit 0
fi
echo "You've hit your limit · resets May 11 at 9pm (America/New_York)"
exit 1
FAKECLAUDE
chmod +x "$FAKE_BIN/claude"

echo "==> Slow guidance probes do not let later quota mask prior failures"
count_file="$TEST_DIR/claude-count-after-failure"
set +e
response="$(PATH="$FAKE_BIN:$PATH" \
  TOUCHSTONE_FAKE_CLAUDE_COUNT="$count_file" \
  TOUCHSTONE_CLAUDE_PROBE_TIMEOUT=5 \
  bash "$TOUCHSTONE_ROOT/tests/slow-guidance-probes.sh" 2>&1)"
rc=$?
set -e

assert_equals "$rc" "1" "quota after prior guidance failure exit code"
assert_contains_text "$response" "Provider unavailability cannot mask earlier guidance drift"
count_value="$(cat "$count_file" 2>/dev/null || echo 0)"
assert_equals "$count_value" "2" "slow guidance quota-after-failure call count"

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: claude probe helper process control and quota classification work"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
