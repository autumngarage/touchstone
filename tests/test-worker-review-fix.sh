#!/usr/bin/env bash
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
    if [ -f "${FAKE_HEAD_MOVED:-/nonexistent}" ]; then
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
        printf '%s\ttarget.txt\t1\tfalse\t%s\t%s\t%s\t%s\t%s\t%s\thttps://example.test/thread/%s\t%s\n' \
          "$thread_id" \
          "${FAKE_THREAD_AUTHOR:-chatgpt-codex-connector}" \
          "$review_head" \
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
    elif [[ "$args" == *resolveReviewThread* ]]; then
      printf 'resolve\n' >>"$FAKE_RESOLVE_LOG"
      : >"$FAKE_RESOLVED"
      if [ "${FAKE_REPLACE_THREAD:-0}" = 1 ] && [ ! -f "$FAKE_REPLACED" ]; then
        printf 'thread-2\n' >"$FAKE_THREAD_ID"
        : >"$FAKE_REPLACED"
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
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$resolved" "$total_count" "$loaded_count" "$nonmarker_count" \
        "$marker_count" "$comment_ids" "$snapshot_encoded"
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
    *) printf 'thread_id=%s\n' "$(cat "$FAKE_THREAD_ID")" ;;
  esac
} >"$result_file"
EOF
  chmod +x "$worker"
}

export FAKE_THREAD_ACTIVE="$TEST_DIR/thread-active"
export FAKE_THREAD_ID="$TEST_DIR/thread-id"
export FAKE_REPLY_LOG="$TEST_DIR/replies"
export FAKE_RESOLVE_LOG="$TEST_DIR/resolves"
export FAKE_REPLIED="$TEST_DIR/replied"
export FAKE_RESOLVED="$TEST_DIR/resolved"
export FAKE_REPLACED="$TEST_DIR/replaced"
export FAKE_STALE_NEXT="$TEST_DIR/stale-next"
export FAKE_HEAD_MOVED="$TEST_DIR/head-moved"
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

echo "==> Case c9: another author's marker-shaped comment cannot authorize resolution"
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
rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED" "$FAKE_REPLACED"
export FAKE_REPLACE_THREAD=1
TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
  "$TOUCHSTONE_ROOT/bin/touchstone" worker ship \
  --worktree "$BUDGET_WT" --detach --review-fix \
  --max-fix-iterations 1 --validation-command : >/dev/null
wait_for_status "$BUDGET_WT" needs-attention "$STATUS" \
  || fail "iteration budget exhaustion did not enter needs-attention"
assert_contains "$STATUS" '"reason":"iteration-budget-exhausted"'
unset FAKE_REPLACE_THREAD

echo "==> Case e: a checkpoint cannot cross PR identity boundaries"
# shellcheck source=../lib/worker-state.sh
source "$TOUCHSTONE_ROOT/lib/worker-state.sh"
# shellcheck source=../lib/worker-ship-job.sh
source "$TOUCHSTONE_ROOT/lib/worker-ship-job.sh"
# shellcheck source=../lib/events.sh
source "$TOUCHSTONE_ROOT/lib/events.sh"
# shellcheck source=../lib/worker-review-fix.sh
source "$TOUCHSTONE_ROOT/lib/worker-review-fix.sh"
CROSS_CHECKPOINT="$TEST_DIR/cross-checkpoint"
mkdir -p "$CROSS_CHECKPOINT/review-fix"
RESTART_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
printf 'thread-cross\ttarget.txt\t1\tfalse\tchatgpt-codex-connector\t%s\tfalse\t1\tthread-cross\t%s\turl\tbody\n' \
  "$(git -C "$WORKTREE" rev-parse HEAD~1)" "$FAKE_SNAPSHOT_DIGEST" \
  >"$CROSS_CHECKPOINT/review-fix/threads.tsv"
touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" source-head "$(git -C "$WORKTREE" rev-parse HEAD~1)"
touchstone_ship_write "$CROSS_CHECKPOINT/review-fix" fix-head "$RESTART_HEAD"
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

echo "==> Case e2: restart checkpoint detects duplicate replies and resumes resolution"
CHECKPOINT="$TEST_DIR/checkpoint"
mkdir -p "$CHECKPOINT/review-fix"
printf 'thread-restart\ttarget.txt\t1\tfalse\tchatgpt-codex-connector\t%s\tfalse\t1\tthread-restart\t%s\turl\tbody\n' \
  "$(git -C "$WORKTREE" rev-parse HEAD~1)" "$FAKE_SNAPSHOT_DIGEST" \
  >"$CHECKPOINT/review-fix/threads.tsv"
touchstone_ship_write "$CHECKPOINT/review-fix" source-head "$(git -C "$WORKTREE" rev-parse HEAD~1)"
touchstone_ship_write "$CHECKPOINT/review-fix" fix-head "$RESTART_HEAD"
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

echo "==> Case f: the persisted wall-clock deadline terminates a stalled child"
touchstone_ship_write "$CHECKPOINT" deadline-epoch "$(date +%s)"
if touchstone_review_fix_run_child "$CHECKPOINT" sleep 5; then
  fail "expired review-fix deadline did not stop the child"
else
  DEADLINE_EXIT=$?
  [ "$DEADLINE_EXIT" -eq 124 ] || fail "deadline returned $DEADLINE_EXIT instead of 124"
fi

echo "==> Case f2: the persisted deadline terminates hung validation"
DEADLINE_WT="$TEST_DIR/deadline-worktree"
git -C "$REPO" branch feat/review-deadline main
git -C "$REPO" push -q origin feat/review-deadline
git -C "$REPO" worktree add -q "$DEADLINE_WT" feat/review-deadline
: >"$FAKE_THREAD_ACTIVE"
printf 'thread-deadline\n' >"$FAKE_THREAD_ID"
rm -f "$FAKE_REPLIED" "$FAKE_RESOLVED"
DEADLINE_JOB="$(touchstone_ship_job_dir "$DEADLINE_WT")"
DEADLINE_EPOCH="$(($(date +%s) + 4))"
VALIDATION_STARTED="$TEST_DIR/validation-started"
touchstone_ship_write "$DEADLINE_JOB" deadline-epoch "$DEADLINE_EPOCH"
touchstone_ship_write "$DEADLINE_JOB" review-fix-iteration 0
DEADLINE_START="$(date +%s)"
if TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND="$FIX_WORKER" \
  touchstone_review_fix_run \
  "$DEADLINE_JOB" "$DEADLINE_WT" 2 "$DEADLINE_EPOCH" \
  "trap '' TERM; printf started >'$VALIDATION_STARTED'; sleep 10" false; then
  fail "hung validation unexpectedly completed"
fi
DEADLINE_ELAPSED=$(($(date +%s) - DEADLINE_START))
assert_contains "$DEADLINE_JOB/reason" '^time-budget-exhausted$'
[ -f "$VALIDATION_STARTED" ] || fail "deadline fixture did not reach validation"
[ "$DEADLINE_ELAPSED" -lt 9 ] \
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

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: autonomous review-fix is bounded, exact-head, durable, and idempotent"
  exit 0
fi

echo "==> FAIL: $ERRORS autonomous review-fix assertion(s) failed" >&2
exit 1
