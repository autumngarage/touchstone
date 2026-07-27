#!/usr/bin/env bash
#
# tests/test-merge-pr-dirty-tree-narrow.sh — verify merge-pr.sh refuses the
# merge review only when dirty paths overlap the PR's diff vs the default
# base. Unrelated WIP outside the diff must not block the review.
#
# Issue #168: scripts/merge-pr.sh used to refuse review on any non-empty
# `git status --porcelain`, false-positiving on unrelated dirty files. The
# fix narrows the refusal to overlap with `git diff origin/main...HEAD`.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-merge-pr-dirty.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=tests/review-log-test-helper.sh
source "$TOUCHSTONE_ROOT/tests/review-log-test-helper.sh"
touchstone_isolate_review_log "$TEST_DIR"

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
exit "${CODEX_REVIEW_EXIT:-0}"
EOF
chmod +x "$MERGE_SCRIPT_DIR/merge-pr.sh" "$MERGE_SCRIPT_DIR/codex-review.sh"

# Fake `gh` — same shape as tests/test-merge-pr.sh, trimmed to what this test
# exercises (PR view + merge + comment + checkout).
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "repo view")
    case "${4:-}" in
      defaultBranchRef) echo "main" ;;
      nameWithOwner) echo "autumngarage/touchstone" ;;
      *)
        echo "unexpected gh repo view args: $*" >&2
        exit 1
        ;;
    esac
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
      isDraft) echo "false" ;;
      reviewDecision) echo "" ;;
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
  "api graphql")
    ;;
  "api repos/"*)
    echo "base-oid"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF

# Fake `git` — same shape as tests/test-merge-pr.sh, with two extensions:
#   GIT_DIRTY_STATUS  — value returned from `git status --porcelain`
#   GIT_DIFF_PATHS    — newline-separated paths returned from
#                       `git diff --name-only origin/main...HEAD`
cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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
  "rev-parse feature/test")
    printf 'pr-head-oid\n'
    ;;
  "show-ref --verify --quiet refs/heads/feature/test")
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
  "rev-parse --verify origin/main^{commit}")
    echo "base-oid"
    ;;
  "status --porcelain")
    if [ -n "${GIT_DIRTY_STATUS:-}" ]; then
      printf '%s' "$GIT_DIRTY_STATUS"
    fi
    ;;
  "diff --name-only origin/main...HEAD")
    if [ -n "${GIT_DIFF_PATHS:-}" ]; then
      printf '%s\n' "$GIT_DIFF_PATHS"
    fi
    ;;
  "worktree list --porcelain")
    printf '%s' "${GIT_WORKTREE_LIST:-}"
    ;;
  "checkout main")
    echo "Switched to branch 'main'"
    ;;
  "checkout --detach main")
    echo "HEAD is now at main"
    ;;
  "pull --rebase")
    echo "Already up to date."
    ;;
  "branch -D feature/test")
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
    "$TEST_DIR"/gh-merge-args* "$TEST_DIR"/gh-comment* \
    "$TEST_DIR"/gh-merged-marker*
  rm -rf "$GIT_PATH_ROOT"
  mkdir -p "$GIT_PATH_ROOT"
  unset GIT_DIRTY_STATUS
  unset GIT_DIFF_PATHS
  unset CODEX_REVIEW_EXIT
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
    GIT_DIRTY_STATUS="${GIT_DIRTY_STATUS:-}" \
    GIT_DIFF_PATHS="${GIT_DIFF_PATHS:-}" \
    CODEX_REVIEW_EXIT="${CODEX_REVIEW_EXIT:-0}" \
    TEST_CURRENT_WORKTREE="${TEST_CURRENT_WORKTREE:-/tmp/touchstone-feature-worktree}" \
    bash "$MERGE_SCRIPT_DIR/merge-pr.sh" "$@" >"$output_file" 2>&1
}

# ---------------------------------------------------------------------------
# Case 1: dirty file outside PR diff — review proceeds.
# ---------------------------------------------------------------------------
echo "==> Test: dirty file outside PR diff lets review proceed"
reset_case_files
GIT_DIRTY_STATUS=" M bootstrap/new-project.sh
" \
  GIT_DIFF_PATHS="scripts/merge-pr.sh
tests/test-merge-pr.sh" \
  run_merge_pr "$TEST_DIR/output-outside.txt" 123
