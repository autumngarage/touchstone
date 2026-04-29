#!/usr/bin/env bash
#
# tests/test-update.sh — verify update-project.sh handles updates correctly.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-update.XXXXXX)"
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
  git -C "$repo" config user.email "touchstone-test@example.com"
  git -C "$repo" config user.name "Touchstone Test"
}

commit_all() {
  local repo="$1"
  local message="$2"
  git -C "$repo" add -A
  # Skip the commit when there's nothing staged — new-project.sh now creates an
  # initial commit during bootstrap, so the test helper must not error out when
  # the tree is already clean.
  if [ -n "$(git -C "$repo" status --porcelain)" ] || \
     ! git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$repo" commit --no-verify -m "$message" >/dev/null
  fi
}

PROJECT="$TEST_DIR/test-project"

# --------------------------------------------------------------------------
# Setup: bootstrap a project and commit the initial state.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 1: Bootstrap ---"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT" --no-register
configure_git "$PROJECT"
commit_all "$PROJECT" "initial touchstone project"

BASE_BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)"
INITIAL_SHA="$(cat "$PROJECT/.touchstone-version" | tr -d '[:space:]')"
echo "    Initial .touchstone-version: $INITIAL_SHA"

# --------------------------------------------------------------------------
# Test 1: update with no touchstone changes -> "already up to date"
# --------------------------------------------------------------------------
echo ""
echo "--- Step 2: Update with no changes (should report up to date) ---"
(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-1.txt"

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
# Test 2: committed local touchstone-owned changes update on a review branch.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3: Modify a Touchstone-owned file, then update ---"

echo "# locally modified" >> "$PROJECT/principles/engineering-principles.md"
rm "$PROJECT/scripts/touchstone-run.sh"
printf '{"custom": true}\n' > "$PROJECT/.claude/settings.json"
echo "0000000000000000000000000000000000000000" > "$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate old touchstone state"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-2.txt"

UPDATE_BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)"
if [ "$UPDATE_BRANCH" = "$BASE_BRANCH" ]; then
  echo "FAIL: update did not switch to a chore/touchstone branch" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/update-output-2.txt" 'Creating update branch: chore/touchstone-'
assert_contains "$TEST_DIR/update-output-2.txt" 'Committed: chore: update touchstone to'
assert_contains "$TEST_DIR/update-output-2.txt" 'bash scripts/open-pr.sh'
assert_exists "$PROJECT/scripts/touchstone-run.sh"
assert_exists "$PROJECT/scripts/spawn-worktree.sh"
assert_exists "$PROJECT/scripts/cleanup-worktrees.sh"
assert_exists "$PROJECT/.touchstone-manifest"
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/touchstone-run.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/spawn-worktree.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/cleanup-worktrees.sh$'
assert_not_exists "$PROJECT/principles/engineering-principles.md.bak"
assert_not_exists "$PROJECT/.claude/settings.json.touchstone-pre-update.bak"

if find "$PROJECT" -name '*.bak' -print | grep -q .; then
  echo "FAIL: update should not create .bak files" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "    PASS: update did not create .bak files"
fi

if diff -q "$TOUCHSTONE_ROOT/principles/engineering-principles.md" "$PROJECT/principles/engineering-principles.md" >/dev/null 2>&1; then
  echo "    PASS: file was updated to touchstone version"
else
  echo "    FAIL: file does not match touchstone version" >&2
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

if git -C "$PROJECT" ls-files --error-unmatch .touchstone-version >/dev/null 2>&1; then
  echo "    PASS: .touchstone-version is tracked in the update commit"
else
  echo "FAIL: expected .touchstone-version to be tracked" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 2b: --in-place updates the current feature branch without creating a
# chore/touchstone-* branch. This is the explicit escape hatch for drivers that
# already created a task branch.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3b: In-place update stays on the current branch ---"

IN_PLACE_PROJECT="$TEST_DIR/in-place-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$IN_PLACE_PROJECT" --no-register >/dev/null
configure_git "$IN_PLACE_PROJECT"
commit_all "$IN_PLACE_PROJECT" "initial in-place test project"
git -C "$IN_PLACE_PROJECT" checkout -q -b feature/in-place-update
rm "$IN_PLACE_PROJECT/scripts/touchstone-run.sh"
printf '{"custom": true}\n' > "$IN_PLACE_PROJECT/.claude/settings.json"
echo "0000000000000000000000000000000000000004" > "$IN_PLACE_PROJECT/.touchstone-version"
commit_all "$IN_PLACE_PROJECT" "simulate old in-place touchstone state"
IN_PLACE_BASE="$(git -C "$IN_PLACE_PROJECT" rev-parse HEAD)"

