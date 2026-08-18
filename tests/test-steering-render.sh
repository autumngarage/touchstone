#!/usr/bin/env bash
#
# tests/test-steering-render.sh — the managed steering blocks must equal
# TOUCHSTONE.md.
#
# Ten consumer repositories were measured on 2026-08-18 and none carried a
# managed block matching this contract. Several had drifted far enough to
# instruct agents to do things the contract forbids. Nothing detected it,
# because nothing compared them. This is that comparison, for the four copies
# this repository owns.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER="$REPO_ROOT/scripts/render-steering.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-render-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }

[ -x "$RENDER" ] || {
  echo "ERROR: missing or non-executable $RENDER" >&2
  exit 1
}

echo "==> Managed blocks match TOUCHSTONE.md"
if bash "$RENDER" --check >/dev/null 2>&1; then
  pass "every managed block matches the canonical contract"
else
  bash "$RENDER" --check 2>&1 | head -25 >&2
  fail "a managed block drifted; run: bash scripts/render-steering.sh"
fi

# A checker that cannot fail is decoration. Copy the repository, introduce a
# single-word divergence inside a managed block, and require detection.
echo "==> The drift check can actually fail"
WORK="$TMP_DIR/repo"
mkdir -p "$WORK/scripts" "$WORK/templates"
cp "$REPO_ROOT/TOUCHSTONE.md" "$WORK/TOUCHSTONE.md"
cp "$REPO_ROOT/AGENTS.md" "$WORK/AGENTS.md"
cp "$REPO_ROOT/GEMINI.md" "$WORK/GEMINI.md"
cp "$REPO_ROOT/templates/AGENTS.md" "$WORK/templates/AGENTS.md"
cp "$REPO_ROOT/templates/GEMINI.md" "$WORK/templates/GEMINI.md"
cp "$RENDER" "$WORK/scripts/render-steering.sh"

# Change content inside the block only.
awk '
  /<!-- touchstone:steering:start -->/ { inside = 1 }
  /<!-- touchstone:steering:end -->/   { inside = 0 }
  inside && !done && /^## Purpose$/ { print "## Purpose DRIFTED"; done = 1; next }
  { print }
' "$WORK/AGENTS.md" >"$WORK/AGENTS.md.tmp" && mv "$WORK/AGENTS.md.tmp" "$WORK/AGENTS.md"

if grep -q "## Purpose DRIFTED" "$WORK/AGENTS.md"; then
  if bash "$WORK/scripts/render-steering.sh" --check >/dev/null 2>&1; then
    fail "the drift check passed a block containing an injected change"
  else
    pass "an injected in-block change is detected"
  fi
else
  fail "could not inject drift into the test copy; the assertion proves nothing"
fi

# Content outside the markers is the project's own and must survive rendering.
echo "==> Rendering preserves content outside the markers"
printf '\n<!-- sentinel-outside-block -->\n' >>"$WORK/GEMINI.md"
bash "$WORK/scripts/render-steering.sh" >/dev/null 2>&1 || true
if grep -q "sentinel-outside-block" "$WORK/GEMINI.md"; then
  pass "text after the end marker survives a render"
else
  fail "rendering discarded content outside the managed markers"
fi

# Rendering twice must produce the same bytes, or the check would flap.
echo "==> Rendering is idempotent"
bash "$WORK/scripts/render-steering.sh" >/dev/null 2>&1 || true
cp "$WORK/AGENTS.md" "$TMP_DIR/first"
bash "$WORK/scripts/render-steering.sh" >/dev/null 2>&1 || true
if cmp -s "$TMP_DIR/first" "$WORK/AGENTS.md"; then
  pass "a second render changes nothing"
else
  fail "rendering is not idempotent"
fi

# A file missing its markers must fail loudly rather than being silently skipped.
echo "==> A target without markers fails closed"
grep -v "touchstone:steering" "$WORK/GEMINI.md" >"$WORK/GEMINI.md.tmp" && mv "$WORK/GEMINI.md.tmp" "$WORK/GEMINI.md"
if bash "$WORK/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  fail "a target with no markers was accepted"
else
  pass "a target with no markers is rejected"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: managed steering blocks are rendered, not hand-mirrored"
