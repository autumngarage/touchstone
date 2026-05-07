#!/usr/bin/env bash
#
# tests/test-auto-project-sync.sh — touchstone CLI per-project auto-sync.
#
set -euo pipefail

# Hermeticity: clear inherited opt-out env vars so the test exercises the
# real default-on behavior. Without this, `TOUCHSTONE_NO_AUTO_UPDATE=1` set
# by an outer script (e.g., a pre-push hook caller) silently skips sync in
# cases that expect it to fire, producing confusing per-context failures.
unset TOUCHSTONE_NO_AUTO_UPDATE TOUCHSTONE_NO_AUTO_PROJECT_SYNC

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone"
TEST_DIR="$(mktemp -d -t touchstone-test-auto-project-sync.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
  CURRENT_ID="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
else
  CURRENT_ID="$(tr -d '[:space:]' <"$TOUCHSTONE_ROOT/VERSION")"
fi

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to contain '$needle'" >&2
    echo "  ---- file content ----" >&2
    sed 's/^/    /' "$file" >&2 || true
    echo "  ----------------------" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to NOT contain '$needle'" >&2
    echo "  ---- file content ----" >&2
    sed 's/^/    /' "$file" >&2 || true
    echo "  ----------------------" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_version_equals() {
  local project="$1" expected="$2"
  local actual
  actual="$(tr -d '[:space:]' <"$project/.touchstone-version")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: expected $project/.touchstone-version to be '$expected', got '$actual'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

run_touchstone() {
  local fake_home="$1"
  shift
  mkdir -p "$fake_home/.touchstone-state"
  date +%s >"$fake_home/.touchstone-state/last-update-check"
  HOME="$fake_home" \
    NO_COLOR=1 \
    TOUCHSTONE_STATE_DIR="$fake_home/.touchstone-state" \
    bash "$TOUCHSTONE_BIN" "$@"
}

make_project() {
  local project="$1" version="$2"
  mkdir -p "$project"
  git -C "$project" init -q
  git -C "$project" config user.name "Touchstone Test"
  git -C "$project" config user.email "touchstone@example.invalid"
  printf '%s\n' "$version" >"$project/.touchstone-version"
  printf 'test project\n' >"$project/README.md"
  git -C "$project" add README.md .touchstone-version
  git -C "$project" commit -q -m "test fixture"
}

echo "==> Test: auto-project-sync"
echo "    Test dir: $TEST_DIR"

echo ""
echo "--- drift + clean tree: sync runs, then subcommand proceeds ---"
CLEAN_HOME="$TEST_DIR/home-clean"
CLEAN_PROJECT="$TEST_DIR/project-clean"
make_project "$CLEAN_PROJECT" "0000000000000000000000000000000000000001"
CLEAN_OUT="$TEST_DIR/clean.out"
(cd "$CLEAN_PROJECT" && run_touchstone "$CLEAN_HOME" run validate) >"$CLEAN_OUT" 2>&1
assert_contains "$CLEAN_OUT" "auto-synced touchstone 0000000000000000000000000000000000000001 -> $CURRENT_ID"
assert_contains "$CLEAN_OUT" "generic project has no default 'lint' command"
assert_version_equals "$CLEAN_PROJECT" "$CURRENT_ID"
if ! git -C "$CLEAN_PROJECT" branch --show-current | grep -q '^chore/touchstone-'; then
  echo "FAIL: expected auto-sync to leave project on a chore/touchstone-* update branch" >&2
  ERRORS=$((ERRORS + 1))
fi

echo ""
echo "--- drift + dirty tree: warning, no sync, subcommand proceeds ---"
DIRTY_HOME="$TEST_DIR/home-dirty"
DIRTY_PROJECT="$TEST_DIR/project-dirty"
DIRTY_OLD="0000000000000000000000000000000000000002"
make_project "$DIRTY_PROJECT" "$DIRTY_OLD"
printf 'dirty\n' >>"$DIRTY_PROJECT/README.md"
DIRTY_OUT="$TEST_DIR/dirty.out"
(cd "$DIRTY_PROJECT" && run_touchstone "$DIRTY_HOME" run validate) >"$DIRTY_OUT" 2>&1
assert_contains "$DIRTY_OUT" "WARNING: touchstone auto-sync skipped for $DIRTY_PROJECT (working tree is dirty)."
assert_contains "$DIRTY_OUT" "generic project has no default 'lint' command"
assert_version_equals "$DIRTY_PROJECT" "$DIRTY_OLD"

echo ""
echo "--- no drift: no-op, subcommand proceeds ---"
CURRENT_HOME="$TEST_DIR/home-current"
CURRENT_PROJECT="$TEST_DIR/project-current"
make_project "$CURRENT_PROJECT" "$CURRENT_ID"
CURRENT_OUT="$TEST_DIR/current.out"
(cd "$CURRENT_PROJECT" && run_touchstone "$CURRENT_HOME" run validate) >"$CURRENT_OUT" 2>&1
assert_not_contains "$CURRENT_OUT" "auto-synced touchstone"
assert_contains "$CURRENT_OUT" "generic project has no default 'lint' command"
assert_version_equals "$CURRENT_PROJECT" "$CURRENT_ID"

echo ""
echo "--- TOUCHSTONE_NO_AUTO_PROJECT_SYNC=1: no-op on drift ---"
NO_PROJECT_SYNC_HOME="$TEST_DIR/home-no-project-sync"
NO_PROJECT_SYNC_PROJECT="$TEST_DIR/project-no-project-sync"
NO_PROJECT_SYNC_OLD="0000000000000000000000000000000000000003"
make_project "$NO_PROJECT_SYNC_PROJECT" "$NO_PROJECT_SYNC_OLD"
NO_PROJECT_SYNC_OUT="$TEST_DIR/no-project-sync.out"
(
  cd "$NO_PROJECT_SYNC_PROJECT"
  TOUCHSTONE_NO_AUTO_PROJECT_SYNC=1 run_touchstone "$NO_PROJECT_SYNC_HOME" run validate
) >"$NO_PROJECT_SYNC_OUT" 2>&1
assert_not_contains "$NO_PROJECT_SYNC_OUT" "auto-synced touchstone"
assert_version_equals "$NO_PROJECT_SYNC_PROJECT" "$NO_PROJECT_SYNC_OLD"

echo ""
echo "--- TOUCHSTONE_NO_AUTO_UPDATE=1: no-op on drift ---"
NO_AUTO_UPDATE_HOME="$TEST_DIR/home-no-auto-update"
NO_AUTO_UPDATE_PROJECT="$TEST_DIR/project-no-auto-update"
NO_AUTO_UPDATE_OLD="0000000000000000000000000000000000000004"
make_project "$NO_AUTO_UPDATE_PROJECT" "$NO_AUTO_UPDATE_OLD"
NO_AUTO_UPDATE_OUT="$TEST_DIR/no-auto-update.out"
(
  cd "$NO_AUTO_UPDATE_PROJECT"
  TOUCHSTONE_NO_AUTO_UPDATE=1 run_touchstone "$NO_AUTO_UPDATE_HOME" run validate
) >"$NO_AUTO_UPDATE_OUT" 2>&1
assert_not_contains "$NO_AUTO_UPDATE_OUT" "auto-synced touchstone"
assert_version_equals "$NO_AUTO_UPDATE_PROJECT" "$NO_AUTO_UPDATE_OLD"

echo ""
echo "--- non-touchstone project: no-op ---"
PLAIN_HOME="$TEST_DIR/home-plain"
PLAIN_PROJECT="$TEST_DIR/project-plain"
mkdir -p "$PLAIN_PROJECT"
git -C "$PLAIN_PROJECT" init -q
PLAIN_OUT="$TEST_DIR/plain.out"
(cd "$PLAIN_PROJECT" && run_touchstone "$PLAIN_HOME" run validate) >"$PLAIN_OUT" 2>&1
assert_not_contains "$PLAIN_OUT" "auto-synced touchstone"
assert_contains "$PLAIN_OUT" "generic project has no default 'lint' command"

echo ""
echo "--- touchstone source repo: self-sync is skipped ---"
# Capture the real touchstone lib path BEFORE we override TOUCHSTONE_ROOT for
# the subshell — `VAR=x bash -c '...' _ "$VAR/..."` would have the outer shell
# expand the second $VAR before the assignment takes effect (SC2097/SC2098).
REAL_TS_LIB="$TOUCHSTONE_ROOT/lib/auto-update.sh"
SELF_SYNC_HOME="$TEST_DIR/home-self-sync"
SELF_SYNC_PROJECT="$TEST_DIR/project-self-sync"
make_project "$SELF_SYNC_PROJECT" "0000000000000000000000000000000000000006"
printf '9.9.9\n' >"$SELF_SYNC_PROJECT/VERSION"
SELF_SYNC_OUT="$TEST_DIR/self-sync.out"
(
  cd "$SELF_SYNC_PROJECT"
  HOME="$SELF_SYNC_HOME" \
    NO_COLOR=1 \
    TOUCHSTONE_ROOT="$SELF_SYNC_PROJECT" \
    bash -c 'source "$1"; touchstone_auto_project_sync run validate' _ "$REAL_TS_LIB"
) >"$SELF_SYNC_OUT" 2>&1
assert_not_contains "$SELF_SYNC_OUT" "auto-synced touchstone"
assert_version_equals "$SELF_SYNC_PROJECT" "0000000000000000000000000000000000000006"

echo ""
echo "--- touchstone version/help: read-only commands do not sync ---"
VERSION_HOME="$TEST_DIR/home-version"
VERSION_PROJECT="$TEST_DIR/project-version"
VERSION_OLD="0000000000000000000000000000000000000005"
make_project "$VERSION_PROJECT" "$VERSION_OLD"
VERSION_OUT="$TEST_DIR/version.out"
(cd "$VERSION_PROJECT" && run_touchstone "$VERSION_HOME" version) >"$VERSION_OUT" 2>&1
assert_not_contains "$VERSION_OUT" "auto-synced touchstone"
assert_contains "$VERSION_OUT" "touchstone v"
assert_version_equals "$VERSION_PROJECT" "$VERSION_OLD"
LONG_VERSION_OUT="$TEST_DIR/long-version.out"
(cd "$VERSION_PROJECT" && run_touchstone "$VERSION_HOME" --version) >"$LONG_VERSION_OUT" 2>&1
assert_not_contains "$LONG_VERSION_OUT" "auto-synced touchstone"
assert_contains "$LONG_VERSION_OUT" "touchstone v"
assert_version_equals "$VERSION_PROJECT" "$VERSION_OLD"
HELP_OUT="$TEST_DIR/help.out"
(cd "$VERSION_PROJECT" && run_touchstone "$VERSION_HOME" --help) >"$HELP_OUT" 2>&1
assert_not_contains "$HELP_OUT" "auto-synced touchstone"
assert_contains "$HELP_OUT" "TOUCHSTONE_NO_AUTO_PROJECT_SYNC"
assert_version_equals "$VERSION_PROJECT" "$VERSION_OLD"

if [ -e "$TEST_DIR/home-clean/.touchstone-projects" ] \
  || [ -e "$TEST_DIR/home-dirty/.touchstone-projects" ] \
  || [ -e "$TEST_DIR/home-current/.touchstone-projects" ]; then
  echo "FAIL: auto-project-sync tests must not touch ~/.touchstone-projects" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -ne 0 ]; then
  echo ""
  echo "FAIL: $ERRORS auto-project-sync assertion(s) failed" >&2
  exit 1
fi

echo ""
echo "PASS: auto-project-sync"
