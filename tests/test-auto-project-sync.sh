#!/usr/bin/env bash
#
# tests/test-auto-project-sync.sh — touchstone CLI per-project auto-sync.
#
set -euo pipefail

# Hermeticity: clear inherited opt-out env vars so the test exercises the
# real default-on behavior. Without this, `TOUCHSTONE_NO_AUTO_UPDATE=1` set
# by an outer script (e.g., a pre-push hook caller) silently skips sync in
# cases that expect it to fire, producing confusing per-context failures.
unset TOUCHSTONE_NO_AUTO_UPDATE TOUCHSTONE_NO_AUTO_PROJECT_SYNC TOUCHSTONE_FORCE_OVERLAP TOUCHSTONE_NO_DRIFT_WARNING

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

# shellcheck source=lib/auto-update.sh
source "$TOUCHSTONE_ROOT/lib/auto-update.sh"

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
echo "--- drift + unrelated dirty tree: sync proceeds, subcommand proceeds ---"
DIRTY_HOME="$TEST_DIR/home-dirty"
DIRTY_PROJECT="$TEST_DIR/project-dirty"
DIRTY_OLD="0000000000000000000000000000000000000002"
make_project "$DIRTY_PROJECT" "$DIRTY_OLD"
printf 'dirty\n' >>"$DIRTY_PROJECT/README.md"
DIRTY_OUT="$TEST_DIR/dirty.out"
(cd "$DIRTY_PROJECT" && run_touchstone "$DIRTY_HOME" run validate) >"$DIRTY_OUT" 2>&1
assert_contains "$DIRTY_OUT" "Proceeding with sync past unrelated dirty paths: README.md"
assert_contains "$DIRTY_OUT" "auto-synced touchstone $DIRTY_OLD -> $CURRENT_ID"
assert_contains "$DIRTY_OUT" "generic project has no default 'lint' command"
assert_version_equals "$DIRTY_PROJECT" "$CURRENT_ID"

echo ""
echo "--- drift + overlapping dirty tree: warning, no sync, subcommand proceeds ---"
OVERLAP_HOME="$TEST_DIR/home-overlap"
OVERLAP_PROJECT="$TEST_DIR/project-overlap"
OVERLAP_OLD="0000000000000000000000000000000000000007"
make_project "$OVERLAP_PROJECT" "$OVERLAP_OLD"
mkdir -p "$OVERLAP_PROJECT/scripts"
printf 'dirty\n' >"$OVERLAP_PROJECT/scripts/touchstone-run.sh"
OVERLAP_OUT="$TEST_DIR/overlap.out"
(cd "$OVERLAP_PROJECT" && run_touchstone "$OVERLAP_HOME" run validate) >"$OVERLAP_OUT" 2>&1
assert_contains "$OVERLAP_OUT" "WARNING: touchstone auto-sync skipped for $OVERLAP_PROJECT (dirty paths overlap planned touchstone writes)."
assert_contains "$OVERLAP_OUT" "scripts/touchstone-run.sh"
assert_contains "$OVERLAP_OUT" "generic project has no default 'lint' command"
assert_version_equals "$OVERLAP_PROJECT" "$OVERLAP_OLD"
OVERLAP_SKIP_LOG="$OVERLAP_PROJECT/.git/touchstone/sync-skips.jsonl"
assert_contains "$OVERLAP_SKIP_LOG" '"reason":"dirty-overlap"'
assert_contains "$OVERLAP_SKIP_LOG" '"overlapping_paths":\["scripts/touchstone-run.sh"\]'

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
echo "--- --no-auto-sync: no-op on drift ---"
NO_AUTO_SYNC_FLAG_HOME="$TEST_DIR/home-no-auto-sync-flag"
NO_AUTO_SYNC_FLAG_PROJECT="$TEST_DIR/project-no-auto-sync-flag"
NO_AUTO_SYNC_FLAG_OLD="0000000000000000000000000000000000000009"
make_project "$NO_AUTO_SYNC_FLAG_PROJECT" "$NO_AUTO_SYNC_FLAG_OLD"
NO_AUTO_SYNC_FLAG_OUT="$TEST_DIR/no-auto-sync-flag.out"
(cd "$NO_AUTO_SYNC_FLAG_PROJECT" && run_touchstone "$NO_AUTO_SYNC_FLAG_HOME" --no-auto-sync run validate) >"$NO_AUTO_SYNC_FLAG_OUT" 2>&1
assert_not_contains "$NO_AUTO_SYNC_FLAG_OUT" "auto-synced touchstone"
assert_contains "$NO_AUTO_SYNC_FLAG_OUT" "generic project has no default 'lint' command"
assert_version_equals "$NO_AUTO_SYNC_FLAG_PROJECT" "$NO_AUTO_SYNC_FLAG_OLD"

echo ""
echo "--- .touchstone-config sync_auto=false: no-op on drift ---"
CONFIG_OFF_HOME="$TEST_DIR/home-config-off"
CONFIG_OFF_PROJECT="$TEST_DIR/project-config-off"
CONFIG_OFF_OLD="0000000000000000000000000000000000000010"
make_project "$CONFIG_OFF_PROJECT" "$CONFIG_OFF_OLD"
printf 'sync_auto=false\n' >"$CONFIG_OFF_PROJECT/.touchstone-config"
git -C "$CONFIG_OFF_PROJECT" add .touchstone-config && git -C "$CONFIG_OFF_PROJECT" commit -q -m "disable auto sync"
CONFIG_OFF_OUT="$TEST_DIR/config-off.out"
(cd "$CONFIG_OFF_PROJECT" && run_touchstone "$CONFIG_OFF_HOME" run validate) >"$CONFIG_OFF_OUT" 2>&1
assert_not_contains "$CONFIG_OFF_OUT" "auto-synced touchstone"
assert_contains "$CONFIG_OFF_OUT" "generic project has no default 'lint' command"
assert_version_equals "$CONFIG_OFF_PROJECT" "$CONFIG_OFF_OLD"