if grep -q '==> Working tree has uncommitted changes outside PR #123' "$TEST_DIR/output-outside.txt" \
  && grep -q '==> Running merge review' "$TEST_DIR/output-outside.txt" \
  && grep -q '^CODEX_REVIEW_BASE=origin/main$' "$TEST_DIR/codex-review.log" \
  && grep -q '^CODEX_REVIEW_MODE=fix$' "$TEST_DIR/codex-review.log" \
  && grep -q '==> Done\.' "$TEST_DIR/output-outside.txt" \
  && ! grep -q 'refusing to run review' "$TEST_DIR/output-outside.txt"; then
  echo "==> PASS: unrelated dirty path does not block the review"
else
  echo "FAIL: dirty path outside PR diff should not block the review" >&2
  cat "$TEST_DIR/output-outside.txt" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Case 2: dirty file inside PR diff — review still refuses.
# ---------------------------------------------------------------------------
echo "==> Test: dirty file inside PR diff still refuses the review"
reset_case_files
if GIT_DIRTY_STATUS=" M scripts/merge-pr.sh
" \
  GIT_DIFF_PATHS="scripts/merge-pr.sh
tests/test-merge-pr.sh" \
  run_merge_pr "$TEST_DIR/output-inside.txt" 123; then
  echo "FAIL: dirty path inside PR diff should refuse the review" >&2
  cat "$TEST_DIR/output-inside.txt" >&2
  exit 1
fi
if grep -q "ERROR: Working tree has uncommitted changes that overlap PR #123's diff vs origin/main" "$TEST_DIR/output-inside.txt" \
  && grep -q 'scripts/merge-pr.sh' "$TEST_DIR/output-inside.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: overlapping dirty path refuses with the path listed"
else
  echo "FAIL: overlapping dirty path did not refuse with the expected error" >&2
  cat "$TEST_DIR/output-inside.txt" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Case 3: dirty rename — path resolution does not crash, post-rename path used.
# ---------------------------------------------------------------------------
# `git status --porcelain` rename row: `R  old -> new`. The post-rename path
# is what exists in the working tree, so that's what the overlap parser must
# extract. With the new path outside the PR diff, review must proceed.
echo "==> Test: dirty rename outside PR diff is handled and lets review proceed"
reset_case_files
GIT_DIRTY_STATUS="R  bootstrap/old-name.sh -> bootstrap/new-name.sh
" \
  GIT_DIFF_PATHS="scripts/merge-pr.sh" \
  run_merge_pr "$TEST_DIR/output-rename-outside.txt" 123
if grep -q '==> Running merge review' "$TEST_DIR/output-rename-outside.txt" \
  && grep -q '==> Done\.' "$TEST_DIR/output-rename-outside.txt" \
  && ! grep -q 'refusing to run review' "$TEST_DIR/output-rename-outside.txt"; then
  echo "==> PASS: rename row parsed without crashing, review proceeded"
else
  echo "FAIL: rename row should not block review when post-rename path is outside PR diff" >&2
  cat "$TEST_DIR/output-rename-outside.txt" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Case 4: dirty rename whose post-rename path is inside PR diff — refuses,
# and the listed path is the post-rename (working-tree) path.
# ---------------------------------------------------------------------------
echo "==> Test: dirty rename inside PR diff refuses with post-rename path"
reset_case_files
if GIT_DIRTY_STATUS="R  scripts/old-name.sh -> scripts/merge-pr.sh
" \
  GIT_DIFF_PATHS="scripts/merge-pr.sh" \
  run_merge_pr "$TEST_DIR/output-rename-inside.txt" 123; then
  echo "FAIL: rename whose target is inside PR diff should refuse" >&2
  cat "$TEST_DIR/output-rename-inside.txt" >&2
  exit 1
fi
if grep -q "ERROR: Working tree has uncommitted changes that overlap PR #123's diff vs origin/main" "$TEST_DIR/output-rename-inside.txt" \
  && grep -q 'scripts/merge-pr.sh' "$TEST_DIR/output-rename-inside.txt" \
  && ! grep -q 'scripts/old-name.sh' "$TEST_DIR/output-rename-inside.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: post-rename path used for overlap check"
else
  echo "FAIL: post-rename path was not the one reported as the overlap" >&2
  cat "$TEST_DIR/output-rename-inside.txt" >&2
  exit 1
fi

echo "==> ALL PASS"
