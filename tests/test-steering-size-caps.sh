#!/usr/bin/env bash
#
# tests/test-steering-size-caps.sh — guardrail against steering-doc bloat.
#
# The whole point of the TOUCHSTONE.md routing layer is to keep auto-loaded
# context lean: rules that fire on every turn live in TOUCHSTONE.md (which
# CLAUDE.md @-imports and AGENTS.md/GEMINI.md inline via the managed block),
# and everything else is routed via skills or principles/*.md.
#
# These caps catch the failure mode where someone adds a fourth section to
# TOUCHSTONE.md without thinking about the per-turn cost. If a cap is hit,
# either:
#   - move the new content to principles/* or skills/ and route to it from
#     the TOUCHSTONE.md routing table, OR
#   - raise the cap deliberately, with the reasoning documented in the
#     commit message.
#
# Codex's project_doc_max_bytes default is 32 KiB; AGENTS.md staying under
# 24 KiB leaves headroom for project-specific tail content.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_under() {
  local label="$1" path="$2" cap_bytes="$3"
  if [ ! -f "$path" ]; then
    fail "$label: file not found: $path"
    return
  fi
  local actual
  actual="$(wc -c <"$path" | tr -d '[:space:]')"
  if [ "$actual" -gt "$cap_bytes" ]; then
    fail "$label: $path is $actual bytes, cap is $cap_bytes (raise the cap deliberately or trim the file)"
  else
    printf '  OK: %s — %s bytes (cap %s)\n' "$label" "$actual" "$cap_bytes"
  fi
}

echo "==> TOUCHSTONE.md size cap (8 KiB — lean router)"
assert_under "TOUCHSTONE.md" "$TOUCHSTONE_ROOT/TOUCHSTONE.md" 8192

echo "==> AGENTS.md size cap (24 KiB — leaves headroom under Codex's 32 KiB default)"
assert_under "AGENTS.md" "$TOUCHSTONE_ROOT/AGENTS.md" 24576
assert_under "templates/AGENTS.md" "$TOUCHSTONE_ROOT/templates/AGENTS.md" 24576

echo "==> GEMINI.md size cap (24 KiB — same headroom)"
assert_under "GEMINI.md" "$TOUCHSTONE_ROOT/GEMINI.md" 24576
assert_under "templates/GEMINI.md" "$TOUCHSTONE_ROOT/templates/GEMINI.md" 24576

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS size-cap check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: all steering-doc size caps respected"
