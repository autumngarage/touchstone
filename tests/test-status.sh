#!/usr/bin/env bash
#
# tests/test-status.sh — regression test for `touchstone status` and
# `touchstone status --all`.
#
# Covers:
#   - status --all walks ~/.touchstone-projects and renders a row per project
#   - "current" / behind / "(missing)" / "(no manifest)" branches all render
#   - bare `status` from inside a project prints the per-project block
#   - bare `status` from a tempdir without .touchstone-version exits nonzero
#   - empty/missing registry prints "no registered projects" and exits 0
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone"
TEST_DIR="$(mktemp -d -t touchstone-test-status.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

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
    ERRORS=$((ERRORS + 1))
  fi
}

# Run touchstone with HOME pointed at a tempdir registry. NO_COLOR keeps the
# output ANSI-free so grep assertions don't trip over escapes.
run_touchstone() {
  local fake_home="$1"
  shift
  HOME="$fake_home" \
    NO_COLOR=1 \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" "$@"
}

CURRENT_VERSION="$(tr -d '[:space:]' <"$TOUCHSTONE_ROOT/VERSION")"

echo "==> Test: touchstone status / status --all"
echo "    Test dir: $TEST_DIR"

# --------------------------------------------------------------------------
# Setup: build a synthetic HOME with a registry pointing at three fake
# projects and one nonexistent path.
# --------------------------------------------------------------------------
FAKE_HOME="$TEST_DIR/home"
mkdir -p "$FAKE_HOME"

CURRENT_PROJECT="$TEST_DIR/proj-current"
BEHIND_PROJECT="$TEST_DIR/proj-behind"
NO_MANIFEST_PROJECT="$TEST_DIR/proj-no-manifest"
MISSING_PROJECT="$TEST_DIR/proj-missing" # never created

mkdir -p "$CURRENT_PROJECT" "$BEHIND_PROJECT" "$NO_MANIFEST_PROJECT"

# proj-current: version matches the touchstone HEAD (VERSION string, since
# the brew-install path uses that as the id when there's no .git directory —
# which is also the worktree path we're running from).
printf '%s\n' "$CURRENT_VERSION" >"$CURRENT_PROJECT/.touchstone-version"

# proj-behind: arbitrary GC'd-style id that isn't reachable in touchstone's
# git history. The behind computation must report "?" rather than crash.
printf '%s\n' "0000000000000000000000000000000000000abc" >"$BEHIND_PROJECT/.touchstone-version"

# proj-no-manifest: directory exists but has no .touchstone-version. The
# table must render "(no manifest)" without aborting the walk.
# (no file written intentionally)

# Registry includes all four — current, behind, no-manifest, missing path.
{
  printf '%s\n' "$CURRENT_PROJECT"
  printf '%s\n' "$BEHIND_PROJECT"
  printf '%s\n' "$NO_MANIFEST_PROJECT"
  printf '%s\n' "$MISSING_PROJECT"
} >"$FAKE_HOME/.touchstone-projects"

# --------------------------------------------------------------------------
# Test 1: `touchstone status --all` renders a row per registry entry
# --------------------------------------------------------------------------
echo ""
echo "--- Test 1: status --all ---"

ALL_OUT="$TEST_DIR/all.out"
run_touchstone "$FAKE_HOME" status --all >"$ALL_OUT" 2>&1

assert_contains "$ALL_OUT" "PROJECT"
assert_contains "$ALL_OUT" "VERSION"
assert_contains "$ALL_OUT" "BEHIND"
assert_contains "$ALL_OUT" "AGE"

# All three real projects show up by their basename (path may be tildefied
# or absolute depending on whether HOME prefix matched).
assert_contains "$ALL_OUT" "proj-current"
assert_contains "$ALL_OUT" "proj-behind"
assert_contains "$ALL_OUT" "proj-no-manifest"
assert_contains "$ALL_OUT" "proj-missing"

# proj-current: version column shows the touchstone version, behind=current.
assert_contains "$ALL_OUT" "current"

# proj-behind: behind=? because the recorded id isn't in touchstone history.
# (The literal "?" appears in the AGE/BEHIND cells for unresolvable rows.)
assert_contains "$ALL_OUT" "proj-behind.* ?"

# proj-no-manifest: literal "(no manifest)" appears for the missing-file row.
assert_contains "$ALL_OUT" "(no manifest)"

# proj-missing: literal "(missing)" appears for the nonexistent path row.
assert_contains "$ALL_OUT" "(missing)"

# Footer tally — counts the four registered rows.
assert_contains "$ALL_OUT" "4 projects total"

# --------------------------------------------------------------------------
# Test 2: bare `touchstone status` from inside a project prints the block
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2: status from inside a project ---"

