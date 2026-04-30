#!/usr/bin/env bash
#
# tests/test-merge-pr.sh — verify merge-pr.sh and reviewer-bypass behavior.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-merge-pr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
MERGE_SCRIPT_DIR="$TEST_DIR/scripts"
GIT_PATH_ROOT="$TEST_DIR/git-path"
mkdir -p "$FAKE_BIN" "$MERGE_SCRIPT_DIR" "$GIT_PATH_ROOT"
cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$MERGE_SCRIPT_DIR/merge-pr.sh"
cat > "$MERGE_SCRIPT_DIR/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'CODEX_REVIEW_BASE=%s\n' "${CODEX_REVIEW_BASE:-}"
  printf 'CODEX_REVIEW_FORCE=%s\n' "${CODEX_REVIEW_FORCE:-}"
  printf 'CODEX_REVIEW_MODE=%s\n' "${CODEX_REVIEW_MODE:-}"
  printf 'CODEX_REVIEW_BRANCH_NAME=%s\n' "${CODEX_REVIEW_BRANCH_NAME:-}"
} > "$CODEX_REVIEW_LOG"
EOF
chmod +x "$MERGE_SCRIPT_DIR/merge-pr.sh" "$MERGE_SCRIPT_DIR/codex-review.sh"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "repo view")
    echo "main"
    ;;
  "pr view")
    case "${5:-}" in
      state) echo "OPEN" ;;
      headRefName) echo "feature/test" ;;
      headRefOid) echo "pr-head-oid" ;;
      mergeStateStatus,mergeable) echo "CLEAN MERGEABLE" ;;
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
    if [ "${4:-}" != "--body" ]; then
      echo "unexpected gh pr comment args: $*" >&2
      exit 1
    fi
    printf '%s\n' "${5:-}" > "$GH_COMMENT_FILE"
    echo "commented"
    ;;
  "pr merge")
    printf '%s\n' "$*" > "$GH_MERGE_ARGS_FILE"
    if [ "${4:-} ${5:-} ${6:-} ${7:-}" != "--squash --delete-branch --match-head-commit pr-head-oid" ]; then
      echo "unexpected gh pr merge args: $*" >&2
      exit 1
    fi
    if [ "${8:-}" = "--body" ]; then
      printf '%s\n' "${9:-}" > "$GH_MERGE_BODY_FILE"
    fi
    echo "$7" > "$GH_MERGE_HEAD_FILE"
    echo "merged"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-C" ]; then
  if [ "${3:-} ${4:-}" != "pull --ff-only" ]; then
    echo "unexpected git -C args: $*" >&2
    exit 1
  fi
  printf '%s\n' "$2" > "$GIT_SIBLING_PULL_FILE"
  if [ "${GIT_SIBLING_PULL_FAIL:-false}" = "true" ]; then
    echo "sibling pull failed" >&2
    exit 1
  fi
  echo "Already up to date."
  exit 0
fi

case "$*" in
  "rev-parse --abbrev-ref HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "HEAD"
    else
      echo "feature/test"
    fi
    ;;
  "rev-parse HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "pr-head-oid"
    else
      echo "stale-local-oid"
    fi
    ;;
  "rev-parse --git-path touchstone/reviewer-clean")
    printf '%s\n' "$GIT_PATH_ROOT/touchstone/reviewer-clean"
    ;;
  "rev-parse --show-toplevel")
    printf '%s\n' "${TEST_CURRENT_WORKTREE:-/tmp/touchstone-feature-worktree}"
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
    printf '%s' "${GIT_WORKTREE_LIST:-}"
    ;;
  "checkout main")
    echo "checkout main" > "$GIT_CHECKOUT_MAIN_FILE"
    echo "Switched to branch 'main'"
    ;;
  "pull --rebase")
    echo "Already up to date."
    ;;
  *)
    echo "unexpected git args: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/git"

