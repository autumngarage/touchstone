#!/usr/bin/env bash
#
# tests/test-cleanup-worktrees.sh — verify cleanup-worktrees is dry-run first,
# removes only clean merged/equivalent worktrees, and refuses dirty trees.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-cleanup-worktrees.XXXXXX)"
LOCKED_ALIVE_PID=""

cleanup() {
  if [ -n "$LOCKED_ALIVE_PID" ]; then
    kill "$LOCKED_ALIVE_PID" >/dev/null 2>&1 || true
    wait "$LOCKED_ALIVE_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT

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
DETACHED_WT="$TEST_DIR/demo-detached"
LOCKED_STALE_WT="$TEST_DIR/demo-locked-stale"
LOCKED_ALIVE_WT="$TEST_DIR/demo-locked-alive"
LOCKED_NOPID_WT="$TEST_DIR/demo-locked-nopid"

dead_pid() {
  local pid
  pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid - 1))
  done
  printf '%s\n' "$pid"
}

git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$REMOTE"

echo "base" >"$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -qm "initial"
git -C "$REPO" push -q -u origin main
git -C "$REPO" remote set-head origin main

git -C "$REPO" worktree add -q "$MERGED_WT" -b feat/merged main
echo "merged" >"$MERGED_WT/merged.txt"
git -C "$MERGED_WT" add merged.txt
git -C "$MERGED_WT" commit -qm "feat: merged"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff -q feat/merged -m "merge feat/merged"

git -C "$REPO" worktree add -q "$SQUASH_WT" -b feat/squash main
echo "squash" >"$SQUASH_WT/squash.txt"
git -C "$SQUASH_WT" add squash.txt
git -C "$SQUASH_WT" commit -qm "feat: squash"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --squash feat/squash >/dev/null
git -C "$REPO" commit -qm "feat: squash (#1)"

git -C "$REPO" worktree add -q "$UNIQUE_WT" -b feat/unique main
echo "unique" >"$UNIQUE_WT/unique.txt"
git -C "$UNIQUE_WT" add unique.txt
git -C "$UNIQUE_WT" commit -qm "feat: unique"

git -C "$REPO" worktree add -q "$DIRTY_WT" -b feat/dirty main
echo "dirty" >"$DIRTY_WT/dirty.txt"
git -C "$DIRTY_WT" add dirty.txt
git -C "$DIRTY_WT" commit -qm "feat: dirty"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff -q feat/dirty -m "merge feat/dirty"
echo "uncommitted" >>"$DIRTY_WT/dirty.txt"

git -C "$REPO" worktree add -q "$LOCKED_STALE_WT" -b feat/locked-stale main
echo "locked stale" >"$LOCKED_STALE_WT/locked-stale.txt"
git -C "$LOCKED_STALE_WT" add locked-stale.txt
git -C "$LOCKED_STALE_WT" commit -qm "feat: locked stale"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff -q feat/locked-stale -m "merge feat/locked-stale"
DEAD_PID="$(dead_pid)"
git -C "$REPO" worktree lock --reason "agent pid $DEAD_PID" "$LOCKED_STALE_WT"

git -C "$REPO" worktree add -q "$LOCKED_ALIVE_WT" -b feat/locked-alive main
echo "locked alive" >"$LOCKED_ALIVE_WT/locked-alive.txt"
git -C "$LOCKED_ALIVE_WT" add locked-alive.txt
git -C "$LOCKED_ALIVE_WT" commit -qm "feat: locked alive"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff -q feat/locked-alive -m "merge feat/locked-alive"
sleep 120 &
LOCKED_ALIVE_PID="$!"
git -C "$REPO" worktree lock --reason "agent pid $LOCKED_ALIVE_PID" "$LOCKED_ALIVE_WT"

git -C "$REPO" worktree add -q "$LOCKED_NOPID_WT" -b feat/locked-nopid main
echo "locked no pid" >"$LOCKED_NOPID_WT/locked-nopid.txt"
git -C "$LOCKED_NOPID_WT" add locked-nopid.txt
git -C "$REPO" checkout -q main
git -C "$LOCKED_NOPID_WT" commit -qm "feat: locked no pid"
git -C "$REPO" merge --no-ff -q feat/locked-nopid -m "merge feat/locked-nopid"
git -C "$REPO" worktree lock --reason "manual inspection" "$LOCKED_NOPID_WT"

