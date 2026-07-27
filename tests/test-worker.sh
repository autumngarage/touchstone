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

make_failing_gh() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "pr list")
    echo "simulated gh pr list failure" >&2
    exit 42
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
ORIGIN_URL="$(git -C "$REPO" remote get-url origin)"
git -C "$REPO" remote set-url origin https://github.com/autumngarage/touchstone-test.git
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
git -C "$REPO" remote set-url origin "$ORIGIN_URL"

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

echo "==> Case d2: detached worker ship persists lifecycle state and supports takeover"
DETACHED_WT="$TEST_DIR/detached-ship-worktree"
git -C "$REPO" worktree add -q "$DETACHED_WT" -b feat/detached-ship-test main

write_detached_open_pr() {
  local worktree="$1"
  mkdir -p "$worktree/scripts"
  cat >"$worktree/scripts/open-pr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "detached runner started"
printf 'started\n' >"$SHIP_STARTED_FILE"
sleep "${SHIP_SLEEP_SECONDS:-0}"
echo "detached runner finished"
exit "${SHIP_EXIT_CODE:-0}"
EOF
  chmod +x "$worktree/scripts/open-pr.sh"
}
write_detached_open_pr "$DETACHED_WT"

wait_for_ship_status() {
  local worktree="$1" expected="$2" output_file="$3" attempts=0
  while [ "$attempts" -lt 100 ]; do
    "$TOUCHSTONE_ROOT/bin/touchstone" worker status \
      --worktree "$worktree" --json >"$output_file"
    if grep -q "\"status\":\"$expected\"" "$output_file"; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  return 1
}

DETACHED_EVENTS="$TEST_DIR/detached-events.ndjson"
DETACHED_STATUS="$TEST_DIR/detached-status.json"
SHIP_STARTED_FILE="$TEST_DIR/detached-started" \
  SHIP_SLEEP_SECONDS=10 \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$DETACHED_WT" \
  --detach \
  --events-json "$DETACHED_EVENTS" >"$TEST_DIR/detached-start.out"
if ! wait_for_ship_status "$DETACHED_WT" running "$DETACHED_STATUS"; then
  fail "detached ship did not enter running state"
  cat "$DETACHED_STATUS" >&2
fi
assert_contains "$DETACHED_STATUS" '"log_path":'
assert_contains "$DETACHED_EVENTS" '"event":"worker_ship_started"'

if SHIP_STARTED_FILE="$TEST_DIR/duplicate-started" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$DETACHED_WT" --detach >"$TEST_DIR/detached-duplicate.out" 2>&1; then
  fail "detached ship should refuse a duplicate active job"
fi
assert_contains "$TEST_DIR/detached-duplicate.out" 'already active'

if "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon \
  --worktree "$DETACHED_WT" --force >"$TEST_DIR/detached-abandon.out" 2>&1; then
  fail "worker abandon should refuse an active detached ship"
fi
assert_contains "$TEST_DIR/detached-abandon.out" 'detached shipping is active'

"$TOUCHSTONE_ROOT/bin/touchstone" worker takeover \
  --worktree "$DETACHED_WT" >"$TEST_DIR/detached-takeover.out"
if ! wait_for_ship_status "$DETACHED_WT" stopped "$DETACHED_STATUS"; then
  fail "takeover did not stop detached shipping"
  cat "$DETACHED_STATUS" >&2
fi
if [ ! -d "$DETACHED_WT" ]; then
  fail "takeover removed the worker worktree"
fi

SHIP_STARTED_FILE="$TEST_DIR/success-started" \
  SHIP_EXIT_CODE=0 \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$DETACHED_WT" \
  --detach \
  --events-json "$DETACHED_EVENTS" >/dev/null
if ! wait_for_ship_status "$DETACHED_WT" succeeded "$DETACHED_STATUS"; then
  fail "detached ship did not persist success"
  cat "$DETACHED_STATUS" >&2
fi
assert_contains "$DETACHED_STATUS" '"exit_code":0'
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" \
  --show-log \
  --log-lines 5 >"$TEST_DIR/detached-log.out"