(cd "$IN_PLACE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place) 2>&1 | tee "$TEST_DIR/update-in-place-output.txt"

if [ "$(git -C "$IN_PLACE_PROJECT" branch --show-current)" != "feature/in-place-update" ]; then
  echo "FAIL: --in-place update should stay on the current feature branch" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/update-in-place-output.txt" 'Applying update on current branch: feature/in-place-update'
assert_contains "$TEST_DIR/update-in-place-output.txt" 'Committed: chore: update touchstone to'
assert_not_contains "$TEST_DIR/update-in-place-output.txt" 'Creating update branch: chore/touchstone-'
assert_exists "$IN_PLACE_PROJECT/scripts/touchstone-run.sh"
assert_not_exists "$IN_PLACE_PROJECT/.claude/settings.json.touchstone-pre-update.bak"

if git -C "$IN_PLACE_PROJECT" branch --list 'chore/touchstone-*' | grep -q .; then
  echo "FAIL: --in-place update should not create a chore/touchstone-* branch" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(git -C "$IN_PLACE_PROJECT" rev-parse HEAD^)" != "$IN_PLACE_BASE" ]; then
  echo "FAIL: --in-place update commit should be based on the pre-update feature branch HEAD" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$(git -C "$IN_PLACE_PROJECT" status --porcelain)" ]; then
  echo "FAIL: --in-place update should leave a clean worktree after committing" >&2
  git -C "$IN_PLACE_PROJECT" status --short >&2
  ERRORS=$((ERRORS + 1))
fi

if (cd "$IN_PLACE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place --branch chore/custom) >"$TEST_DIR/update-in-place-branch-output.txt" 2>&1; then
  echo "FAIL: --in-place and --branch should be rejected together" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/update-in-place-branch-output.txt" 'cannot be combined'
fi

# --------------------------------------------------------------------------
# Test 3: project-owned files are NOT touched.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4: Verify project-owned files are untouched ---"

echo "# my project context" >> "$PROJECT/CLAUDE.md"
echo "0000000000000000000000000000000000000001" > "$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate project-owned customization"
CLAUDE_CHECKSUM="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

CLAUDE_CHECKSUM_AFTER="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"

if [ "$CLAUDE_CHECKSUM" = "$CLAUDE_CHECKSUM_AFTER" ]; then
  echo "    PASS: CLAUDE.md was not modified by update"
else
  echo "    FAIL: CLAUDE.md was modified by update" >&2
  ERRORS=$((ERRORS + 1))
fi

assert_not_exists "$PROJECT/CLAUDE.md.bak"

# Existing projects from before Gemini support should receive GEMINI.md once,
# but the file remains project-owned after that.
rm -f "$PROJECT/GEMINI.md"
echo "0000000000000000000000000000000000000001" > "$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate pre-gemini project"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_exists "$PROJECT/GEMINI.md"
assert_contains "$PROJECT/GEMINI.md" "Gemini CLI"
assert_not_contains "$PROJECT/GEMINI.md" "{{PROJECT_NAME}}"
assert_contains "$PROJECT/GEMINI.md" "test-project"
if ! git -C "$PROJECT" log -1 --name-only --pretty=format: | grep -qx 'GEMINI.md'; then
  echo "FAIL: update commit must include GEMINI.md when adding the project-owned Gemini instructions" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 3b: pre-existing AGENTS.md without the shared-principles block gets
# the touchstone-managed block injected on update. This is the migration
# path for projects bootstrapped before the shared-principles block existed —
# without it, non-Claude reviewers (Codex/Gemini) silently miss every
# engineering principle.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4b: AGENTS.md without principles block gets backfilled on update ---"

cat > "$PROJECT/AGENTS.md" <<'EOF'
# AGENTS.md — AI Reviewer Guide for Test Project

You are reviewing PRs for Test Project.

## Specific review rules

- Project-specific rule that must survive the update.
EOF
echo "0000000000000000000000000000000000000002" > "$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate pre-block AGENTS.md state"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_contains "$PROJECT/AGENTS.md" "touchstone:shared-principles:start"
assert_contains "$PROJECT/AGENTS.md" "touchstone:shared-principles:end"
assert_contains "$PROJECT/AGENTS.md" "No band-aids"
# Project-specific content must survive injection.
assert_contains "$PROJECT/AGENTS.md" "Project-specific rule that must survive the update."
# H1 must remain on line 1.
first_line="$(head -n 1 "$PROJECT/AGENTS.md")"
if [ "$first_line" != "# AGENTS.md — AI Reviewer Guide for Test Project" ]; then
  echo "FAIL: AGENTS.md H1 not preserved on line 1: '$first_line'" >&2
  ERRORS=$((ERRORS + 1))
fi
# The update commit must include AGENTS.md (so the block ships in the same
# review boundary as the rest of the touchstone update).
if ! git -C "$PROJECT" log -1 --name-only --pretty=format: | grep -qx 'AGENTS.md'; then
  echo "FAIL: update commit must include AGENTS.md when the block was refreshed" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 4: dirty worktrees fail before branching or patching.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 5: Dirty worktree is refused ---"

DIRTY_PROJECT="$TEST_DIR/dirty-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$DIRTY_PROJECT" --no-register >/dev/null
configure_git "$DIRTY_PROJECT"
commit_all "$DIRTY_PROJECT" "initial dirty test project"
echo "0000000000000000000000000000000000000002" > "$DIRTY_PROJECT/.touchstone-version"
commit_all "$DIRTY_PROJECT" "simulate old dirty test project"
DIRTY_BRANCH="$(git -C "$DIRTY_PROJECT" rev-parse --abbrev-ref HEAD)"
echo "# uncommitted change" >> "$DIRTY_PROJECT/scripts/open-pr.sh"

if (cd "$DIRTY_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/dirty-output.txt" 2>&1; then
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
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$ROLLBACK_PROJECT" --no-register >/dev/null
configure_git "$ROLLBACK_PROJECT"
commit_all "$ROLLBACK_PROJECT" "initial rollback test project"
printf '\n.touchstone-version\n.touchstone-manifest\n' >> "$ROLLBACK_PROJECT/.gitignore"
git -C "$ROLLBACK_PROJECT" rm --cached .touchstone-version .touchstone-manifest >/dev/null
commit_all "$ROLLBACK_PROJECT" "simulate legacy ignored touchstone metadata"
echo "legacy-old-version" > "$ROLLBACK_PROJECT/.touchstone-version"
rm "$ROLLBACK_PROJECT/.touchstone-manifest"
mkdir "$ROLLBACK_PROJECT/.touchstone-manifest"
ROLLBACK_BRANCH="$(git -C "$ROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)"

if (cd "$ROLLBACK_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/rollback-output.txt" 2>&1; then
  echo "FAIL: expected rollback update to fail on legacy manifest directory" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/rollback-output.txt" 'Update failed; rolling back'
fi

if [ "$(git -C "$ROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)" != "$ROLLBACK_BRANCH" ]; then
  echo "FAIL: rollback should return to the original branch" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(cat "$ROLLBACK_PROJECT/.touchstone-version")" = "legacy-old-version" ]; then
  echo "    PASS: rollback restored ignored .touchstone-version"
else
  echo "FAIL: rollback did not restore ignored .touchstone-version" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$ROLLBACK_PROJECT" branch --list 'chore/touchstone-*' | grep -q .; then
  echo "FAIL: rollback should delete the failed update branch" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 5b: swift profile gains .swiftlint.yml on update without clobbering
# a hand-edited copy.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 5b: Swift project gains .swiftlint.yml on update ---"

SWIFT_UPDATE_PROJECT="$TEST_DIR/swift-update-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SWIFT_UPDATE_PROJECT" --no-register --type swift >/dev/null
configure_git "$SWIFT_UPDATE_PROJECT"
commit_all "$SWIFT_UPDATE_PROJECT" "initial swift touchstone project"

# Simulate a stale touchstone version + a project that pre-existed the swiftlint
# template (so .swiftlint.yml was never created at bootstrap time).
rm -f "$SWIFT_UPDATE_PROJECT/.swiftlint.yml"
echo "0000000000000000000000000000000000000010" > "$SWIFT_UPDATE_PROJECT/.touchstone-version"
commit_all "$SWIFT_UPDATE_PROJECT" "simulate pre-swiftlint-template swift project"

(cd "$SWIFT_UPDATE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/swift-update-output.txt" 2>&1

assert_contains "$TEST_DIR/swift-update-output.txt" 'added (project-owned).*\.swiftlint\.yml'
assert_exists "$SWIFT_UPDATE_PROJECT/.swiftlint.yml"
assert_contains "$SWIFT_UPDATE_PROJECT/.swiftlint.yml" '^  - \.build$'

# .swiftlint.yml stays out of .touchstone-manifest — it's project-owned, not
# touchstone-owned. Future updates must not include it in the touchstone-owned
# overwrite path.
if grep -qxF '.swiftlint.yml' "$SWIFT_UPDATE_PROJECT/.touchstone-manifest"; then
  echo "FAIL: .swiftlint.yml must NOT be in .touchstone-manifest (project-owned, not touchstone-owned)" >&2
  ERRORS=$((ERRORS + 1))
fi

# The newly added .swiftlint.yml must be staged in the update commit so
# `--ship` does not leave it behind.
if git -C "$SWIFT_UPDATE_PROJECT" log -1 --name-only --format='' | grep -qxF '.swiftlint.yml'; then
  echo "    PASS: .swiftlint.yml committed as part of the update"
else
  echo "FAIL: .swiftlint.yml was not committed in the update commit" >&2
  ERRORS=$((ERRORS + 1))
fi

# Re-run on a swift project that already has a hand-edited .swiftlint.yml —
# update must NOT clobber it. Use a sentinel string to verify the original
# bytes survive.
SWIFT_HAND_EDITED_PROJECT="$TEST_DIR/swift-hand-edited-update"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SWIFT_HAND_EDITED_PROJECT" --no-register --type swift >/dev/null
configure_git "$SWIFT_HAND_EDITED_PROJECT"
printf 'SENTINEL_HAND_EDITED_SWIFTLINT\n' > "$SWIFT_HAND_EDITED_PROJECT/.swiftlint.yml"
commit_all "$SWIFT_HAND_EDITED_PROJECT" "initial swift project with hand-edited swiftlint"
echo "0000000000000000000000000000000000000011" > "$SWIFT_HAND_EDITED_PROJECT/.touchstone-version"
commit_all "$SWIFT_HAND_EDITED_PROJECT" "simulate stale touchstone state"

(cd "$SWIFT_HAND_EDITED_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_contains "$SWIFT_HAND_EDITED_PROJECT/.swiftlint.yml" '^SENTINEL_HAND_EDITED_SWIFTLINT$'

# Non-swift profiles must NOT receive .swiftlint.yml on update — the per-profile
# gate keeps the swift template out of unrelated projects.
NON_SWIFT_UPDATE_PROJECT="$TEST_DIR/non-swift-update-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$NON_SWIFT_UPDATE_PROJECT" --no-register --type python >/dev/null
configure_git "$NON_SWIFT_UPDATE_PROJECT"
commit_all "$NON_SWIFT_UPDATE_PROJECT" "initial python project"
echo "0000000000000000000000000000000000000012" > "$NON_SWIFT_UPDATE_PROJECT/.touchstone-version"
commit_all "$NON_SWIFT_UPDATE_PROJECT" "simulate stale python touchstone state"

(cd "$NON_SWIFT_UPDATE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_not_exists "$NON_SWIFT_UPDATE_PROJECT/.swiftlint.yml"

# --------------------------------------------------------------------------
# Test 6: check mode and ordinary commands do not print the old startup nag.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 7: Check mode and no broad startup nag ---"

CHECK_PROJECT="$TEST_DIR/check-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$CHECK_PROJECT" --no-register >/dev/null
configure_git "$CHECK_PROJECT"
commit_all "$CHECK_PROJECT" "initial check project"
echo "0000000000000000000000000000000000000003" > "$CHECK_PROJECT/.touchstone-version"
commit_all "$CHECK_PROJECT" "simulate old check project"
CHECK_BRANCH="$(git -C "$CHECK_PROJECT" rev-parse --abbrev-ref HEAD)"

(cd "$CHECK_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) >"$TEST_DIR/check-output.txt" 2>&1
assert_contains "$TEST_DIR/check-output.txt" 'Needs sync'
assert_contains "$TEST_DIR/check-output.txt" 'Run: touchstone update'

if [ "$(git -C "$CHECK_PROJECT" rev-parse --abbrev-ref HEAD)" != "$CHECK_BRANCH" ]; then
  echo "FAIL: update --check should not switch branches" >&2
  ERRORS=$((ERRORS + 1))
fi

(cd "$CHECK_PROJECT" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" detect) >"$TEST_DIR/detect-output.txt" 2>&1
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
