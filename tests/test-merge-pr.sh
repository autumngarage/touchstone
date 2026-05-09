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
cat >"$MERGE_SCRIPT_DIR/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'CODEX_REVIEW_BASE=%s\n' "${CODEX_REVIEW_BASE:-}"
  printf 'CODEX_REVIEW_FORCE=%s\n' "${CODEX_REVIEW_FORCE:-}"
  printf 'CODEX_REVIEW_MODE=%s\n' "${CODEX_REVIEW_MODE:-}"
  printf 'CODEX_REVIEW_ON_ERROR=%s\n' "${CODEX_REVIEW_ON_ERROR:-}"
  printf 'CODEX_REVIEW_BRANCH_NAME=%s\n' "${CODEX_REVIEW_BRANCH_NAME:-}"
  printf 'TOUCHSTONE_CONDUCTOR_WITH=%s\n' "${TOUCHSTONE_CONDUCTOR_WITH:-}"
} > "$CODEX_REVIEW_LOG"
if [ -n "${CODEX_REVIEW_STUB_OUTPUT:-}" ]; then
  printf '%s\n' "$CODEX_REVIEW_STUB_OUTPUT"
fi
exit "${CODEX_REVIEW_EXIT:-0}"
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
      mergeStateStatus,mergeable) echo "${GH_MERGE_STATE:-CLEAN MERGEABLE}" ;;
      *)
        echo "unexpected gh pr view args: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "pr checks")
    if [ -n "${GH_FAILED_CHECKS:-}" ]; then
      printf '%s\n' "$GH_FAILED_CHECKS"
    else
      echo "no failed checks reported on the branch" >&2
      exit 1
    fi
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
    if [ -n "${GH_MERGED_MARKER:-}" ]; then
      touch "$GH_MERGED_MARKER"
    fi
    if [ "${GH_PR_MERGE_FAIL_LOCAL:-false}" = "true" ]; then
      echo "failed to delete local branch feature/test: failed to run git: error: cannot delete branch 'feature/test' used by worktree at '/tmp/touchstone-feature-worktree'" >&2
      exit 1
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
    if [ -f "$GIT_CHECKOUT_MAIN_FILE" ]; then
      echo "main"
    elif [ -f "$GIT_DETACHED_DEFAULT_FILE" ]; then
      echo "HEAD"
    elif [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "HEAD"
    else
      echo "feature/test"
    fi
    ;;
  "rev-parse HEAD")
    if [ -f "$GIT_CHECKOUT_MAIN_FILE" ]; then
      echo "main-oid"
    elif [ -f "$GIT_DETACHED_DEFAULT_FILE" ]; then
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
    printf '%s\n' "${TEST_CURRENT_WORKTREE:-/tmp/touchstone-feature-worktree}"
    ;;
  "rev-parse feature/test")
    if [ -f "$GIT_BRANCH_DELETED_FILE" ]; then
      exit 1
    fi
    printf '%s\n' "${GIT_LOCAL_BRANCH_HEAD:-pr-head-oid}"
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
    printf '%s' "${GIT_WORKTREE_LIST:-}"
    ;;
  "checkout main")
    echo "checkout main" > "$GIT_CHECKOUT_MAIN_FILE"
    echo "Switched to branch 'main'"
    ;;
  "checkout --detach main")
    echo "checkout --detach main" > "$GIT_DETACHED_DEFAULT_FILE"
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
  rm -f "$TEST_DIR"/output*.txt "$TEST_DIR"/codex-review*.log \
    "$TEST_DIR"/gh-checkout* "$TEST_DIR"/gh-merge-head* \
    "$TEST_DIR"/gh-merge-args* "$TEST_DIR"/gh-merge-body* \
    "$TEST_DIR"/gh-comment* "$TEST_DIR"/git-checkout-main* \
    "$TEST_DIR"/git-detached-default* "$TEST_DIR"/git-branch-deleted* \
    "$TEST_DIR"/git-sibling-pull* "$TEST_DIR"/gh-merged-marker*
  rm -rf "$GIT_PATH_ROOT"
  mkdir -p "$GIT_PATH_ROOT"
  unset GIT_WORKTREE_LIST
  unset GIT_SIBLING_PULL_FAIL
  unset TEST_CURRENT_WORKTREE
  unset GH_PR_MERGE_FAIL_LOCAL
  unset GH_MERGE_STATE
  unset GH_FAILED_CHECKS
  unset CODEX_REVIEW_EXIT
  unset CODEX_REVIEW_STUB_OUTPUT
  unset GIT_LOCAL_BRANCH_HEAD
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
    GH_MERGED_MARKER="$TEST_DIR/gh-merged-marker" \
    GH_PR_MERGE_FAIL_LOCAL="${GH_PR_MERGE_FAIL_LOCAL:-false}" \
    GH_MERGE_STATE="${GH_MERGE_STATE:-CLEAN MERGEABLE}" \
    GH_FAILED_CHECKS="${GH_FAILED_CHECKS:-}" \
    GIT_CHECKOUT_MAIN_FILE="$TEST_DIR/git-checkout-main" \
    GIT_DETACHED_DEFAULT_FILE="$TEST_DIR/git-detached-default" \
    GIT_BRANCH_DELETED_FILE="$TEST_DIR/git-branch-deleted" \
    GIT_SIBLING_PULL_FILE="$TEST_DIR/git-sibling-pull" \
    GIT_WORKTREE_LIST="${GIT_WORKTREE_LIST:-}" \
    GIT_SIBLING_PULL_FAIL="${GIT_SIBLING_PULL_FAIL:-false}" \
    CODEX_REVIEW_EXIT="${CODEX_REVIEW_EXIT:-0}" \
    CODEX_REVIEW_STUB_OUTPUT="${CODEX_REVIEW_STUB_OUTPUT:-}" \
    GIT_LOCAL_BRANCH_HEAD="${GIT_LOCAL_BRANCH_HEAD:-pr-head-oid}" \
    TEST_CURRENT_WORKTREE="${TEST_CURRENT_WORKTREE:-/tmp/touchstone-feature-worktree}" \
    bash "$MERGE_SCRIPT_DIR/merge-pr.sh" "$@" >"$output_file" 2>&1
}

