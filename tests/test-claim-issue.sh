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

(
  # tests/test-tracker-adapter.sh — tracker-neutral adapter contract tests.

  set -euo pipefail

  ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
  TMP="$(mktemp -d -t touchstone-tracker.XXXXXX)"
  trap 'rm -rf "$TMP"' EXIT
  ERRORS=0

  fail() {
    echo "FAIL: $*" >&2
    ERRORS=$((ERRORS + 1))
  }
  assert_has() { grep -qF -- "$2" "$1" || fail "expected $1 to contain: $2"; }
  assert_not_has() { grep -qF -- "$2" "$1" && fail "expected $1 not to contain: $2" || true; }
  assert_rc() { [ "$1" -eq "$2" ] || fail "expected rc $2, got $1"; }
  assert_json() { jq -e '.schema == "touchstone.tracker/v1" and (.status == "verified" or .status == "unverifiable" or .status == "failed")' "$1" >/dev/null || fail "$1 is not a valid v1 tracker result"; }

  mkdir -p "$TMP/bin" "$TMP/github" "$TMP/linear"
  git -C "$TMP/github" init -q
  git -C "$TMP/linear" init -q
  git -C "$TMP/github" remote add origin git@github.com:autumngarage/current.git
  git -C "$TMP/linear" remote add origin https://github.com/autumngarage/current.git
  printf '%s\n' 'schema = 1' '' '[validation]' 'runtime = "bash"' \
    'setup = "touch contract-ran"' \
    '' '[[validation.targets]]' 'name = "root"' 'path = "."' \
    '' '[[validation.tasks]]' 'name = "test"' 'target = "root"' \
    'command = "touch contract-ran"' 'required = true' >"$TMP/github/.touchstone.toml"
  cp "$TMP/github/.touchstone.toml" "$TMP/linear/.touchstone.toml"
  printf '%s\n' 'schema = 1' 'type = "github"' >"$TMP/github/.touchstone-tracker.toml"
  printf '%s\n' 'schema = 1' 'type = "linear"' 'key_prefix = "AUT"' >"$TMP/linear/.touchstone-tracker.toml"

  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"
case "$1 ${2:-}" in
  "auth status") [ "${GH_MODE:-ok}" != auth_fail ] ;;
	"api user") printf '%s\n' henry ;;
  "issue view")
    if printf '%s\n' "$*" | grep -q -- '--json state'; then
      printf '%s\n' OPEN
    elif [ "${GH_MODE:-ok}" = post_claim_read_fail ] && [ -s "$GH_STATE" ]; then
			exit 1
    elif [ -f "$GH_STATE" ]; then cat "$GH_STATE"
    fi
    ;;
  "issue edit")
    if [ "${GH_MODE:-ok}" = claim_control_error ]; then
      printf 'claim failed\rwith control\fbyte\n' >&2
      exit 1
    fi
    printf '%s\n' henry >"$GH_STATE"
    ;;
  "issue comment") ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" GH_CALLS="$TMP/gh-calls" GH_STATE="$TMP/gh-state"

  run_adapter() {
    local output="$1"
    shift
    set +e
    bash "$ROOT/scripts/touchstone-tracker.sh" "$@" >"$output" 2>&1
    RUN_RC=$?
    set -e
  }

  echo "==> GitHub claim is verified only after the surviving adapter re-reads assignment"
  : >"$GH_CALLS"
  : >"$GH_STATE"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"schema":"touchstone.tracker/v1"'
  assert_has "$TMP/out" '"status":"verified"'
  assert_json "$TMP/out"
  assert_has "$GH_CALLS" 'issue edit 42 --add-assignee @me'
  test "$(cat "$GH_STATE")" = henry || fail "claim did not persist mocked assignment"
  [ ! -e "$TMP/github/contract-ran" ] || fail "contract check executed validation commands"

  echo "==> authentication and failed mutations never report success"
  GH_MODE=auth_fail run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"status":"failed"'
  assert_not_has "$TMP/out" '"status":"verified"'
  : >"$GH_STATE"
  GH_MODE=claim_control_error run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 1
  assert_json "$TMP/out"
  assert_has "$TMP/out" 'claim failed\rwith control\u000cbyte'
  : >"$GH_STATE"
  GH_MODE=post_claim_read_fail run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"reason":"github-claim-failed"'
  assert_has "$TMP/out" '"partial":true'
  test "$(cat "$GH_STATE")" = henry || fail "partial claim did not preserve the mutated assignment"

  echo "==> Linear claim exposes an exact MCP/API action without false verification"
  run_adapter "$TMP/out" claim aut-281 --project "$TMP/linear" --json
  assert_rc "$RUN_RC" 3
  assert_has "$TMP/out" '"tracker":"linear"'
  assert_has "$TMP/out" '"reference":"AUT-281"'
  assert_has "$TMP/out" '"status":"unverifiable"'
  assert_has "$TMP/out" 'assign AUT-281 to yourself'
  assert_json "$TMP/out"

  echo "==> wrong-tracker issue references fail with a concrete rewrite"
  run_adapter "$TMP/out" claim 281 --project "$TMP/linear"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'Use a Linear issue key such as AUT-123'
  run_adapter "$TMP/out" claim AUT-281 --project "$TMP/github"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" "Use a GitHub issue number such as 123, or quote '#123'"
  run_adapter "$TMP/out" claim 42 --project "$TMP/missing" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"reason":"project-not-found"'
  assert_json "$TMP/out"
  run_adapter "$TMP/out" claim 42 --json --bogus
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"reason":"unknown-argument"'
  assert_json "$TMP/out"
  run_adapter "$TMP/out" claim 42 --json --project
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"reason":"missing-option-value"'
  assert_json "$TMP/out"
  run_adapter "$TMP/out" claim 42 --project '' --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"reason":"missing-option-value"'
  assert_json "$TMP/out"
  run_adapter "$TMP/out" claim --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"reason":"missing-reference"'
  assert_json "$TMP/out"
  run_adapter "$TMP/out" bogus --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"reason":"unknown-operation"'
  assert_json "$TMP/out"
  run_adapter "$TMP/out" claim 42 --project --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"reason":"missing-option-value"'
  assert_json "$TMP/out"
  cat >"$TMP/no-gh.bash" <<'EOF'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = gh ]; then
    return 1
  fi
  builtin command "$@"
}
EOF
  BASH_ENV="$TMP/no-gh.bash" run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 3
  assert_has "$TMP/out" '"status":"unverifiable"'
  assert_has "$TMP/out" '"reason":"transport-unavailable"'
  assert_json "$TMP/out"

  echo "==> malformed, old-compatible, and unsupported tracker declarations are explicit"
  cp "$TMP/github/.touchstone-tracker.toml" "$TMP/github/tracker-good"
  rm "$TMP/github/.touchstone-tracker.toml"
  : >"$GH_STATE"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 0
  printf '%s\n' 'type = "linear"' 'key_prefix = "AUT"' >"$TMP/github/.touchstone-tracker.toml"
  run_adapter "$TMP/out" claim AUT-1 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'missing-tracker-schema'
  printf '%s\n' 'schema = 2' 'type = "github"' >"$TMP/github/.touchstone-tracker.toml"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'unsupported-tracker-schema'
  printf '%s\n' 'schema = 1' 'type = "github"' 'type = "github"' >"$TMP/github/.touchstone-tracker.toml"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'duplicate-tracker-key'
  printf '%s\n' 'schema = 1' 'type = "linear"' 'key_prefix = "aut"' >"$TMP/github/.touchstone-tracker.toml"
  run_adapter "$TMP/out" claim AUT-1 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'invalid-key-prefix'
  printf '%s\n' 'schema = 1' '[tracker]' 'type = "github"' >"$TMP/github/.touchstone-tracker.toml"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'malformed-config'
  printf '%s\n' 'schema = 1' 'type = "github' >"$TMP/github/.touchstone-tracker.toml"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'malformed-config'
  mv "$TMP/github/tracker-good" "$TMP/github/.touchstone-tracker.toml"

  echo "==> tracker mutations require a valid project contract"
  cp "$TMP/github/.touchstone.toml" "$TMP/github/project-good"
  printf '%s\n' 'schema = 1' '' '[validation]' 'runtime = "bash"' >"$TMP/github/.touchstone.toml"
  : >"$GH_CALLS"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'invalid-project-contract'
  assert_not_has "$GH_CALLS" 'issue edit'
  mv "$TMP/github/project-good" "$TMP/github/.touchstone.toml"

  echo "==> tracker selection cannot follow a configuration symlink"
  rm "$TMP/github/.touchstone-tracker.toml"
  ln -s "$TMP/linear/.touchstone-tracker.toml" "$TMP/github/.touchstone-tracker.toml"
  : >"$GH_CALLS"
  run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'unsafe-config'
  assert_not_has "$GH_CALLS" 'issue edit'

  if [ "$ERRORS" -gt 0 ]; then
    echo "==> FAIL: $ERRORS tracker adapter assertion(s) failed" >&2
    exit 1
  fi
  echo "==> PASS: tracker adapter preserves claim semantics"
)

# The vacuous PR-time claim gate was deleted (AUT-302): it enforced GitHub
# issue claims for a repository whose tracking is Linear-only, so it could
# only pass over an empty set. These assertions lock the deletion in -- a
# template refresh or workflow restore would otherwise bring it back
# silently. claim-issue.sh itself stays: it is the tracker adapter's GitHub
# transport and is covered above.
echo "==> the deleted claim gate stays deleted"
for relic in \
  "scripts/issue-claim-check.sh" \
  ".github/workflows/issue-claim-check.yml" \
  "templates/ci/issue-claim-check.yml"; do
  if [ -e "$TOUCHSTONE_ROOT/$relic" ]; then
    echo "FAIL: deleted claim-gate file has returned: $relic" >&2
    exit 1
  fi
done
if grep -rn "skip-claim-check" "$TOUCHSTONE_ROOT/docs" "$TOUCHSTONE_ROOT/scripts" "$TOUCHSTONE_ROOT/.github" 2>/dev/null; then
  echo "FAIL: the retired skip-claim-check contract is referenced again" >&2
  exit 1
fi
echo "  ok: claim-gate files and the skip token remain absent"
