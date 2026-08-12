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
SKIPPED=0

fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

# Three cases below need the OS to express a precondition that Windows cannot:
# NTFS through MSYS2 does not honour Unix permission bits, Git Bash silently
# creates a copy instead of a symlink unless developer mode is on, and a
# directory mode of 0500 does not stop writes there.
#
# Asserting anyway reports a platform limitation as a shim defect — which is
# what the first Windows run of this file did. Skipping silently is worse: it
# lets a real regression hide behind "green on Windows". So each of those cases
# PROVES its precondition first, and says out loud when the platform cannot
# provide one. A skip is a visible gap in coverage, never a pass.
skip() {
  echo "  SKIP — platform cannot establish the precondition: $1"
  SKIPPED=$((SKIPPED + 1))
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

echo "==> file mode is carried onto the replacement before the rename"
printf 'keep\n' >"$TEST_DIR/mode.txt"
chmod 0741 "$TEST_DIR/mode.txt"
before="$(ls -l "$TEST_DIR/mode.txt" | cut -c1-10)"
if [ "$before" != "-rwxr----x" ]; then
  skip "chmod 0741 did not take (got $before) — filesystem has no Unix mode bits"
else
  touchstone_sed_inplace 's/keep/kept/' "$TEST_DIR/mode.txt"
  mode="$(ls -l "$TEST_DIR/mode.txt" | cut -c1-10)"
  [ "$mode" = "-rwxr----x" ] || fail "mode not preserved, got $mode"
  [ "$(cat "$TEST_DIR/mode.txt")" = "kept" ] || fail "mode case did not rewrite content"
fi

echo "==> a missing file is a loud failure, not a silent no-op"
rc=0
touchstone_sed_inplace 's/a/b/' "$TEST_DIR/does-not-exist.txt" 2>"$TEST_DIR/err1" || rc=$?
[ "$rc" -ne 0 ] || fail "missing file should exit nonzero"
grep -q "not a regular file" "$TEST_DIR/err1" || fail "missing file should name the problem"

echo "==> a symlink target is refused"
printf 'real\n' >"$TEST_DIR/real.txt"
ln -s "$TEST_DIR/real.txt" "$TEST_DIR/link.txt" 2>/dev/null || true
if [ ! -L "$TEST_DIR/link.txt" ]; then
  skip "ln -s produced a copy, not a symlink — no symlink support here"
else
  rc=0
  touchstone_sed_inplace 's/real/hacked/' "$TEST_DIR/link.txt" 2>"$TEST_DIR/err2" || rc=$?
  [ "$rc" -ne 0 ] || fail "symlink should be refused"
  [ "$(cat "$TEST_DIR/real.txt")" = "real" ] || fail "symlink target was rewritten through the link"
fi

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

echo "==> no temp files are left behind, in the target dir or TMPDIR"
leaked="$(find "$TEST_DIR" "${TMPDIR:-/tmp}" -maxdepth 1 -name '*touchstone-sed.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$leaked" = "0" ] || fail "$leaked touchstone-sed temp file(s) leaked"

# The replacement is a rename, and rename(2) is only atomic within a
# filesystem — so the temp must be a sibling of the target, not in $TMPDIR.
# A temp on another device silently degrades `mv` to copy-then-delete and
# reopens exactly the torn-write window this design closes.
echo "==> an interrupt between mktemp and rename leaves no stray temp"
printf 'slow\n' >"$TEST_DIR/interrupt.txt"
(
  # shellcheck disable=SC1090
  source "$TOUCHSTONE_ROOT/lib/sed-inplace.sh"
  touchstone_sed_inplace 's/slow/fast/' "$TEST_DIR/interrupt.txt"
) &
worker=$!
kill -TERM "$worker" 2>/dev/null || true
wait "$worker" 2>/dev/null || true
strays="$(find "$TEST_DIR" -maxdepth 1 -name '.touchstone-sed.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$strays" = "0" ] || fail "$strays stray temp file(s) survived a TERM"
# Whichever side of the rename the signal landed on, the file must be readable
# and hold one of the two valid contents — never empty, never partial.
content="$(cat "$TEST_DIR/interrupt.txt")"
case "$content" in
  slow | fast) ;;
  *) fail "interrupted rewrite left the file as: '$content'" ;;