echo "==> Test: merge preflight sanitizes reviewer routing env"
mkdir -p "$TEST_DIR/lib"
cat >"$TEST_DIR/lib/preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

touchstone_preflight_main() {
  {
    printf 'TOUCHSTONE_CONDUCTOR_WITH=%s\n' "${TOUCHSTONE_CONDUCTOR_WITH:-}"
    printf 'TOUCHSTONE_CONDUCTOR_EFFORT=%s\n' "${TOUCHSTONE_CONDUCTOR_EFFORT:-}"
    printf 'CODEX_REVIEW_MODE=%s\n' "${CODEX_REVIEW_MODE:-}"
    printf 'CODEX_REVIEW_TIMEOUT=%s\n' "${CODEX_REVIEW_TIMEOUT:-}"
  } >"$PREFLIGHT_ENV_LOG"
}

touchstone_preflight_main_sanitized() {
  (
    unset TOUCHSTONE_CONDUCTOR_WITH
    unset TOUCHSTONE_CONDUCTOR_EFFORT
    unset CODEX_REVIEW_MODE
    unset CODEX_REVIEW_TIMEOUT
    touchstone_preflight_main "$@"
  )
}
EOF
reset_case_files
(
  export PREFLIGHT_ENV_LOG="$TEST_DIR/preflight-env.log"
  export TOUCHSTONE_CONDUCTOR_WITH="deepseek-reasoner"
  export TOUCHSTONE_CONDUCTOR_EFFORT="high"
  export CODEX_REVIEW_MODE="diff-only"
  export CODEX_REVIEW_TIMEOUT="7"
  run_merge_pr "$TEST_DIR/output-preflight-env.txt" 123
)
rm -rf "${TEST_DIR:?}/lib"
if grep -q '^TOUCHSTONE_CONDUCTOR_WITH=$' "$TEST_DIR/preflight-env.log" \
  && grep -q '^TOUCHSTONE_CONDUCTOR_EFFORT=$' "$TEST_DIR/preflight-env.log" \
  && grep -q '^CODEX_REVIEW_MODE=$' "$TEST_DIR/preflight-env.log" \
  && grep -q '^CODEX_REVIEW_TIMEOUT=$' "$TEST_DIR/preflight-env.log" \
  && grep -q '^TOUCHSTONE_CONDUCTOR_WITH=deepseek-reasoner$' "$TEST_DIR/codex-review.log"; then
  echo "==> PASS: merge preflight saw sanitized env while live review kept provider pin"
else
  echo "FAIL: merge preflight should not inherit reviewer routing env" >&2
  echo "--- preflight env ---" >&2
  cat "$TEST_DIR/preflight-env.log" >&2
  echo "--- review env ---" >&2
  cat "$TEST_DIR/codex-review.log" >&2
  echo "--- output ---" >&2
  cat "$TEST_DIR/output-preflight-env.txt" >&2
  exit 1
