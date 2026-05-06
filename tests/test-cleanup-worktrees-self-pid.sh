#!/usr/bin/env bash
#
# tests/test-cleanup-worktrees-self-pid.sh — verify cleanup-worktrees treats
# a lock held by the invoking shell's parent PID as stale.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-cleanup-self-pid.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: cleanup-worktrees.sh unlocks self-parent PID locks only with --unlock-stale"

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
SELF_PID_WT="$TEST_DIR/demo-self-pid"

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

git -C "$REPO" worktree add -q "$SELF_PID_WT" -b feat/self-pid main
echo "self pid" > "$SELF_PID_WT/self-pid.txt"
git -C "$SELF_PID_WT" add self-pid.txt
git -C "$SELF_PID_WT" commit -qm "feat: self pid"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff -q feat/self-pid -m "merge feat/self-pid"
git -C "$REPO" push -q origin main

git -C "$REPO" worktree lock --reason "agent pid $$" "$SELF_PID_WT"

DRY_RUN_OUTPUT="$TEST_DIR/dry-run-output.txt"
pushd "$REPO" >/dev/null
bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" >"$DRY_RUN_OUTPUT" 2>&1
popd >/dev/null

assert_exists "$SELF_PID_WT"
assert_contains "$DRY_RUN_OUTPUT" "lock: stale (pid $$ is current shell parent)"
assert_contains "$DRY_RUN_OUTPUT" 'pass --unlock-stale --execute to remove'

UNLOCK_OUTPUT="$TEST_DIR/unlock-output.txt"
pushd "$REPO" >/dev/null
bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" --unlock-stale --execute >"$UNLOCK_OUTPUT" 2>&1
popd >/dev/null

assert_not_exists "$SELF_PID_WT"
assert_contains "$UNLOCK_OUTPUT" 'unlocked stale lock:'
assert_contains "$UNLOCK_OUTPUT" 'removed:'

echo "==> PASS: cleanup-worktrees removes self-parent PID locks only after explicit stale unlock"
