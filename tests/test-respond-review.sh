#!/usr/bin/env bash
#
# tests/test-respond-review.sh — the one-command review-response contract.
#
# scripts/respond-review.sh owns reply + thread-resolve + verification for a
# review finding (issue #652). Cases:
#   1. Happy path — reply posted, thread resolved, verification read passes.
#   2. Fix-commit trailer appended to the reply body.
#   3. Resolution verification failure → nonzero (mutation lies, read wins).
#   4. Transient GraphQL failure retries and then succeeds.
#   5. --all-resolved-check passes when clean, fails listing open threads.
#   6. Unknown comment id → nonzero, no mutation attempted.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-respond-review.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

SCRIPT="$TOUCHSTONE_ROOT/scripts/respond-review.sh"
FAKE_BIN="$TEST_DIR/bin"
GH_LOG="$TEST_DIR/gh.log"
mkdir -p "$FAKE_BIN"

ERRORS=0
fail_case() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

# Mock gh. Behavior keyed by env:
#   GH_THREADS_JSON_TSV — tsv lines returned for the unresolved-thread list
#   GH_RESOLVE_RESULT   — isResolved value returned by the mutation
#   GH_VERIFY_RESULT    — isResolved value returned by the verification read
#   GH_FAIL_GRAPHQL_TIMES — fail the first N graphql calls with HTML garbage
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "${1:-} ${2:-}" in
  "repo view")
    echo "autumngarage/example"
    exit 0
    ;;
  "api graphql")
    count_file="${GH_GRAPHQL_COUNT_FILE:?}"
    count="$(cat "$count_file" 2>/dev/null || echo 0)"
    count=$((count + 1))
    printf '%s' "$count" >"$count_file"
    if [ "$count" -le "${GH_FAIL_GRAPHQL_TIMES:-0}" ]; then
      echo "invalid character '<' looking for beginning of value" >&2
      exit 1
    fi
    query=""
    prev=""
    for arg in "$@"; do
      case "$prev" in query=*) ;; esac
      prev="$arg"
    done
    case "$*" in
      *"resolveReviewThread"*)
        echo "${GH_RESOLVE_RESULT:-true}"
        ;;
      *"node(id:"*)
        echo "${GH_VERIFY_RESULT:-true}"
        ;;
      *"reviewThreads"*)
        # Thread lookup vs unresolved list share this query shape; the jq
        # filter differs, so emit per-mode canned output.
        if [ -n "${GH_THREADS_OUTPUT:-}" ]; then
          printf '%s\n' "$GH_THREADS_OUTPUT"
        fi
        ;;
      *)
        echo "unexpected graphql: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "api repos/autumngarage/example/pulls/77/comments/9001/replies")
    echo "5555"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"
cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/sleep"

run_respond() {
  : >"$GH_LOG"
  printf '0' >"$TEST_DIR/graphql-count"
  PATH="$FAKE_BIN:/usr/bin:/bin" \
    GH_LOG="$GH_LOG" \
    GH_GRAPHQL_COUNT_FILE="$TEST_DIR/graphql-count" \
    GH_THREADS_OUTPUT="${GH_THREADS_OUTPUT:-}" \
    GH_RESOLVE_RESULT="${GH_RESOLVE_RESULT:-true}" \
    GH_VERIFY_RESULT="${GH_VERIFY_RESULT:-true}" \
    GH_FAIL_GRAPHQL_TIMES="${GH_FAIL_GRAPHQL_TIMES:-0}" \
    bash "$SCRIPT" "$@"
}

BODY_FILE="$TEST_DIR/reply.md"
printf 'Fixed by hardening the check.\n' >"$BODY_FILE"

echo "==> Case 1: happy path replies, resolves, verifies"
OUT="$TEST_DIR/case1.out"
RC=0
GH_THREADS_OUTPUT="THREAD_NODE_1" run_respond 77 --comment-id 9001 --body-file "$BODY_FILE" >"$OUT" 2>&1 || RC=$?
if [ "$RC" = 0 ] \
  && grep -q 'reply id: 5555' "$OUT" \
  && grep -q 'Replied and resolved' "$OUT" \
  && grep -q 'resolveReviewThread' "$GH_LOG"; then
  echo "    PASS"
else
  fail_case "case 1 rc=$RC"
  cat "$OUT" >&2
fi

echo "==> Case 2: --fix-commit appends the trailer to the reply"
OUT="$TEST_DIR/case2.out"
RC=0
GH_THREADS_OUTPUT="THREAD_NODE_1" run_respond 77 --comment-id 9001 --body-file "$BODY_FILE" --fix-commit abc1234 >"$OUT" 2>&1 || RC=$?
if [ "$RC" = 0 ] && grep -q 'Fixed in abc1234' "$GH_LOG"; then
  echo "    PASS"
else
  fail_case "case 2 rc=$RC (trailer missing from reply payload)"
  cat "$OUT" >&2
fi

echo "==> Case 3: verification failure exits nonzero"
OUT="$TEST_DIR/case3.out"
RC=0
GH_THREADS_OUTPUT="THREAD_NODE_1" GH_VERIFY_RESULT=false \
  run_respond 77 --comment-id 9001 --body-file "$BODY_FILE" >"$OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ] && grep -q 'still unresolved after the mutation' "$OUT"; then
  echo "    PASS"
else
  fail_case "case 3 rc=$RC"
  cat "$OUT" >&2
fi

echo "==> Case 4: transient GraphQL failures retry then succeed"
OUT="$TEST_DIR/case4.out"
RC=0
GH_THREADS_OUTPUT="THREAD_NODE_1" GH_FAIL_GRAPHQL_TIMES=1 \
  run_respond 77 --comment-id 9001 --body-file "$BODY_FILE" >"$OUT" 2>&1 || RC=$?
if [ "$RC" = 0 ] && grep -q 'retrying in' "$OUT"; then
  echo "    PASS"
else
  fail_case "case 4 rc=$RC"
  cat "$OUT" >&2
fi

echo "==> Case 5: --all-resolved-check gates on open threads"
OUT="$TEST_DIR/case5-clean.out"
RC=0
GH_THREADS_OUTPUT="" run_respond 77 --all-resolved-check >"$OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ]; then
  fail_case "case 5 clean rc=$RC"
  cat "$OUT" >&2
fi
OUT="$TEST_DIR/case5-dirty.out"
RC=0
GH_THREADS_OUTPUT="$(printf 'THREAD_NODE_2\t9002\tscripts/foo.sh')" \
  run_respond 77 --all-resolved-check >"$OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ] && grep -q 'comment 9002 (scripts/foo.sh)' "$OUT"; then
  echo "    PASS"
else
  fail_case "case 5 dirty rc=$RC"
  cat "$OUT" >&2
fi

echo "==> Case 6: unknown comment id fails before any mutation"
OUT="$TEST_DIR/case6.out"
RC=0
GH_THREADS_OUTPUT="" run_respond 77 --comment-id 9001 --body-file "$BODY_FILE" >"$OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ] \
  && grep -q 'no review thread found' "$OUT" \
  && ! grep -q 'resolveReviewThread' "$GH_LOG"; then
  echo "    PASS"
else
  fail_case "case 6 rc=$RC"
  cat "$OUT" >&2
fi

if [ "$ERRORS" != 0 ]; then
  echo "==> FAIL: $ERRORS respond-review case(s) regressed" >&2
  exit 1
fi
echo "==> PASS: respond-review one-command contract holds"