reset_case_files() {
  rm -f "$TEST_DIR"/output*.txt "$TEST_DIR"/codex-review*.log \
    "$TEST_DIR"/gh-checkout* "$TEST_DIR"/gh-merge-head* \
    "$TEST_DIR"/gh-merge-args* "$TEST_DIR"/gh-merge-body* \
    "$TEST_DIR"/gh-comment* "$TEST_DIR"/git-checkout-main* \
    "$TEST_DIR"/git-sibling-pull*
  rm -rf "$GIT_PATH_ROOT"
  mkdir -p "$GIT_PATH_ROOT"
  unset GIT_WORKTREE_LIST
  unset GIT_SIBLING_PULL_FAIL
  unset TEST_CURRENT_WORKTREE
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
    GH_MERGE_BODY_FILE="$TEST_DIR/gh-merge-body" \
    GH_COMMENT_FILE="$TEST_DIR/gh-comment" \
    GIT_CHECKOUT_MAIN_FILE="$TEST_DIR/git-checkout-main" \
    GIT_SIBLING_PULL_FILE="$TEST_DIR/git-sibling-pull" \
    GIT_WORKTREE_LIST="${GIT_WORKTREE_LIST:-}" \
    GIT_SIBLING_PULL_FAIL="${GIT_SIBLING_PULL_FAIL:-false}" \
    TEST_CURRENT_WORKTREE="${TEST_CURRENT_WORKTREE:-/tmp/touchstone-feature-worktree}" \
    bash "$MERGE_SCRIPT_DIR/merge-pr.sh" "$@" >"$output_file" 2>&1
}

echo "==> Test: merge script works without jq in PATH"
reset_case_files
run_merge_pr "$TEST_DIR/output-normal.txt" 123
if grep -q 'attempt 1: mergeStateStatus=CLEAN mergeable=MERGEABLE' "$TEST_DIR/output-normal.txt" \
  && grep -q '==> Refreshing origin/main for merge review' "$TEST_DIR/output-normal.txt" \
  && grep -q '==> Checking out PR #123 head (feature/test) for merge review' "$TEST_DIR/output-normal.txt" \
  && grep -q '==> Running merge review' "$TEST_DIR/output-normal.txt" \
  && grep -q '==> Done\.' "$TEST_DIR/output-normal.txt" \
  && grep -q '^checked-out$' "$TEST_DIR/gh-checkout" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && grep -q '^CODEX_REVIEW_BASE=origin/main$' "$TEST_DIR/codex-review.log" \
  && grep -q '^CODEX_REVIEW_FORCE=1$' "$TEST_DIR/codex-review.log" \
  && grep -q '^CODEX_REVIEW_MODE=review-only$' "$TEST_DIR/codex-review.log" \
  && grep -q '^CODEX_REVIEW_BRANCH_NAME=feature/test$' "$TEST_DIR/codex-review.log"; then
  echo "==> PASS: merge-pr.sh completed without jq"
else
  echo "FAIL: merge-pr.sh output did not show a successful jq-free merge path" >&2
  cat "$TEST_DIR/output-normal.txt" >&2
  exit 1
fi

echo "==> Test: sibling worktree owning main is fast-forwarded without false merge failure"
reset_case_files
TEST_CURRENT_WORKTREE="/tmp/touchstone-feature-worktree"
GIT_WORKTREE_LIST="$(cat <<'EOF'
worktree /tmp/touchstone-main-worktree
HEAD main-oid
branch refs/heads/main

worktree /tmp/touchstone-feature-worktree
HEAD feature-oid
branch refs/heads/feature/test

EOF
)"
run_merge_pr "$TEST_DIR/output-sibling-worktree.txt" 123
if grep -q '==> main is checked out in sibling worktree: /tmp/touchstone-main-worktree' "$TEST_DIR/output-sibling-worktree.txt" \
  && grep -q '==> Fast-forwarding that worktree after remote merge' "$TEST_DIR/output-sibling-worktree.txt" \
  && grep -q '==> Done\.' "$TEST_DIR/output-sibling-worktree.txt" \
  && grep -q '^/tmp/touchstone-main-worktree$' "$TEST_DIR/git-sibling-pull" \
  && [ ! -f "$TEST_DIR/git-checkout-main" ] \
  && ! grep -q 'ERROR:' "$TEST_DIR/output-sibling-worktree.txt"; then
  echo "==> PASS: sibling default worktree sync avoids false merge failure"
