#!/usr/bin/env bash
#
# tests/test-worker.sh — verify touchstone worker lifecycle commands.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-worker.XXXXXX)"
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

assert_json_value() {
  local file="$1" key="$2" expected="$3"
  if ! grep -q "\"$key\":\"$expected\"" "$file"; then
    fail "expected JSON key $key to equal $expected"
    cat "$file" >&2
  fi
}

setup_repo_with_origin() {
  local repo="$1" origin="$2"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null 2>&1
  git -C "$repo" config user.name "Touchstone Test"
  git -C "$repo" config user.email "touchstone@example.com"
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m "base commit" >/dev/null 2>&1
  git init --bare "$origin" >/dev/null 2>&1
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -u origin main >/dev/null 2>&1
}

make_fake_gh() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "pr list")
    field=""
    while [ "$#" -gt 0 ]; do
      if [ "${1:-}" = "--jq" ]; then
        field="$2"
        break
      fi
      shift
    done
    case "$field" in
      *number*) printf '%s\n' "${GH_PR_NUMBER:-}" ;;
      *url*) printf '%s\n' "${GH_PR_URL:-}" ;;
      *state*) printf '%s\n' "${GH_PR_STATE:-}" ;;
      *mergedAt*) printf '%s\n' "${GH_PR_MERGED_AT:-}" ;;
      *) printf '\n' ;;
    esac
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/gh"
}