PROJECT_OUT="$TEST_DIR/project.out"
# Capture the exit code instead of letting `set -e` kill the script. A bare
# invocation here dies with no output at all, which in CI reads as "the file
# failed" with nothing to act on — observed on ubuntu-latest, where the run
# ended at this line and reported nothing.
PROJECT_EXIT=0
(cd "$CURRENT_PROJECT" && run_touchstone "$FAKE_HOME" status) >"$PROJECT_OUT" 2>&1 \
  || PROJECT_EXIT=$?
if [ "$PROJECT_EXIT" -ne 0 ]; then
  echo "FAIL: 'touchstone status' inside a project exited $PROJECT_EXIT" >&2
  echo "  ---- output ----" >&2
  sed 's/^/    /' "$PROJECT_OUT" >&2 || true
  echo "  ----------------" >&2
  ERRORS=$((ERRORS + 1))
fi

assert_contains "$PROJECT_OUT" "^project: *${CURRENT_PROJECT}"
assert_contains "$PROJECT_OUT" "^touchstone: *${CURRENT_VERSION}"
assert_contains "$PROJECT_OUT" "^latest: *${CURRENT_VERSION} (current)"
assert_contains "$PROJECT_OUT" "^last update: *"
assert_contains "$PROJECT_OUT" "^workflow scripts: project-local copies from .touchstone-manifest"
assert_contains "$PROJECT_OUT" "^script runner: *touchstone run-script"

# --------------------------------------------------------------------------
# Test 3: bare `touchstone status` in a non-touchstone dir exits nonzero
# --------------------------------------------------------------------------
echo ""
echo "--- Test 3: status in non-touchstone dir exits nonzero ---"

NON_PROJECT="$TEST_DIR/not-a-project"
mkdir -p "$NON_PROJECT"
NOT_OUT="$TEST_DIR/not.out"

set +e
(cd "$NON_PROJECT" && run_touchstone "$FAKE_HOME" status) >"$NOT_OUT" 2>&1
NOT_EXIT=$?
set -e

if [ "$NOT_EXIT" -eq 0 ]; then
  echo "FAIL: status in a non-touchstone dir should exit nonzero (got 0)" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$NOT_OUT" "not a touchstone project"

# --------------------------------------------------------------------------
# Test 4: empty / missing registry prints "no registered projects" and exit 0
# --------------------------------------------------------------------------
echo ""
echo "--- Test 4: status --all with empty registry ---"

EMPTY_HOME="$TEST_DIR/empty-home"
mkdir -p "$EMPTY_HOME"
# No .touchstone-projects file at all.

EMPTY_OUT="$TEST_DIR/empty.out"
set +e
run_touchstone "$EMPTY_HOME" status --all >"$EMPTY_OUT" 2>&1
EMPTY_EXIT=$?
set -e

if [ "$EMPTY_EXIT" -ne 0 ]; then
  echo "FAIL: status --all with empty registry should exit 0 (got $EMPTY_EXIT)" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$EMPTY_OUT" "no registered projects"

# --------------------------------------------------------------------------
# Test 5: registry exists but is empty — same "no registered projects" path
# --------------------------------------------------------------------------
echo ""
echo "--- Test 5: status --all with zero-byte registry ---"

EMPTY_FILE_HOME="$TEST_DIR/empty-file-home"
mkdir -p "$EMPTY_FILE_HOME"
: >"$EMPTY_FILE_HOME/.touchstone-projects"

EMPTY_FILE_OUT="$TEST_DIR/empty-file.out"
set +e
run_touchstone "$EMPTY_FILE_HOME" status --all >"$EMPTY_FILE_OUT" 2>&1
EMPTY_FILE_EXIT=$?
set -e

if [ "$EMPTY_FILE_EXIT" -ne 0 ]; then
  echo "FAIL: status --all with zero-byte registry should exit 0 (got $EMPTY_FILE_EXIT)" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$EMPTY_FILE_OUT" "no registered projects"

# --------------------------------------------------------------------------
# Test 6: registry with comments and blank lines is tolerated
# --------------------------------------------------------------------------
echo ""
echo "--- Test 6: registry with comments and blank lines ---"

COMMENT_HOME="$TEST_DIR/comment-home"
mkdir -p "$COMMENT_HOME"
{
  printf '# leading comment\n'
  printf '\n'
  printf '%s\n' "$CURRENT_PROJECT"
  printf '   \n'
  printf '# trailing comment\n'
} >"$COMMENT_HOME/.touchstone-projects"

COMMENT_OUT="$TEST_DIR/comment.out"
run_touchstone "$COMMENT_HOME" status --all >"$COMMENT_OUT" 2>&1

assert_contains "$COMMENT_OUT" "proj-current"
assert_contains "$COMMENT_OUT" "1 projects total"
assert_not_contains "$COMMENT_OUT" "leading comment"

# --------------------------------------------------------------------------
# Test 7: status --json exposes drift and capability state for callers
# --------------------------------------------------------------------------
echo ""
echo "--- Test 7: status --json project capability state ---"