else
  echo "FAIL: sibling worktree sync did not avoid the checkout-main failure path" >&2
  cat "$TEST_DIR/output-sibling-worktree.txt" >&2
  exit 1
fi

echo "==> Test: bypass without reason is rejected before merge"
reset_case_files
if run_merge_pr "$TEST_DIR/output-no-reason.txt" 123 --bypass-with-disclosure; then
  echo "FAIL: bypass without reason unexpectedly succeeded" >&2
  exit 1
fi
if grep -q 'requires a non-empty reason' "$TEST_DIR/output-no-reason.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ]; then
  echo "==> PASS: missing bypass reason rejected"
else
  echo "FAIL: missing bypass reason did not fail safely" >&2
  cat "$TEST_DIR/output-no-reason.txt" >&2
  exit 1
fi

echo "==> Test: bypass on fresh branch is rejected"
reset_case_files
if run_merge_pr "$TEST_DIR/output-fresh.txt" 123 --bypass-with-disclosure="reviewer timed out"; then
  echo "FAIL: bypass on fresh branch unexpectedly succeeded" >&2
  exit 1
fi
if grep -q "No prior clean review marker matches branch 'feature/test' at head 'pr-head-oid' and merge base 'base-oid'" "$TEST_DIR/output-fresh.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ] \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: fresh-branch bypass rejected"
else
  echo "FAIL: fresh-branch bypass did not fail safely" >&2
  cat "$TEST_DIR/output-fresh.txt" >&2
  exit 1
fi

echo "==> Test: bypass after clean marker records disclosure and trailer"
reset_case_files
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=base-oid\n' > "$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
run_merge_pr "$TEST_DIR/output-bypass.txt" 123 --bypass-with-disclosure="reviewer timed out after prior clean review"
if grep -q 'BYPASSING REVIEWER GATE' "$TEST_DIR/output-bypass.txt" \
  && grep -q 'reason: reviewer timed out after prior clean review' "$TEST_DIR/output-bypass.txt" \
  && grep -q 'Reviewer bypassed via `--bypass-with-disclosure`. Reason: reviewer timed out after prior clean review' "$TEST_DIR/gh-comment" \
  && grep -q '^Reviewer-bypass: reviewer timed out after prior clean review$' "$TEST_DIR/gh-merge-body" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: bypass is disclosed and merged with trailer"
else
  echo "FAIL: bypass path did not disclose and merge as expected" >&2
  cat "$TEST_DIR/output-bypass.txt" >&2
  exit 1
fi

echo "==> Test: stale clean marker is rejected"
reset_case_files
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=old-head\n' > "$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
if run_merge_pr "$TEST_DIR/output-stale.txt" 123 --bypass-with-disclosure="reviewer timed out"; then
  echo "FAIL: bypass with stale marker unexpectedly succeeded" >&2
  exit 1
fi
if grep -q "No prior clean review marker matches branch 'feature/test' at head 'pr-head-oid' and merge base 'base-oid'" "$TEST_DIR/output-stale.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ]; then
  echo "==> PASS: stale clean marker rejected"
else
  echo "FAIL: stale marker did not fail safely" >&2
  cat "$TEST_DIR/output-stale.txt" >&2
  exit 1
fi

echo "==> Test: old-base clean marker is rejected"
reset_case_files
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=old-base\n' > "$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
if run_merge_pr "$TEST_DIR/output-old-base.txt" 123 --bypass-with-disclosure="reviewer timed out"; then
  echo "FAIL: bypass with old-base marker unexpectedly succeeded" >&2
  exit 1
fi
if grep -q "No prior clean review marker matches branch 'feature/test' at head 'pr-head-oid' and merge base 'base-oid'" "$TEST_DIR/output-old-base.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ]; then
  echo "==> PASS: old-base clean marker rejected"
  exit 0
fi

echo "FAIL: old-base marker did not fail safely" >&2
cat "$TEST_DIR/output-old-base.txt" >&2
exit 1