fi

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
  && grep -q '^CODEX_REVIEW_ON_ERROR=fail-closed$' "$TEST_DIR/codex-review.log" \
  && grep -q '^CODEX_REVIEW_BRANCH_NAME=feature/test$' "$TEST_DIR/codex-review.log" \
  && grep -q "==> Deleting local branch 'feature/test' after verified squash merge of pr-head-oid" "$TEST_DIR/output-normal.txt" \
  && grep -q '^deleted feature/test$' "$TEST_DIR/git-branch-deleted"; then
  echo "==> PASS: merge-pr.sh completed without jq"
else
  echo "FAIL: merge-pr.sh output did not show a successful jq-free merge path" >&2
  cat "$TEST_DIR/output-normal.txt" >&2
  exit 1
fi

echo "==> Test: blocked review preserves the local feature branch"
reset_case_files
if CODEX_REVIEW_EXIT=1 run_merge_pr "$TEST_DIR/output-review-blocked.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly succeeded when review blocked" >&2
  exit 1
fi
if grep -q '==> Running merge review' "$TEST_DIR/output-review-blocked.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/git-checkout-main" ] \
  && [ ! -f "$TEST_DIR/git-detached-default" ] \
  && [ ! -f "$TEST_DIR/git-branch-deleted" ]; then
  echo "==> PASS: blocked review leaves local branch intact"
else
  echo "FAIL: blocked review should not merge, sync, detach, or delete the branch" >&2
  cat "$TEST_DIR/output-review-blocked.txt" >&2
  exit 1
fi

echo "==> Test: failed checks stop merge polling before review"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS=$'Issue claim check\tFAILURE\thttps://example.test/checks/claim-check' \
  run_merge_pr "$TEST_DIR/output-check-failed.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly succeeded with a failed check" >&2
  exit 1
fi
if grep -q 'has failed check(s); stopping automerge' "$TEST_DIR/output-check-failed.txt" \
  && grep -q 'Issue claim check (FAILURE): https://example.test/checks/claim-check' "$TEST_DIR/output-check-failed.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: failed checks fail fast before review"
else
  echo "FAIL: failed checks should stop before review/merge" >&2
  cat "$TEST_DIR/output-check-failed.txt" >&2
  exit 1
fi

echo "==> Test: review infrastructure failure with prior clean marker fails closed"
reset_case_files
# Synthesize a clean review marker for the same head/base the harness's fake
# git resolves to (pr-head-oid + base-oid). The marker permits an explicit
# --bypass-with-disclosure path, but an unrequested merge-gate reviewer
# infrastructure failure must fail closed rather than auto-bypass.
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nbase=origin/main\nmerge_base=base-oid\nhead=pr-head-oid\n' \
  >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
if CODEX_REVIEW_EXIT=124 run_merge_pr "$TEST_DIR/output-auto-bypass.txt" 123; then
  echo "FAIL: merge-pr.sh auto-bypassed a merge-gate reviewer failure" >&2
  cat "$TEST_DIR/output-auto-bypass.txt" >&2
  exit 1
