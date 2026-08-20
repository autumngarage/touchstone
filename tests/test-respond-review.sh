#!/usr/bin/env bash
#
# tests/test-respond-review.sh — respond-review.sh parses GitHub response
# data from stdout alone; diagnostics a successful gh call writes to stderr
# never become an author login, a reply id, or a thread id (AUT-294).
#
# With the streams merged, a debug line ahead of the login made the
# idempotency author check fail, so a rerun posted a duplicate reply; the
# same line ahead of `.id` was echoed to the operator as the reply id.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-respond-review.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"
cat >"$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Every successful call writes a diagnostic to stderr first, as gh does
# under GH_DEBUG or when warning about a deprecated flag.
echo "gh: debug detail for $*" >&2
[ "${GH_MODE:-ok}" = fail_user ] && [[ "$*" == *"api user"* ]] && {
  echo "gh: HTTP 401 bad credentials" >&2
  exit 1
}
has() { local needle="$1"; shift; for arg in "$@"; do [[ "$arg" == *"$needle"* ]] && return 0; done; return 1; }
case "$1 $2" in
  "repo view")
    echo "autumngarage/current"
    ;;
  "api user")
    echo "alice"
    ;;
  "api graphql")
    if has resolveReviewThread "$@"; then
      touch "$GH_STATE/resolved"
      echo "true"
    elif has "node(id:" "$@"; then
      echo "true"
    elif [ -f "$GH_STATE/resolved" ]; then
      # Thread lookup after resolution: by first-comment id only.
      has 'databaseId == 51' "$@" && echo "THREAD_51"
    else
      has 'databaseId == 51' "$@" && echo "THREAD_51"
      has 'isResolved == false' "$@" && printf 'THREAD_51\t51\tscripts/x.sh\n'
    fi
    ;;
  "api repos/autumngarage/current/pulls/7/comments/51/replies")
    echo 1 >>"$GH_STATE/replies"
    echo "71"
    ;;
  "api --paginate")
    if [ -f "$GH_STATE/replies" ]; then
      echo "<!-- touchstone:respond-review comment=51 -->"
    fi
    ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP_DIR/bin/gh"
export PATH="$TMP_DIR/bin:$PATH" GH_STATE="$TMP_DIR/state"

printf 'Fixed.\n' >"$TMP_DIR/body"
run() {
  set +e
  bash "$REPO_ROOT/scripts/respond-review.sh" "$@" >"$TMP_DIR/out" 2>&1
  RUN_RC=$?
  set -e
}

echo "==> a reply is posted once and the id is parsed from stdout alone"
run 7 --comment-id 51 --body-file "$TMP_DIR/body"
[ "$RUN_RC" -eq 0 ] || {
  fail "first run exited $RUN_RC"
  cat "$TMP_DIR/out"
}
grep -qF 'reply id: 71' "$TMP_DIR/out" && pass "reply id carries no diagnostic text" \
  || fail "reply id was not parsed from stdout alone: $(grep 'reply id' "$TMP_DIR/out")"
[ -f "$GH_STATE/resolved" ] && pass "thread resolved" || fail "thread was not resolved"

echo "==> a rerun recognises its own reply despite stderr noise on the login read"
run 7 --comment-id 51 --body-file "$TMP_DIR/body"
[ "$RUN_RC" -eq 0 ] || fail "rerun exited $RUN_RC"
replies="$(wc -l <"$GH_STATE/replies" | tr -d ' ')"
[ "$replies" -eq 1 ] && pass "no duplicate reply posted" \
  || fail "rerun posted a duplicate reply (replies=$replies): author check read stderr"
grep -qF 'matched our own reply as @alice' "$TMP_DIR/out" && pass "author parsed as alice" \
  || fail "author was not parsed cleanly: $(grep 'matched' "$TMP_DIR/out")"

echo "==> --all-resolved-check reads the thread list from stdout alone"
run 7 --all-resolved-check
[ "$RUN_RC" -eq 0 ] && pass "resolved PR passes the check" || {
  fail "all-resolved-check exited $RUN_RC"
  cat "$TMP_DIR/out"
}

echo "==> a failed read still surfaces its diagnostics"
GH_MODE=fail_user run 7 --comment-id 51 --body-file "$TMP_DIR/body"
[ "$RUN_RC" -eq 1 ] || fail "failed login read exited $RUN_RC, expected 1"
grep -qF 'bad credentials' "$TMP_DIR/out" && pass "failure keeps the stderr detail" \
  || fail "failure diagnostic was dropped"

echo "==> no production script captures a gh response with stderr merged in"
# The guardrail for the class: a \$(gh ... 2>&1) capture parses diagnostics
# as data. Successful reads take stdout alone; failure detail is gathered
# separately (gh_read here, capture_command in touchstone-pr.sh).
merged="$(grep -nE '\$\(\s*gh\b[^)]*2>&1' "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/bin/* || true)"
[ -z "$merged" ] && pass "no merged-stream gh capture in scripts/ or bin/" \
  || fail "merged-stream gh capture found:
$merged"

[ "$FAILURES" -eq 0 ] || {
  echo "$FAILURES failure(s)" >&2
  exit 1
}
echo "test-respond-review: all checks passed"
