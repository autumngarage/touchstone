#!/usr/bin/env bash
#
# tests/test-claude-probe-helper.sh — verify Claude probe helper process control.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-claude-probe.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=claude-probe-helper.sh
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

FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'FAKECLAUDE'
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

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: claude probe helper process control is bounded"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
