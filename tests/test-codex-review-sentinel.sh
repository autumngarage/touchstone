#!/usr/bin/env bash
#
# tests/test-codex-review-sentinel.sh — unit tests for the sentinel
# extraction helper in hooks/codex-review.sh. The wrapper used to
# inspect only the final physical line via `tail -1 | tr -d '\r '` and
# case on that exact value, so any footer after the sentinel — a stray
# markdown rule, a closing fence, an LLM's habitual closing remark —
# pushed the real sentinel off the last position and the wrapper
# reported "malformed sentinel" despite a clean review. The new
# extract_review_sentinel reads "the unique standalone sentinel line,
# anywhere in the output" — robust to that footer class while still
# rejecting genuinely ambiguous outputs (zero or multiple sentinels).
#
# These tests exercise the helper via CODEX_REVIEW_TEST_SENTINEL=1,
# which short-circuits the script after the helper definition and
# pipes stdin through awk only.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$TOUCHSTONE_ROOT/hooks/codex-review.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not found or not executable" >&2
  exit 1
fi

run_detector() {
  local input="$1"
  printf '%s' "$input" | CODEX_REVIEW_TEST_SENTINEL=1 bash "$SCRIPT"
}

assert_detector() {
  local name="$1"
  local input="$2"
  local expected="$3"
  local actual

  actual="$(run_detector "$input")"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s\nexpected: [%s]\nactual:   [%s]\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
  printf '  OK: %s\n' "$name"
}

echo "==> codex-review sentinel extraction"

assert_detector \
  "exact sentinel" \
  $'Summary\nCODEX_REVIEW_CLEAN\n' \
  "CODEX_REVIEW_CLEAN"

assert_detector \
  "trailing whitespace" \
  $'Summary\nCODEX_REVIEW_CLEAN   \n\n' \
  "CODEX_REVIEW_CLEAN"

# This is the regression case: footer after sentinel was reported as
# malformed by the old `tail -1` parser. The helper now finds the
# sentinel anywhere in the output as long as it's the only one.
assert_detector \
  "footer after sentinel — does not break extraction" \
  $'LGTM\nCODEX_REVIEW_CLEAN\n---\nreview complete\n' \
  "CODEX_REVIEW_CLEAN"

assert_detector \
  "indented sentinel" \
  $'Summary\n  CODEX_REVIEW_FIXED\t\nextra note\n' \
  "CODEX_REVIEW_FIXED"

# Conductor Gemini may wrap the provider response in JSON while preserving the
# sentinel as the exact response value. Accept that narrow wrapper so fallbacks
# remain usable without accepting arbitrary inline sentinel prose.
assert_detector \
  "JSON response wrapper with exact sentinel" \
  $'{\n  "session_id": "demo",\n  "response": "CODEX_REVIEW_CLEAN\\n",\n  "stats": {}\n}\n' \
  "CODEX_REVIEW_CLEAN"

assert_detector \
  "JSON response wrapper with exact sentinel and no newline" \
  $'{\n  "session_id": "demo",\n  "response": "CODEX_REVIEW_CLEAN",\n  "stats": {}\n}\n' \
  "CODEX_REVIEW_CLEAN"

# Inline sentinels (text on the same line as other content) are NOT
# accepted — the contract is "sentinel on its own line."
assert_detector \
  "inline sentinel rejected" \
  $'Summary: CODEX_REVIEW_CLEAN\n' \
  ""

assert_detector \
  "JSON response wrapper with prose rejected" \
  $'{\n  "response": "Summary\\nCODEX_REVIEW_CLEAN\\n"\n}\n' \
  ""

# Multiple sentinel lines are ambiguous — the reviewer either changed
# its mind or got confused; reject and surface as malformed.
assert_detector \
  "multiple sentinel lines rejected" \
  $'CODEX_REVIEW_CLEAN\nCODEX_REVIEW_BLOCKED\n' \
  ""

# Empty output → empty result. The wrapper's malformed-sentinel branch
# then reports "no unique standalone sentinel" rather than echoing an
# empty last line.
assert_detector \
  "no sentinel at all" \
  $'just some prose\nno verdict\n' \
  ""

echo "==> OK: all sentinel tests passed"