assert_contains "$TEST_DIR/detached-log.out" 'detached runner finished'

git -C "$REPO" worktree remove --force "$DETACHED_WT"
(
  cd "$REPO"
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status \
    --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
)
assert_contains "$DETACHED_STATUS" '"status":"succeeded"'
assert_contains "$DETACHED_STATUS" '"exit_code":0'
git -C "$REPO" worktree add -q "$DETACHED_WT" feat/detached-ship-test
write_detached_open_pr "$DETACHED_WT"

SHIP_STARTED_FILE="$TEST_DIR/failure-started" \
  SHIP_EXIT_CODE=23 \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$DETACHED_WT" --detach >/dev/null
if ! wait_for_ship_status "$DETACHED_WT" failed "$DETACHED_STATUS"; then
  fail "detached ship did not persist failure"
  cat "$DETACHED_STATUS" >&2
fi
assert_contains "$DETACHED_STATUS" '"exit_code":23'

DETACHED_JOB_DIR="$(dirname "$(sed -n 's/.*"log_path":"\([^"]*\)".*/\1/p' "$DETACHED_STATUS")")"
printf 'running\n' >"$DETACHED_JOB_DIR/status"
printf '999999\n' >"$DETACHED_JOB_DIR/pid"
mkdir -p "$DETACHED_JOB_DIR/active"
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
assert_contains "$DETACHED_STATUS" '"status":"failed"'
assert_contains "$DETACHED_STATUS" '"exit_code":125'
assert_contains "$DETACHED_STATUS" '"reason":"stale-runner"'

printf 'starting\n' >"$DETACHED_JOB_DIR/status"
printf '%s\n' "$$" >"$DETACHED_JOB_DIR/pid"
printf '%s\n' "$(($(date +%s) - 10))" >"$DETACHED_JOB_DIR/started-epoch"
mkdir -p "$DETACHED_JOB_DIR/active"
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
assert_contains "$DETACHED_STATUS" '"status":"failed"'
assert_contains "$DETACHED_STATUS" '"reason":"stale-runner"'
assert_contains "$DETACHED_EVENTS" '"event":"worker_ship_finished"'

echo "==> Case d2b: concurrent startup preserves the first atomic claim"
ATOMIC_JOB_DIR="$TEST_DIR/atomic-claim-job"
# shellcheck source=../lib/worker-ship-job.sh
source "$TOUCHSTONE_ROOT/lib/worker-ship-job.sh"
touchstone_ship_claim "$ATOMIC_JOB_DIR"
(
  sleep 0.1
  touchstone_ship_refresh "$ATOMIC_JOB_DIR"
) &
ATOMIC_REFRESH_PID=$!
if touchstone_ship_claim "$ATOMIC_JOB_DIR"; then
  fail "concurrent detached startup acquired an existing claim"
fi
wait "$ATOMIC_REFRESH_PID"
if [ ! -d "$ATOMIC_JOB_DIR/active" ]; then
  fail "refresh removed a newly created detached startup claim"
fi
rmdir "$ATOMIC_JOB_DIR/active"

echo "==> Case d3: detached jobs do not collide when branch names sanitize alike"
COLLISION_SLASH_WT="$TEST_DIR/collision-slash-worktree"
COLLISION_UNDERSCORE_WT="$TEST_DIR/collision-underscore-worktree"
COLLISION_SLASH_STATUS="$TEST_DIR/collision-slash-status.json"
COLLISION_UNDERSCORE_STATUS="$TEST_DIR/collision-underscore-status.json"
git -C "$REPO" worktree add -q "$COLLISION_SLASH_WT" -b feat/collision/a main
git -C "$REPO" worktree add -q "$COLLISION_UNDERSCORE_WT" -b feat/collision_a main
write_detached_open_pr "$COLLISION_SLASH_WT"
write_detached_open_pr "$COLLISION_UNDERSCORE_WT"

