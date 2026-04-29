#!/usr/bin/env bash
#
# tests/test-cleanup-worktrees.sh — verify cleanup-worktrees is dry-run first,
# removes only clean merged/equivalent worktrees, and refuses dirty trees.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-cleanup-worktrees.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: cleanup-worktrees.sh removes only safe worktree candidates"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_exists() {
  [ -e "$1" ] || fail "expected $1 to exist"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected $1 to NOT exist"
}

assert_contains() {
  grep -q "$2" "$1" 2>/dev/null || fail "expected $1 to contain '$2'"
}

REMOTE="$TEST_DIR/remote.git"
REPO="$TEST_DIR/demo"
MERGED_WT="$TEST_DIR/demo-merged"
SQUASH_WT="$TEST_DIR/demo-squash"
UNIQUE_WT="$TEST_DIR/demo-unique"
DIRTY_WT="$TEST_DIR/demo-dirty"

git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$REMOTE"

echo "base" > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -qm "initial"
git -C "$REPO" push -q -u origin main
git -C "$REPO" remote set-head origin main

git -C "$REPO" worktree add -q "$MERGED_WT" -b feat/merged main
echo "merged" > "$MERGED_WT/merged.txt"
git -C "$MERGED_WT" add merged.txt
git -C "$MERGED_WT" commit -qm "feat: merged"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff -q feat/merged -m "merge feat/merged"

git -C "$REPO" worktree add -q "$SQUASH_WT" -b feat/squash main
echo "squash" > "$SQUASH_WT/squash.txt"
git -C "$SQUASH_WT" add squash.txt
git -C "$SQUASH_WT" commit -qm "feat: squash"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --squash feat/squash >/dev/null
git -C "$REPO" commit -qm "feat: squash (#1)"

git -C "$REPO" worktree add -q "$UNIQUE_WT" -b feat/unique main
echo "unique" > "$UNIQUE_WT/unique.txt"
git -C "$UNIQUE_WT" add unique.txt
git -C "$UNIQUE_WT" commit -qm "feat: unique"

git -C "$REPO" worktree add -q "$DIRTY_WT" -b feat/dirty main
echo "dirty" > "$DIRTY_WT/dirty.txt"
git -C "$DIRTY_WT" add dirty.txt
git -C "$DIRTY_WT" commit -qm "feat: dirty"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff -q feat/dirty -m "merge feat/dirty"
echo "uncommitted" >> "$DIRTY_WT/dirty.txt"

git -C "$REPO" push -q origin main

DRY_RUN_OUTPUT="$TEST_DIR/dry-run-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh") >"$DRY_RUN_OUTPUT" 2>&1

assert_contains "$DRY_RUN_OUTPUT" 'Dry run'
assert_contains "$DRY_RUN_OUTPUT" "$MERGED_WT"
assert_contains "$DRY_RUN_OUTPUT" "$SQUASH_WT"
assert_contains "$DRY_RUN_OUTPUT" 'dirty; use --force to remove'
assert_exists "$MERGED_WT"
assert_exists "$SQUASH_WT"
assert_exists "$UNIQUE_WT"
assert_exists "$DIRTY_WT"

EXEC_OUTPUT="$TEST_DIR/execute-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" --execute) >"$EXEC_OUTPUT" 2>&1

assert_not_exists "$MERGED_WT"
assert_not_exists "$SQUASH_WT"
assert_exists "$UNIQUE_WT"
assert_exists "$DIRTY_WT"
assert_contains "$EXEC_OUTPUT" 'removed:'
assert_contains "$EXEC_OUTPUT" 'branch has unique work'
assert_contains "$EXEC_OUTPUT" 'dirty; use --force to remove'

FORCE_OUTPUT="$TEST_DIR/force-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" --force) >"$FORCE_OUTPUT" 2>&1
assert_not_exists "$DIRTY_WT"
assert_exists "$UNIQUE_WT"

echo "==> PASS: cleanup-worktrees dry-runs, removes safe candidates, and refuses dirty worktrees by default"
