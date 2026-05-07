#!/usr/bin/env bash
#
# tests/test-merge-pr-merge-state-retry.sh — verify merge-pr.sh waits through
# transient UNKNOWN mergeability while fast-failing definite conflict states.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-merge-pr-retry.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
MERGE_SCRIPT_DIR="$TEST_DIR/scripts"
GIT_PATH_ROOT="$TEST_DIR/git-path"
mkdir -p "$FAKE_BIN" "$MERGE_SCRIPT_DIR" "$GIT_PATH_ROOT"
cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$MERGE_SCRIPT_DIR/merge-pr.sh"
cat >"$MERGE_SCRIPT_DIR/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'CODEX_REVIEW_BASE=%s\n' "${CODEX_REVIEW_BASE:-}"
  printf 'CODEX_REVIEW_FORCE=%s\n' "${CODEX_REVIEW_FORCE:-}"
  printf 'CODEX_REVIEW_MODE=%s\n' "${CODEX_REVIEW_MODE:-}"
  printf 'CODEX_REVIEW_BRANCH_NAME=%s\n' "${CODEX_REVIEW_BRANCH_NAME:-}"
} > "$CODEX_REVIEW_LOG"
exit 0
EOF
chmod +x "$MERGE_SCRIPT_DIR/merge-pr.sh" "$MERGE_SCRIPT_DIR/codex-review.sh"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "repo view")
    echo "main"
    ;;
  "pr view")
    case "${5:-}" in
      state)
        if [ -f "${GH_MERGED_MARKER:-/dev/null/never}" ]; then
          echo "MERGED"
        else
          echo "OPEN"
        fi
        ;;
      headRefName) echo "feature/test" ;;
      headRefOid) echo "pr-head-oid" ;;
      mergeStateStatus,mergeable)
        attempt="$(cat "$GH_MERGE_ATTEMPTS_FILE" 2>/dev/null || echo 0)"
        attempt="$((attempt + 1))"
        printf '%s\n' "$attempt" > "$GH_MERGE_ATTEMPTS_FILE"
        if [ -n "${GH_MERGE_STATE_IMMEDIATE:-}" ]; then
          echo "$GH_MERGE_STATE_IMMEDIATE"
        elif [ "$attempt" -le "${GH_MERGE_STATE_UNKNOWN_ATTEMPTS:-0}" ]; then
          echo "UNKNOWN UNKNOWN"
        else
          echo "CLEAN MERGEABLE"
        fi
        ;;
      *)
        echo "unexpected gh pr view args: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "pr checkout")
    if [ "${4:-}" != "--detach" ]; then
      echo "unexpected gh pr checkout args: $*" >&2
      exit 1
    fi
    echo "checked-out" > "$GH_CHECKOUT_FILE"
    echo "checked out PR $3"
    ;;
  "pr comment")
    printf '%s\n' "${5:-}" > "$GH_COMMENT_FILE"
    echo "commented"
    ;;
  "pr merge")
    printf '%s\n' "$*" > "$GH_MERGE_ARGS_FILE"
    echo "$7" > "$GH_MERGE_HEAD_FILE"
    if [ -n "${GH_MERGED_MARKER:-}" ]; then
      touch "$GH_MERGED_MARKER"
    fi
    echo "merged"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "rev-parse --abbrev-ref HEAD")
    if [ -f "$GIT_CHECKOUT_MAIN_FILE" ]; then
      echo "main"
    elif [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "HEAD"
    else
      echo "feature/test"
    fi
    ;;
  "rev-parse HEAD")
    if [ -f "$GIT_CHECKOUT_MAIN_FILE" ]; then
      echo "main-oid"
    elif [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "pr-head-oid"
    else
      echo "stale-local-oid"
    fi
    ;;
  "rev-parse --git-path touchstone/reviewer-clean")
    printf '%s\n' "$GIT_PATH_ROOT/touchstone/reviewer-clean"
    ;;
  "rev-parse --show-toplevel")
    printf '%s\n' "/tmp/touchstone-feature-worktree"
    ;;
  "rev-parse feature/test")
    if [ -f "$GIT_BRANCH_DELETED_FILE" ]; then
      exit 1
    fi
    printf 'pr-head-oid\n'
    ;;
  "show-ref --verify --quiet refs/heads/feature/test")
    if [ -f "$GIT_BRANCH_DELETED_FILE" ]; then
      exit 1
    fi
    ;;
  "cat-file -e pr-head-oid^{commit}")
    ;;
  "merge-base origin/main pr-head-oid")
    echo "base-oid"
    ;;
  "fetch origin +refs/heads/main:refs/remotes/origin/main")
    echo "fetched main"
    ;;
  "rev-parse --verify --quiet origin/main^{commit}")
    echo "base-oid"
    ;;
  "status --porcelain")
    ;;
  "worktree list --porcelain")
    ;;
  "checkout main")
    echo "checkout main" > "$GIT_CHECKOUT_MAIN_FILE"
    echo "Switched to branch 'main'"
    ;;
  "checkout --detach main")
    echo "HEAD is now at main"
    ;;
  "pull --rebase")
    echo "Already up to date."
    ;;
  "branch -D feature/test")
    echo "deleted feature/test" > "$GIT_BRANCH_DELETED_FILE"
    echo "Deleted branch feature/test (was pr-head-oid)."
    ;;
  *)
    echo "unexpected git args: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/git"

