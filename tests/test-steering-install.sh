#!/usr/bin/env bash
#
# tests/test-steering-install.sh — machine-level steering distribution.
#
# Steering was the only layer that propagated by copying, and copying failed:
# measured 2026-08-18, zero of ten consumer repositories carried a managed
# block matching this contract, several instructing agents to do what the
# contract forbids. Installing once per machine removes the per-repository
# refresh entirely -- but only if the block is exact, idempotent, and never
# touches a byte the operator wrote.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/touchstone-steering-install.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-steering-install-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }

DRIVER_FILES=(".claude/CLAUDE.md" ".codex/AGENTS.md" ".gemini/GEMINI.md")

echo "==> a clean install reaches every supported driver"
H1="$TMP_DIR/h1"
bash "$INSTALL" install --home "$H1" >/dev/null
for f in "${DRIVER_FILES[@]}"; do
  if grep -qF '## Touchstone — Shared Agent Steering' "$H1/$f" 2>/dev/null; then
    pass "$f carries the contract"
  else
    fail "$f did not receive the contract"
  fi
done

echo "==> installing twice changes nothing"
cp "$H1/.claude/CLAUDE.md" "$TMP_DIR/first"
bash "$INSTALL" install --home "$H1" >/dev/null
if cmp -s "$TMP_DIR/first" "$H1/.claude/CLAUDE.md"; then
  pass "a second install is a no-op"
else
  fail "install is not idempotent"
fi

echo "==> operator content survives, including a newline-less tail"
H2="$TMP_DIR/h2"
mkdir -p "$H2/.claude"
printf 'MY HEADER\nkeep me\n' >"$H2/.claude/CLAUDE.md"
printf 'TRAILING NO NEWLINE' >>"$H2/.claude/CLAUDE.md"
before_head="$(head -2 "$H2/.claude/CLAUDE.md")"
bash "$INSTALL" install --home "$H2" >/dev/null
if [ "$(head -2 "$H2/.claude/CLAUDE.md")" = "$before_head" ]; then
  pass "content before the block is unchanged"
else
  fail "install rewrote content above the block"
fi
# On first install the block is appended, so pre-existing content -- including
# a newline-less final line -- ends up above it, intact. What must never
# happen is losing or mangling those bytes.
if grep -qF 'TRAILING NO NEWLINE' "$H2/.claude/CLAUDE.md"; then
  pass "a newline-less final line survives the append"
else
  fail "install lost the operator's newline-less trailing content"
fi
if [ "$(grep -c 'TRAILING NO NEWLINE' "$H2/.claude/CLAUDE.md")" = 1 ]; then
  pass "the trailing content is not duplicated"
else
  fail "install duplicated the operator's trailing content"
fi

echo "==> uninstall restores the file to the operator's own content"
bash "$INSTALL" uninstall --home "$H2" >/dev/null
expected="$(printf 'MY HEADER\nkeep me\nTRAILING NO NEWLINE')"
if [ "$(cat "$H2/.claude/CLAUDE.md")" = "$expected" ]; then
  pass "uninstall leaves exactly what the operator wrote"
else
  fail "uninstall did not restore the original content"
fi

echo "==> check distinguishes operator edits from real drift"
H3="$TMP_DIR/h3"
bash "$INSTALL" install --home "$H3" >/dev/null
printf '\nmy own note outside the block\n' >>"$H3/.claude/CLAUDE.md"
if bash "$INSTALL" check --home "$H3" >/dev/null 2>&1; then
  pass "an edit outside the markers is not drift"
else
  fail "check called an operator edit outside the block drift"
fi
python3 - "$H3/.codex/AGENTS.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("## Purpose", "## Purpose TAMPERED", 1))
PY
if bash "$INSTALL" check --home "$H3" >/dev/null 2>&1; then
  fail "check passed a tampered managed block"
else
  pass "a changed managed block is detected"
fi

echo "==> a missing install is reported, not silently tolerated"
H4="$TMP_DIR/h4"
mkdir -p "$H4"
if bash "$INSTALL" check --home "$H4" >/dev/null 2>&1; then
  fail "check passed a machine with no steering installed"
else
  pass "an unsteered machine fails check"
fi

echo "==> --dry-run writes nothing"
H5="$TMP_DIR/h5"
bash "$INSTALL" install --home "$H5" --dry-run >/dev/null
if [ -e "$H5/.claude/CLAUDE.md" ]; then
  fail "--dry-run created files"
else
  pass "--dry-run leaves the filesystem alone"
fi

echo "==> unknown actions and arguments fail closed"
if bash "$INSTALL" nonsense --home "$TMP_DIR/h6" >/dev/null 2>&1; then
  fail "an unknown action was accepted"
else
  pass "an unknown action is rejected"
fi
if bash "$INSTALL" install --home "$TMP_DIR/h7" --bogus >/dev/null 2>&1; then
  fail "an unknown argument was accepted"
else
  pass "an unknown argument is rejected"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: machine-level steering installs, checks, and uninstalls cleanly"
