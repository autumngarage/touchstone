#!/usr/bin/env bash
#
# tests/test-sync-scope-aware.sh — scope-aware dirty checks for project sync.
#
set -euo pipefail

exec </dev/null

unset TOUCHSTONE_NO_AUTO_UPDATE TOUCHSTONE_NO_AUTO_PROJECT_SYNC TOUCHSTONE_FORCE_OVERLAP TOUCHSTONE_NO_DRIFT_WARNING

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/sync-discipline.sh
source "$TOUCHSTONE_ROOT/lib/sync-discipline.sh"
TEST_DIR="$(mktemp -d -t touchstone-test-sync-scope.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to contain '$needle'" >&2
    sed 's/^/    /' "$file" >&2 || true
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to NOT contain '$needle'" >&2
    sed 's/^/    /' "$file" >&2 || true
    ERRORS=$((ERRORS + 1))
  fi
}

configure_git() {
  local repo="$1"
  git -C "$repo" config user.email "touchstone-test@example.com"
  git -C "$repo" config user.name "Touchstone Test"
}

commit_all() {
  local repo="$1" message="$2"
  git -C "$repo" add -A
  if [ -n "$(git -C "$repo" status --porcelain)" ] \
    || ! git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$repo" commit --no-verify -m "$message" >/dev/null
  fi
}

make_stale_project() {
  local project="$1" old_id="$2"
  bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$project" --no-register >/dev/null
  configure_git "$project"
  commit_all "$project" "initial project"
  printf '%s\n' "$old_id" >"$project/.touchstone-version"
  commit_all "$project" "simulate stale touchstone"
}

