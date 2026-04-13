#!/usr/bin/env bash
#
# tests/test-update.sh — verify update-project.sh handles updates correctly.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t toolkit-test-update.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: update an existing project"
echo "    Test dir: $TEST_DIR/test-project"

ERRORS=0

assert_exists() {
  if [ ! -e "$1" ]; then
    echo "FAIL: expected $1 to exist" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_exists() {
  if [ -e "$1" ]; then
    echo "FAIL: expected $1 to NOT exist" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_contains() {
  if ! grep -q "$2" "$1" 2>/dev/null; then
    echo "FAIL: expected $1 to contain '$2'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_contains() {
  if grep -q "$2" "$1" 2>/dev/null; then
    echo "FAIL: expected $1 to NOT contain '$2'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

configure_git() {
  local repo="$1"
  git -C "$repo" config user.email "toolkit-test@example.com"
  git -C "$repo" config user.name "Toolkit Test"
}

commit_all() {
  local repo="$1"
  local message="$2"
  git -C "$repo" add -A
  git -C "$repo" commit --no-verify -m "$message" >/dev/null
}

PROJECT="$TEST_DIR/test-project"

# --------------------------------------------------------------------------
# Setup: bootstrap a project and commit the initial state.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 1: Bootstrap ---"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$PROJECT" --no-register
configure_git "$PROJECT"
commit_all "$PROJECT" "initial toolkit project"

BASE_BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)"
INITIAL_SHA="$(cat "$PROJECT/.toolkit-version" | tr -d '[:space:]')"
echo "    Initial .toolkit-version: $INITIAL_SHA"

# --------------------------------------------------------------------------
# Test 1: update with no toolkit changes -> "already up to date"
# --------------------------------------------------------------------------
echo ""
echo "--- Step 2: Update with no changes (should report up to date) ---"
(cd "$PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-1.txt"

if grep -q "Already up to date" "$TEST_DIR/update-output-1.txt"; then
  echo "    PASS: correctly reported up to date"
else
  echo "    FAIL: did not report up to date" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)" != "$BASE_BRANCH" ]; then
  echo "FAIL: up-to-date update should not create or switch branches" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 2: committed local toolkit-owned changes update on a review branch.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3: Modify a toolkit-owned file, then update ---"

echo "# locally modified" >> "$PROJECT/principles/engineering-principles.md"
rm "$PROJECT/scripts/toolkit-run.sh"
echo "0000000000000000000000000000000000000000" > "$PROJECT/.toolkit-version"
commit_all "$PROJECT" "simulate old toolkit state"

(cd "$PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-2.txt"

UPDATE_BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)"
if [ "$UPDATE_BRANCH" = "$BASE_BRANCH" ]; then
  echo "FAIL: update did not switch to a chore/toolkit branch" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/update-output-2.txt" 'Creating update branch: chore/toolkit-'
assert_contains "$TEST_DIR/update-output-2.txt" 'Committed: chore: update toolkit to'
assert_contains "$TEST_DIR/update-output-2.txt" 'bash scripts/open-pr.sh'
assert_exists "$PROJECT/scripts/toolkit-run.sh"
assert_exists "$PROJECT/.toolkit-manifest"
assert_contains "$PROJECT/.toolkit-manifest" '^scripts/toolkit-run.sh$'
assert_not_exists "$PROJECT/principles/engineering-principles.md.bak"

if find "$PROJECT" -name '*.bak' -print | grep -q .; then
  echo "FAIL: update should not create .bak files" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "    PASS: update did not create .bak files"
fi

if diff -q "$TOOLKIT_ROOT/principles/engineering-principles.md" "$PROJECT/principles/engineering-principles.md" >/dev/null 2>&1; then
  echo "    PASS: file was updated to toolkit version"
else
  echo "    FAIL: file does not match toolkit version" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$PROJECT" show HEAD^:principles/engineering-principles.md | grep -q "locally modified"; then
  echo "    PASS: previous committed state remains available via git"
else
  echo "    FAIL: previous state was not reviewable in git history" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$(git -C "$PROJECT" status --porcelain)" ]; then
  echo "FAIL: update should leave a clean worktree after committing" >&2
  git -C "$PROJECT" status --short >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$PROJECT" ls-files --error-unmatch .toolkit-version >/dev/null 2>&1; then
  echo "    PASS: .toolkit-version is tracked in the update commit"
else
  echo "FAIL: expected .toolkit-version to be tracked" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 3: project-owned files are NOT touched.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4: Verify project-owned files are untouched ---"

echo "# my project context" >> "$PROJECT/CLAUDE.md"
echo "0000000000000000000000000000000000000001" > "$PROJECT/.toolkit-version"
commit_all "$PROJECT" "simulate project-owned customization"
CLAUDE_CHECKSUM="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"

(cd "$PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

CLAUDE_CHECKSUM_AFTER="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"

if [ "$CLAUDE_CHECKSUM" = "$CLAUDE_CHECKSUM_AFTER" ]; then
  echo "    PASS: CLAUDE.md was not modified by update"
else
  echo "    FAIL: CLAUDE.md was modified by update" >&2
  ERRORS=$((ERRORS + 1))
fi

assert_not_exists "$PROJECT/CLAUDE.md.bak"

# --------------------------------------------------------------------------
# Test 4: dirty worktrees fail before branching or patching.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 5: Dirty worktree is refused ---"

DIRTY_PROJECT="$TEST_DIR/dirty-project"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$DIRTY_PROJECT" --no-register >/dev/null
configure_git "$DIRTY_PROJECT"
commit_all "$DIRTY_PROJECT" "initial dirty test project"
echo "0000000000000000000000000000000000000002" > "$DIRTY_PROJECT/.toolkit-version"
commit_all "$DIRTY_PROJECT" "simulate old dirty test project"
DIRTY_BRANCH="$(git -C "$DIRTY_PROJECT" rev-parse --abbrev-ref HEAD)"
echo "# uncommitted change" >> "$DIRTY_PROJECT/scripts/open-pr.sh"

if (cd "$DIRTY_PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/dirty-output.txt" 2>&1; then
  echo "FAIL: expected dirty update to fail" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/dirty-output.txt" 'Working tree is dirty'
fi

if [ "$(git -C "$DIRTY_PROJECT" rev-parse --abbrev-ref HEAD)" != "$DIRTY_BRANCH" ]; then
  echo "FAIL: dirty update should not switch branches" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 5: failed updates restore ignored legacy metadata.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 6: Failed update rolls back legacy metadata ---"

ROLLBACK_PROJECT="$TEST_DIR/rollback-project"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$ROLLBACK_PROJECT" --no-register >/dev/null
configure_git "$ROLLBACK_PROJECT"
commit_all "$ROLLBACK_PROJECT" "initial rollback test project"
printf '\n.toolkit-version\n.toolkit-manifest\n' >> "$ROLLBACK_PROJECT/.gitignore"
git -C "$ROLLBACK_PROJECT" rm --cached .toolkit-version .toolkit-manifest >/dev/null
commit_all "$ROLLBACK_PROJECT" "simulate legacy ignored toolkit metadata"
echo "legacy-old-version" > "$ROLLBACK_PROJECT/.toolkit-version"
rm "$ROLLBACK_PROJECT/.toolkit-manifest"
mkdir "$ROLLBACK_PROJECT/.toolkit-manifest"
ROLLBACK_BRANCH="$(git -C "$ROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)"

if (cd "$ROLLBACK_PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/rollback-output.txt" 2>&1; then
  echo "FAIL: expected rollback update to fail on legacy manifest directory" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/rollback-output.txt" 'Update failed; rolling back'
fi

if [ "$(git -C "$ROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)" != "$ROLLBACK_BRANCH" ]; then
  echo "FAIL: rollback should return to the original branch" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(cat "$ROLLBACK_PROJECT/.toolkit-version")" = "legacy-old-version" ]; then
  echo "    PASS: rollback restored ignored .toolkit-version"
else
  echo "FAIL: rollback did not restore ignored .toolkit-version" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$ROLLBACK_PROJECT" branch --list 'chore/toolkit-*' | grep -q .; then
  echo "FAIL: rollback should delete the failed update branch" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 6: check mode and ordinary commands do not print the old startup nag.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 7: Check mode and no broad startup nag ---"

CHECK_PROJECT="$TEST_DIR/check-project"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$CHECK_PROJECT" --no-register >/dev/null
configure_git "$CHECK_PROJECT"
commit_all "$CHECK_PROJECT" "initial check project"
echo "0000000000000000000000000000000000000003" > "$CHECK_PROJECT/.toolkit-version"
commit_all "$CHECK_PROJECT" "simulate old check project"
CHECK_BRANCH="$(git -C "$CHECK_PROJECT" rev-parse --abbrev-ref HEAD)"

(cd "$CHECK_PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh" --check) >"$TEST_DIR/check-output.txt" 2>&1
assert_contains "$TEST_DIR/check-output.txt" 'Needs sync'
assert_contains "$TEST_DIR/check-output.txt" 'Run: toolkit update'

if [ "$(git -C "$CHECK_PROJECT" rev-parse --abbrev-ref HEAD)" != "$CHECK_BRANCH" ]; then
  echo "FAIL: update --check should not switch branches" >&2
  ERRORS=$((ERRORS + 1))
fi

(cd "$CHECK_PROJECT" && TOOLKIT_NO_AUTO_UPDATE=1 "$TOOLKIT_ROOT/bin/toolkit" detect) >"$TEST_DIR/detect-output.txt" 2>&1
assert_not_contains "$TEST_DIR/detect-output.txt" 'needs sync'

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