fi
if grep -q 'merge-gate review fails closed' "$TEST_DIR/output-auto-bypass.txt" \
  && grep -q 'Emergency bypass requires an explicit --bypass-with-disclosure reason' "$TEST_DIR/output-auto-bypass.txt" \
  && [ ! -f "$TEST_DIR/gh-comment" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && ! grep -q 'Auto-promoting to reviewer bypass' "$TEST_DIR/output-auto-bypass.txt"; then
  echo "==> PASS: review infrastructure failure with prior clean marker fails closed"
else
  echo "FAIL: merge-gate reviewer failure should require explicit bypass" >&2
  cat "$TEST_DIR/output-auto-bypass.txt" >&2
  exit 1
fi

echo "==> Test: prior clean marker does not bypass concrete review findings"
reset_case_files
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nbase=origin/main\nmerge_base=base-oid\nhead=pr-head-oid\n' \
  >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
if CODEX_REVIEW_EXIT=1 CODEX_REVIEW_STUB_OUTPUT=$'Conductor review found 1 finding(s)\n- blocking finding\nCODEX_REVIEW_BLOCKED' \
  run_merge_pr "$TEST_DIR/output-blocked-with-marker.txt" 123; then
  echo "FAIL: merge-pr.sh auto-bypassed concrete findings despite prior clean marker" >&2
  cat "$TEST_DIR/output-blocked-with-marker.txt" >&2
  exit 1
fi
if grep -q 'merge-gate review fails closed' "$TEST_DIR/output-blocked-with-marker.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && ! grep -q 'Auto-promoting to reviewer bypass' "$TEST_DIR/output-blocked-with-marker.txt"; then
  echo "==> PASS: concrete findings block merge even with prior clean marker"
else
  echo "FAIL: concrete findings should not merge without explicit bypass" >&2
  cat "$TEST_DIR/output-blocked-with-marker.txt" >&2
  exit 1
fi

echo "==> Test: review failure with NO prior clean marker still fails closed (#182 safety)"
reset_case_files
# No marker is created. The auto-promotion must NOT fire — without a marker
# there is no proof the diff was ever reviewed cleanly, so failing the
# review must still refuse the merge (preserves the safety guarantee).
if CODEX_REVIEW_EXIT=124 run_merge_pr "$TEST_DIR/output-no-marker.txt" 123; then
  echo "FAIL: merge-pr.sh auto-bypassed even without a clean marker" >&2
  cat "$TEST_DIR/output-no-marker.txt" >&2
  exit 1
fi
if [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && ! grep -q 'Auto-promoting to reviewer bypass' "$TEST_DIR/output-no-marker.txt"; then
  echo "==> PASS: review failure without marker fails closed (no auto-bypass)"
else
  echo "FAIL: failure-without-marker case should not merge or auto-bypass" >&2
  cat "$TEST_DIR/output-no-marker.txt" >&2
  exit 1
fi

echo "==> Test: auto-bypass rejects clean marker when live branch HEAD advanced (#211)"
reset_case_files
# Reproduce the safety regression: the branch has a clean marker for the
# earlier PR head, then the local branch advances before the final merge
# review fails. The stale marker must not auto-promote that failed review
# to a bypass, because the live branch HEAD has never reviewed cleanly.
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nbase=origin/main\nmerge_base=base-oid\nhead=pr-head-oid\n' \
  >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
if CODEX_REVIEW_EXIT=124 GIT_LOCAL_BRANCH_HEAD="advanced-head-oid" \
  run_merge_pr "$TEST_DIR/output-advanced-head.txt" 123; then
  echo "FAIL: merge-pr.sh auto-bypassed with a clean marker for an earlier HEAD" >&2
  cat "$TEST_DIR/output-advanced-head.txt" >&2
  exit 1
fi
if [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && ! grep -q 'Auto-promoting to reviewer bypass' "$TEST_DIR/output-advanced-head.txt"; then
  echo "==> PASS: clean marker for earlier HEAD does not auto-bypass advanced branch"
else
  echo "FAIL: advanced-head case should not merge or auto-bypass" >&2
  cat "$TEST_DIR/output-advanced-head.txt" >&2
  exit 1
fi

echo "==> Test: sibling worktree owning main is fast-forwarded without false merge failure"
reset_case_files
MAIN_WORKTREE="$TEST_DIR/main-worktree"
FEATURE_WORKTREE="$TEST_DIR/feature-worktree"
mkdir -p "$MAIN_WORKTREE" "$FEATURE_WORKTREE"
TEST_CURRENT_WORKTREE="$FEATURE_WORKTREE"
GIT_WORKTREE_LIST="$(
  cat <<EOF
worktree $MAIN_WORKTREE
HEAD main-oid
branch refs/heads/main

worktree $FEATURE_WORKTREE
HEAD feature-oid
branch refs/heads/feature/test

EOF
)"
run_merge_pr "$TEST_DIR/output-sibling-worktree.txt" 123
if grep -q "==> main is checked out in sibling worktree: $MAIN_WORKTREE" "$TEST_DIR/output-sibling-worktree.txt" \
  && grep -q '==> Fast-forwarding that worktree after remote merge' "$TEST_DIR/output-sibling-worktree.txt" \
  && grep -q '==> Done\.' "$TEST_DIR/output-sibling-worktree.txt" \
  && grep -q "^$MAIN_WORKTREE$" "$TEST_DIR/git-sibling-pull" \
  && grep -q '^checkout --detach main$' "$TEST_DIR/git-detached-default" \
  && grep -q '^deleted feature/test$' "$TEST_DIR/git-branch-deleted" \
  && [ ! -f "$TEST_DIR/git-checkout-main" ] \
  && ! grep -q 'ERROR:' "$TEST_DIR/output-sibling-worktree.txt"; then
  echo "==> PASS: sibling default worktree sync avoids false merge failure"
else
  echo "FAIL: sibling worktree sync did not avoid the checkout-main failure path" >&2
  cat "$TEST_DIR/output-sibling-worktree.txt" >&2
  exit 1
fi

echo "==> Test: local branch that moved after review is preserved"
reset_case_files
GIT_LOCAL_BRANCH_HEAD="new-local-oid" run_merge_pr "$TEST_DIR/output-moved-branch.txt" 123
if grep -q "WARNING: Local branch 'feature/test' is at new-local-oid, not reviewed PR head pr-head-oid; leaving it intact." "$TEST_DIR/output-moved-branch.txt" \
  && [ ! -f "$TEST_DIR/git-branch-deleted" ] \
  && grep -q '==> Done\.' "$TEST_DIR/output-moved-branch.txt"; then
  echo "==> PASS: moved local branch is not deleted"
else
  echo "FAIL: moved local branch should be preserved after merge" >&2
  cat "$TEST_DIR/output-moved-branch.txt" >&2
  exit 1
fi

echo "==> Test: stale default worktree metadata is diagnosed with prune recovery"
reset_case_files
STALE_MAIN_WORKTREE="$TEST_DIR/missing-main-worktree"
FEATURE_WORKTREE="$TEST_DIR/feature-worktree"
mkdir -p "$FEATURE_WORKTREE"
TEST_CURRENT_WORKTREE="$FEATURE_WORKTREE"
GIT_WORKTREE_LIST="$(
  cat <<EOF
worktree $STALE_MAIN_WORKTREE
HEAD main-oid
branch refs/heads/main

worktree $FEATURE_WORKTREE
HEAD feature-oid
branch refs/heads/feature/test

EOF
)"
run_merge_pr "$TEST_DIR/output-stale-worktree.txt" 123
if grep -q "WARNING: main is recorded as checked out in a missing worktree: $STALE_MAIN_WORKTREE" "$TEST_DIR/output-stale-worktree.txt" \
  && grep -q "stale git worktree metadata" "$TEST_DIR/output-stale-worktree.txt" \
  && grep -q "git worktree prune" "$TEST_DIR/output-stale-worktree.txt" \
  && grep -q '==> Done\.' "$TEST_DIR/output-stale-worktree.txt" \
  && [ ! -f "$TEST_DIR/git-sibling-pull" ] \
  && [ ! -f "$TEST_DIR/git-checkout-main" ] \
  && ! grep -q 'ERROR:' "$TEST_DIR/output-stale-worktree.txt"; then
  echo "==> PASS: stale default worktree metadata points to git worktree prune"
else
  echo "FAIL: stale default worktree metadata was not diagnosed clearly" >&2
  cat "$TEST_DIR/output-stale-worktree.txt" >&2
  exit 1
fi

echo "==> Test: gh local-branch-delete failure on a MERGED PR is a warning, not an error"
reset_case_files
TEST_CURRENT_WORKTREE="/tmp/touchstone-feature-worktree"
GIT_WORKTREE_LIST="$(
  cat <<'EOF'
worktree /tmp/touchstone-main-worktree
HEAD main-oid
branch refs/heads/main

worktree /tmp/touchstone-feature-worktree
HEAD feature-oid
branch refs/heads/feature/test

EOF
)"
GH_PR_MERGE_FAIL_LOCAL=true \
  run_merge_pr "$TEST_DIR/output-gh-local-fail.txt" 123
rc=$?
if [ "$rc" = "0" ] \
  && grep -q 'WARNING: gh pr merge exited 1, but PR #123 is MERGED on GitHub.' "$TEST_DIR/output-gh-local-fail.txt" \
  && grep -q 'git worktree remove <path>' "$TEST_DIR/output-gh-local-fail.txt" \
  && grep -q 'git worktree prune' "$TEST_DIR/output-gh-local-fail.txt" \
  && grep -q '==> Done\.' "$TEST_DIR/output-gh-local-fail.txt" \
  && ! grep -q '^ERROR:' "$TEST_DIR/output-gh-local-fail.txt"; then
  echo "==> PASS: local-delete failure on MERGED PR degrades to warning"
else
  echo "FAIL: gh local-delete failure should warn, not error, when PR is MERGED" >&2
  echo "    rc=$rc" >&2
  cat "$TEST_DIR/output-gh-local-fail.txt" >&2
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
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=base-oid\n' >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
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
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=old-head\n' >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
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
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=old-base\n' >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
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