SHIP_STARTED_FILE="$TEST_DIR/collision-slash-started" \
  SHIP_SLEEP_SECONDS=10 \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$COLLISION_SLASH_WT" --detach >/dev/null
if ! wait_for_ship_status "$COLLISION_SLASH_WT" running "$COLLISION_SLASH_STATUS"; then
  fail "slash-branch detached ship did not enter running state"
fi
COLLISION_SLASH_LOG="$(sed -n 's/.*"log_path":"\([^"]*\)".*/\1/p' "$COLLISION_SLASH_STATUS")"
git -C "$COLLISION_SLASH_WT" branch -m feat/collision/renamed
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$COLLISION_SLASH_WT" --json >"$COLLISION_SLASH_STATUS"
assert_contains "$COLLISION_SLASH_STATUS" "\"log_path\":\"$COLLISION_SLASH_LOG\""
if SHIP_STARTED_FILE="$TEST_DIR/renamed-duplicate-started" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$COLLISION_SLASH_WT" --detach >"$TEST_DIR/renamed-duplicate.out" 2>&1; then
  fail "branch rename allowed a duplicate detached job for one worktree"
fi
assert_contains "$TEST_DIR/renamed-duplicate.out" 'already active'
if ! SHIP_STARTED_FILE="$TEST_DIR/collision-underscore-started" \
  SHIP_SLEEP_SECONDS=10 \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$COLLISION_UNDERSCORE_WT" --detach >"$TEST_DIR/collision-start.out" 2>&1; then
  fail "sanitized branch-name collision blocked an independent detached job"
fi
if ! wait_for_ship_status "$COLLISION_UNDERSCORE_WT" running "$COLLISION_UNDERSCORE_STATUS"; then
  fail "underscore-branch detached ship did not enter running state"
fi
COLLISION_UNDERSCORE_LOG="$(sed -n 's/.*"log_path":"\([^"]*\)".*/\1/p' "$COLLISION_UNDERSCORE_STATUS")"
if [ "$COLLISION_SLASH_LOG" = "$COLLISION_UNDERSCORE_LOG" ]; then
  fail "distinct branches resolved to the same detached job directory"
fi
"$TOUCHSTONE_ROOT/bin/touchstone" worker takeover \
  --worktree "$COLLISION_SLASH_WT" >/dev/null
"$TOUCHSTONE_ROOT/bin/touchstone" worker takeover \
  --worktree "$COLLISION_UNDERSCORE_WT" >/dev/null

echo "==> Case e: worker abandon refuses unique work and removes spawned worktrees"
if "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon --worktree "$WORKTREE_PATH" >"$TEST_DIR/abandon-refuse.out" 2>&1; then
  fail "worker abandon should refuse unique commits without --force"
fi
assert_contains "$TEST_DIR/abandon-refuse.out" 'refusing to abandon'

NO_DEFAULT_REPO="$TEST_DIR/no-default-repo"
NO_DEFAULT_WT="$TEST_DIR/no-default-worktree"
git init -q -b trunk "$NO_DEFAULT_REPO"
git -C "$NO_DEFAULT_REPO" config user.name "Touchstone Test"
git -C "$NO_DEFAULT_REPO" config user.email "touchstone@example.com"
# Force default-ref discovery to try a configured branch that does not exist,
# then main/master. This repo intentionally has only trunk plus the worker branch.
git -C "$NO_DEFAULT_REPO" config init.defaultBranch missing-default
printf 'base\n' >"$NO_DEFAULT_REPO/file.txt"
git -C "$NO_DEFAULT_REPO" add file.txt
git -C "$NO_DEFAULT_REPO" commit -qm "base commit"
git -C "$NO_DEFAULT_REPO" worktree add -q "$NO_DEFAULT_WT" -b fix/no-default trunk
printf 'unique\n' >"$NO_DEFAULT_WT/unique.txt"
git -C "$NO_DEFAULT_WT" add unique.txt
git -C "$NO_DEFAULT_WT" commit -qm "unique worker work"

NO_DEFAULT_STATUS="$TEST_DIR/no-default-status.json"
"$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$NO_DEFAULT_WT" --json >"$NO_DEFAULT_STATUS"
assert_json_value "$NO_DEFAULT_STATUS" state "unknown"
if "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon --worktree "$NO_DEFAULT_WT" >"$TEST_DIR/abandon-no-default.out" 2>&1; then
  fail "worker abandon should refuse when default ref cannot be resolved"
fi
assert_contains "$TEST_DIR/abandon-no-default.out" 'could not resolve a default branch ref'
if [ ! -d "$NO_DEFAULT_WT" ]; then
  fail "worker abandon removed worktree when default ref resolution failed"
fi

FAILING_GH="$TEST_DIR/failing-gh"
make_failing_gh "$FAILING_GH"
GITHUBISH_ORIGIN="$TEST_DIR/github.com/origin.git"
PR_LOOKUP_FAIL_WT="$TEST_DIR/pr-lookup-fail-worktree"
mkdir -p "$(dirname "$GITHUBISH_ORIGIN")"
ln -s "$ORIGIN" "$GITHUBISH_ORIGIN"
git -C "$REPO" branch fix/pr-lookup-fail main
git -C "$REPO" push origin fix/pr-lookup-fail >/dev/null 2>&1
git -C "$REPO" worktree add -q "$PR_LOOKUP_FAIL_WT" fix/pr-lookup-fail
git -C "$REPO" remote set-url origin "$GITHUBISH_ORIGIN"

PR_LOOKUP_FAIL_STATUS="$TEST_DIR/pr-lookup-fail-status.json"
PATH="$FAILING_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status --worktree "$WORKTREE_PATH" --json >"$PR_LOOKUP_FAIL_STATUS" 2>"$TEST_DIR/pr-lookup-fail-status.err"
assert_json_value "$PR_LOOKUP_FAIL_STATUS" state "unknown"

if PATH="$FAILING_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon --worktree "$PR_LOOKUP_FAIL_WT" >"$TEST_DIR/abandon-pr-lookup-fail.out" 2>&1; then
  fail "worker abandon should refuse when PR lookup fails before remote branch deletion"
fi
assert_contains "$TEST_DIR/abandon-pr-lookup-fail.out" 'could not inspect PRs before deleting origin/fix/pr-lookup-fail'
if [ ! -d "$PR_LOOKUP_FAIL_WT" ]; then
  fail "worker abandon removed worktree when PR lookup failed"
fi
if ! git -C "$REPO" ls-remote --exit-code --heads origin fix/pr-lookup-fail >/dev/null 2>&1; then
  fail "worker abandon deleted remote branch when PR lookup failed"
fi

PATH="$FAILING_GH:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon --worktree "$PR_LOOKUP_FAIL_WT" --force >"$TEST_DIR/abandon-pr-lookup-force.out" 2>&1
assert_contains "$TEST_DIR/abandon-pr-lookup-force.out" 'Kept remote branch because PR state could not be inspected for: fix/pr-lookup-fail'
if [ -d "$PR_LOOKUP_FAIL_WT" ]; then
  fail "worker abandon --force preserved worktree when PR lookup failed"
fi
if ! git -C "$REPO" ls-remote --exit-code --heads origin fix/pr-lookup-fail >/dev/null 2>&1; then
  fail "worker abandon --force deleted remote branch when PR lookup failed"
fi
git -C "$REPO" remote set-url origin "$ORIGIN_URL"

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
printf 'dirty\n' >"$SAFE_WORKTREE/uncommitted.txt"
if "$TOUCHSTONE_ROOT/bin/touchstone" worker abandon --worktree "$SAFE_WORKTREE" >"$TEST_DIR/abandon-dirty.out" 2>&1; then
  fail "worker abandon should refuse dirty worktrees without --force"
fi
assert_contains "$TEST_DIR/abandon-dirty.out" 'worktree has uncommitted changes'
if [ ! -d "$SAFE_WORKTREE" ]; then
  fail "worker abandon removed dirty worktree without --force"
fi
rm "$SAFE_WORKTREE/uncommitted.txt"
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
