#!/usr/bin/env bash
#
# tests/test-claim-issue.sh — deterministic unit tests for claim-issue.sh.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-claim-issue.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${GH_CALL_LOG:?}"

echo "$*" >>"$GH_CALL_LOG"

cmd1="${1:-}"
cmd2="${2:-}"

if [ "$cmd1" = "auth" ] && [ "$cmd2" = "status" ]; then
  exit "${GH_AUTH_EXIT:-0}"
fi

if [ "$cmd1" = "api" ] && [ "$cmd2" = "user" ]; then
  echo "${GH_USER_LOGIN:-me}"
  exit 0
fi

if [ "$cmd1" = "issue" ] && [ "$cmd2" = "view" ]; then
  if [ "${GH_ISSUE_EXISTS:-true}" != "true" ]; then
    exit 1
  fi
  case "$*" in
    *"--json state"*)
      echo "${GH_ISSUE_STATE:-OPEN}"
      exit 0
      ;;
    *"--json assignees"*)
      count_file="${GH_ASSIGNEE_VIEW_COUNT_FILE:?}"
      count=0
      if [ -f "$count_file" ]; then
        count="$(cat "$count_file")"
      fi
      count=$((count + 1))
      printf '%s' "$count" >"$count_file"
      if [ "$count" -eq 1 ]; then
        printf '%s' "${GH_PRE_ASSIGNEES:-}"
      else
        printf '%s' "${GH_POST_ASSIGNEES:-${GH_PRE_ASSIGNEES:-}}"
      fi
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
fi

if [ "$cmd1" = "issue" ] && [ "$cmd2" = "edit" ]; then
  exit 0
fi

if [ "$cmd1" = "issue" ] && [ "$cmd2" = "comment" ]; then
  body=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--body" ]; then
      body="$arg"
      break
    fi
    prev="$arg"
  done
  printf '%s\n' "$body" >>"${GH_COMMENT_LOG:?}"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2"
  if ! grep -qF "$needle" "$file"; then
    fail "expected $file to contain '$needle'"
  fi
}

assert_file_not_contains() {
  local file="$1" needle="$2"
  if grep -qF "$needle" "$file"; then
    fail "expected $file to NOT contain '$needle'"
  fi
}

run_claim_issue() {
  local output_file="$1"
  shift
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    GH_COMMENT_LOG="$TEST_DIR/gh-comments.log" \
    GH_ASSIGNEE_VIEW_COUNT_FILE="$TEST_DIR/gh-assignee-views.count" \
    GH_AUTH_EXIT="${GH_AUTH_EXIT:-0}" \
    GH_USER_LOGIN="${GH_USER_LOGIN:-me}" \
    GH_ISSUE_EXISTS="${GH_ISSUE_EXISTS:-true}" \
    GH_ISSUE_STATE="${GH_ISSUE_STATE:-OPEN}" \
    GH_PRE_ASSIGNEES="${GH_PRE_ASSIGNEES:-}" \
    GH_POST_ASSIGNEES="${GH_POST_ASSIGNEES:-}" \
    bash "$TOUCHSTONE_ROOT/scripts/claim-issue.sh" "$@" >"$output_file" 2>&1
}

reset_case() {
  rm -f "$TEST_DIR/gh-calls.log" "$TEST_DIR/gh-comments.log" "$TEST_DIR/gh-assignee-views.count"
  GH_AUTH_EXIT=0
  GH_USER_LOGIN=me
  GH_ISSUE_EXISTS=true
  GH_ISSUE_STATE=OPEN
  GH_PRE_ASSIGNEES=
  GH_POST_ASSIGNEES=
}

echo "==> Case 1: happy path (unassigned -> claim succeeds)"
reset_case
OUT="$TEST_DIR/case1.out"
GH_PRE_ASSIGNEES=""
GH_POST_ASSIGNEES="me"
if run_claim_issue "$OUT" 101 "dispatch: case1"; then
  assert_file_contains "$TEST_DIR/gh-calls.log" "issue edit 101 --add-assignee @me"
  assert_file_contains "$TEST_DIR/gh-calls.log" "issue comment 101 --body dispatch: case1"
  assert_file_contains "$OUT" "touchstone-claim-state: assignment-mutated"
else
  fail "case 1 expected exit 0"
  cat "$OUT" >&2
fi

echo "==> Case 2: already claimed by me (idempotent)"
reset_case
OUT="$TEST_DIR/case2.out"
GH_PRE_ASSIGNEES="me"
GH_POST_ASSIGNEES="me"
if run_claim_issue "$OUT" 102 "dispatch: case2"; then
  assert_file_not_contains "$TEST_DIR/gh-calls.log" "issue edit 102 --add-assignee @me"
  assert_file_contains "$TEST_DIR/gh-calls.log" "issue comment 102 --body dispatch: case2"
else
  fail "case 2 expected exit 0"
  cat "$OUT" >&2
fi

echo "==> Case 3: already claimed by other user"
reset_case
OUT="$TEST_DIR/case3.out"
GH_PRE_ASSIGNEES="someoneelse"
if run_claim_issue "$OUT" 103; then
  fail "case 3 expected exit 1"
else
  rc=$?
  assert_eq "case 3 rc" "1" "$rc"
  assert_file_contains "$OUT" "already claimed by @someoneelse"
  assert_file_not_contains "$TEST_DIR/gh-calls.log" "issue edit 103 --add-assignee @me"
fi

echo "==> Case 4: race detected after add-assignee"
reset_case
OUT="$TEST_DIR/case4.out"
GH_PRE_ASSIGNEES=""
GH_POST_ASSIGNEES=$'me\notheruser'
if run_claim_issue "$OUT" 104; then
  fail "case 4 expected exit 1"
else
  rc=$?
  assert_eq "case 4 rc" "1" "$rc"
  assert_file_contains "$TEST_DIR/gh-calls.log" "issue edit 104 --add-assignee @me"
  assert_file_contains "$TEST_DIR/gh-calls.log" "issue edit 104 --remove-assignee @me"
  assert_file_contains "$OUT" "race detected"
fi

echo "==> Case 5: closed issue"
reset_case
OUT="$TEST_DIR/case5.out"
GH_ISSUE_STATE="CLOSED"
if run_claim_issue "$OUT" 105; then
  fail "case 5 expected exit 1"
else
  rc=$?
  assert_eq "case 5 rc" "1" "$rc"
  assert_file_contains "$OUT" "can't claim closed issue"
fi

echo "==> Case 6: missing args"
reset_case
OUT="$TEST_DIR/case6.out"
if run_claim_issue "$OUT"; then
  fail "case 6 expected exit 2"
else
  rc=$?
  assert_eq "case 6 rc" "2" "$rc"
  assert_file_contains "$OUT" "Usage:"
fi

echo "==> Case 7: gh not authenticated"
reset_case
OUT="$TEST_DIR/case7.out"
GH_AUTH_EXIT=1
if run_claim_issue "$OUT" 107; then
  fail "case 7 expected exit 2"
else
  rc=$?
  assert_eq "case 7 rc" "2" "$rc"
  assert_file_contains "$OUT" "not authenticated"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS case(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: claim-issue.sh behaves correctly across 7 cases"
