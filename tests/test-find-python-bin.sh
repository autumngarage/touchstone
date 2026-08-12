#!/usr/bin/env bash
#
# tests/test-find-python-bin.sh — Issue #171: scripts/touchstone-run.sh must
# resolve the parent repo's .venv/bin/python when run from a git worktree, and
# must fail loudly rather than fall through to a system interpreter.
#
# #737 retired scripts/run-pytest-in-venv.sh (the PATH-fallback half of the
# original suite went with it). find_python_bin did not go: it is the venv
# resolver every managed project's pre-push validate runs through, so its
# regression coverage stays.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOUCHSTONE_SCRIPT="${TOUCHSTONE_RUN_SCRIPT_UNDER_TEST:-$REPO_ROOT/scripts/touchstone-run.sh}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s\nexpected: [%s]\nactual:   [%s]\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$name missing [$needle] in [$haystack]" ;;
  esac
}

setup_worktree_fixture() {
  local root="$1" parent worktree
  parent="$root/parent"
  worktree="$root/foo"

  mkdir -p "$parent/.git/worktrees/foo" "$parent/.venv/bin" "$worktree"
  printf '#!/usr/bin/env bash\n' >"$parent/.venv/bin/python"
  chmod +x "$parent/.venv/bin/python"
  printf 'gitdir: %s\n' "$parent/.git/worktrees/foo" >"$worktree/.git"
}

run_touchstone_lookup() {
  local checkout="$1"
  (
    cd "$checkout"
    # shellcheck source=/dev/null
    TOUCHSTONE_RUN_SOURCE_ONLY=1 source "$TOUCHSTONE_SCRIPT"
    find_python_bin
  )
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Case 1: worktree → parent .venv resolved.
# ---------------------------------------------------------------------------
echo "==> Case 1: worktree resolves parent's .venv"
setup_worktree_fixture "$tmp/with-venv"
expected="$tmp/with-venv/parent/.venv/bin/python"

actual="$(run_touchstone_lookup "$tmp/with-venv/foo")"
assert_eq "touchstone worktree parent venv" "$expected" "$actual"

# ---------------------------------------------------------------------------
# Case 2: worktree without parent venv → clear error, never a silent fallback
# to whatever python3 happens to be on PATH.
# ---------------------------------------------------------------------------
echo "==> Case 2: worktree without parent venv errors clearly instead of guessing"
mkdir -p "$tmp/no-venv/parent/.git/worktrees/foo" "$tmp/no-venv/foo"
printf 'gitdir: %s\n' "$tmp/no-venv/parent/.git/worktrees/foo" >"$tmp/no-venv/foo/.git"

err_file="$tmp/touchstone.err"
if run_touchstone_lookup "$tmp/no-venv/foo" >"$tmp/touchstone.out" 2>"$err_file"; then
  fail "touchstone lookup should fail without any project venv"
fi
err="$(cat "$err_file")"
assert_contains "touchstone error" "$err" "ERROR: no project virtualenv found."
assert_contains "touchstone checkout tried" "$err" "Tried: $tmp/no-venv/foo/.venv/bin/python (this checkout)"
assert_contains "touchstone parent tried" "$err" "Tried: $tmp/no-venv/parent/.venv/bin/python (worktree parent)"

# ---------------------------------------------------------------------------
# Case 3: regular checkout with local .venv → returns the local venv, and the
# worktree branch does not fire (a real .git directory is not a gitfile).
# ---------------------------------------------------------------------------
echo "==> Case 3: regular checkout with local .venv"
mkdir -p "$tmp/local/.venv/bin"
printf '#!/usr/bin/env bash\n' >"$tmp/local/.venv/bin/python"
chmod +x "$tmp/local/.venv/bin/python"
# Real .git directory marks this as a non-worktree checkout.
mkdir -p "$tmp/local/.git"

actual="$(run_touchstone_lookup "$tmp/local")"
assert_eq "local checkout local venv" ".venv/bin/python" "$actual"

# ---------------------------------------------------------------------------
# Case 4: PYTEST_PYTHON overrides everything, and a broken override — absent
# (4a) or present-but-not-executable (4b) — is rejected instead of silently
# falling through to the venv.
# ---------------------------------------------------------------------------
echo "==> Case 4: PYTEST_PYTHON override wins, and a broken override fails closed"
mkdir -p "$tmp/override/bin" "$tmp/override/.venv/bin" "$tmp/override/.git"
printf '#!/usr/bin/env bash\n' >"$tmp/override/.venv/bin/python"
chmod +x "$tmp/override/.venv/bin/python"
printf '#!/usr/bin/env bash\n' >"$tmp/override/bin/python-override"
chmod +x "$tmp/override/bin/python-override"

actual="$(PYTEST_PYTHON="$tmp/override/bin/python-override" run_touchstone_lookup "$tmp/override")"
assert_eq "PYTEST_PYTHON override" "$tmp/override/bin/python-override" "$actual"

# 4a. An override pointing at nothing at all.
err_file="$tmp/override-missing.err"
if PYTEST_PYTHON="$tmp/override/bin/does-not-exist" \
  run_touchstone_lookup "$tmp/override" >"$tmp/override-missing.out" 2>"$err_file"; then
  fail "an absent PYTEST_PYTHON should fail rather than fall back to the venv"
fi
assert_contains "PYTEST_PYTHON absent error" "$(cat "$err_file")" \
  "ERROR: PYTEST_PYTHON is set but not executable:"

# 4b. An override that EXISTS but is not executable — a distinct rejection from
# 4a, and the one the case name claims. find_python_bin gates on `command -v`,
# which rejects both, so a fixture that only ever pointed at a missing path
# tested absence twice and left non-executability unproven (#737 round-2
# review). Assert the fixture shape first: without this the case silently
# degrades back into a second absence test the moment the path is wrong.
nonexec="$tmp/override/bin/python-nonexec"
printf '#!/usr/bin/env bash\n' >"$nonexec"
chmod 644 "$nonexec"
[ -f "$nonexec" ] || fail "fixture: $nonexec must exist to test non-executability"
if [ -x "$nonexec" ]; then
  fail "fixture: $nonexec must NOT be executable"
fi

err_file="$tmp/override-nonexec.err"
if PYTEST_PYTHON="$nonexec" \
  run_touchstone_lookup "$tmp/override" >"$tmp/override-nonexec.out" 2>"$err_file"; then
  fail "a non-executable PYTEST_PYTHON should fail rather than fall back to the venv"
fi
assert_contains "PYTEST_PYTHON non-executable error" "$(cat "$err_file")" \
  "ERROR: PYTEST_PYTHON is set but not executable: $nonexec"
# The venv is right there and readable; the point is that it was NOT used.
assert_eq "non-executable override does not fall back to the venv" "" "$(cat "$tmp/override-nonexec.out")"

echo "==> PASS: find_python_bin worktree-aware lookup (#171)"