git -C "$REPO" worktree add -q -b feat/detached-source "$TEST_DIR/demo-detached-source" main
echo "detached-unique" >"$TEST_DIR/demo-detached-source/detached.txt"
git -C "$TEST_DIR/demo-detached-source" add detached.txt
git -C "$TEST_DIR/demo-detached-source" commit -qm "feat: detached unique work"
DETACHED_SHA="$(git -C "$TEST_DIR/demo-detached-source" rev-parse HEAD)"
git -C "$REPO" worktree remove "$TEST_DIR/demo-detached-source" >/dev/null 2>&1
git -C "$REPO" worktree add -q --detach "$DETACHED_WT" "$DETACHED_SHA"
git -C "$REPO" branch -D feat/detached-source >/dev/null

git -C "$REPO" push -q origin main

DRY_RUN_OUTPUT="$TEST_DIR/dry-run-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh") >"$DRY_RUN_OUTPUT" 2>&1

assert_contains "$DRY_RUN_OUTPUT" 'Dry run'
assert_contains "$DRY_RUN_OUTPUT" "$MERGED_WT"
assert_contains "$DRY_RUN_OUTPUT" "$SQUASH_WT"
assert_contains "$DRY_RUN_OUTPUT" 'dirty; use --force to remove'
assert_contains "$DRY_RUN_OUTPUT" 'detached HEAD has unique work'
assert_contains "$DRY_RUN_OUTPUT" "lock: stale (pid $DEAD_PID dead)"
assert_contains "$DRY_RUN_OUTPUT" "lock: alive (pid $LOCKED_ALIVE_PID)"
assert_contains "$DRY_RUN_OUTPUT" 'lock: present, no PID'
assert_contains "$DRY_RUN_OUTPUT" 'pass --unlock-stale --execute to remove'
assert_contains "$DRY_RUN_OUTPUT" 'locked by live process'
assert_contains "$DRY_RUN_OUTPUT" 'locked without PID'
assert_exists "$MERGED_WT"
assert_exists "$SQUASH_WT"
assert_exists "$UNIQUE_WT"
assert_exists "$DIRTY_WT"
assert_exists "$DETACHED_WT"
assert_exists "$LOCKED_STALE_WT"
assert_exists "$LOCKED_ALIVE_WT"
assert_exists "$LOCKED_NOPID_WT"

EXEC_OUTPUT="$TEST_DIR/execute-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" --execute) >"$EXEC_OUTPUT" 2>&1

assert_not_exists "$MERGED_WT"
assert_not_exists "$SQUASH_WT"
assert_exists "$UNIQUE_WT"
assert_exists "$DIRTY_WT"
assert_exists "$DETACHED_WT"
assert_exists "$LOCKED_STALE_WT"
assert_exists "$LOCKED_ALIVE_WT"
assert_exists "$LOCKED_NOPID_WT"
assert_contains "$EXEC_OUTPUT" 'removed:'
assert_contains "$EXEC_OUTPUT" 'branch has unique work'
assert_contains "$EXEC_OUTPUT" 'dirty; use --force to remove'
assert_contains "$EXEC_OUTPUT" 'detached HEAD has unique work'
assert_contains "$EXEC_OUTPUT" "locked by dead process (pid $DEAD_PID)"

UNLOCK_OUTPUT="$TEST_DIR/unlock-stale-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" --unlock-stale --execute) >"$UNLOCK_OUTPUT" 2>&1
assert_not_exists "$LOCKED_STALE_WT"
assert_exists "$LOCKED_ALIVE_WT"
assert_exists "$LOCKED_NOPID_WT"
assert_contains "$UNLOCK_OUTPUT" 'unlocked stale lock:'
assert_contains "$UNLOCK_OUTPUT" 'locked by live process'
assert_contains "$UNLOCK_OUTPUT" 'locked without PID'

FORCE_OUTPUT="$TEST_DIR/force-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" --force) >"$FORCE_OUTPUT" 2>&1
assert_not_exists "$DIRTY_WT"
assert_exists "$UNIQUE_WT"
assert_exists "$LOCKED_ALIVE_WT"
assert_exists "$LOCKED_NOPID_WT"

echo "==> PASS: cleanup-worktrees dry-runs, removes safe candidates, refuses dirty worktrees by default, and handles PID locks safely"