echo ""
echo "--- [sync] auto=false: no-op on drift ---"
CONFIG_SECTION_OFF_HOME="$TEST_DIR/home-config-section-off"
CONFIG_SECTION_OFF_PROJECT="$TEST_DIR/project-config-section-off"
CONFIG_SECTION_OFF_OLD="0000000000000000000000000000000000000011"
make_project "$CONFIG_SECTION_OFF_PROJECT" "$CONFIG_SECTION_OFF_OLD"
{
  printf '[sync]\n'
  printf 'auto = false\n'
} >"$CONFIG_SECTION_OFF_PROJECT/.touchstone-config"
git -C "$CONFIG_SECTION_OFF_PROJECT" add .touchstone-config && git -C "$CONFIG_SECTION_OFF_PROJECT" commit -q -m "disable auto sync"
CONFIG_SECTION_OFF_OUT="$TEST_DIR/config-section-off.out"
(cd "$CONFIG_SECTION_OFF_PROJECT" && run_touchstone "$CONFIG_SECTION_OFF_HOME" run validate) >"$CONFIG_SECTION_OFF_OUT" 2>&1
assert_not_contains "$CONFIG_SECTION_OFF_OUT" "auto-synced touchstone"
assert_contains "$CONFIG_SECTION_OFF_OUT" "generic project has no default 'lint' command"
assert_version_equals "$CONFIG_SECTION_OFF_PROJECT" "$CONFIG_SECTION_OFF_OLD"

echo ""
echo "--- semver patch drift does not auto-sync, minor drift does ---"
if touchstone_auto_project_sync_should_sync "2.11.9" "2.11.10"; then
  echo "FAIL: patch-only semver drift should not auto-sync" >&2
  ERRORS=$((ERRORS + 1))
fi
if ! touchstone_auto_project_sync_should_sync "2.10.9" "2.11.0"; then
  echo "FAIL: minor semver drift should auto-sync" >&2
  ERRORS=$((ERRORS + 1))
fi
if ! touchstone_auto_project_sync_should_sync "0000000000000000000000000000000000000012" "$CURRENT_ID"; then
  echo "FAIL: non-semver source-checkout drift should auto-sync" >&2
  ERRORS=$((ERRORS + 1))
fi

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

echo ""
echo "--- drift warning surfaces after repeated skips ---"
DRIFT_HOME="$TEST_DIR/home-drift-warning"
DRIFT_PROJECT="$TEST_DIR/project-drift-warning"
DRIFT_OLD="0000000000000000000000000000000000000008"
make_project "$DRIFT_PROJECT" "$DRIFT_OLD"
mkdir -p "$DRIFT_PROJECT/.git/touchstone"
for _ in 1 2 3 4; do
  printf '{"timestamp":"%s","from_version":"%s","to_version":"%s","reason":"dirty-overlap","overlapping_paths":["scripts/touchstone-run.sh"],"command":"touchstone run"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$DRIFT_OLD" "$CURRENT_ID" >>"$DRIFT_PROJECT/.git/touchstone/sync-skips.jsonl"
done
DRIFT_OUT="$TEST_DIR/drift-warning.out"
(cd "$DRIFT_PROJECT" && run_touchstone "$DRIFT_HOME" version) >"$DRIFT_OUT" 2>&1
assert_contains "$DRIFT_OUT" "\[touchstone drift\] project at $DRIFT_OLD, current is $CURRENT_ID"
assert_contains "$DRIFT_OUT" "4 sync attempts skipped"
assert_contains "$DRIFT_OUT" "dirty-overlap on scripts/touchstone-run.sh"

echo ""
echo "--- TOUCHSTONE_NO_DRIFT_WARNING=1 suppresses drift warning ---"
NO_DRIFT_WARNING_HOME="$TEST_DIR/home-no-drift-warning"
NO_DRIFT_WARNING_OUT="$TEST_DIR/no-drift-warning.out"
(
  cd "$DRIFT_PROJECT"
  TOUCHSTONE_NO_DRIFT_WARNING=1 run_touchstone "$NO_DRIFT_WARNING_HOME" version
) >"$NO_DRIFT_WARNING_OUT" 2>&1
assert_not_contains "$NO_DRIFT_WARNING_OUT" "\[touchstone drift\]"

echo ""
echo "--- no drift and no skips: no drift warning ---"
NO_WARNING_HOME="$TEST_DIR/home-no-warning"
NO_WARNING_PROJECT="$TEST_DIR/project-no-warning"
make_project "$NO_WARNING_PROJECT" "$CURRENT_ID"
NO_WARNING_OUT="$TEST_DIR/no-warning.out"
(cd "$NO_WARNING_PROJECT" && run_touchstone "$NO_WARNING_HOME" version) >"$NO_WARNING_OUT" 2>&1
assert_not_contains "$NO_WARNING_OUT" "\[touchstone drift\]"

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