esac

echo "==> ownership is preserved, or the rewrite refuses"
grep -q '_touchstone_sed_file_owner' "$TOUCHSTONE_ROOT/lib/sed-inplace.sh" \
  || fail "no owner check: a privileged rewrite would silently transfer ownership"

echo "==> the shim never writes its temp into TMPDIR"
if ! grep -q 'mktemp "\$dir/' "$TOUCHSTONE_ROOT/lib/sed-inplace.sh"; then
  fail "temp file is no longer created beside the target — rename is not atomic across filesystems"
fi
# Comment lines are excluded deliberately: the shim *explains* why it avoids
# $TMPDIR, so a naive grep matches its own rationale.
if grep -v '^[[:space:]]*#' "$TOUCHSTONE_ROOT/lib/sed-inplace.sh" | grep -q 'TMPDIR'; then
  fail "lib/sed-inplace.sh uses TMPDIR in code; the temp must be a sibling of the target"
fi

echo "==> a read-only directory fails loudly instead of destroying the file"
mkdir -p "$TEST_DIR/ro"
printf 'precious\n' >"$TEST_DIR/ro/keep.txt"
chmod 0500 "$TEST_DIR/ro"
# Prove the directory really is unwritable before asserting on that basis.
# Windows honours the chmod call but not its meaning, so a write still lands.
if touch "$TEST_DIR/ro/.writable-probe" 2>/dev/null; then
  rm -f "$TEST_DIR/ro/.writable-probe"
  chmod 0700 "$TEST_DIR/ro"
  skip "chmod 0500 on a directory does not prevent writes here"
else
  rc=0
  touchstone_sed_inplace 's/precious/gone/' "$TEST_DIR/ro/keep.txt" 2>"$TEST_DIR/err4" || rc=$?
  chmod 0700 "$TEST_DIR/ro"
  [ "$rc" -ne 0 ] || fail "unwritable directory should exit nonzero"
  [ "$(cat "$TEST_DIR/ro/keep.txt")" = "precious" ] \
    || fail "file destroyed when its directory was unwritable — got: $(cat "$TEST_DIR/ro/keep.txt")"
fi

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
# alone — a caller that writes its own backup and removes it is portable.
# This check therefore flags what is actually broken rather than every
# in-place spelling.
# Comment lines are filtered out: prose explaining why the broken spelling is
# broken necessarily contains the broken spelling, and a guard that fires on
# its own rationale is the false-positive class tracked in #745. Match on
# `path:line:` followed by a non-comment character.
echo "==> no space-separated 'sed -i' survives anywhere in the tree"
# Scoped to executable shell sources. A repository-wide grep also matches
# documentation that legitimately quotes the broken spelling while explaining
# it — a README or principle would then fail the fast tier despite introducing
# no executable use, which is the false-positive class this guard is supposed
# to avoid rather than commit (PR #747 review).
offenders="$(cd "$TOUCHSTONE_ROOT" && git grep -nE "sed +-i +" -- \
  'bin/*' 'lib/*' 'scripts/*' 'hooks/*' 'bootstrap/*' 'tests/*.sh' \
  ':!lib/sed-inplace.sh' ':!tests/test-sed-inplace.sh' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$offenders" ]; then
  fail "non-portable space-separated \`sed -i\` reintroduced:"
  printf '%s\n' "$offenders" | sed 's/^/    /' >&2
fi

echo ""
if [ "$ERRORS" -ne 0 ]; then
  echo "FAIL: $ERRORS assertion(s) failed" >&2
  exit 1
fi
if [ "$SKIPPED" -ne 0 ]; then
  # Reported, never hidden: a skip means this platform left a real property
  # unverified, and the log should say which one rather than read as a clean
  # pass. The substantive cases — substitution, atomicity, loud failure, and
  # the class guardrail — never skip on any platform.
  echo "==> PASS with $SKIPPED case(s) not applicable on this platform"
  exit 0
fi
echo "==> PASS: portable in-place sed, and the BSD-only spelling cannot return"