echo "==> Case a: worker spawn creates a worktree, JSON, and event"
REPO="$TEST_DIR/repo"
ORIGIN="$TEST_DIR/origin.git"
setup_repo_with_origin "$REPO" "$ORIGIN"
SPAWN_EVENTS="$TEST_DIR/spawn-events.ndjson"
SPAWN_JSON="$TEST_DIR/spawn.json"
(
  cd "$REPO"
  TOUCHSTONE_EVENTS_FILE="$SPAWN_EVENTS" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker spawn \
    --task "Fix Worker Lifecycle!" \
    --type fix \
    --json >"$SPAWN_JSON"
)
WORKTREE_PATH="$(sed -n 's/.*"worktree_path":"\([^"]*\)".*/\1/p' "$SPAWN_JSON")"
if [ ! -d "$WORKTREE_PATH" ]; then
  fail "spawn did not create worktree at $WORKTREE_PATH"
fi
assert_json_value "$SPAWN_JSON" branch "fix/fix-worker-lifecycle"
assert_json_value "$SPAWN_JSON" base_branch "main"
assert_contains "$SPAWN_EVENTS" '"event":"worker_spawned"'
assert_contains "$SPAWN_EVENTS" '"task":"Fix Worker Lifecycle!"'

echo "==> Case b: worker status derives spawned, working, dirty, PR, reviewing, and merged states"
STATUS_JSON="$TEST_DIR/status.json"
(
  cd "$REPO"
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
)
assert_json_value "$STATUS_JSON" state "spawned"

printf 'change\n' >>"$WORKTREE_PATH/file.txt"
git -C "$WORKTREE_PATH" add file.txt
git -C "$WORKTREE_PATH" commit -m "worker change" >/dev/null 2>&1
(
  cd "$REPO"
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
)
assert_json_value "$STATUS_JSON" state "working"

printf 'dirty\n' >>"$WORKTREE_PATH/file.txt"
(
  cd "$REPO"
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
)
assert_json_value "$STATUS_JSON" state "dirty"
git -C "$WORKTREE_PATH" checkout -- file.txt

FAKE_GH="$TEST_DIR/fake-gh"
make_fake_gh "$FAKE_GH"
PATH="$FAKE_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_PR_NUMBER=138 \
  GH_PR_URL="https://example.test/autumngarage/touchstone/pull/138" \
  GH_PR_STATE=OPEN \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
assert_json_value "$STATUS_JSON" state "pr_opened"
assert_contains "$STATUS_JSON" '"pr_number":138'

COMMON_DIR="$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)"
mkdir -p "$COMMON_DIR/touchstone/reviewer-clean"
cat >"$COMMON_DIR/touchstone/reviewer-clean/fix_fix-worker-lifecycle.clean" <<'EOF'
result=CODEX_REVIEW_CLEAN
branch=fix/fix-worker-lifecycle
EOF
PATH="$FAKE_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_PR_STATE=OPEN \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
assert_json_value "$STATUS_JSON" state "reviewing"

PATH="$FAKE_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_PR_STATE=MERGED \
  GH_PR_MERGED_AT=2026-05-06T12:00:00Z \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
assert_json_value "$STATUS_JSON" state "cleanup_failed"
assert_json_value "$STATUS_JSON" merged_at "2026-05-06T12:00:00Z"

PATH="$FAKE_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_PR_STATE=CLOSED \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
assert_json_value "$STATUS_JSON" state "abandoned"

mkdir -p "$COMMON_DIR/touchstone/reviewer-blocked"
: >"$COMMON_DIR/touchstone/reviewer-blocked/fix_fix-worker-lifecycle.blocked"
PATH="$FAKE_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_PR_STATE=CLOSED \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
assert_json_value "$STATUS_JSON" state "review_blocked"

echo "==> Case c: worker list filters lifecycle branches"
LIST_JSON="$TEST_DIR/list.json"
PATH="$FAKE_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_PR_STATE=OPEN \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker list --repo "$REPO" --json >"$LIST_JSON"
assert_contains "$LIST_JSON" '"branch":"fix/fix-worker-lifecycle"'

echo "==> Case d: worker ship delegates to project-local open-pr with cleanup and events env"
SHIP_WT="$TEST_DIR/ship-worktree"
mkdir -p "$SHIP_WT/scripts"
cat >"$SHIP_WT/scripts/open-pr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$SHIP_ARGS_FILE"
printf '%s\n' "${TOUCHSTONE_EVENTS_FILE:-}" > "$SHIP_EVENTS_FILE"
EOF
chmod +x "$SHIP_WT/scripts/open-pr.sh"
SHIP_ARGS_FILE="$TEST_DIR/ship-args" \
  SHIP_EVENTS_FILE="$TEST_DIR/ship-events-env" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$SHIP_WT" \
  --cleanup \
  --events-json "$TEST_DIR/ship-events.ndjson"
if ! grep -q -- '--auto-merge --cleanup-worktree' "$TEST_DIR/ship-args"; then
  fail "worker ship did not pass expected open-pr args"
  cat "$TEST_DIR/ship-args" >&2
fi
if ! grep -q "$TEST_DIR/ship-events.ndjson" "$TEST_DIR/ship-events-env"; then
  fail "worker ship did not forward TOUCHSTONE_EVENTS_FILE"
fi

echo "==> Case e: worker abandon refuses unique work and removes spawned worktrees"
if "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon --worktree "$WORKTREE_PATH" >"$TEST_DIR/abandon-refuse.out" 2>&1; then
  fail "worker abandon should refuse unique commits without --force"
fi
assert_contains "$TEST_DIR/abandon-refuse.out" 'refusing to abandon'

SAFE_JSON="$TEST_DIR/safe-spawn.json"
SAFE_EVENTS="$TEST_DIR/safe-events.ndjson"
(
  cd "$REPO"
  TOUCHSTONE_EVENTS_FILE="$SAFE_EVENTS" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker spawn \
    --task "Docs noop" \
    --type docs \
    --json >"$SAFE_JSON"
)
SAFE_WORKTREE="$(sed -n 's/.*"worktree_path":"\([^"]*\)".*/\1/p' "$SAFE_JSON")"
ABANDON_EVENTS="$TEST_DIR/abandon-events.ndjson"
TOUCHSTONE_EVENTS_FILE="$ABANDON_EVENTS" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon --worktree "$SAFE_WORKTREE" >"$TEST_DIR/abandon.out" 2>&1
if [ -d "$SAFE_WORKTREE" ]; then
  fail "worker abandon did not remove spawned worktree"
fi
assert_contains "$ABANDON_EVENTS" '"event":"worker_abandoned"'
assert_contains "$ABANDON_EVENTS" '"branch":"docs/docs-noop"'

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: worker lifecycle commands derive state and delegate safely"
  exit 0
fi

echo "==> FAIL: $ERRORS worker assertion(s) failed" >&2
exit 1