CURRENT_JSON_OUT="$TEST_DIR/current-json.out"
(cd "$CURRENT_PROJECT" && run_touchstone "$FAKE_HOME" status --json) >"$CURRENT_JSON_OUT" 2>&1

assert_contains "$CURRENT_JSON_OUT" '"installed_touchstone"'
assert_contains "$CURRENT_JSON_OUT" '"project_touchstone"'
assert_contains "$CURRENT_JSON_OUT" '"drift"'
assert_contains "$CURRENT_JSON_OUT" '"workflow_scripts"'
assert_contains "$CURRENT_JSON_OUT" '"implementation": "project-local-copy"'
assert_contains "$CURRENT_JSON_OUT" '"pinned_shim_runner": "touchstone run-script"'
assert_contains "$CURRENT_JSON_OUT" '"state": "up_to_date"'
assert_contains "$CURRENT_JSON_OUT" '"worktree-lifecycle"'
assert_contains "$CURRENT_JSON_OUT" '"installed_state": "supported"'
assert_contains "$CURRENT_JSON_OUT" '"project_state": "available"'

PARENT_GIT_INSTALL_ROOT="$TEST_DIR/homebrew/Cellar/touchstone/$CURRENT_VERSION/libexec"
mkdir -p "$PARENT_GIT_INSTALL_ROOT"
git -C "$TEST_DIR/homebrew" init >/dev/null 2>&1
git -C "$TEST_DIR/homebrew" config user.name "Touchstone Test"
git -C "$TEST_DIR/homebrew" config user.email "touchstone@example.com"
printf 'parent git repo\n' >"$TEST_DIR/homebrew/README.md"
git -C "$TEST_DIR/homebrew" add README.md
git -C "$TEST_DIR/homebrew" commit -m "parent repo" >/dev/null 2>&1
cp -R "$TOUCHSTONE_ROOT/bin" "$PARENT_GIT_INSTALL_ROOT/bin"
cp -R "$TOUCHSTONE_ROOT/lib" "$PARENT_GIT_INSTALL_ROOT/lib"
cp "$TOUCHSTONE_ROOT/VERSION" "$PARENT_GIT_INSTALL_ROOT/VERSION"

PARENT_GIT_JSON_OUT="$TEST_DIR/parent-git-json.out"
(
  cd "$CURRENT_PROJECT"
  HOME="$FAKE_HOME" \
    NO_COLOR=1 \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$PARENT_GIT_INSTALL_ROOT/bin/touchstone" status --json
) >"$PARENT_GIT_JSON_OUT" 2>&1

assert_contains "$PARENT_GIT_JSON_OUT" "\"id\": \"$CURRENT_VERSION\""
assert_contains "$PARENT_GIT_JSON_OUT" '"state": "up_to_date"'
assert_contains "$PARENT_GIT_JSON_OUT" '"installed_state": "supported"'
assert_not_contains "$PARENT_GIT_JSON_OUT" "installed_cli_too_old"

OLD_CAPABILITY_PROJECT="$TEST_DIR/proj-old-capability"
mkdir -p "$OLD_CAPABILITY_PROJECT"
OLD_WORKTREE_BOUNDARY_ID="$(git -C "$TOUCHSTONE_ROOT" rev-parse d596930^)"
printf '%s\n' "$OLD_WORKTREE_BOUNDARY_ID" >"$OLD_CAPABILITY_PROJECT/.touchstone-version"

OLD_JSON_OUT="$TEST_DIR/old-json.out"
(cd "$OLD_CAPABILITY_PROJECT" && run_touchstone "$FAKE_HOME" status --json) >"$OLD_JSON_OUT" 2>&1

assert_contains "$OLD_JSON_OUT" '"state": "project_files_outdated"'
assert_contains "$OLD_JSON_OUT" '"name": "worktree-lifecycle"'
assert_contains "$OLD_JSON_OUT" '"project_state": "project_files_too_old"'
assert_contains "$OLD_JSON_OUT" '"remediation": "touchstone update"'

# --------------------------------------------------------------------------
# Test 8: doctor --project --require-capability fails on project-file drift
# --------------------------------------------------------------------------
echo ""
echo "--- Test 8: doctor required capability gates old project files ---"

REQUIRE_OUT="$TEST_DIR/require-capability.out"
set +e
(cd "$OLD_CAPABILITY_PROJECT" && run_touchstone "$FAKE_HOME" doctor --project --require-capability worktree-lifecycle) >"$REQUIRE_OUT" 2>&1
REQUIRE_EXIT=$?
set -e

if [ "$REQUIRE_EXIT" -eq 0 ]; then
  echo "FAIL: required capability should fail when project files predate it" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$REQUIRE_OUT" "Project Touchstone files are too old for capability 'worktree-lifecycle'"
assert_contains "$REQUIRE_OUT" "touchstone update"

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all assertions passed"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
