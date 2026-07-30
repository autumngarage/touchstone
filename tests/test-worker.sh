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

assert_contains_fixed() {
  local file="$1" text="$2"
  if ! grep -qF "$text" "$file"; then
    fail "expected $file to contain: $text"
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

STATUS_GIT_BIN="$TEST_DIR/status-git-bin"
STATUS_GIT_LOG="$TEST_DIR/status-git.log"
mkdir -p "$STATUS_GIT_BIN"
cat >"$STATUS_GIT_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" status --porcelain "* ]]; then
  printf '%s\n' "${GIT_OPTIONAL_LOCKS-unset}" >>"$STATUS_GIT_LOG"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$STATUS_GIT_BIN/git"
REAL_GIT="$(command -v git)" STATUS_GIT_LOG="$STATUS_GIT_LOG" \
PATH="$STATUS_GIT_BIN:$PATH" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$WORKTREE_PATH" --json >"$STATUS_JSON"
if [ ! -s "$STATUS_GIT_LOG" ] || grep -Ev '^0$' "$STATUS_GIT_LOG" >/dev/null; then
  fail "worker status did not disable optional Git index locks"
  [ ! -f "$STATUS_GIT_LOG" ] || cat "$STATUS_GIT_LOG" >&2
fi

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
  TOUCHSTONE_EVENTS_FILE="$TEST_DIR/inherited-ship-events.ndjson" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$SHIP_WT" \
  --cleanup \
  --events-json "$TEST_DIR/ship-events.ndjson"
if ! grep -q -- '--auto-merge --cleanup-worktree' "$TEST_DIR/ship-args"; then
  fail "worker ship did not pass expected open-pr args"
  cat "$TEST_DIR/ship-args" >&2
fi
if ! grep -q "$TEST_DIR/ship-events.ndjson" "$TEST_DIR/ship-events-env"; then
  fail "explicit worker ship events path did not override inherited TOUCHSTONE_EVENTS_FILE"
fi

SHIP_ARGS_FILE="$TEST_DIR/ship-inherited-args" \
  SHIP_EVENTS_FILE="$TEST_DIR/ship-inherited-events-env" \
  TOUCHSTONE_EVENTS_FILE="$TEST_DIR/inherited-ship-events.ndjson" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$SHIP_WT"
if ! grep -q "$TEST_DIR/inherited-ship-events.ndjson" "$TEST_DIR/ship-inherited-events-env"; then
  fail "worker ship did not preserve inherited TOUCHSTONE_EVENTS_FILE"
fi

echo "==> Case d2: detached worker ship persists lifecycle state and supports takeover"
DETACHED_WT="$TEST_DIR/detached ship 'worktree"
git -C "$REPO" worktree add -q "$DETACHED_WT" -b feat/detached-ship-test main
DETACHED_WT="$(cd "$DETACHED_WT" && pwd -P)"
DETACHED_REPO="$(cd "$REPO" && pwd -P)"
QUOTED_DETACHED_WT="$(printf '%q' "$DETACHED_WT")"
QUOTED_DETACHED_REPO="$(printf '%q' "$DETACHED_REPO")"

write_detached_open_pr() {
  local worktree="$1"
  mkdir -p "$worktree/scripts"
  cat >"$worktree/scripts/open-pr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "detached runner started"
printf 'started\n' >"$SHIP_STARTED_FILE"
if [ "${SHIP_RECORD_CHILD_EVENT:-0}" = 1 ]; then
  printf '%s\n' "$TOUCHSTONE_EVENTS_FILE" >"$SHIP_CHILD_EVENT_PATH_FILE"
  printf '{"event":"open_pr_child"}\n' >>"$TOUCHSTONE_EVENTS_FILE"
fi
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
DETACHED_RUNNER_PID="$(
  sed -nE 's/.*"ship":\{[^}]*"pid":([0-9]+).*/\1/p' "$DETACHED_STATUS"
)"
DETACHED_RUNNING_JOB_DIR="$(
  dirname "$(sed -n 's/.*"log_path":"\([^"]*\)".*/\1/p' "$DETACHED_STATUS")"
)"
DETACHED_CLAIM_OWNER="$(sed -n 's/^owner-pid=//p' "$DETACHED_RUNNING_JOB_DIR/active")"
if [ "$DETACHED_CLAIM_OWNER" != "$DETACHED_RUNNER_PID" ]; then
  fail "detached runner did not take ownership of the active claim"
fi
if [ -z "$(sed -n 's/^owner-start=//p' "$DETACHED_RUNNING_JOB_DIR/active")" ]; then
  fail "detached runner claim did not record process birth identity"
fi
DETACHED_RUNNER_PGID="$(ps -p "$DETACHED_RUNNER_PID" -o pgid= | tr -d '[:space:]')"
TEST_PGID="$(ps -p "$$" -o pgid= | tr -d '[:space:]')"
if [ -z "$DETACHED_RUNNER_PGID" ] || [ "$DETACHED_RUNNER_PGID" = "$TEST_PGID" ]; then
  fail "detached runner remained in the invoking process group"
fi
assert_contains_fixed "$TEST_DIR/detached-start.out" \
  "Status: touchstone worker status --repo $QUOTED_DETACHED_REPO --worktree $QUOTED_DETACHED_WT --show-log"
assert_contains_fixed "$TEST_DIR/detached-start.out" \
  "Take over: touchstone worker takeover --worktree $QUOTED_DETACHED_WT"
assert_contains "$TEST_DIR/detached-start.out" "Events: $DETACHED_EVENTS"

if SHIP_STARTED_FILE="$TEST_DIR/duplicate-started" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$DETACHED_WT" --detach >"$TEST_DIR/detached-duplicate.out" 2>&1; then
  fail "detached ship should refuse a duplicate active job"
fi
assert_contains "$TEST_DIR/detached-duplicate.out" 'already active'
assert_contains_fixed "$TEST_DIR/detached-duplicate.out" \
  "Inspect it with: touchstone worker status --worktree $QUOTED_DETACHED_WT --show-log"

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

git -C "$DETACHED_WT" checkout -q --detach
git -C "$REPO" branch -D feat/detached-ship-test >/dev/null
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
assert_contains "$DETACHED_STATUS" '"status":"succeeded"'
assert_contains "$DETACHED_STATUS" '"exit_code":0'
git -C "$DETACHED_WT" switch -q -c feat/detached-ship-test

RELATIVE_EVENTS_CALLER="$TEST_DIR/relative-events-caller"
mkdir -p "$RELATIVE_EVENTS_CALLER"
RELATIVE_EVENTS_FILE="$(cd "$RELATIVE_EVENTS_CALLER" && pwd -P)/relative-events.ndjson"
(
  cd "$RELATIVE_EVENTS_CALLER"
  SHIP_STARTED_FILE="$TEST_DIR/relative-events-started" \
    SHIP_EXIT_CODE=0 \
    SHIP_RECORD_CHILD_EVENT=1 \
    SHIP_CHILD_EVENT_PATH_FILE="$TEST_DIR/relative-events-path" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$DETACHED_WT" \
    --detach \
    --events-json relative-events.ndjson >/dev/null
)
if ! wait_for_ship_status "$DETACHED_WT" succeeded "$DETACHED_STATUS"; then
  fail "relative-event detached ship did not persist success"
fi
assert_contains "$TEST_DIR/relative-events-path" "^$RELATIVE_EVENTS_FILE$"
assert_contains "$RELATIVE_EVENTS_FILE" '"event":"worker_ship_started"'
assert_contains "$RELATIVE_EVENTS_FILE" '"event":"open_pr_child"'
assert_contains "$RELATIVE_EVENTS_FILE" '"event":"worker_ship_finished"'
if [ -e "$DETACHED_WT/relative-events.ndjson" ]; then
  fail "relative detached event stream split into the worker worktree"
fi

"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" \
  --show-log \
  --log-lines 5 >"$TEST_DIR/detached-log.out"
assert_contains "$TEST_DIR/detached-log.out" 'detached runner finished'

git -C "$REPO" worktree remove --force "$DETACHED_WT"
REMOVED_STATUS_CALLER="$TEST_DIR/removed-status-caller"
mkdir -p "$REMOVED_STATUS_CALLER"
(
  cd "$REMOVED_STATUS_CALLER"
  "$TOUCHSTONE_ROOT/bin/touchstone" worker status \
    --repo "$DETACHED_REPO" --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
)
assert_contains "$DETACHED_STATUS" '"status":"succeeded"'
assert_contains "$DETACHED_STATUS" '"exit_code":0'
git -C "$REPO" worktree add -q "$DETACHED_WT" feat/detached-ship-test
write_detached_open_pr "$DETACHED_WT"

SHIP_STARTED_FILE="$TEST_DIR/failure-started" \
  SHIP_EXIT_CODE=23 \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$DETACHED_WT" --detach >/dev/null
if ! wait_for_ship_status "$DETACHED_WT" needs-attention "$DETACHED_STATUS"; then
  fail "detached ship did not preserve a nonzero result for takeover"
  cat "$DETACHED_STATUS" >&2
fi
assert_contains "$DETACHED_STATUS" '"exit_code":23'
assert_contains "$DETACHED_STATUS" '"reason":"shipping-needs-attention"'
assert_contains "$DETACHED_STATUS" '"events_path":"[^"]*/events.ndjson"'
DEFAULT_EVENTS_PATH="$(sed -n 's/.*"events_path":"\([^"]*\)".*/\1/p' "$DETACHED_STATUS")"
assert_contains "$DEFAULT_EVENTS_PATH" '"event":"worker_ship_finished"'
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" --show-log >"$TEST_DIR/detached-needs-attention.out"
assert_contains "$TEST_DIR/detached-needs-attention.out" "Take over: touchstone worker takeover"
assert_contains_fixed "$TEST_DIR/detached-needs-attention.out" \
  "Take over: touchstone worker takeover --worktree $QUOTED_DETACHED_WT"
"$TOUCHSTONE_ROOT/bin/touchstone" worker takeover \
  --worktree "$DETACHED_WT" >"$TEST_DIR/detached-needs-attention-takeover.out"
assert_contains "$DEFAULT_EVENTS_PATH" '"event":"worker_ship_takeover"'

DETACHED_JOB_DIR="$(dirname "$(sed -n 's/.*"log_path":"\([^"]*\)".*/\1/p' "$DETACHED_STATUS")")"
printf 'running\n' >"$DETACHED_JOB_DIR/status"
printf '999999\n' >"$DETACHED_JOB_DIR/pid"
mkdir -p "$DETACHED_JOB_DIR/active"
printf '%s\n' "$(($(date +%s) - 2))" >"$DETACHED_JOB_DIR/suspected-stale-at"
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
assert_contains "$DETACHED_STATUS" '"status":"failed"'
assert_contains "$DETACHED_STATUS" '"exit_code":125'
assert_contains "$DETACHED_STATUS" '"reason":"stale-runner"'

printf 'starting\n' >"$DETACHED_JOB_DIR/status"
printf '%s\n' "$$" >"$DETACHED_JOB_DIR/pid"
printf '%s\n' "$(date +%s)" >"$DETACHED_JOB_DIR/started-epoch"
mkdir -p "$DETACHED_JOB_DIR/active"
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
assert_contains "$DETACHED_STATUS" '"status":"starting"'
if [ ! -d "$DETACHED_JOB_DIR/active" ]; then
  fail "refresh removed a populated startup claim during its grace period"
fi

printf '%s\n' "$(($(date +%s) - 10))" >"$DETACHED_JOB_DIR/started-epoch"
printf '%s\n' "$(($(date +%s) - 2))" >"$DETACHED_JOB_DIR/suspected-stale-at"
"$TOUCHSTONE_ROOT/bin/touchstone" worker status \
  --worktree "$DETACHED_WT" --json >"$DETACHED_STATUS"
assert_contains "$DETACHED_STATUS" '"status":"failed"'
assert_contains "$DETACHED_STATUS" '"reason":"stale-runner"'
assert_contains "$DETACHED_EVENTS" '"event":"worker_ship_finished"'

echo "==> Case d2b: concurrent startup preserves the first atomic claim"
ATOMIC_JOB_DIR="$TEST_DIR/atomic-claim-job"
# shellcheck source=../lib/worker-ship-job.sh
source "$TOUCHSTONE_ROOT/lib/worker-ship-job.sh"
ATOMIC_TOKEN="$(touchstone_ship_claim "$ATOMIC_JOB_DIR" "$$")"
touch -t 200001010000 "$ATOMIC_JOB_DIR/active"
(
  sleep 0.1
  touchstone_ship_refresh "$ATOMIC_JOB_DIR"
) &
ATOMIC_REFRESH_PID=$!
if touchstone_ship_claim "$ATOMIC_JOB_DIR"; then
  fail "concurrent detached startup acquired an existing claim"
fi
wait "$ATOMIC_REFRESH_PID"
if ! touchstone_ship_claim_matches "$ATOMIC_JOB_DIR" "$ATOMIC_TOKEN"; then
  fail "refresh removed an aged claim whose owner was still live"
fi
touchstone_ship_release_claim "$ATOMIC_JOB_DIR" "$ATOMIC_TOKEN"

echo "==> Case d2c: refresh tolerates a transient runner identity inspection failure"
LIVE_OWNER_JOB_DIR="$TEST_DIR/live-owner-job"
LIVE_OWNER_BIN="$TEST_DIR/live-owner-bin"
LIVE_OWNER_PS_CALLS="$TEST_DIR/live-owner-ps-calls"
mkdir -p "$LIVE_OWNER_BIN"
cat >"$LIVE_OWNER_BIN/_ship-run" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
chmod +x "$LIVE_OWNER_BIN/_ship-run"
cat >"$LIVE_OWNER_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
calls=0
[ ! -f "$LIVE_OWNER_PS_CALLS" ] || calls="$(cat "$LIVE_OWNER_PS_CALLS")"
calls=$((calls + 1))
printf '%s\n' "$calls" >"$LIVE_OWNER_PS_CALLS"
if [ "$calls" -eq 1 ]; then
  exit 1
fi
exec "$REAL_PS" "$@"
EOF
chmod +x "$LIVE_OWNER_BIN/ps"
"$LIVE_OWNER_BIN/_ship-run" "$LIVE_OWNER_JOB_DIR" &
LIVE_RUNNER_PID=$!
LIVE_OWNER_TOKEN="$(touchstone_ship_claim "$LIVE_OWNER_JOB_DIR" "$$")"
touchstone_ship_transfer_claim "$LIVE_OWNER_JOB_DIR" "$LIVE_OWNER_TOKEN" "$LIVE_RUNNER_PID"
touchstone_ship_write "$LIVE_OWNER_JOB_DIR" status running
touchstone_ship_write "$LIVE_OWNER_JOB_DIR" pid "$LIVE_RUNNER_PID"
LIVE_OWNER_REAL_PS="$(command -v ps)"
PATH="$LIVE_OWNER_BIN:$PATH" \
  LIVE_OWNER_PS_CALLS="$LIVE_OWNER_PS_CALLS" \
  REAL_PS="$LIVE_OWNER_REAL_PS" \
  touchstone_ship_refresh "$LIVE_OWNER_JOB_DIR"
if [ "$(touchstone_ship_read "$LIVE_OWNER_JOB_DIR" status)" != "running" ] \
  || ! touchstone_ship_claim_matches "$LIVE_OWNER_JOB_DIR" "$LIVE_OWNER_TOKEN" \
  || [ "$(cat "$LIVE_OWNER_PS_CALLS")" -lt 2 ]; then
  fail "refresh replaced a live runner with stale-runner after a transient ps failure"
fi
kill "$LIVE_RUNNER_PID"
wait "$LIVE_RUNNER_PID" 2>/dev/null || true
touchstone_ship_release_claim "$LIVE_OWNER_JOB_DIR" "$LIVE_OWNER_TOKEN"

echo "==> Case d2d: a reused runner PID cannot keep a stale claim alive"
REUSED_PID_JOB_DIR="$TEST_DIR/reused-pid-job"
sleep 10 &
UNRELATED_PID=$!
REUSED_PID_TOKEN="$(touchstone_ship_claim "$REUSED_PID_JOB_DIR" "$UNRELATED_PID")"
cat >"$REUSED_PID_JOB_DIR/active" <<EOF_REUSED_PID
owner-pid=$UNRELATED_PID
owner-start=stale-process-birth
owner-token=$REUSED_PID_TOKEN
EOF_REUSED_PID
touchstone_ship_write "$REUSED_PID_JOB_DIR" status running
touchstone_ship_write "$REUSED_PID_JOB_DIR" pid "$UNRELATED_PID"
touchstone_ship_refresh "$REUSED_PID_JOB_DIR"
if [ "$(touchstone_ship_read "$REUSED_PID_JOB_DIR" status)" != "running" ]; then
  fail "one stale observation failed a runner before confirmation"
fi
touchstone_ship_write "$REUSED_PID_JOB_DIR" suspected-stale-at "$(($(date +%s) - 2))"
touchstone_ship_refresh "$REUSED_PID_JOB_DIR"
if [ "$(touchstone_ship_read "$REUSED_PID_JOB_DIR" status)" != "failed" ] \
  || [ "$(touchstone_ship_read "$REUSED_PID_JOB_DIR" reason)" != "stale-runner" ]; then
  fail "unrelated live process kept a stale runner claim alive"
fi
kill "$UNRELATED_PID"
wait "$UNRELATED_PID" 2>/dev/null || true

echo "==> Case d2e: terminal state is published before runner ownership is released"
INTERLEAVE_JOB_DIR="$TEST_DIR/finish-interleave-job"
INTERLEAVE_WT="$TEST_DIR/finish-interleave-worktree"
INTERLEAVE_BIN="$TEST_DIR/finish-interleave-bin"
INTERLEAVE_SIGNAL="$TEST_DIR/finish-interleave-signal"
INTERLEAVE_GATE="$TEST_DIR/finish-interleave-gate"
mkdir -p "$INTERLEAVE_WT/scripts" "$INTERLEAVE_BIN"
cat >"$INTERLEAVE_WT/scripts/open-pr.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$INTERLEAVE_WT/scripts/open-pr.sh"
cat >"$INTERLEAVE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
if [ "$(basename "$destination")" = "status" ] \
  && [ "$(cat "$source_path")" = "succeeded" ] \
  && [ -e "$INTERLEAVE_WATCH_JOB_DIR/active" ]; then
  : >"$INTERLEAVE_SIGNAL"
  while [ ! -e "$INTERLEAVE_GATE" ]; do
    sleep 0.05
  done
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$INTERLEAVE_BIN/mv"
PREDECESSOR_TOKEN="$(touchstone_ship_claim "$INTERLEAVE_JOB_DIR" "$$")"
touchstone_ship_write "$INTERLEAVE_JOB_DIR" branch feat/finish-interleave
PATH="$INTERLEAVE_BIN:$PATH" \
  REAL_MV="$(command -v mv)" \
  INTERLEAVE_WATCH_JOB_DIR="$INTERLEAVE_JOB_DIR" \
  INTERLEAVE_SIGNAL="$INTERLEAVE_SIGNAL" \
  INTERLEAVE_GATE="$INTERLEAVE_GATE" \
  "$TOUCHSTONE_ROOT/scripts/worker.sh" _ship-run \
  --job-dir "$INTERLEAVE_JOB_DIR" \
  --worktree "$INTERLEAVE_WT" \
  --claim-token "$PREDECESSOR_TOKEN" &
PREDECESSOR_PID=$!
touchstone_ship_transfer_claim "$INTERLEAVE_JOB_DIR" "$PREDECESSOR_TOKEN" "$PREDECESSOR_PID"
for _ in $(seq 1 100); do
  if [ -e "$INTERLEAVE_SIGNAL" ] || ! kill -0 "$PREDECESSOR_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [ ! -e "$INTERLEAVE_SIGNAL" ]; then
  fail "predecessor did not reach terminal publication gate"
else
  touchstone_ship_refresh "$INTERLEAVE_JOB_DIR"
  if [ "$(touchstone_ship_read "$INTERLEAVE_JOB_DIR" status)" != "finishing" ]; then
    fail "status polling replaced the predecessor's finishing state"
  fi
  if touchstone_ship_claim "$INTERLEAVE_JOB_DIR" "$$" >/dev/null; then
    fail "successor claimed before predecessor published terminal state"
  fi
  : >"$INTERLEAVE_GATE"
fi
wait "$PREDECESSOR_PID" || fail "predecessor failed during terminal publication"
if [ "$(touchstone_ship_read "$INTERLEAVE_JOB_DIR" status)" != "succeeded" ]; then
  fail "predecessor did not publish succeeded terminal state"
fi
if touchstone_ship_claim_exists "$INTERLEAVE_JOB_DIR"; then
  fail "predecessor did not release ownership after terminal publication"
fi

DEAD_OWNER_JOB_DIR="$TEST_DIR/dead-owner-claim-job"
sleep 30 &
DEAD_OWNER_PID=$!
DEAD_OWNER_TOKEN="$(touchstone_ship_claim "$DEAD_OWNER_JOB_DIR" "$DEAD_OWNER_PID")"
kill "$DEAD_OWNER_PID"
wait "$DEAD_OWNER_PID" 2>/dev/null || true
touchstone_ship_refresh "$DEAD_OWNER_JOB_DIR"
if touchstone_ship_claim_exists "$DEAD_OWNER_JOB_DIR"; then
  fail "refresh preserved a claim whose owner had exited"
fi
SUCCESSOR_TOKEN="$(touchstone_ship_claim "$DEAD_OWNER_JOB_DIR" "$$")"
if touchstone_ship_release_claim "$DEAD_OWNER_JOB_DIR" "$DEAD_OWNER_TOKEN" 2>/dev/null; then
  fail "a stale owner token released its successor's claim"
fi
if ! touchstone_ship_claim_matches "$DEAD_OWNER_JOB_DIR" "$SUCCESSOR_TOKEN"; then
  fail "successor claim did not survive stale-token release"
fi
touchstone_ship_release_claim "$DEAD_OWNER_JOB_DIR" "$SUCCESSOR_TOKEN"

LEGACY_CLAIM_JOB_DIR="$TEST_DIR/legacy-claim-job"
mkdir -p "$LEGACY_CLAIM_JOB_DIR/active"
touch -t 200001010000 "$LEGACY_CLAIM_JOB_DIR/active"
touchstone_ship_refresh "$LEGACY_CLAIM_JOB_DIR"
if [ ! -d "$LEGACY_CLAIM_JOB_DIR/active" ]; then
  fail "ownerless legacy claim was expired solely by age"
fi
rmdir "$LEGACY_CLAIM_JOB_DIR/active"

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

if [ "$ERRORS" -ne 0 ]; then
  echo "==> FAIL: $ERRORS worker assertion(s) failed" >&2
  exit 1
fi
echo "==> PASS: worker lifecycle commands derive state and delegate safely"

# -----------------------------------------------------------------------------
# Consolidated feature coverage: autonomous worker review repair
# -----------------------------------------------------------------------------
(
  #
  # End-to-end fixtures for detached autonomous PR review repair.
  set -euo pipefail

  TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  TEST_DIR="$(mktemp -d -t touchstone-test-worker-review-fix.XXXXXX)"
  trap '[ "${TOUCHSTONE_KEEP_TEST_DIR:-0}" = 1 ] || rm -rf "$TEST_DIR"' EXIT
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

  wait_for_status() {
    local worktree="$1" expected="$2" output="$3" attempts=0
    while [ "$attempts" -lt 150 ]; do
      "$TOUCHSTONE_ROOT/bin/touchstone" worker status \
        --worktree "$worktree" --json >"$output"
      grep -q "\"status\":\"$expected\"" "$output" && return 0
      if grep -qE '"status":"(succeeded|failed|stopped|needs-attention)"' "$output"; then
        return 1
      fi
      attempts=$((attempts + 1))
      sleep 0.1
    done
    return 1
  }

  setup_fixture_repo() {
    local repo="$1" origin="$2" branch="$3"
    git init -q --bare "$origin"
    git init -q -b main "$repo"
    git -C "$repo" config user.name "Touchstone Test"
    git -C "$repo" config user.email "touchstone@example.com"
    mkdir -p "$repo/scripts"
    printf 'original\n' >"$repo/target.txt"
    cat >"$repo/scripts/open-pr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(git rev-parse HEAD)" >>"$FAKE_OPEN_PR_LOG"
if [ -f "$FAKE_THREAD_ACTIVE" ]; then
  echo "review feedback blocks merge" >&2
  exit 1
fi
printf 'merged\n' >"$FAKE_MERGED"
EOF
    chmod +x "$repo/scripts/open-pr.sh"
    git -C "$repo" add target.txt scripts/open-pr.sh
    git -C "$repo" commit -qm "fixture base"
    git -C "$repo" remote add origin "$origin"
    git -C "$repo" push -q -u origin main
    git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    git -C "$repo" branch "$branch"
    git -C "$repo" push -q -u origin "$branch"
  }

  make_fake_gh() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
subcommand="${2:-}"
case "$command_name:$subcommand" in
  "pr:list")
    printf '77\n'
    ;;
  "pr:view")
    if [[ "$*" == *baseRefName* ]] && [[ "$*" == *baseRefOid* ]]; then
      base_oid="${FAKE_PR_BASE_OID:-$(git rev-parse main)}"
      [ ! -f "${FAKE_BASE_MOVED:-/nonexistent}" ] || base_oid="$(printf '%040d' 0)"
      printf '%s\t%s\t%s\n' \
        "${FAKE_PR_URL:-$(git remote get-url origin)/pull/77}" \
        "${FAKE_PR_BASE_BRANCH:-main}" \
        "$base_oid"
    elif [[ "$*" == *baseRefOid* ]]; then
      if [ -f "${FAKE_BASE_MOVED:-/nonexistent}" ]; then
        printf '%040d\n' 0
      else
        printf '%s\n' "${FAKE_PR_BASE_OID:-$(git rev-parse main)}"
      fi
    elif [ -f "${FAKE_HEAD_MOVED:-/nonexistent}" ]; then
      printf '%040d\n' 0
    elif [ -f "${FAKE_STALE_NEXT:-/nonexistent}" ]; then
      rm -f "$FAKE_STALE_NEXT"
      printf '%040d\n' 0
    else
      git rev-parse HEAD
    fi
    ;;
  "repo:view")
    printf 'example/project\n'
    ;;
  "api:--paginate")
    request_base="${FAKE_REQUEST_BASE_OID:-$(git rev-parse main)}"
    printf 'touchstone/review-request-intent\t2026-01-01T00:00:00Z\ttouchstone-test-user\tpr=77 base=%s\n' \
      "$request_base"
    printf 'touchstone/review-request-complete\t2026-01-01T00:00:01Z\ttouchstone-test-user\tpr=77 base=%s intent=2026-01-01T00:00:00Z trigger=2026-01-01T00:00:01Z\n' \
      "$request_base"
    ;;
  api:repos/*/collaborators/*/permission)
    printf 'write\n'
    ;;
  "api:user")
    printf 'touchstone-test-user\n'
    ;;
  "api:graphql")
    args="$*"
    if [[ "$args" == *reviewThreads* ]]; then
      if [ -f "$FAKE_THREAD_ACTIVE" ]; then
        review_head="${FAKE_REVIEW_HEAD:-$(git rev-parse HEAD)}"
        body_truncated="${FAKE_THREAD_TRUNCATED:-false}"
        body='Replace the original value with fixed.'
        if [ "$body_truncated" = true ]; then
          body="$(awk 'BEGIN { for (i = 0; i < 1100; i++) printf "x" }')"
        fi
        thread_id="$(cat "$FAKE_THREAD_ID")"
        comment_count="${FAKE_INITIAL_COMMENT_COUNT:-1}"
        comment_ids="$thread_id"
        snapshot_encoded="$FAKE_SNAPSHOT_ENCODED"
        if [ "$comment_count" != 1 ]; then
          comment_ids="$thread_id,follow-up-comment"
          snapshot_encoded="$FAKE_CHANGED_SNAPSHOT_ENCODED"
        fi
        printf '%s\ttarget.txt\t1\tfalse\t%s\t%s\t%s\t%s\t%s\t%s\t%s\thttps://example.test/thread/%s\t%s\n' \
          "$thread_id" \
          "${FAKE_THREAD_AUTHOR:-chatgpt-codex-connector}" \
          "$review_head" \
          "${FAKE_REVIEW_SUBMITTED_AT:-2026-01-01T00:00:02Z}" \
          "$body_truncated" \
          "$comment_count" \
          "$comment_ids" \
          "$snapshot_encoded" \
          "$thread_id" \
          "$body"
        [ "${FAKE_STALE_AFTER_THREADS:-0}" = 1 ] && : >"$FAKE_STALE_NEXT" || true
      fi
    elif [[ "$args" == *addPullRequestReviewThreadReply* ]]; then
      printf 'reply\n' >>"$FAKE_REPLY_LOG"
      : >"$FAKE_REPLIED"
      [ "${FAKE_MOVE_HEAD_DURING_FINISH:-0}" = 1 ] && : >"$FAKE_HEAD_MOVED" || true
      [ "${FAKE_MOVE_BASE_DURING_FINISH:-0}" = 1 ] && : >"$FAKE_BASE_MOVED" || true
    elif [[ "$args" == *unresolveReviewThread* ]]; then
      printf 'unresolve\n' >>"$FAKE_UNRESOLVE_LOG"
      [ "${FAKE_UNRESOLVE_FAIL:-0}" != 1 ] || exit 42
      rm -f "$FAKE_RESOLVED"
      : >"$FAKE_THREAD_ACTIVE"
    elif [[ "$args" == *resolveReviewThread* ]]; then
      printf 'resolve\n' >>"$FAKE_RESOLVE_LOG"
      : >"$FAKE_RESOLVED"
      [ "${FAKE_ADD_COMMENT_DURING_RESOLVE:-0}" = 1 ] && : >"$FAKE_LATE_COMMENT" || true
      if [ "${FAKE_REPLACE_THREAD_ALWAYS:-0}" = 1 ]; then
        : >"$FAKE_PENDING_REPLACEMENT"
      elif [ "${FAKE_REPLACE_THREAD:-0}" = 1 ] && [ ! -f "$FAKE_REPLACED" ]; then
        : >"$FAKE_REPLACED"
        : >"$FAKE_PENDING_REPLACEMENT"
      else
        rm -f "$FAKE_THREAD_ACTIVE"
      fi
    elif [[ "$args" == *"node(id:"* ]]; then
      if [[ "$args" != *'.author.login == "touchstone-test-user"'* ]]; then
        echo "thread snapshot query did not bind the marker reply to the authenticated actor" >&2
        exit 1
      fi
      thread_id="$(cat "$FAKE_THREAD_ID")"
      total_count=1
      loaded_count=1
      nonmarker_count=1
      marker_count=0
      comment_ids="$thread_id"
      snapshot_encoded="$FAKE_SNAPSHOT_ENCODED"
      if [ -f "$FAKE_REPLIED" ]; then
        total_count=2
        loaded_count=2
        marker_count=1
      fi
      if [ "${FAKE_ADD_COMMENT_BEFORE_RESOLVE:-0}" = 1 ] && [ -f "$FAKE_REPLIED" ]; then
        total_count=3
        loaded_count=3
        nonmarker_count=2
        comment_ids="$thread_id,follow-up-comment"
        snapshot_encoded="$FAKE_CHANGED_SNAPSHOT_ENCODED"
      fi
      if [ -f "$FAKE_LATE_COMMENT" ]; then
        total_count=3
        loaded_count=3
        nonmarker_count=2
        comment_ids="$thread_id,late-follow-up-comment"
        snapshot_encoded="$FAKE_CHANGED_SNAPSHOT_ENCODED"
      fi
      if [ "${FAKE_UNTRUSTED_MARKER:-0}" = 1 ] && [ ! -f "$FAKE_REPLIED" ]; then
        total_count=2
        loaded_count=2
        nonmarker_count=2
        marker_count=0
        comment_ids="$thread_id,attacker-marker-comment"
        snapshot_encoded="$FAKE_CHANGED_SNAPSHOT_ENCODED"
      fi
      if [ -f "$FAKE_RESOLVED" ]; then
        resolved=true
      else
        resolved=false
      fi
      if [ "${FAKE_RESOLVE_EXTERNALLY_BEFORE_REPLY:-0}" = 1 ] \
        && [ ! -f "$FAKE_REPLIED" ]; then
        resolved=true
        : >"$FAKE_RESOLVED"
        rm -f "$FAKE_THREAD_ACTIVE"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$resolved" "$total_count" "$loaded_count" "$nonmarker_count" \
        "$marker_count" "$comment_ids" "$snapshot_encoded"
      if [ -f "$FAKE_PENDING_REPLACEMENT" ]; then
        printf 'thread-2\n' >"$FAKE_THREAD_ID"
        rm -f "$FAKE_PENDING_REPLACEMENT" "$FAKE_REPLIED" "$FAKE_RESOLVED"
        : >"$FAKE_THREAD_ACTIVE"
      fi
    else
      echo "unexpected gh api request: $args" >&2
      exit 1
    fi
    ;;
  *)
    echo "unexpected gh request: $*" >&2
    exit 1
    ;;