reset_case_files() {
  rm -f "$TEST_DIR"/output*.txt "$TEST_DIR"/codex-review.log \
    "$TEST_DIR"/gh-checkout "$TEST_DIR"/gh-merge-head \
    "$TEST_DIR"/gh-merge-args "$TEST_DIR"/gh-comment \
    "$TEST_DIR"/gh-merged-marker "$TEST_DIR"/merge-attempts \
    "$TEST_DIR"/git-checkout-main "$TEST_DIR"/git-branch-deleted
  rm -rf "$GIT_PATH_ROOT"
  mkdir -p "$GIT_PATH_ROOT"
  unset GH_MERGE_STATE_UNKNOWN_ATTEMPTS
  unset GH_MERGE_STATE_IMMEDIATE
}

run_merge_pr() {
  local output_file="$1"
  shift
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GIT_PATH_ROOT="$GIT_PATH_ROOT" \
    CODEX_REVIEW_LOG="$TEST_DIR/codex-review.log" \
    GH_CHECKOUT_FILE="$TEST_DIR/gh-checkout" \
    GH_MERGE_HEAD_FILE="$TEST_DIR/gh-merge-head" \
    GH_MERGE_ARGS_FILE="$TEST_DIR/gh-merge-args" \
    GH_COMMENT_FILE="$TEST_DIR/gh-comment" \
    GH_MERGED_MARKER="$TEST_DIR/gh-merged-marker" \
    GH_MERGE_ATTEMPTS_FILE="$TEST_DIR/merge-attempts" \
    GH_MERGE_STATE_UNKNOWN_ATTEMPTS="${GH_MERGE_STATE_UNKNOWN_ATTEMPTS:-0}" \
    GH_MERGE_STATE_IMMEDIATE="${GH_MERGE_STATE_IMMEDIATE:-}" \
    GIT_CHECKOUT_MAIN_FILE="$TEST_DIR/git-checkout-main" \
    GIT_BRANCH_DELETED_FILE="$TEST_DIR/git-branch-deleted" \
    MERGE_PR_SLEEP_OVERRIDE=0 \
    bash "$MERGE_SCRIPT_DIR/merge-pr.sh" "$@" >"$output_file" 2>&1
}

echo "==> Test: transient UNKNOWN merge state retries past five attempts"
reset_case_files
GH_MERGE_STATE_UNKNOWN_ATTEMPTS=6 run_merge_pr "$TEST_DIR/output-unknown-then-clean.txt" 123
attempt_count="$(grep -c 'attempt [0-9][0-9]*: mergeStateStatus=' "$TEST_DIR/output-unknown-then-clean.txt")"
if [ "$attempt_count" -eq 7 ] \
  && grep -q 'attempt 6: mergeStateStatus=UNKNOWN mergeable=UNKNOWN' "$TEST_DIR/output-unknown-then-clean.txt" \
  && grep -q 'attempt 7: mergeStateStatus=CLEAN mergeable=MERGEABLE' "$TEST_DIR/output-unknown-then-clean.txt" \
  && grep -q '==> Done\.' "$TEST_DIR/output-unknown-then-clean.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: UNKNOWN state uses the expanded retry budget and then merges"
else
  echo "FAIL: UNKNOWN state did not retry past the old five-attempt budget" >&2
  cat "$TEST_DIR/output-unknown-then-clean.txt" >&2
  exit 1
fi

echo "==> Test: definite conflict refuses fast"
reset_case_files
if GH_MERGE_STATE_IMMEDIATE="DIRTY CONFLICTING" run_merge_pr "$TEST_DIR/output-conflict.txt" 123; then
  echo "FAIL: conflicting PR unexpectedly merged" >&2
  cat "$TEST_DIR/output-conflict.txt" >&2
  exit 1
fi
attempt_count="$(grep -c 'attempt [0-9][0-9]*: mergeStateStatus=' "$TEST_DIR/output-conflict.txt")"
if [ "$attempt_count" -eq 1 ] \
  && grep -q 'attempt 1: mergeStateStatus=DIRTY mergeable=CONFLICTING' "$TEST_DIR/output-conflict.txt" \
  && grep -q 'Final merge state: mergeStateStatus=DIRTY mergeable=CONFLICTING' "$TEST_DIR/output-conflict.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: definite conflict refused without burning retry budget"
else
  echo "FAIL: conflicting PR did not refuse fast with final merge-state context" >&2
  cat "$TEST_DIR/output-conflict.txt" >&2
  exit 1
fi

echo "==> ALL PASS"
