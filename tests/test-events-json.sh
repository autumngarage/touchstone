#!/usr/bin/env bash
#
# tests/test-events-json.sh — verify opt-in lifecycle NDJSON events.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=stage-touchstone-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/stage-touchstone-libs.sh"

TEST_DIR="$(mktemp -d -t touchstone-test-events.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_contains() {
  local file="$1" pattern="$2"
  if ! grep -qE "$pattern" "$file"; then
    fail "expected $file to contain: $pattern"
    [ -f "$file" ] && cat "$file" >&2
  fi
}

assert_not_contains() {
  local file="$1" pattern="$2"
  if grep -qE "$pattern" "$file"; then
    fail "expected $file not to contain: $pattern"
    cat "$file" >&2
  fi
}

assert_event_order() {
  local file="$1"
  shift
  local expected="$*" actual
  actual="$(sed -n 's/.*"event":"\([^"]*\)".*/\1/p' "$file" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ "$actual" != "$expected" ]; then
    fail "event order mismatch: expected '$expected', got '$actual'"
    cat "$file" >&2
  fi
}

assert_json_lines() {
  local file="$1"
  if [ ! -s "$file" ]; then
    fail "expected non-empty events file: $file"
    return
  fi
  if grep -nvE '^\{"event":"[^"]+","ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z","script":"[^"]+"' "$file"; then
    fail "events file has malformed required fields: $file"
    cat "$file" >&2
  fi
}

copy_event_scripts() {
  local dst="$1"
  mkdir -p "$dst/scripts" "$dst/lib"
  cp "$TOUCHSTONE_ROOT/lib/events.sh" "$dst/lib/events.sh"
  cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$dst/scripts/open-pr.sh"
  stage_touchstone_libs "$TOUCHSTONE_ROOT" "$dst/scripts"
  cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$dst/scripts/issue-claim-check.sh"
  cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$dst/scripts/merge-pr.sh"
  chmod +x "$dst/scripts/"*.sh
}

setup_git_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null 2>&1
  git -C "$repo" config user.name "Touchstone Test"
  git -C "$repo" config user.email "touchstone@example.com"
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m "base commit" >/dev/null 2>&1
}

echo "==> Case a: spawn-worktree emits worktree_created"
SPAWN_REPO="$TEST_DIR/spawn-repo"
setup_git_repo "$SPAWN_REPO"
SPAWN_REPO_REAL="$(cd "$SPAWN_REPO" && pwd -P)"
SPAWN_EVENTS="$TEST_DIR/spawn-events.ndjson"
SPAWN_WORKTREE="$TEST_DIR/spawn-worktree"
(
  cd "$SPAWN_REPO"
  TOUCHSTONE_EVENTS_FILE="$SPAWN_EVENTS" \
    bash "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" "feat/events-one" "$SPAWN_WORKTREE" >"$TEST_DIR/spawn.out" 2>&1
)
assert_json_lines "$SPAWN_EVENTS"
assert_event_order "$SPAWN_EVENTS" worktree_created
assert_contains "$SPAWN_EVENTS" '"branch":"feat/events-one"'
assert_contains "$SPAWN_EVENTS" "\"worktree_path\":\"$SPAWN_WORKTREE\""
assert_contains "$SPAWN_EVENTS" '"base_branch":"main"'
assert_contains "$SPAWN_EVENTS" "\"repo_root\":\"$SPAWN_REPO_REAL\""

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: worktree event stream is opt-in, ordered, and machine-readable"
  exit 0
fi

echo "==> FAIL: $ERRORS event assertion(s) failed" >&2
exit 1
