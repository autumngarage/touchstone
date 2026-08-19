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

# An indented marker satisfies a substring count but not whole-line
# extraction; the old validation accepted it and rendered a duplicate block
# with exit 0. Both modes must refuse it. Reported as P2 on PR #919.
echo "==> An indented marker is refused, not silently duplicated"
INDENTED="$TMP_DIR/indented"
mkdir -p "$INDENTED/scripts" "$INDENTED/templates"
cp "$REPO_ROOT/TOUCHSTONE.md" "$INDENTED/TOUCHSTONE.md"
for f in AGENTS.md GEMINI.md templates/AGENTS.md templates/GEMINI.md; do
  cp "$REPO_ROOT/$f" "$INDENTED/$f"
done
cp "$RENDER" "$INDENTED/scripts/render-steering.sh"
sed 's/^<!-- touchstone:steering:start -->$/  <!-- touchstone:steering:start -->/' "$INDENTED/AGENTS.md" >"$INDENTED/AGENTS.md.tmp" && mv "$INDENTED/AGENTS.md.tmp" "$INDENTED/AGENTS.md"
before_hash="$(cksum "$INDENTED/AGENTS.md")"
if bash "$INDENTED/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render accepted an indented start marker"
else
  pass "render refuses an indented start marker"
fi
after_hash="$(cksum "$INDENTED/AGENTS.md")"
if [ "$before_hash" = "$after_hash" ]; then
  pass "the refused file was not modified"
else
  fail "render modified a file it refused"
fi
if bash "$INDENTED/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  fail "--check accepted an indented start marker"
else
  pass "--check refuses an indented start marker"
fi

echo "==> Reversed marker order is refused"
REVERSED="$TMP_DIR/reversed"
mkdir -p "$REVERSED/scripts" "$REVERSED/templates"
cp "$REPO_ROOT/TOUCHSTONE.md" "$REVERSED/TOUCHSTONE.md"
for f in AGENTS.md GEMINI.md templates/AGENTS.md templates/GEMINI.md; do
  cp "$REPO_ROOT/$f" "$REVERSED/$f"
done
cp "$RENDER" "$REVERSED/scripts/render-steering.sh"
awk '
  /^<!-- touchstone:steering:start -->$/ { print "<!-- touchstone:steering:end -->"; next }
  /^<!-- touchstone:steering:end -->$/   { print "<!-- touchstone:steering:start -->"; next }
  { print }
' "$REVERSED/GEMINI.md" >"$REVERSED/GEMINI.md.tmp" && mv "$REVERSED/GEMINI.md.tmp" "$REVERSED/GEMINI.md"
if bash "$REVERSED/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  fail "--check accepted an end marker before the start marker"
else
  pass "--check refuses reversed marker order"
fi

# Two byte-exactness regressions from PR #919 review. A source lacking a
# final newline used to weld the end marker to its last line -- render
# reported success, the very next --check rejected every target. And the awk
# tail extraction appended a newline to project content that ended without
# one, mutating bytes outside the markers the script promises not to touch.
echo "==> A newline-less source still renders a valid, re-checkable block"
NONL="$TMP_DIR/nonl"
mkdir -p "$NONL/scripts" "$NONL/templates"
printf '%s' "$(cat "$REPO_ROOT/TOUCHSTONE.md")" >"$NONL/TOUCHSTONE.md" # strips final newline
for f in AGENTS.md GEMINI.md templates/AGENTS.md templates/GEMINI.md; do
  cp "$REPO_ROOT/$f" "$NONL/$f"
done
cp "$RENDER" "$NONL/scripts/render-steering.sh"
if bash "$NONL/scripts/render-steering.sh" >/dev/null 2>&1 && bash "$NONL/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  pass "render then --check both succeed without a source trailing newline"
else
  fail "a newline-less source produced a block its own --check rejects"
fi

echo "==> Rendering leaves a newline-less project tail byte-identical"
printf '\ntrailing-sentinel-no-newline' >>"$NONL/GEMINI.md" # tail now ends without newline
last_before="$(tail -c 1 "$NONL/GEMINI.md" | od -An -c | tr -d ' \n')"
if ! bash "$NONL/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render failed on a target with a newline-less tail; preservation not exercised"
fi
last_after="$(tail -c 1 "$NONL/GEMINI.md" | od -An -c | tr -d ' \n')"
if [ "$last_before" = "$last_after" ]; then
  pass "the tail's final byte is unchanged by a render"
else
  fail "render mutated the trailing byte outside the markers ($last_before -> $last_after)"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: managed steering blocks are rendered, not hand-mirrored"