esac
EOF
    chmod +x "$bin_dir/gh"
  }

  make_fix_worker() {
    local worker="$1"
    cat >"$worker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
worktree="$1"
result_file="$3"
printf 'fixed\n' >>"$worktree/target.txt"
{
  printf 'TOUCHSTONE_REVIEW_FIX_FIXED\n'
  case "$(basename "$0")" in
    *ambiguous*) ;;
    *)
      printf 'thread_id=%s\n' "$(cat "$FAKE_THREAD_ID")"
      case "$(basename "$0")" in
        *mixed*) printf 'TOUCHSTONE_REVIEW_FIX_NEEDS_ATTENTION\n' ;;
        *extra*) printf 'Worker completed successfully.\n' ;;
      esac
      ;;
  esac
} >"$result_file"
EOF
    chmod +x "$worker"
  }

  export FAKE_THREAD_ACTIVE="$TEST_DIR/thread-active"
  export FAKE_THREAD_ID="$TEST_DIR/thread-id"
  export FAKE_REPLY_LOG="$TEST_DIR/replies"
  export FAKE_RESOLVE_LOG="$TEST_DIR/resolves"
  export FAKE_UNRESOLVE_LOG="$TEST_DIR/unresolves"
  export FAKE_REPLIED="$TEST_DIR/replied"
  export FAKE_RESOLVED="$TEST_DIR/resolved"
  export FAKE_LATE_COMMENT="$TEST_DIR/late-comment"
  export FAKE_REPLACED="$TEST_DIR/replaced"
  export FAKE_PENDING_REPLACEMENT="$TEST_DIR/pending-replacement"
  export FAKE_STALE_NEXT="$TEST_DIR/stale-next"
  export FAKE_HEAD_MOVED="$TEST_DIR/head-moved"
  export FAKE_BASE_MOVED="$TEST_DIR/base-moved"
  export FAKE_OPEN_PR_LOG="$TEST_DIR/open-pr.log"
  export FAKE_MERGED="$TEST_DIR/merged"
  export FAKE_SNAPSHOT_ENCODED="c25hcHNob3Q="
  export FAKE_CHANGED_SNAPSHOT_ENCODED="Y2hhbmdlZC1zbmFwc2hvdA=="
  FAKE_SNAPSHOT_DIGEST="$(printf '%s' "$FAKE_SNAPSHOT_ENCODED" | git hash-object --stdin)"

  FAKE_BIN="$TEST_DIR/bin"
  make_fake_gh "$FAKE_BIN"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

  echo "==> Case a: finding is fixed, pushed, replied, resolved, re-reviewed, and merged"
  REPO="$TEST_DIR/repo"
  ORIGIN="$TEST_DIR/origin.git"
  WORKTREE="$TEST_DIR/worktree"
  setup_fixture_repo "$REPO" "$ORIGIN" feat/review-fix
  git -C "$REPO" worktree add -q "$WORKTREE" feat/review-fix
  for INVALID_MINUTES in 00 08; do
    if "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
      --worktree "$WORKTREE" --detach --review-fix \
      --max-fix-minutes "$INVALID_MINUTES" >"$TEST_DIR/invalid-minutes-$INVALID_MINUTES.out" 2>&1; then
      fail "non-canonical fix-minute budget $INVALID_MINUTES was accepted"
    fi
    assert_contains "$TEST_DIR/invalid-minutes-$INVALID_MINUTES.out" \
      'max-fix-minutes must be a canonical positive integer'
  done
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-1\n' >"$FAKE_THREAD_ID"
  : >"$FAKE_REPLY_LOG"
  : >"$FAKE_RESOLVE_LOG"
  : >"$FAKE_OPEN_PR_LOG"
  FIX_WORKER="$TEST_DIR/fix-worker"
  make_fix_worker "$FIX_WORKER"
  EVENTS="$TEST_DIR/events.ndjson"
  STATUS="$TEST_DIR/status.json"
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$WORKTREE" \
    --detach \
    --review-fix \
    --max-fix-iterations 2 \
    --max-fix-minutes 2 \
    --validation-command 'grep -qx fixed <(tail -n 1 target.txt)' \
    --events-json "$EVENTS" >"$TEST_DIR/start.out"
  if ! wait_for_status "$WORKTREE" succeeded "$STATUS"; then
    fail "autonomous review-fix did not merge successfully"
    cat "$STATUS" >&2
    SHIP_LOG="$(sed -n 's/.*"log_path":"\([^"]*\)".*/\1/p' "$STATUS")"
    [ -f "$SHIP_LOG" ] && cat "$SHIP_LOG" >&2
  fi
  assert_contains "$STATUS" '"mode":"autonomous-review-fix"'
  assert_contains "$STATUS" '"review_fix_iteration":1'
  assert_contains "$EVENTS" '"event":"review_waiting"'
  assert_contains "$EVENTS" '"event":"fixing"'
  assert_contains "$EVENTS" '"event":"fix_pushed"'
  assert_contains "$EVENTS" '"event":"review_requested"'
  assert_contains "$EVENTS" '"event":"merged"'
  [ "$(wc -l <"$FAKE_REPLY_LOG" | tr -d ' ')" = 1 ] || fail "thread reply was not idempotent"
  [ "$(wc -l <"$FAKE_RESOLVE_LOG" | tr -d ' ')" = 1 ] || fail "thread resolution was not idempotent"
  [ "$(wc -l <"$FAKE_OPEN_PR_LOG" | tr -d ' ')" = 2 ] || fail "expected review gate to run twice"
  [ -f "$FAKE_MERGED" ] || fail "fixture PR did not merge"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$(git --git-dir="$ORIGIN" rev-parse feat/review-fix)" ] \
    || fail "fix commit was not pushed to the branch"

  echo "==> Case b: failed validation persists needs-attention and takeover preserves work"
  FAIL_WT="$TEST_DIR/fail-worktree"
  git -C "$REPO" branch feat/review-fail main
  git -C "$REPO" push -q origin feat/review-fail
  git -C "$REPO" worktree add -q "$FAIL_WT" feat/review-fail
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-validation\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_MERGED"
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$FAIL_WT" --detach --review-fix \
    --validation-command false >/dev/null
  if ! wait_for_status "$FAIL_WT" needs-attention "$STATUS"; then
    fail "failed validation did not enter needs-attention"
  fi
  assert_contains "$STATUS" '"reason":"validation-failed"'
  [ -n "$(git -C "$FAIL_WT" status --porcelain)" ] || fail "failed fix work was not preserved"
  "$TOUCHSTONE_ROOT/bin/touchstone" worker takeover \
    --worktree "$FAIL_WT" >"$TEST_DIR/takeover.out"
  assert_contains "$TEST_DIR/takeover.out" 'needs attention'
  [ -d "$FAIL_WT" ] || fail "takeover removed needs-attention worktree"

  echo "==> Case b2: validation cannot mutate the autonomous fix"
  MUTATING_VALIDATION_WT="$TEST_DIR/mutating-validation-worktree"
  git -C "$REPO" branch feat/review-mutating-validation main
  git -C "$REPO" push -q origin feat/review-mutating-validation
  git -C "$REPO" worktree add -q "$MUTATING_VALIDATION_WT" feat/review-mutating-validation
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-mutating-validation\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_MERGED"
  MUTATING_VALIDATION_HEAD="$(git -C "$MUTATING_VALIDATION_WT" rev-parse HEAD)"
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$MUTATING_VALIDATION_WT" --detach --review-fix \
    --validation-command 'printf generated > validation-output.txt' >/dev/null
  wait_for_status "$MUTATING_VALIDATION_WT" needs-attention "$STATUS" \
    || fail "mutating validation did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"validation-mutated-worktree"'
  [ -f "$MUTATING_VALIDATION_WT/validation-output.txt" ] \
    || fail "validator-authored output was not preserved for takeover"
  [ -n "$(git -C "$MUTATING_VALIDATION_WT" status --porcelain)" ] \
    || fail "mutating validation work was not preserved"
  [ "$(git -C "$MUTATING_VALIDATION_WT" rev-parse HEAD)" = "$MUTATING_VALIDATION_HEAD" ] \
    || fail "mutating validation created an autonomous commit"
  [ ! -f "$FAKE_REPLIED" ] || fail "mutating validation reached thread reply"
  [ ! -f "$FAKE_RESOLVED" ] || fail "mutating validation reached thread resolution"
  [ ! -f "$FAKE_MERGED" ] || fail "mutating validation reached merge"

  echo "==> Case c: ambiguous feedback result and stale heads fail closed"
  AMBIG_WT="$TEST_DIR/ambiguous-worktree"
  git -C "$REPO" branch feat/review-ambiguous main
  git -C "$REPO" push -q origin feat/review-ambiguous
  git -C "$REPO" worktree add -q "$AMBIG_WT" feat/review-ambiguous
  AMBIG_WORKER="$TEST_DIR/ambiguous-worker"
  make_fix_worker "$AMBIG_WORKER"
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-ambiguous\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$AMBIG_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$AMBIG_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$AMBIG_WT" needs-attention "$STATUS" \
    || fail "ambiguous worker result did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"ambiguous-worker-result"'

  for INVALID_RESULT_KIND in mixed extra; do
    INVALID_RESULT_WT="$TEST_DIR/$INVALID_RESULT_KIND-result-worktree"
    git -C "$REPO" branch "feat/review-$INVALID_RESULT_KIND-result" main
    git -C "$REPO" push -q origin "feat/review-$INVALID_RESULT_KIND-result"
    git -C "$REPO" worktree add -q \
      "$INVALID_RESULT_WT" "feat/review-$INVALID_RESULT_KIND-result"
    INVALID_RESULT_WORKER="$TEST_DIR/$INVALID_RESULT_KIND-worker"
    make_fix_worker "$INVALID_RESULT_WORKER"
    : >"$FAKE_THREAD_ACTIVE"
    printf 'thread-%s\n' "$INVALID_RESULT_KIND" >"$FAKE_THREAD_ID"
    rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
    TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$INVALID_RESULT_WORKER" \
      "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
      --worktree "$INVALID_RESULT_WT" --detach --review-fix \
      --validation-command : >/dev/null
    wait_for_status "$INVALID_RESULT_WT" needs-attention "$STATUS" \
      || fail "$INVALID_RESULT_KIND worker result did not enter needs-attention"
    assert_contains "$STATUS" '"reason":"ambiguous-worker-result"'
  done

  STALE_WT="$TEST_DIR/stale-worktree"
  git -C "$REPO" branch feat/review-stale main
  git -C "$REPO" push -q origin feat/review-stale
  git -C "$REPO" worktree add -q "$STALE_WT" feat/review-stale
  git -C "$STALE_WT" config user.name "Touchstone Test"
  git -C "$STALE_WT" config user.email "touchstone@example.com"
  git -C "$STALE_WT" status --porcelain | cut -c4- | xargs -I{} rm -f "$STALE_WT/{}"
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-stale\n' >"$FAKE_THREAD_ID"
  export FAKE_STALE_AFTER_THREADS=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$STALE_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$STALE_WT" needs-attention "$STATUS" \
    || fail "stale review head did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"stale-review-head"'
  unset FAKE_STALE_AFTER_THREADS

  echo "==> Case c2: untrusted authors cannot drive autonomous edits"
  UNTRUSTED_WT="$TEST_DIR/untrusted-worktree"
  git -C "$REPO" branch feat/review-untrusted main
  git -C "$REPO" push -q origin feat/review-untrusted
  git -C "$REPO" worktree add -q "$UNTRUSTED_WT" feat/review-untrusted
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-untrusted\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  export FAKE_THREAD_AUTHOR=untrusted-user
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$UNTRUSTED_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$UNTRUSTED_WT" needs-attention "$STATUS" \
    || fail "untrusted review author did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"untrusted-review-author"'
  [ -z "$(git -C "$UNTRUSTED_WT" status --porcelain)" ] \
    || fail "untrusted review author caused worktree edits"
  [ ! -f "$FAKE_REPLIED" ] || fail "untrusted review thread received an autonomous reply"
  [ ! -f "$FAKE_RESOLVED" ] || fail "untrusted review thread was autonomously resolved"
  unset FAKE_THREAD_AUTHOR

  echo "==> Case c3: a prior-head review thread cannot drive current-head edits"
  PRIOR_HEAD_WT="$TEST_DIR/prior-head-worktree"
  git -C "$REPO" branch feat/review-prior-head main
  git -C "$REPO" push -q origin feat/review-prior-head
  git -C "$REPO" worktree add -q "$PRIOR_HEAD_WT" feat/review-prior-head
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-prior-head\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  export FAKE_REVIEW_HEAD=0000000000000000000000000000000000000000
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$PRIOR_HEAD_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$PRIOR_HEAD_WT" needs-attention "$STATUS" \
    || fail "prior-head review thread did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"stale-review-thread"'
  [ -z "$(git -C "$PRIOR_HEAD_WT" status --porcelain)" ] \
    || fail "prior-head review thread caused worktree edits"
  unset FAKE_REVIEW_HEAD

  echo "==> Case c3b: prior-base review evidence cannot drive current-base edits"
  PRIOR_BASE_WT="$TEST_DIR/prior-base-worktree"
  git -C "$REPO" branch feat/review-prior-base main
  git -C "$REPO" push -q origin feat/review-prior-base
  git -C "$REPO" worktree add -q "$PRIOR_BASE_WT" feat/review-prior-base
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-prior-base\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  export FAKE_REQUEST_BASE_OID=0000000000000000000000000000000000000000
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$PRIOR_BASE_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$PRIOR_BASE_WT" needs-attention "$STATUS" \
    || fail "prior-base review evidence did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"review-request-base-mismatch"'
  [ -z "$(git -C "$PRIOR_BASE_WT" status --porcelain)" ] \
    || fail "prior-base review evidence caused worktree edits"
  [ ! -f "$FAKE_REPLIED" ] || fail "prior-base review evidence received an autonomous reply"
  [ ! -f "$FAKE_RESOLVED" ] || fail "prior-base review evidence was autonomously resolved"
  unset FAKE_REQUEST_BASE_OID

  echo "==> Case c4: an explicitly empty trusted-author list trusts nobody"
  EMPTY_TRUST_REPO="$TEST_DIR/empty-trust-repo"
  EMPTY_TRUST_ORIGIN="$TEST_DIR/empty-trust-origin.git"
  EMPTY_TRUST_WT="$TEST_DIR/empty-trust-worktree"
  setup_fixture_repo "$EMPTY_TRUST_REPO" "$EMPTY_TRUST_ORIGIN" feat/review-empty-trust
  cat >"$EMPTY_TRUST_REPO/.touchstone-review.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = []
EOF
  git -C "$EMPTY_TRUST_REPO" add .touchstone-review.toml
  git -C "$EMPTY_TRUST_REPO" commit -qm "configure an empty review allowlist"
  git -C "$EMPTY_TRUST_REPO" push -q origin main
  git -C "$EMPTY_TRUST_REPO" branch -f feat/review-empty-trust main
  git -C "$EMPTY_TRUST_REPO" push -q --force origin feat/review-empty-trust
  git -C "$EMPTY_TRUST_REPO" worktree add -q "$EMPTY_TRUST_WT" feat/review-empty-trust
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-empty-trust\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$EMPTY_TRUST_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$EMPTY_TRUST_WT" needs-attention "$STATUS" \
    || fail "empty trusted-author list did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"untrusted-review-author"'
  [ -z "$(git -C "$EMPTY_TRUST_WT" status --porcelain)" ] \
    || fail "empty trusted-author list allowed autonomous edits"
  [ ! -f "$FAKE_REPLIED" ] || fail "empty trusted-author list allowed an autonomous reply"
  [ ! -f "$FAKE_RESOLVED" ] || fail "empty trusted-author list allowed autonomous resolution"

  echo "==> Case c5: truncated feedback cannot be autonomously resolved"
  TRUNCATED_WT="$TEST_DIR/truncated-worktree"
  git -C "$REPO" branch feat/review-truncated main
  git -C "$REPO" push -q origin feat/review-truncated
  git -C "$REPO" worktree add -q "$TRUNCATED_WT" feat/review-truncated
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-truncated\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  export FAKE_THREAD_TRUNCATED=true
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$TRUNCATED_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$TRUNCATED_WT" needs-attention "$STATUS" \
    || fail "truncated feedback did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"review-thread-body-truncated"'
  [ -z "$(git -C "$TRUNCATED_WT" status --porcelain)" ] \
    || fail "truncated feedback caused autonomous edits"
  [ ! -f "$FAKE_REPLIED" ] || fail "truncated feedback received an autonomous reply"
  [ ! -f "$FAKE_RESOLVED" ] || fail "truncated feedback was autonomously resolved"
  unset FAKE_THREAD_TRUNCATED

  echo "==> Case c6: head movement during thread updates stops the merge path"
  MOVED_HEAD_WT="$TEST_DIR/moved-head-worktree"
  git -C "$REPO" branch feat/review-moved-head main
  git -C "$REPO" push -q origin feat/review-moved-head
  git -C "$REPO" worktree add -q "$MOVED_HEAD_WT" feat/review-moved-head
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-moved-head\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_HEAD_MOVED" "$FAKE_MERGED"
  export FAKE_MOVE_HEAD_DURING_FINISH=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$MOVED_HEAD_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$MOVED_HEAD_WT" needs-attention "$STATUS" \
    || fail "head movement during thread updates did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"head-changed-during-thread-update"'
  [ -f "$FAKE_REPLIED" ] || fail "head-movement fixture did not reach the reply boundary"
  [ ! -f "$FAKE_RESOLVED" ] \
    || fail "head movement after reply allowed stale-thread resolution"
  [ ! -f "$FAKE_MERGED" ] || fail "head movement during thread updates reached merge"
  unset FAKE_MOVE_HEAD_DURING_FINISH
  rm -f "$FAKE_HEAD_MOVED"

  echo "==> Case c6b: base movement during thread updates stops the merge path"
  MOVED_BASE_WT="$TEST_DIR/moved-base-worktree"
  git -C "$REPO" branch feat/review-moved-base main
  git -C "$REPO" push -q origin feat/review-moved-base
  git -C "$REPO" worktree add -q "$MOVED_BASE_WT" feat/review-moved-base
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-moved-base\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_BASE_MOVED" "$FAKE_MERGED"
  export FAKE_MOVE_BASE_DURING_FINISH=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$MOVED_BASE_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$MOVED_BASE_WT" needs-attention "$STATUS" \
    || fail "base movement during thread updates did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"base-changed-during-thread-update"'
  [ -f "$FAKE_REPLIED" ] || fail "base-movement fixture did not reach the reply boundary"
  [ ! -f "$FAKE_RESOLVED" ] \
    || fail "base movement after reply allowed stale-thread resolution"
  [ ! -f "$FAKE_MERGED" ] || fail "base movement during thread updates reached merge"
  unset FAKE_MOVE_BASE_DURING_FINISH
  rm -f "$FAKE_BASE_MOVED"

  echo "==> Case c7: an existing follow-up comment blocks autonomous edits"
  FOLLOWUP_WT="$TEST_DIR/followup-worktree"
  git -C "$REPO" branch feat/review-followup main
  git -C "$REPO" push -q origin feat/review-followup
  git -C "$REPO" worktree add -q "$FOLLOWUP_WT" feat/review-followup
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-followup\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  export FAKE_INITIAL_COMMENT_COUNT=2
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$FOLLOWUP_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$FOLLOWUP_WT" needs-attention "$STATUS" \
    || fail "multi-comment review thread did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"review-thread-has-follow-ups"'
  [ -z "$(git -C "$FOLLOWUP_WT" status --porcelain)" ] \
    || fail "multi-comment review thread caused autonomous edits"
  [ ! -f "$FAKE_REPLIED" ] || fail "multi-comment review thread received an autonomous reply"
  [ ! -f "$FAKE_RESOLVED" ] || fail "multi-comment review thread was autonomously resolved"
  unset FAKE_INITIAL_COMMENT_COUNT

  echo "==> Case c8: a comment arriving after the fix prevents thread resolution"
  CHANGED_THREAD_WT="$TEST_DIR/changed-thread-worktree"
  git -C "$REPO" branch feat/review-changed-thread main
  git -C "$REPO" push -q origin feat/review-changed-thread
  git -C "$REPO" worktree add -q "$CHANGED_THREAD_WT" feat/review-changed-thread
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-changed\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_MERGED"
  export FAKE_ADD_COMMENT_BEFORE_RESOLVE=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$CHANGED_THREAD_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$CHANGED_THREAD_WT" needs-attention "$STATUS" \
    || fail "changed review thread did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"review-thread-changed"'
  [ -f "$FAKE_REPLIED" ] || fail "changed-thread fixture did not reach the reply boundary"
  [ ! -f "$FAKE_RESOLVED" ] || fail "new follow-up feedback was autonomously resolved"
  [ ! -f "$FAKE_MERGED" ] || fail "new follow-up feedback reached merge"
  unset FAKE_ADD_COMMENT_BEFORE_RESOLVE

  echo "==> Case c8b: external resolution cannot authorize an autonomous merge"
  EXTERNAL_RESOLVE_WT="$TEST_DIR/external-resolve-worktree"
  git -C "$REPO" branch feat/review-external-resolve main
  git -C "$REPO" push -q origin feat/review-external-resolve
  git -C "$REPO" worktree add -q "$EXTERNAL_RESOLVE_WT" feat/review-external-resolve
  : >"$FAKE_THREAD_ACTIVE"
  : >"$FAKE_REPLY_LOG"
  : >"$FAKE_RESOLVE_LOG"
  : >"$FAKE_UNRESOLVE_LOG"
  printf 'thread-external-resolve\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_MERGED"
  export FAKE_RESOLVE_EXTERNALLY_BEFORE_REPLY=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$EXTERNAL_RESOLVE_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$EXTERNAL_RESOLVE_WT" needs-attention "$STATUS" \
    || fail "external thread resolution did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"review-thread-changed"'
  [ ! -s "$FAKE_REPLY_LOG" ] || fail "external resolution received a Touchstone reply"
  [ ! -s "$FAKE_RESOLVE_LOG" ] || fail "external resolution was resolved again"
  [ ! -s "$FAKE_UNRESOLVE_LOG" ] || fail "external resolution was reopened"
  [ ! -f "$FAKE_MERGED" ] || fail "external resolution authorized merge"
  [ -f "$FAKE_RESOLVED" ] || fail "external reviewer resolution was not preserved"
  unset FAKE_RESOLVE_EXTERNALLY_BEFORE_REPLY

  echo "==> Case c9: a comment arriving during resolution reopens the thread"
  RESOLVE_RACE_WT="$TEST_DIR/resolve-race-worktree"
  git -C "$REPO" branch feat/review-resolve-race main
  git -C "$REPO" push -q origin feat/review-resolve-race
  git -C "$REPO" worktree add -q "$RESOLVE_RACE_WT" feat/review-resolve-race
  : >"$FAKE_THREAD_ACTIVE"
  : >"$FAKE_RESOLVE_LOG"
  : >"$FAKE_UNRESOLVE_LOG"
  printf 'thread-resolve-race\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_LATE_COMMENT" "$FAKE_MERGED"
  export FAKE_ADD_COMMENT_DURING_RESOLVE=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$RESOLVE_RACE_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$RESOLVE_RACE_WT" needs-attention "$STATUS" \
    || fail "post-resolve follow-up did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"review-thread-changed"'
  [ "$(wc -l <"$FAKE_RESOLVE_LOG" | tr -d ' ')" = 1 ] \
    || fail "resolve-race fixture did not resolve exactly once"
  [ "$(wc -l <"$FAKE_UNRESOLVE_LOG" | tr -d ' ')" = 1 ] \
    || fail "resolve-race fixture did not reopen exactly once"
  [ ! -f "$FAKE_RESOLVED" ] || fail "changed thread remained resolved after post-resolve verification"
  [ -f "$FAKE_THREAD_ACTIVE" ] || fail "changed thread was not restored to the unresolved set"
  [ ! -f "$FAKE_MERGED" ] || fail "post-resolve follow-up reached merge"
  unset FAKE_ADD_COMMENT_DURING_RESOLVE
  rm -f "$FAKE_LATE_COMMENT"

  echo "==> Case c9b: a failed thread rollback persists a distinct handoff"
  ROLLBACK_FAIL_WT="$TEST_DIR/rollback-fail-worktree"
  git -C "$REPO" branch feat/review-rollback-fail main
  git -C "$REPO" push -q origin feat/review-rollback-fail
  git -C "$REPO" worktree add -q "$ROLLBACK_FAIL_WT" feat/review-rollback-fail
  : >"$FAKE_THREAD_ACTIVE"
  : >"$FAKE_UNRESOLVE_LOG"
  printf 'thread-rollback-fail\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_LATE_COMMENT" "$FAKE_MERGED"
  export FAKE_ADD_COMMENT_DURING_RESOLVE=1
  export FAKE_UNRESOLVE_FAIL=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$ROLLBACK_FAIL_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$ROLLBACK_FAIL_WT" needs-attention "$STATUS" \
    || fail "failed thread rollback did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"thread-rollback-failed"'
  ROLLBACK_FAIL_JOB="$(touchstone_ship_job_dir "$ROLLBACK_FAIL_WT")"
  assert_contains "$ROLLBACK_FAIL_JOB/review-fix/rollback-thread-id" '^thread-rollback-fail$'
  [ -f "$FAKE_RESOLVED" ] || fail "rollback failure fixture did not preserve the remote resolved state"
  [ ! -f "$FAKE_MERGED" ] || fail "failed thread rollback reached merge"
  unset FAKE_ADD_COMMENT_DURING_RESOLVE FAKE_UNRESOLVE_FAIL
  rm -f "$FAKE_LATE_COMMENT"

  echo "==> Case c10: another author's marker-shaped comment cannot authorize resolution"
  UNTRUSTED_MARKER_WT="$TEST_DIR/untrusted-marker-worktree"
  git -C "$REPO" branch feat/review-untrusted-marker main
  git -C "$REPO" push -q origin feat/review-untrusted-marker
  git -C "$REPO" worktree add -q "$UNTRUSTED_MARKER_WT" feat/review-untrusted-marker
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-untrusted-marker\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_MERGED"
  export FAKE_UNTRUSTED_MARKER=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$UNTRUSTED_MARKER_WT" --detach --review-fix --validation-command : >/dev/null
  wait_for_status "$UNTRUSTED_MARKER_WT" needs-attention "$STATUS" \
    || fail "untrusted marker comment did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"review-thread-changed"'
  [ ! -f "$FAKE_REPLIED" ] || fail "untrusted marker comment authorized an autonomous reply"
  [ ! -f "$FAKE_RESOLVED" ] || fail "untrusted marker comment authorized thread resolution"
  [ ! -f "$FAKE_MERGED" ] || fail "untrusted marker comment reached merge"
  unset FAKE_UNTRUSTED_MARKER

  echo "==> Case d: a new thread after a fix exhausts the bounded iteration budget"
  BUDGET_WT="$TEST_DIR/budget-worktree"
  git -C "$REPO" branch feat/review-budget main
  git -C "$REPO" push -q origin feat/review-budget
  git -C "$REPO" worktree add -q "$BUDGET_WT" feat/review-budget
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-budget-1\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_REPLACED" "$FAKE_PENDING_REPLACEMENT"
  export FAKE_REPLACE_THREAD=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$BUDGET_WT" --detach --review-fix \
    --max-fix-iterations 1 --validation-command : >/dev/null
  wait_for_status "$BUDGET_WT" needs-attention "$STATUS" \
    || fail "iteration budget exhaustion did not enter needs-attention"
  assert_contains "$STATUS" '"reason":"iteration-budget-exhausted"'
  assert_contains "$STATUS" '"handoff_invariant":"No autonomous edit is dispatched after needs-attention."'
  assert_contains "$STATUS" '"handoff_validation":"[0-9a-f]{40}"'
  assert_contains "$STATUS" '"handoff_non_goals":"No further edits, cleanup, thread resolution, or merge were attempted."'
  unset FAKE_REPLACE_THREAD

  echo "==> Case e: oversized budgets are clamped before a third autonomous edit"
  HARD_LIMIT_WT="$TEST_DIR/hard-limit-worktree"
  git -C "$REPO" branch feat/review-hard-limit main
  git -C "$REPO" push -q origin feat/review-hard-limit
  git -C "$REPO" worktree add -q "$HARD_LIMIT_WT" feat/review-hard-limit
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-hard-limit\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_REPLACED" "$FAKE_PENDING_REPLACEMENT"
  export FAKE_REPLACE_THREAD_ALWAYS=1
  TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
    --worktree "$HARD_LIMIT_WT" --detach --review-fix \
    --max-fix-iterations 9 --validation-command : >"$TEST_DIR/hard-limit-start.out" 2>&1
  wait_for_status "$HARD_LIMIT_WT" needs-attention "$STATUS" \
    || fail "hard autonomous mutation ceiling did not enter needs-attention"
  assert_contains "$TEST_DIR/hard-limit-start.out" 'capped at 2 mutation cycles'
  assert_contains "$STATUS" '"reason":"iteration-budget-exhausted"'
  assert_contains "$STATUS" '"review_fix_iteration":2'
  [ "$(git -C "$HARD_LIMIT_WT" rev-list --count main..HEAD)" = 2 ] \
    || fail "oversized budget dispatched more than two autonomous fixes"
  unset FAKE_REPLACE_THREAD_ALWAYS

  echo "==> Case f: a checkpoint cannot cross PR identity boundaries"
  # shellcheck source=../lib/worker-state.sh
  source "$TOUCHSTONE_ROOT/lib/worker-state.sh"
  # shellcheck source=../lib/worker-ship-job.sh
  source "$TOUCHSTONE_ROOT/lib/worker-ship-job.sh"
  # shellcheck source=../lib/events.sh
  source "$TOUCHSTONE_ROOT/lib/events.sh"
  # shellcheck source=../lib/worker-review-fix.sh
  source "$TOUCHSTONE_ROOT/lib/worker-review-fix.sh"
  [ "$(touchstone_review_fix_effective_iterations 999999999999999999999999)" = 2 ] \
    || fail "oversized decimal iteration budget was not clamped without arithmetic"
  [ "$(touchstone_review_fix_effective_iterations 1)" = 1 ] \
    || fail "lower autonomous iteration budget was not preserved"
  if touchstone_review_fix_effective_iterations 01 >/dev/null; then
    fail "non-canonical decimal iteration budget was accepted"
  fi
  STACK_BASE_WT="$TEST_DIR/stack-base-worktree"
  git -C "$REPO" branch stack-parent main
  git -C "$REPO" worktree add -q "$STACK_BASE_WT" stack-parent
  cat >"$STACK_BASE_WT/.touchstone-review.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = ["stack-reviewer"]
EOF
  git -C "$STACK_BASE_WT" add .touchstone-review.toml
  git -C "$STACK_BASE_WT" commit -qm "stack base policy"
  git -C "$STACK_BASE_WT" push -q -u origin stack-parent
  git -C "$REPO" worktree remove "$STACK_BASE_WT"
  STACK_BASE_REPO="$TEST_DIR/stack-base.git"
  git init -q --bare "$STACK_BASE_REPO"
  git -C "$REPO" push -q "$STACK_BASE_REPO" stack-parent
  git --git-dir="$ORIGIN" update-ref refs/heads/stack-parent "$(git -C "$REPO" rev-parse main)"
  git -C "$REPO" tag touchstone-pr-base/77 main
  export FAKE_PR_BASE_BRANCH=stack-parent
  export FAKE_PR_URL="$STACK_BASE_REPO/pull/77"
  export FAKE_PR_BASE_OID
  FAKE_PR_BASE_OID="$(git --git-dir="$STACK_BASE_REPO" rev-parse stack-parent)"
  STACK_BASE_SNAPSHOT="$(touchstone_review_fix_pr_base_snapshot "$WORKTREE" 77)" \
    || fail "stacked PR base ref was not resolved"
  IFS="$(printf '\t')" read -r STACK_BASE_REF STACK_BASE_OID <<EOF
$STACK_BASE_SNAPSHOT
EOF
  [ "$STACK_BASE_REF" = refs/remotes/touchstone-pr-base/77 ] \
    || fail "stacked PR resolved an unexpected base ref: $STACK_BASE_REF"
  [ "$STACK_BASE_OID" = "$FAKE_PR_BASE_OID" ] \
    || fail "stacked PR did not preserve its exact base revision"
  [ "$(touchstone_review_fix_trusted_authors "$WORKTREE" "$STACK_BASE_REF")" = stack-reviewer ] \
    || fail "fully qualified stacked PR ref did not load policy from the base repository"
  STACK_REWRITTEN_HEAD="$(git -C "$REPO" rev-parse main)"
  git --git-dir="$STACK_BASE_REPO" update-ref refs/heads/stack-parent "$STACK_REWRITTEN_HEAD"
  FAKE_PR_BASE_OID="$STACK_REWRITTEN_HEAD"
  STACK_BASE_SNAPSHOT="$(touchstone_review_fix_pr_base_snapshot "$WORKTREE" 77)" \
    || fail "rewritten stacked PR base ref was not resolved"
  IFS="$(printf '\t')" read -r STACK_BASE_REF STACK_BASE_OID <<EOF
$STACK_BASE_SNAPSHOT
EOF
  [ "$(git -C "$WORKTREE" rev-parse "$STACK_BASE_REF")" = "$STACK_REWRITTEN_HEAD" ] \
    || fail "rewritten stacked PR base did not force-update its tracking ref"
  unset FAKE_PR_BASE_BRANCH FAKE_PR_URL FAKE_PR_BASE_OID
  ROLLBACK_CHECKPOINT="$TEST_DIR/rollback-checkpoint"
  mkdir -p "$ROLLBACK_CHECKPOINT/review-fix"
  {
    printf 'thread-checkpoint\ttarget.txt\t1\tfalse\tchatgpt-codex-connector\t%s\t2026-01-01T00:00:02Z\tfalse\t1\tthread-checkpoint\t%s\turl\tbody\n' \
      "$(git -C "$WORKTREE" rev-parse HEAD)" "$FAKE_SNAPSHOT_DIGEST"
    printf 'thread-checkpoint-2\ttarget.txt\t2\tfalse\tchatgpt-codex-connector\t%s\t2026-01-01T00:00:03Z\tfalse\t1\tthread-checkpoint-2\t%s\turl\tbody\n' \
      "$(git -C "$WORKTREE" rev-parse HEAD)" "$FAKE_SNAPSHOT_DIGEST"
  } >"$ROLLBACK_CHECKPOINT/review-fix/threads.tsv"
  ROLLBACK_CHECKPOINT_KEY="$(touchstone_review_fix_thread_key thread-checkpoint)"
  ROLLBACK_CHECKPOINT_KEY_2="$(touchstone_review_fix_thread_key thread-checkpoint-2)"
  touchstone_ship_write "$ROLLBACK_CHECKPOINT/review-fix" \
    "resolved-$ROLLBACK_CHECKPOINT_KEY" "$(git -C "$WORKTREE" rev-parse HEAD)"
  touchstone_ship_write "$ROLLBACK_CHECKPOINT/review-fix" \
    "resolved-$ROLLBACK_CHECKPOINT_KEY_2" "$(git -C "$WORKTREE" rev-parse HEAD)"
  printf 'thread-checkpoint\n' >"$FAKE_THREAD_ID"
  : >"$FAKE_UNRESOLVE_LOG"
  : >"$FAKE_RESOLVED"
  : >"$FAKE_HEAD_MOVED"
  if touchstone_review_fix_confirm_head \
    "$ROLLBACK_CHECKPOINT" "$WORKTREE" 77 "$(git -C "$WORKTREE" rev-parse HEAD)" 4; then
    fail "changed PR head did not stop checkpointed thread finalization"
  else
    ROLLBACK_HEAD_EXIT=$?
    [ "$ROLLBACK_HEAD_EXIT" -eq 4 ] \
      || fail "changed PR head returned $ROLLBACK_HEAD_EXIT instead of 4"
  fi
  rm -f "$FAKE_HEAD_MOVED"
  [ ! -f "$ROLLBACK_CHECKPOINT/review-fix/resolved-$ROLLBACK_CHECKPOINT_KEY" ] \
    || fail "checkpointed review thread remained marked resolved after rollback"
  [ ! -f "$ROLLBACK_CHECKPOINT/review-fix/resolved-$ROLLBACK_CHECKPOINT_KEY_2" ] \
    || fail "second checkpointed review thread remained marked resolved after rollback"
  [ "$(wc -l <"$FAKE_UNRESOLVE_LOG" | tr -d ' ')" -eq 2 ] \
    || fail "all checkpointed review threads were not rolled back"
  CROSS_CHECKPOINT="$TEST_DIR/cross-checkpoint"
  mkdir -p "$CROSS_CHECKPOINT/review-fix"
  RESTART_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
  RESTART_BASE="$(git -C "$WORKTREE" rev-parse main)"
  printf 'thread-cross\ttarget.txt\t1\tfalse\tchatgpt-codex-connector\t%s\t2026-01-01T00:00:02Z\tfalse\t1\tthread-cross\t%s\turl\tbody\n' \
    "$(git -C "$WORKTREE" rev-parse HEAD~1)" "$FAKE_SNAPSHOT_DIGEST" \
    >"$CROSS_CHECKPOINT/review-fix/threads.tsv"
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" source-head "$(git -C "$WORKTREE" rev-parse HEAD~1)"
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" fix-head "$RESTART_HEAD"
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" base-oid "$RESTART_BASE"
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" repo-full-name example/project
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" pr-number 76
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" reply-author touchstone-test-user
  printf 'thread-cross\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  if touchstone_review_fix_resume_checkpoint \
    "$CROSS_CHECKPOINT" "$WORKTREE" example/project 77 "$RESTART_HEAD"; then
    fail "checkpoint from another PR was allowed to resume"
  else
    CROSS_EXIT=$?
    [ "$CROSS_EXIT" -eq 2 ] || fail "cross-PR checkpoint returned $CROSS_EXIT instead of 2"
  fi
  [ ! -f "$FAKE_REPLIED" ] || fail "cross-PR checkpoint replied to an old thread"
  [ ! -f "$FAKE_RESOLVED" ] || fail "cross-PR checkpoint resolved an old thread"
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" pr-number 77
  CROSS_KEY="$(touchstone_review_fix_thread_key thread-cross)"
  touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" "resolved-$CROSS_KEY" "$RESTART_HEAD"
  : >"$FAKE_UNRESOLVE_LOG"
  if touchstone_review_fix_resume_checkpoint \
    "$CROSS_CHECKPOINT" "$WORKTREE" example/project 77 "$(printf '%040d' 0)"; then
    fail "checkpoint resumed after the PR head changed"
  else
    CROSS_HEAD_EXIT=$?
    [ "$CROSS_HEAD_EXIT" -eq 2 ] \
      || fail "changed checkpoint head returned $CROSS_HEAD_EXIT instead of 2"
  fi
  [ ! -f "$CROSS_CHECKPOINT/review-fix/resolved-$CROSS_KEY" ] \
    || fail "resume head mismatch left a checkpointed thread resolved"
  [ "$(wc -l <"$FAKE_UNRESOLVE_LOG" | tr -d ' ')" -eq 1 ] \
    || fail "resume head mismatch did not reopen its checkpointed thread"

  echo "==> Case e2: restart checkpoint detects duplicate replies and resumes resolution"
  CHECKPOINT="$TEST_DIR/checkpoint"
  mkdir -p "$CHECKPOINT/review-fix"
  printf 'thread-restart\ttarget.txt\t1\tfalse\tchatgpt-codex-connector\t%s\t2026-01-01T00:00:02Z\tfalse\t1\tthread-restart\t%s\turl\tbody\n' \
    "$(git -C "$WORKTREE" rev-parse HEAD~1)" "$FAKE_SNAPSHOT_DIGEST" \
    >"$CHECKPOINT/review-fix/threads.tsv"
  touchstone_ship_write "$CHECKPOINT/review-fix" source-head "$(git -C "$WORKTREE" rev-parse HEAD~1)"
  touchstone_ship_write "$CHECKPOINT/review-fix" fix-head "$RESTART_HEAD"
  touchstone_ship_write "$CHECKPOINT/review-fix" base-oid "$RESTART_BASE"
  touchstone_ship_write "$CHECKPOINT/review-fix" repo-full-name example/project
  touchstone_ship_write "$CHECKPOINT/review-fix" pr-number 77
  touchstone_ship_write "$CHECKPOINT/review-fix" reply-author touchstone-test-user
  printf 'thread-restart\n' >"$FAKE_THREAD_ID"
  : >"$FAKE_REPLIED"
  rm -f "$FAKE_RESOLVED"
  BEFORE_REPLIES="$(wc -l <"$FAKE_REPLY_LOG" | tr -d ' ')"
  touchstone_review_fix_resume_checkpoint \
    "$CHECKPOINT" "$WORKTREE" example/project 77 "$RESTART_HEAD" \
    || fail "restart checkpoint did not resume"
  AFTER_REPLIES="$(wc -l <"$FAKE_REPLY_LOG" | tr -d ' ')"
  [ "$BEFORE_REPLIES" = "$AFTER_REPLIES" ] || fail "restart duplicated an existing reply"
  [ ! -d "$CHECKPOINT/review-fix" ] || fail "restart checkpoint was not cleared"

  echo "==> Case f: completed and timed-out child PID state is cleared"
  touchstone_ship_write "$CHECKPOINT" deadline-epoch "$(($(date +%s) + 30))"
  touchstone_review_fix_run_child "$CHECKPOINT" : \
    || fail "successful review-fix child returned failure"
  [ -z "$child_pid" ] || fail "completed review-fix child PID remained in memory"
  [ -z "$(touchstone_ship_read "$CHECKPOINT" child-pid)" ] \
    || fail "completed review-fix child PID remained persisted"
  touchstone_ship_write "$CHECKPOINT" deadline-epoch "$(date +%s)"
  if touchstone_review_fix_run_child "$CHECKPOINT" sleep 5; then
    fail "expired review-fix deadline did not stop the child"
  else
    DEADLINE_EXIT=$?
    [ "$DEADLINE_EXIT" -eq 124 ] || fail "deadline returned $DEADLINE_EXIT instead of 124"
  fi
  [ -z "$child_pid" ] || fail "timed-out review-fix child PID remained in memory"
  [ -z "$(touchstone_ship_read "$CHECKPOINT" child-pid)" ] \
    || fail "timed-out review-fix child PID remained persisted"

  echo "==> Case f2: the persisted deadline terminates hung validation"
  DEADLINE_WT="$TEST_DIR/deadline-worktree"
  git -C "$REPO" branch feat/review-deadline main
  git -C "$REPO" push -q origin feat/review-deadline
  git -C "$REPO" worktree add -q "$DEADLINE_WT" feat/review-deadline
  : >"$FAKE_THREAD_ACTIVE"
  printf 'thread-deadline\n' >"$FAKE_THREAD_ID"
  rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
  DEADLINE_JOB="$(touchstone_ship_job_dir "$DEADLINE_WT")"
  DEADLINE_EPOCH="$(($(date +%s) + 60))"
  VALIDATION_STARTED="$TEST_DIR/validation-started"
  touchstone_ship_write "$DEADLINE_JOB" deadline-epoch "$DEADLINE_EPOCH"
  touchstone_ship_write "$DEADLINE_JOB" review-fix-iteration 0

  # Keep setup independent of runner speed, then expire the persisted clock as
  # soon as validation proves it started. The production poll loop remains real.
  date() {
    if [ "${1:-}" = "+%s" ] && [ -f "$VALIDATION_STARTED" ]; then
      printf '%s\n' "$DEADLINE_EPOCH"
      return
    fi
    command date "$@"
  }

  if TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
    touchstone_review_fix_run \
    "$DEADLINE_JOB" "$DEADLINE_WT" 2 "$DEADLINE_EPOCH" \
    "trap '' TERM; /bin/date +%s >'$VALIDATION_STARTED'; sleep 30" false; then
    fail "hung validation unexpectedly completed"
  fi
  unset -f date
  assert_contains "$DEADLINE_JOB/reason" '^time-budget-exhausted$'
  if [ -f "$VALIDATION_STARTED" ]; then
    DEADLINE_ELAPSED=$(($(date +%s) - $(cat "$VALIDATION_STARTED")))
  else
    fail "deadline fixture did not reach validation"
    DEADLINE_ELAPSED=999
  fi
  [ "$DEADLINE_ELAPSED" -lt 5 ] \
    || fail "hung validation exceeded the persisted deadline ($DEADLINE_ELAPSED seconds)"

  echo "==> Case g: default Codex worker rejects metered or unknown authentication"
  cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  echo "Logged in using an API key"
  exit 0
fi
echo "unexpected Codex execution" >"$FAKE_CODEX_EXECUTED"
EOF
  chmod +x "$FAKE_BIN/codex"
  printf 'brief\n' >"$TEST_DIR/auth-brief"
  export FAKE_CODEX_EXECUTED="$TEST_DIR/codex-executed"
  if touchstone_review_fix_invoke_worker \
    "$WORKTREE" "$TEST_DIR/auth-brief" "$TEST_DIR/auth-result" \
    >"$TEST_DIR/auth.out" 2>&1; then
    fail "API-key Codex authentication was accepted"
  else
    AUTH_EXIT=$?
    [ "$AUTH_EXIT" -eq 126 ] || fail "API-key auth returned $AUTH_EXIT instead of 126"
  fi
  [ ! -f "$FAKE_CODEX_EXECUTED" ] || fail "Codex exec ran after metered authentication was rejected"
  assert_contains "$TEST_DIR/auth.out" 'requires a ChatGPT-authenticated Codex CLI'

  echo "==> Case h: default preflight validates every dirty and untracked worker path"
  PREFLIGHT_REPO="$TEST_DIR/preflight-repo"
  PREFLIGHT_PATHS="$TEST_DIR/preflight-paths.zlist"
  cat >"$FAKE_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >&2
saw_tracked=false
saw_untracked=false
for arg in "$@"; do
  [ "$arg" = tracked-invalid.sh ] && saw_tracked=true
  [ "$arg" = untracked-invalid.sh ] && saw_untracked=true
done
[ "$saw_tracked" = true ] && [ "$saw_untracked" = true ] && exit 1
exit 0
EOF
  chmod +x "$FAKE_BIN/shellcheck"
  git init -q -b main "$PREFLIGHT_REPO"
  git -C "$PREFLIGHT_REPO" config user.name "Touchstone Test"
  git -C "$PREFLIGHT_REPO" config user.email "touchstone@example.com"
  mkdir -p "$PREFLIGHT_REPO/lib"
  cp "$TOUCHSTONE_ROOT/lib/preflight.sh" "$PREFLIGHT_REPO/lib/preflight.sh"
  cp "$TOUCHSTONE_ROOT/lib/preflight-scope.sh" "$PREFLIGHT_REPO/lib/preflight-scope.sh"
  printf 'fixture\n' >"$PREFLIGHT_REPO/tracked.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$PREFLIGHT_REPO/tracked-invalid.sh"
  git -C "$PREFLIGHT_REPO" add lib tracked.txt tracked-invalid.sh
  git -C "$PREFLIGHT_REPO" commit -qm "fixture base"
  printf '#!/usr/bin/env bash\nif then\n' >"$PREFLIGHT_REPO/tracked-invalid.sh"
  printf '#!/usr/bin/env bash\nif then\n' >"$PREFLIGHT_REPO/untracked-invalid.sh"
  printf 'tracked-invalid.sh\0untracked-invalid.sh\0' >"$PREFLIGHT_PATHS"
  if touchstone_review_fix_validate \
    "$PREFLIGHT_REPO" "" HEAD "$PREFLIGHT_PATHS" >"$TEST_DIR/preflight.out" 2>&1; then
    fail "default preflight ignored dirty or untracked worker paths"
  fi
  [ -z "$(git -C "$PREFLIGHT_REPO" diff --cached --name-only)" ] \
    || fail "default preflight staged worker changes before validation"
  assert_contains "$TEST_DIR/preflight.out" 'tracked-invalid.sh'
  assert_contains "$TEST_DIR/preflight.out" 'untracked-invalid.sh'

  if [ "$ERRORS" -eq 0 ]; then
    echo "==> PASS: autonomous review-fix is bounded, exact-head, durable, and idempotent"
    exit 0
  fi

  echo "==> FAIL: $ERRORS autonomous review-fix assertion(s) failed" >&2
  exit 1

)
