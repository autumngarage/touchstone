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
TEST_DIR="$(mktemp -d -t touchstone-test-codex-review-sentinel.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

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
  "JSON response wrapper with escaped-line sentinel" \
  $'{\n  "response": "Summary\\nCODEX_REVIEW_CLEAN\\n"\n}\n' \
  "CODEX_REVIEW_CLEAN"

assert_detector \
  "JSON response wrapper with inline sentinel rejected" \
  $'{\n  "response": "Summary CODEX_REVIEW_CLEAN"\n}\n' \
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

echo "==> codex-review malformed-sentinel gate behavior"

REPO_DIR="$TEST_DIR/repo"
FAKE_BIN="$TEST_DIR/bin"
PROMPT_FILE="$TEST_DIR/review-prompt.txt"
CLOSED_OUTPUT="$TEST_DIR/fail-closed-output.txt"
OPEN_OUTPUT="$TEST_DIR/fail-open-output.txt"

mkdir -p "$REPO_DIR" "$FAKE_BIN"
git -C "$REPO_DIR" init >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' > "$REPO_DIR/example.txt"
git -C "$REPO_DIR" add example.txt
git -C "$REPO_DIR" commit -m "base" >/dev/null 2>&1
printf 'changed\n' >> "$REPO_DIR/example.txt"
git -C "$REPO_DIR" add example.txt
git -C "$REPO_DIR" commit -m "change" >/dev/null 2>&1

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "main"
EOF

cat > "$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then
  printf '{"providers":[{"configured":true}]}\n'
  exit 0
fi
cat > "$PROMPT_FILE"
printf '[conductor] auto (prefer=best, effort=max) -> codex (tier: frontier)\n' >&2
printf 'No blocking issues were found in the diff.\n'
printf 'The changes look safe to merge.\n'
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/conductor"

set +e
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PROMPT_FILE="$PROMPT_FILE" \
    TOUCHSTONE_REVIEW_LOG=/dev/null \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$SCRIPT" > "$CLOSED_OUTPUT" 2>&1
)
CLOSED_EXIT=$?
set -e

if [ "$CLOSED_EXIT" -eq 1 ] \
  && grep -q 'No unique standalone sentinel line was found.' "$CLOSED_OUTPUT" \
  && grep -q 'Conductor selected provider: codex' "$CLOSED_OUTPUT" \
  && grep -q "Conductor command invoked: $FAKE_BIN/conductor exec" "$CLOSED_OUTPUT"; then
  printf '  OK: missing sentinel blocks under fail-closed policy with provider diagnostics\n'
else
  printf 'FAIL: missing sentinel should block with provider and command diagnostics\n' >&2
  printf 'exit code: %s\n' "$CLOSED_EXIT" >&2
  cat "$CLOSED_OUTPUT" >&2
  exit 1
fi

set +e
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PROMPT_FILE="$PROMPT_FILE" \
    TOUCHSTONE_REVIEW_LOG=/dev/null \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-open \
    bash "$SCRIPT" > "$OPEN_OUTPUT" 2>&1
)
OPEN_EXIT=$?
set -e

if [ "$OPEN_EXIT" -eq 0 ] \
  && grep -q 'No unique standalone sentinel line was found.' "$OPEN_OUTPUT" \
  && grep -q '\[review:fail-open\] missing sentinel — policy permits merge but the review verdict is untrustworthy' "$OPEN_OUTPUT"; then
  printf '  OK: missing sentinel fail-opens only with visible warning under fail-open policy\n'
else
  printf 'FAIL: missing sentinel should visibly warn under fail-open policy\n' >&2
  printf 'exit code: %s\n' "$OPEN_EXIT" >&2
  cat "$OPEN_OUTPUT" >&2
  exit 1
fi

if grep -q 'very last physical line of the entire response must be exactly one sentinel token' "$PROMPT_FILE"; then
  printf '  OK: reviewer prompt states the strict final-line sentinel contract\n'
else
  printf 'FAIL: prompt did not include strict final-line sentinel contract\n' >&2
  sed -n '1,220p' "$PROMPT_FILE" >&2
  exit 1
fi

echo "==> OK: malformed-sentinel gate behavior passed"
