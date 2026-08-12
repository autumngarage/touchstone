#!/usr/bin/env bash
#
# tests/test-claim-issue.sh — deterministic unit tests for claim-issue.sh.
#
# Cases 1-7 exercise the GitHub adapter against the repository's own checkout.
# Cases 8-13 exercise which adapter runs at all: the [issues] declaration is
# read from the script's own project root, so those cases need a fixture tree
# whose declaration can change between them (#743).
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=stage-touchstone-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/stage-touchstone-libs.sh"
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

# ---------------------------------------------------------------------------
# Which adapter runs: the [issues] declaration decides, and it is read from the
# script's own project root. The fixture mirrors the shipped layout (scripts/
# next to lib/) so the lookup being exercised is the one downstream projects
# and the CI base checkout actually use.
# ---------------------------------------------------------------------------
FIXTURE="$TEST_DIR/project"
mkdir -p "$FIXTURE/scripts"
cp "$TOUCHSTONE_ROOT/scripts/claim-issue.sh" "$FIXTURE/scripts/"
stage_touchstone_libs "$TOUCHSTONE_ROOT" "$FIXTURE/scripts"

write_fixture_config() {
  printf '%s\n' "$1" >"$FIXTURE/.touchstone-review.toml"
}

# Runs the fixture copy from a cwd that carries no declaration of its own, so
# a case that passes is one where the project root supplied the tracker.
run_fixture_claim() {
  local output_file="$1"
  shift
  (
    cd "$TEST_DIR" || exit 2
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
      GH_COMMENT_LOG="$TEST_DIR/gh-comments.log" \
      GH_ASSIGNEE_VIEW_COUNT_FILE="$TEST_DIR/gh-assignee-views.count" \
      GH_USER_LOGIN="${GH_USER_LOGIN:-me}" \
      GH_PRE_ASSIGNEES="${GH_PRE_ASSIGNEES:-}" \
      GH_POST_ASSIGNEES="${GH_POST_ASSIGNEES:-}" \
      bash "$FIXTURE/scripts/claim-issue.sh" "$@"
  ) >"$output_file" 2>&1
}

assert_no_gh_calls() {
  local why="$1"
  if [ -s "$TEST_DIR/gh-calls.log" ]; then
    fail "$why; gh was invoked:"
    sed 's/^/    | /' "$TEST_DIR/gh-calls.log" >&2
  fi
}

echo "==> Case 8: no [issues] declaration keeps the GitHub claim path"
reset_case
write_fixture_config '[review]
preflight_required = true'
OUT="$TEST_DIR/case8.out"
GH_PRE_ASSIGNEES="" GH_POST_ASSIGNEES="me"
if run_fixture_claim "$OUT" 108 "dispatch: case8"; then
  assert_file_contains "$TEST_DIR/gh-calls.log" "issue edit 108 --add-assignee @me"
  assert_file_contains "$TEST_DIR/gh-calls.log" "issue comment 108 --body dispatch: case8"
else
  fail "case 8 expected exit 0"
  cat "$OUT" >&2
fi

echo "==> Case 9: a linear project claims without touching gh"
reset_case
write_fixture_config '[issues]
tracker = "linear"
key_prefix = "CON"'
OUT="$TEST_DIR/case9.out"
if run_fixture_claim "$OUT" CON-7; then
  fail "case 9 expected exit 3"
else
  rc=$?
  # Exit 3, never 0: nothing was claimed, and a dispatching agent branches on
  # this. Exiting 0 would let a scripted claim silently no-op (#743 review).
  assert_eq "case 9 rc" "3" "$rc"
  assert_file_contains "$OUT" "MANUAL CLAIM REQUIRED"
  assert_file_contains "$OUT" "Assign CON-7 to yourself"
  assert_file_contains "$OUT" "Fixes CON-7"
  assert_file_contains "$OUT" "Exit 3 (manual action required): nothing has been claimed yet."
  assert_no_gh_calls "case 9: the linear claim path must not invoke gh at all"
fi

echo "==> Case 10: a linear project refuses a GitHub-shaped reference"
reset_case
OUT="$TEST_DIR/case10.out"
if run_fixture_claim "$OUT" 743; then
  fail "case 10 expected exit 2"
else
  rc=$?
  assert_eq "case 10 rc" "2" "$rc"
  assert_file_contains "$OUT" "is not a linear issue reference; expected a Linear issue key like CON-123"
fi

echo "==> Case 11: key_prefix pins references to one team"
reset_case
OUT="$TEST_DIR/case11.out"
if run_fixture_claim "$OUT" ABC-7; then
  fail "case 11 expected exit 2"
else
  rc=$?
  assert_eq "case 11 rc" "2" "$rc"
  assert_file_contains "$OUT" "expected a Linear issue key like CON-123"
fi

echo "==> Case 12: an unimplemented tracker fails closed with the remedy"
reset_case
write_fixture_config '[issues]
tracker = "jira"'
OUT="$TEST_DIR/case12.out"
if run_fixture_claim "$OUT" 12; then
  fail "case 12 expected exit 2"
else
  rc=$?
  assert_eq "case 12 rc" "2" "$rc"
  assert_file_contains "$OUT" "unknown issue tracker 'jira'"
  assert_file_contains "$OUT" 'Set [issues].tracker = "github" or [issues].tracker = "linear"'
  assert_no_gh_calls "case 12: an unhonorable declaration must fail before any transport runs"
fi

echo "==> Case 13: key_prefix under GitHub is a declaration error, not a no-op"
reset_case
write_fixture_config '[issues]
tracker = "github"
key_prefix = "CON"'
OUT="$TEST_DIR/case13.out"
if run_fixture_claim "$OUT" 12; then
  fail "case 13 expected exit 2"
else
  rc=$?
  assert_eq "case 13 rc" "2" "$rc"
  assert_file_contains "$OUT" "key_prefix applies to the linear tracker only"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS case(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: claim-issue.sh behaves correctly across 13 cases"
