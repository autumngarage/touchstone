#!/usr/bin/env bash
#
# tests/test-sed-inplace.sh — the portable in-place sed shim, and a guardrail
# against the whole `sed -i ''` class coming back.
#
# Regression test for #719. Every case below FAILS on the pre-fix code, because
# `sed -i '' 's/x/y/' f` on GNU sed (Linux, and Git for Windows) reads the ''
# as the script and the script as a filename.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-sed.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=lib/sed-inplace.sh
source "$TOUCHSTONE_ROOT/lib/sed-inplace.sh"

ERRORS=0

fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

echo "==> substitution actually rewrites the file"
printf 'hello NNNN world\n' >"$TEST_DIR/a.txt"
touchstone_sed_inplace 's/NNNN/0001/g' "$TEST_DIR/a.txt"
[ "$(cat "$TEST_DIR/a.txt")" = "hello 0001 world" ] \
  || fail "expected substitution, got: $(cat "$TEST_DIR/a.txt")"

echo "==> multiple files in one call"
printf 'X\n' >"$TEST_DIR/b1.txt"
printf 'X\n' >"$TEST_DIR/b2.txt"
touchstone_sed_inplace 's/X/Y/' "$TEST_DIR/b1.txt" "$TEST_DIR/b2.txt"
[ "$(cat "$TEST_DIR/b1.txt")" = "Y" ] || fail "b1 not rewritten"
[ "$(cat "$TEST_DIR/b2.txt")" = "Y" ] || fail "b2 not rewritten"

echo "==> file mode is preserved (cat >, not mv)"
printf 'keep\n' >"$TEST_DIR/mode.txt"
chmod 0741 "$TEST_DIR/mode.txt"
touchstone_sed_inplace 's/keep/kept/' "$TEST_DIR/mode.txt"
mode="$(ls -l "$TEST_DIR/mode.txt" | cut -c1-10)"
[ "$mode" = "-rwxr----x" ] || fail "mode not preserved, got $mode"

echo "==> a missing file is a loud failure, not a silent no-op"
rc=0
touchstone_sed_inplace 's/a/b/' "$TEST_DIR/does-not-exist.txt" 2>"$TEST_DIR/err1" || rc=$?
[ "$rc" -ne 0 ] || fail "missing file should exit nonzero"
grep -q "not a regular file" "$TEST_DIR/err1" || fail "missing file should name the problem"

echo "==> a symlink target is refused"
printf 'real\n' >"$TEST_DIR/real.txt"
ln -s "$TEST_DIR/real.txt" "$TEST_DIR/link.txt"
rc=0
touchstone_sed_inplace 's/real/hacked/' "$TEST_DIR/link.txt" 2>"$TEST_DIR/err2" || rc=$?
[ "$rc" -ne 0 ] || fail "symlink should be refused"
[ "$(cat "$TEST_DIR/real.txt")" = "real" ] || fail "symlink target was rewritten through the link"

echo "==> a bad sed script fails loudly and leaves the file intact"
printf 'original\n' >"$TEST_DIR/bad.txt"
rc=0
touchstone_sed_inplace 's/[unterminated' "$TEST_DIR/bad.txt" 2>"$TEST_DIR/err3" || rc=$?
[ "$rc" -ne 0 ] || fail "invalid sed script should exit nonzero"
[ "$(cat "$TEST_DIR/bad.txt")" = "original" ] || fail "file clobbered by a failing sed"

echo "==> missing arguments are usage errors"
rc=0
touchstone_sed_inplace 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "no arguments should exit 2, got $rc"
rc=0
touchstone_sed_inplace 's/a/b/' 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "no files should exit 2, got $rc"

echo "==> no temp files are left behind"
leaked="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'touchstone-sed.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$leaked" = "0" ] || fail "$leaked touchstone-sed temp file(s) leaked"

# --------------------------------------------------------------------------
# Guardrail for the class, not just the instance (principles/audit-weak-points).
# `sed -i ''` is BSD-only: it is a no-op-or-error on GNU sed and on Git Bash.
# Anything reintroducing it fails here rather than in a downstream project.
# --------------------------------------------------------------------------
# The non-portable spellings are exactly those where `-i` is followed by a
# SPACE, because the two userlands then disagree about what the next word is:
#
#   sed -i '' 's/x/y/' f   BSD: empty suffix, then script.  GNU: '' IS the
#                          script, so 's/x/y/' becomes a filename. (#719)
#   sed -i 's/x/y/' f      GNU: no suffix, then script.      BSD: 's/x/y/' is
#                          consumed as the backup SUFFIX, so `f` becomes the
#                          script and there is no input file.
#
# An ATTACHED suffix (`sed -i.bak`) means the same thing to both and is left
# alone — bootstrap/migrate-from-toolkit.sh uses it deliberately and removes
# its own backup. This check therefore flags what is actually broken rather
# than every in-place spelling.
echo "==> no space-separated 'sed -i' survives anywhere in the tree"
offenders="$(cd "$TOUCHSTONE_ROOT" && git grep -nE "sed +-i +" -- \
  ':!lib/sed-inplace.sh' ':!tests/test-sed-inplace.sh' || true)"
if [ -n "$offenders" ]; then
  fail "non-portable space-separated \`sed -i\` reintroduced:"
  printf '%s\n' "$offenders" | sed 's/^/    /' >&2
fi

echo ""
if [ "$ERRORS" -ne 0 ]; then
  echo "FAIL: $ERRORS assertion(s) failed" >&2
  exit 1
fi
echo "==> PASS: portable in-place sed, and the BSD-only spelling cannot return"
