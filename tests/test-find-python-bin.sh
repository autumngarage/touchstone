#!/usr/bin/env bash
#
# tests/test-find-python-bin.sh — Issue #171: scripts/touchstone-run.sh
# and scripts/run-pytest-in-venv.sh must resolve the parent repo's
# .venv/bin/python when run from a git worktree, and must only fall back
# to PATH when the candidate is Python 3.12 with pytest installed.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOUCHSTONE_SCRIPT="$REPO_ROOT/scripts/touchstone-run.sh"
PYTEST_SCRIPT="$REPO_ROOT/scripts/run-pytest-in-venv.sh"

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

write_fake_python() {
  local path="$1" version_check_exit="${2:-0}" import_pytest_exit="${3:-0}"

  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && [[ "\$2" == *"sys.version_info"* ]]; then
  exit $version_check_exit
fi
if [ "\$1" = "-c" ] && [ "\$2" = "import pytest" ]; then
  exit $import_pytest_exit
fi
exit 42
EOF
  chmod +x "$path"
}

run_touchstone_lookup() {
  local worktree="$1"
  (
    cd "$worktree"
    # shellcheck source=/dev/null
    TOUCHSTONE_RUN_SOURCE_ONLY=1 source "$TOUCHSTONE_SCRIPT"
    find_python_bin
  )
}

run_pytest_lookup() {
  local worktree="$1"
  (
    cd "$worktree"
    # shellcheck source=/dev/null
    RUN_PYTEST_IN_VENV_SOURCE_ONLY=1 source "$PYTEST_SCRIPT"
    find_python
  )
}

run_local_lookup() {
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

actual="$(run_pytest_lookup "$tmp/with-venv/foo")"
assert_eq "pytest helper worktree parent venv" "$expected" "$actual"

# ---------------------------------------------------------------------------
# Case 2: worktree without parent venv → clear error when PATH fallback is unsafe.
# ---------------------------------------------------------------------------
echo "==> Case 2: worktree without parent venv errors clearly when PATH fallback is unsafe"
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

err_file="$tmp/pytest.err"
if run_pytest_lookup "$tmp/no-venv/foo" >"$tmp/pytest.out" 2>"$err_file"; then
  fail "pytest helper lookup should fail without any project venv"
fi
err="$(cat "$err_file")"
assert_contains "pytest error" "$err" "ERROR: no project virtualenv found."
assert_contains "pytest checkout tried" "$err" "Tried: $tmp/no-venv/foo/.venv/bin/python (this checkout)"
assert_contains "pytest parent tried" "$err" "Tried: $tmp/no-venv/parent/.venv/bin/python (worktree parent)"
assert_contains "pytest path fallback tried" "$err" "Tried: Python 3.12 on PATH with pytest installed"

# ---------------------------------------------------------------------------
# Case 3: regular checkout with local .venv → returns local venv.
# ---------------------------------------------------------------------------
echo "==> Case 3: regular checkout with local .venv"
mkdir -p "$tmp/local/.venv/bin"
printf '#!/usr/bin/env bash\n' >"$tmp/local/.venv/bin/python"
chmod +x "$tmp/local/.venv/bin/python"
# Real .git directory marks this as a non-worktree checkout.
mkdir -p "$tmp/local/.git"

actual="$(run_local_lookup "$tmp/local")"
assert_eq "local checkout local venv" ".venv/bin/python" "$actual"

# ---------------------------------------------------------------------------
# Case 4: no venv → pytest helper falls back to Python 3.12 on PATH only when
# pytest is importable.
# ---------------------------------------------------------------------------
echo "==> Case 4: pytest helper falls back to PATH Python only when safe"
mkdir -p "$tmp/path-fallback"
write_fake_python "$tmp/path-fallback/bin/python3" 0 0
actual="$(PATH="$tmp/path-fallback/bin:$PATH" run_pytest_lookup "$tmp/path-fallback")"
assert_eq "pytest helper PATH fallback" "$tmp/path-fallback/bin/python3" "$actual"

write_fake_python "$tmp/path-fallback/bin/python3" 0 1
err_file="$tmp/path-fallback-no-pytest.err"
if PATH="$tmp/path-fallback/bin:$PATH" run_pytest_lookup "$tmp/path-fallback" >"$tmp/path-fallback-no-pytest.out" 2>"$err_file"; then
  fail "pytest helper lookup should reject PATH Python without pytest"
fi
assert_contains "pytest path missing pytest" "$(cat "$err_file")" "Python 3.12 on PATH with pytest installed"

write_fake_python "$tmp/path-fallback/bin/python3" 1 0
err_file="$tmp/path-fallback-wrong-version.err"
if PATH="$tmp/path-fallback/bin:$PATH" run_pytest_lookup "$tmp/path-fallback" >"$tmp/path-fallback-wrong-version.out" 2>"$err_file"; then
  fail "pytest helper lookup should reject PATH Python with wrong version"
fi
assert_contains "pytest path wrong version" "$(cat "$err_file")" "Python 3.12 on PATH with pytest installed"

# ---------------------------------------------------------------------------
# Case 5: stale project venv and explicit PYTEST_PYTHON with wrong version are
# rejected instead of silently running tests under the wrong interpreter.
# ---------------------------------------------------------------------------
echo "==> Case 5: pytest helper rejects stale local and explicit Python"
mkdir -p "$tmp/stale-venv/.venv/bin"
write_fake_python "$tmp/stale-venv/.venv/bin/python" 1 0
err_file="$tmp/stale-venv.err"
if run_pytest_lookup "$tmp/stale-venv" >"$tmp/stale-venv.out" 2>"$err_file"; then
  fail "pytest helper lookup should reject stale local venv"
fi
assert_contains "pytest stale venv" "$(cat "$err_file")" "project virtualenv is not Python 3.12"

mkdir -p "$tmp/explicit-python"
write_fake_python "$tmp/explicit-python/bin/python3" 1 0
err_file="$tmp/explicit-python.err"
if PYTEST_PYTHON="$tmp/explicit-python/bin/python3" run_pytest_lookup "$tmp/explicit-python" >"$tmp/explicit-python.out" 2>"$err_file"; then
  fail "pytest helper lookup should reject PYTEST_PYTHON with wrong version"
fi
assert_contains "pytest explicit wrong version" "$(cat "$err_file")" "PYTEST_PYTHON must point to Python 3.12"

echo "==> PASS: find_python_bin worktree-aware lookup (#171)"