assert_version_current() {
  local project="$1" current_id
  if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
    current_id="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
  else
    current_id="$(tr -d '[:space:]' <"$TOUCHSTONE_ROOT/VERSION")"
  fi
  if [ "$(tr -d '[:space:]' <"$project/.touchstone-version")" != "$current_id" ]; then
    echo "FAIL: expected $project to update to current touchstone id" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

echo "==> Test: scope-aware sync dirty checks"
echo "    Test dir: $TEST_DIR"

echo ""
echo "--- clean tree with drift: sync runs without unrelated-dirty notice ---"
CLEAN_PROJECT="$TEST_DIR/clean-project"
make_stale_project "$CLEAN_PROJECT" "0000000000000000000000000000000000000101"
(cd "$CLEAN_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/clean.out" 2>&1
assert_contains "$TEST_DIR/clean.out" "Committed: chore: update touchstone to"
assert_not_contains "$TEST_DIR/clean.out" "Proceeding with sync past unrelated dirty paths"
assert_version_current "$CLEAN_PROJECT"
touchstone_sync_planned_write_paths "$CLEAN_PROJECT" "$TOUCHSTONE_ROOT" >"$TEST_DIR/planned.out"
assert_contains "$TEST_DIR/planned.out" "TOUCHSTONE.md"
assert_contains "$TEST_DIR/planned.out" ".github/workflows/issue-claim-check.yml"
assert_contains "$TEST_DIR/planned.out" "scripts/claim-issue.sh"
assert_contains "$TEST_DIR/planned.out" "scripts/issue-claim-check.sh"
assert_contains "$TEST_DIR/planned.out" "lib/preflight-scope.sh"

echo ""
echo "--- dirty path inside owned set: sync refuses with overlap list ---"
OVERLAP_PROJECT="$TEST_DIR/overlap-project"
make_stale_project "$OVERLAP_PROJECT" "0000000000000000000000000000000000000102"
printf '\n# dirty overlap\n' >>"$OVERLAP_PROJECT/scripts/touchstone-run.sh"
if (cd "$OVERLAP_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/overlap.out" 2>&1; then
  echo "FAIL: expected dirty overlap to refuse sync" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/overlap.out" "Working tree is dirty"
assert_contains "$TEST_DIR/overlap.out" "Dirty paths overlap planned touchstone writes"
assert_contains "$TEST_DIR/overlap.out" "scripts/touchstone-run.sh"
assert_contains "$OVERLAP_PROJECT/.git/touchstone/sync-skips.jsonl" '"reason":"dirty-overlap"'
assert_contains "$OVERLAP_PROJECT/.git/touchstone/sync-skips.jsonl" '"command":"touchstone update"'

echo ""
echo "--- dirty issue-claim workflow refuses sync ---"
WORKFLOW_OVERLAP_PROJECT="$TEST_DIR/workflow-overlap-project"
make_stale_project "$WORKFLOW_OVERLAP_PROJECT" "0000000000000000000000000000000000000106"
printf '\n# dirty workflow overlap\n' >>"$WORKFLOW_OVERLAP_PROJECT/.github/workflows/issue-claim-check.yml"
if (cd "$WORKFLOW_OVERLAP_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/workflow-overlap.out" 2>&1; then
  echo "FAIL: expected dirty workflow overlap to refuse sync" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/workflow-overlap.out" "Dirty paths overlap planned touchstone writes"
assert_contains "$TEST_DIR/workflow-overlap.out" ".github/workflows/issue-claim-check.yml"

echo ""
echo "--- dirty path outside owned set: sync proceeds with notice ---"
UNRELATED_PROJECT="$TEST_DIR/unrelated-project"
make_stale_project "$UNRELATED_PROJECT" "0000000000000000000000000000000000000103"
mkdir -p "$UNRELATED_PROJECT/audits/drafts"
printf 'draft\n' >"$UNRELATED_PROJECT/audits/drafts/notes.md"
printf 'lock\n' >"$UNRELATED_PROJECT/uv.lock"
(cd "$UNRELATED_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/unrelated.out" 2>&1
assert_contains "$TEST_DIR/unrelated.out" "Proceeding with sync past unrelated dirty paths"
assert_contains "$TEST_DIR/unrelated.out" "audits/drafts/notes.md"
assert_contains "$TEST_DIR/unrelated.out" "uv.lock"
assert_contains "$TEST_DIR/unrelated.out" "Committed: chore: update touchstone to"
assert_version_current "$UNRELATED_PROJECT"

echo ""
echo "--- mixed dirty paths: sync refuses because overlap is non-empty ---"
MIXED_PROJECT="$TEST_DIR/mixed-project"
make_stale_project "$MIXED_PROJECT" "0000000000000000000000000000000000000104"
printf '\n# dirty overlap\n' >>"$MIXED_PROJECT/lib/toml.sh"
printf 'outside\n' >"$MIXED_PROJECT/uv.lock"
if (cd "$MIXED_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/mixed.out" 2>&1; then
  echo "FAIL: expected mixed dirty tree to refuse sync" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/mixed.out" "lib/toml.sh"
assert_not_contains "$TEST_DIR/mixed.out" "Proceeding with sync past unrelated dirty paths"

echo ""
echo "--- TOUCHSTONE_FORCE_OVERLAP=1: sync proceeds despite overlap ---"
FORCE_PROJECT="$TEST_DIR/force-project"
make_stale_project "$FORCE_PROJECT" "0000000000000000000000000000000000000105"
printf '\n# dirty overlap\n' >>"$FORCE_PROJECT/scripts/touchstone-run.sh"
(cd "$FORCE_PROJECT" && TOUCHSTONE_FORCE_OVERLAP=1 bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/force.out" 2>&1
assert_contains "$TEST_DIR/force.out" "TOUCHSTONE_FORCE_OVERLAP=1 set"
assert_contains "$TEST_DIR/force.out" "scripts/touchstone-run.sh"
assert_contains "$TEST_DIR/force.out" "Committed: chore: update touchstone to"
assert_version_current "$FORCE_PROJECT"

if [ "$ERRORS" -ne 0 ]; then
  echo ""
  echo "FAIL: $ERRORS scope-aware sync assertion(s) failed" >&2
  exit 1
fi

echo ""
echo "PASS: scope-aware sync dirty checks"
