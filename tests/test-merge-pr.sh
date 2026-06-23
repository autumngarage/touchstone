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
DEFAULT_FAKE_WORKTREE="$TEST_DIR/default-feature-worktree"
mkdir -p "$FAKE_BIN" "$MERGE_SCRIPT_DIR" "$GIT_PATH_ROOT" "$DEFAULT_FAKE_WORKTREE"
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
if [ -n "${CODEX_REVIEW_STUB_SUMMARY:-}" ] && [ -n "${CODEX_REVIEW_SUMMARY_FILE:-}" ]; then
  printf '%s\n' "$CODEX_REVIEW_STUB_SUMMARY" > "$CODEX_REVIEW_SUMMARY_FILE"
fi
if [ -n "${CODEX_REVIEW_MUTATE_HEAD:-}" ]; then
  printf '%s\n' "$CODEX_REVIEW_MUTATE_HEAD" > "$GIT_REVIEW_HEAD_FILE"
fi
exit "${CODEX_REVIEW_EXIT:-0}"
EOF
chmod +x "$MERGE_SCRIPT_DIR/merge-pr.sh" "$MERGE_SCRIPT_DIR/codex-review.sh"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

gh_query_arg() {
  local previous=""
  local arg

  for arg in "$@"; do
    if [ "$previous" = "-f" ]; then
      case "$arg" in
        query=*)
          printf '%s' "${arg#query=}"
          return 0
          ;;
      esac
    fi
    previous="$arg"
  done
  return 0
}

reject_unbalanced_graphql_query() {
  local query="$1"
  local opens closes

  [ "${GH_REJECT_UNBALANCED_GRAPHQL:-false}" = "true" ] || return 0
  opens="$(printf '%s' "$query" | tr -cd '{' | wc -c | tr -d ' ')"
  closes="$(printf '%s' "$query" | tr -cd '}' | wc -c | tr -d ' ')"
  if [ "$opens" != "$closes" ]; then
    echo 'Expected one of: <EOF>, actual: RCURLY ("}")' >&2
    exit 1
  fi
}

increment_counter_file() {
  local counter_file="$1"
  local count=1

  if [ -n "$counter_file" ]; then
    if [ -f "$counter_file" ]; then
      count="$(cat "$counter_file" 2>/dev/null || echo 0)"
      count=$((count + 1))
    fi
    printf '%s\n' "$count" >"$counter_file"
  fi
  printf '%s' "$count"
}

case "${1:-} ${2:-}" in
  "repo view")
    case "${4:-}" in
      defaultBranchRef) echo "main" ;;
      nameWithOwner) echo "${GH_REPO_FULL_NAME:-autumngarage/touchstone}" ;;
      *)
        echo "unexpected gh repo view args: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "pr view")
    if [ -n "${GH_PR_VIEW_FAIL_FIELD:-}" ] && [ "${5:-}" = "$GH_PR_VIEW_FAIL_FIELD" ]; then
      echo "gh pr view ${5:-} unavailable" >&2
      exit 1
    fi
    case "${5:-}" in
      state)
        if [ -f "${GH_MERGED_MARKER:-/dev/null/never}" ]; then
          echo "MERGED"
        else
          echo "OPEN"
        fi
        ;;
      headRefName) echo "feature/test" ;;
      headRefOid)
        head_ref_call_count=1
        if [ -n "${GH_HEAD_REF_CALLS_FILE:-}" ]; then
          if [ -f "$GH_HEAD_REF_CALLS_FILE" ]; then
            head_ref_call_count="$(cat "$GH_HEAD_REF_CALLS_FILE" 2>/dev/null || echo 0)"
            head_ref_call_count=$((head_ref_call_count + 1))
          fi
          printf '%s\n' "$head_ref_call_count" >"$GH_HEAD_REF_CALLS_FILE"
        fi
        if [ -n "${GH_HEAD_REF_FAIL_AFTER:-}" ] && [ "$head_ref_call_count" -ge "$GH_HEAD_REF_FAIL_AFTER" ]; then
          echo "gh pr view headRefOid unavailable" >&2
          exit 1
        fi
        if [ -n "${GH_HEAD_REF_CHANGE_AFTER:-}" ] && [ "$head_ref_call_count" -ge "$GH_HEAD_REF_CHANGE_AFTER" ]; then
          echo "${GH_HEAD_REF_CHANGED_OID:-changed-pr-head}"
        elif [ -f "${GH_HEAD_REF_FILE:-/dev/null/never}" ]; then
          cat "$GH_HEAD_REF_FILE"
        else
          echo "${GH_PR_HEAD_OID:-pr-head-oid}"
        fi
        ;;
      isDraft) echo "${GH_IS_DRAFT:-false}" ;;
      reviewDecision) echo "${GH_REVIEW_DECISION:-}" ;;
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
    expected_head="${GH_EXPECT_MERGE_HEAD:-pr-head-oid}"
    if [ "${4:-} ${5:-} ${6:-} ${7:-}" != "--squash --delete-branch --match-head-commit $expected_head" ]; then
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
  "api graphql")
    query="$(gh_query_arg "$@")"
    reject_unbalanced_graphql_query "$query"
    if [ "${GH_GRAPHQL_FAIL:-false}" = "true" ]; then
      echo "graphql unavailable" >&2
      exit 1
    fi
    if printf '%s' "$query" | grep -q 'reviews(first:'; then
      reviews_graphql_call_count="$(increment_counter_file "${GH_REVIEWS_GRAPHQL_CALLS_FILE:-}")"
      if [ "${GH_REVIEWS_GRAPHQL_FAIL_FIRST:-false}" = "true" ] && [ "$reviews_graphql_call_count" = "1" ]; then
        echo "reviews graphql unavailable" >&2
        exit 1
      fi
      if [ "$reviews_graphql_call_count" -ge 2 ] && [ -n "${GH_TRUSTED_REVIEWS_SECOND:-}" ]; then
        printf '%s' "$GH_TRUSTED_REVIEWS_SECOND"
      else
        printf '%s' "${GH_TRUSTED_REVIEWS:-}"
      fi
      exit 0
    fi
    graphql_call_count="$(increment_counter_file "${GH_GRAPHQL_CALLS_FILE:-}")"
    if [ "$graphql_call_count" -ge 2 ] && [ -n "${GH_UNRESOLVED_THREADS_SECOND:-}" ]; then
      printf '%s' "$GH_UNRESOLVED_THREADS_SECOND"
    else
      printf '%s' "${GH_UNRESOLVED_THREADS:-}"
    fi
    ;;
  "api --paginate")
    case "${3:-}" in
      */comments)
        comments_call_count="$(increment_counter_file "${GH_COMMENTS_CALLS_FILE:-}")"
        if [ "$comments_call_count" -ge 2 ] && [ -n "${GH_ISSUE_COMMENTS_SECOND:-}" ]; then
          printf '%s' "$GH_ISSUE_COMMENTS_SECOND"
        else
          printf '%s' "${GH_ISSUE_COMMENTS:-}"
        fi
        ;;
      *)
        reactions_call_count="$(increment_counter_file "${GH_REACTIONS_CALLS_FILE:-}")"
        if [ "$reactions_call_count" -ge 2 ] && [ -n "${GH_REACTIONS_SECOND:-}" ]; then
          printf '%s' "$GH_REACTIONS_SECOND"
        else
          printf '%s' "${GH_REACTIONS:-}"
        fi
        ;;
    esac
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

untracked_path_for_hash() {
  local target="${GIT_UNTRACKED_PATH:-}"
  local root="${TEST_CURRENT_WORKTREE:-}"

  if [ -n "$root" ]; then
    case "$target" in
      "$root"/*) target="${target#"$root/"}" ;;
    esac
  fi
  printf '%s' "$target"
}

pathspec_matches_untracked() {
  local target arg seen_pathspec=false

  target="$(untracked_path_for_hash)"
  [ -n "$target" ] || return 1

  for arg in "$@"; do
    if [ "$seen_pathspec" = true ]; then
      [ "$arg" = "$target" ] && return 0
    elif [ "$arg" = "--" ]; then
      seen_pathspec=true
    fi
  done

  [ "$seen_pathspec" = false ]
}

emit_untracked_path() {
  [ -n "${GIT_UNTRACKED_PATH:-}" ] || return 0
  if [ "${GIT_REQUIRE_ROOT_FOR_UNTRACKED:-false}" = "true" ] && [ "$PWD" != "${TEST_CURRENT_WORKTREE:-}" ]; then
    return 0
  fi
  pathspec_matches_untracked "$@" || return 0
  printf '%s\0' "$(untracked_path_for_hash)"
}

trusted_touchstone_config_file() {
  if [ -n "${GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE:-}" ] \
    && [ -n "${GIT_FETCH_MAIN_FILE:-}" ] \
    && [ -f "$GIT_FETCH_MAIN_FILE" ]; then
    printf '%s' "$GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE"
    return 0
  fi

  printf '%s' "${GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE:-${TEST_CURRENT_WORKTREE:-}/.touchstone-review.toml}"
}

if [ "${1:-}" = "-C" ]; then
  git_c_target="$2"
  cd "$git_c_target"
  shift 2
  case "${1:-} ${2:-}" in
    "pull --ff-only")
      printf '%s\n' "$git_c_target" > "$GIT_SIBLING_PULL_FILE"
      if [ "${GIT_SIBLING_PULL_FAIL:-false}" = "true" ]; then
        echo "sibling pull failed" >&2
        exit 1
      fi
      echo "Already up to date."
      exit 0
      ;;
    "status --porcelain")
      printf '%s' "${GIT_WORKTREE_STATUS:-}"
      exit 0
      ;;
    "worktree remove")
      remove_target="${4:-${3:-}}"
      printf '%s\n' "$remove_target" > "$GIT_WORKTREE_REMOVE_FILE"
      if [ "${GIT_WORKTREE_REMOVE_FAIL:-false}" = "true" ]; then
        echo "worktree remove failed" >&2
        exit 1
      fi
      echo "removed $remove_target"
      exit 0
      ;;
  esac
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
    elif [ -f "$GIT_REVIEW_HEAD_FILE" ]; then
      cat "$GIT_REVIEW_HEAD_FILE"
    elif [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "${GH_PR_HEAD_OID:-pr-head-oid}"
    else
      echo "stale-local-oid"
    fi
    ;;
  "rev-parse --git-path touchstone/reviewer-clean")
    printf '%s\n' "$GIT_PATH_ROOT/touchstone/reviewer-clean"
    ;;
  "rev-parse --git-path touchstone/preflight-clean")
    printf '%s\n' "$GIT_PATH_ROOT/touchstone/preflight-clean"
    ;;
  rev-parse\ --git-path\ touchstone/review-summary-pr-*.json)
    printf '%s\n' "$GIT_PATH_ROOT/${3:-touchstone/review-summary-pr-unknown.json}"
    ;;
  "rev-parse --show-toplevel")
    printf '%s\n' "${TEST_CURRENT_WORKTREE:-/tmp/touchstone-feature-worktree}"
    ;;
  "rev-parse --verify origin/main^{commit}")
    printf '%s\n' "${GIT_BASE_OID:-base-oid}"
    ;;
  "rev-parse --verify --quiet origin/main^{commit}")
    printf '%s\n' "${GIT_BASE_OID:-base-oid}"
    ;;
  "rev-parse feature/test")
    if [ -f "$GIT_BRANCH_DELETED_FILE" ]; then
      exit 1
    fi
    printf '%s\n' "${GIT_LOCAL_BRANCH_HEAD:-pr-head-oid}"
    ;;
  "cat-file -e origin/main:.touchstone-review.toml")
    [ -f "$(trusted_touchstone_config_file)" ] || exit 1
    ;;
  "cat-file -e origin/main:.codex-review.toml")
    [ -f "${TEST_CURRENT_WORKTREE:-}/.codex-review.toml" ] || exit 1
    ;;
  "show-ref --verify --quiet refs/heads/feature/test")
    if [ -f "$GIT_BRANCH_DELETED_FILE" ]; then
      exit 1
    fi
    ;;
  "show origin/main:.touchstone-review.toml")
    cat "$(trusted_touchstone_config_file)"
    ;;
  "show origin/main:.codex-review.toml")
    cat "${TEST_CURRENT_WORKTREE:-}/.codex-review.toml"
    ;;
  cat-file\ -e\ *^\{commit\})
    ;;
  merge-base\ origin/main\ *)
    printf '%s\n' "${GIT_MERGE_BASE_OID:-base-oid}"
    ;;
  "fetch origin +refs/heads/main:refs/remotes/origin/main")
    if [ -n "${GIT_FETCH_MAIN_FILE:-}" ]; then
      printf 'fetch\n' >>"$GIT_FETCH_MAIN_FILE"
    fi
    echo "fetched main"
    ;;
  status\ --porcelain\ --untracked-files=all\ --*)
    printf '%s' "${GIT_WORKTREE_STATUS:-}"
    ;;
  "status --porcelain" | "status --porcelain --untracked-files=all")
    ;;
  "ls-files --others --exclude-standard -z")
    emit_untracked_path "$@"
    ;;
  ls-files\ --others\ --exclude-standard\ -z\ --*)
    emit_untracked_path "$@"
    ;;
  "diff --name-only origin/main...HEAD")
    printf '%s\n' "${GIT_CHANGED_PATHS:-example.txt}"
    ;;
  diff\ --binary\ --*)
    printf '%s' "${GIT_WORKTREE_DIFF:-}"
    ;;
  "diff --binary")
    printf '%s' "${GIT_WORKTREE_DIFF:-}"
    ;;
  diff\ --cached\ --binary\ --*)
    printf '%s' "${GIT_INDEX_DIFF:-}"
    ;;
  "diff --cached --binary")
    printf '%s' "${GIT_INDEX_DIFF:-}"
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
  "push origin HEAD:refs/heads/feature/test")
    git rev-parse HEAD > "$GIT_PUSH_HEAD_FILE"
    cp "$GIT_PUSH_HEAD_FILE" "$GH_HEAD_REF_FILE"
    echo "pushed"
    ;;
  "branch -D -- feature/test")
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
    "$TEST_DIR"/git-sibling-pull* "$TEST_DIR"/gh-merged-marker* \
    "$TEST_DIR"/git-review-head* "$TEST_DIR"/git-push-head* \
    "$TEST_DIR"/git-fetch-main* \
    "$TEST_DIR"/gh-head-ref* "$TEST_DIR"/preflight-calls* \
    "$TEST_DIR"/git-worktree-remove* "$TEST_DIR"/touchstone-review-log* \
    "$TEST_DIR"/gh-graphql-calls* "$TEST_DIR"/gh-head-ref-calls* \
    "$TEST_DIR"/gh-reviews-graphql-calls* "$TEST_DIR"/gh-reactions-calls* \
    "$TEST_DIR"/gh-comments-calls*
  rm -rf "$GIT_PATH_ROOT"
  rm -rf "$DEFAULT_FAKE_WORKTREE"
  mkdir -p "$GIT_PATH_ROOT"
  mkdir -p "$DEFAULT_FAKE_WORKTREE"
  unset GIT_WORKTREE_LIST
  unset GIT_SIBLING_PULL_FAIL
  unset TEST_CURRENT_WORKTREE
  unset GH_PR_MERGE_FAIL_LOCAL
  unset GH_MERGE_STATE
  unset GH_FAILED_CHECKS
  unset GH_REPO_FULL_NAME
  unset GH_PR_VIEW_FAIL_FIELD
  unset GH_HEAD_REF_FAIL_AFTER
  unset GH_HEAD_REF_CHANGE_AFTER
  unset GH_HEAD_REF_CHANGED_OID
  unset GH_IS_DRAFT
  unset GH_REVIEW_DECISION
  unset GH_UNRESOLVED_THREADS
  unset GH_UNRESOLVED_THREADS_SECOND
  unset GH_GRAPHQL_FAIL
  unset GH_REJECT_UNBALANCED_GRAPHQL
  unset GH_TRUSTED_REVIEWS
  unset GH_TRUSTED_REVIEWS_SECOND
  unset GH_REVIEWS_GRAPHQL_FAIL_FIRST
  unset GH_REACTIONS
  unset GH_REACTIONS_SECOND
  unset GH_ISSUE_COMMENTS
  unset GH_ISSUE_COMMENTS_SECOND
  unset MERGE_PR_SLEEP_OVERRIDE
  unset CODEX_REVIEW_EXIT
  unset CODEX_REVIEW_STUB_OUTPUT
  unset CODEX_REVIEW_STUB_SUMMARY
  unset CODEX_REVIEW_MUTATE_HEAD
  unset GIT_LOCAL_BRANCH_HEAD
  unset GH_EXPECT_MERGE_HEAD
  unset GH_PR_HEAD_OID
  unset GIT_BASE_OID
  unset GIT_MERGE_BASE_OID
  unset GIT_CHANGED_PATHS
  unset GIT_WORKTREE_DIFF
  unset GIT_INDEX_DIFF
  unset GIT_UNTRACKED_PATH
  unset GIT_REQUIRE_ROOT_FOR_UNTRACKED
  unset GIT_WORKTREE_STATUS
  unset GIT_WORKTREE_REMOVE_FAIL
  unset GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE
  unset GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE
  unset SHELLCHECK_VERSION_LINE
  unset TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS
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
    GH_HEAD_REF_FILE="$TEST_DIR/gh-head-ref" \
    GH_PR_HEAD_OID="${GH_PR_HEAD_OID:-pr-head-oid}" \
    GH_MERGED_MARKER="$TEST_DIR/gh-merged-marker" \
    GH_EXPECT_MERGE_HEAD="${GH_EXPECT_MERGE_HEAD:-pr-head-oid}" \
    GH_PR_MERGE_FAIL_LOCAL="${GH_PR_MERGE_FAIL_LOCAL:-false}" \
    GH_MERGE_STATE="${GH_MERGE_STATE:-CLEAN MERGEABLE}" \
    GH_FAILED_CHECKS="${GH_FAILED_CHECKS:-}" \
    GH_REPO_FULL_NAME="${GH_REPO_FULL_NAME:-autumngarage/touchstone}" \
    GH_PR_VIEW_FAIL_FIELD="${GH_PR_VIEW_FAIL_FIELD:-}" \
    GH_HEAD_REF_FAIL_AFTER="${GH_HEAD_REF_FAIL_AFTER:-}" \
    GH_HEAD_REF_CHANGE_AFTER="${GH_HEAD_REF_CHANGE_AFTER:-}" \
    GH_HEAD_REF_CHANGED_OID="${GH_HEAD_REF_CHANGED_OID:-changed-pr-head}" \
    GH_HEAD_REF_CALLS_FILE="$TEST_DIR/gh-head-ref-calls" \
    GH_IS_DRAFT="${GH_IS_DRAFT:-false}" \
    GH_REVIEW_DECISION="${GH_REVIEW_DECISION:-}" \
    GH_UNRESOLVED_THREADS="${GH_UNRESOLVED_THREADS:-}" \
    GH_UNRESOLVED_THREADS_SECOND="${GH_UNRESOLVED_THREADS_SECOND:-}" \
    GH_GRAPHQL_FAIL="${GH_GRAPHQL_FAIL:-false}" \
    GH_REJECT_UNBALANCED_GRAPHQL="${GH_REJECT_UNBALANCED_GRAPHQL:-false}" \
    GH_GRAPHQL_CALLS_FILE="$TEST_DIR/gh-graphql-calls" \
    GH_TRUSTED_REVIEWS="${GH_TRUSTED_REVIEWS:-}" \
    GH_TRUSTED_REVIEWS_SECOND="${GH_TRUSTED_REVIEWS_SECOND:-}" \
    GH_REVIEWS_GRAPHQL_CALLS_FILE="$TEST_DIR/gh-reviews-graphql-calls" \
    GH_REVIEWS_GRAPHQL_FAIL_FIRST="${GH_REVIEWS_GRAPHQL_FAIL_FIRST:-false}" \
    GH_REACTIONS="${GH_REACTIONS:-}" \
    GH_REACTIONS_SECOND="${GH_REACTIONS_SECOND:-}" \
    GH_REACTIONS_CALLS_FILE="$TEST_DIR/gh-reactions-calls" \
    GH_ISSUE_COMMENTS="${GH_ISSUE_COMMENTS:-}" \
    GH_ISSUE_COMMENTS_SECOND="${GH_ISSUE_COMMENTS_SECOND:-}" \
    GH_COMMENTS_CALLS_FILE="$TEST_DIR/gh-comments-calls" \
    MERGE_PR_SLEEP_OVERRIDE="${MERGE_PR_SLEEP_OVERRIDE:-}" \
    GIT_CHECKOUT_MAIN_FILE="$TEST_DIR/git-checkout-main" \
    GIT_DETACHED_DEFAULT_FILE="$TEST_DIR/git-detached-default" \
    GIT_BRANCH_DELETED_FILE="$TEST_DIR/git-branch-deleted" \
    GIT_SIBLING_PULL_FILE="$TEST_DIR/git-sibling-pull" \
    GIT_WORKTREE_REMOVE_FILE="$TEST_DIR/git-worktree-remove" \
    GIT_REVIEW_HEAD_FILE="$TEST_DIR/git-review-head" \
    GIT_PUSH_HEAD_FILE="$TEST_DIR/git-push-head" \
    GIT_FETCH_MAIN_FILE="$TEST_DIR/git-fetch-main" \
    GIT_WORKTREE_LIST="${GIT_WORKTREE_LIST:-}" \
    GIT_SIBLING_PULL_FAIL="${GIT_SIBLING_PULL_FAIL:-false}" \
    GIT_BASE_OID="${GIT_BASE_OID:-base-oid}" \
    GIT_MERGE_BASE_OID="${GIT_MERGE_BASE_OID:-base-oid}" \
    GIT_CHANGED_PATHS="${GIT_CHANGED_PATHS:-example.txt}" \
    GIT_WORKTREE_DIFF="${GIT_WORKTREE_DIFF:-}" \
    GIT_INDEX_DIFF="${GIT_INDEX_DIFF:-}" \
    GIT_UNTRACKED_PATH="${GIT_UNTRACKED_PATH:-}" \
    GIT_REQUIRE_ROOT_FOR_UNTRACKED="${GIT_REQUIRE_ROOT_FOR_UNTRACKED:-false}" \
    GIT_WORKTREE_STATUS="${GIT_WORKTREE_STATUS:-}" \
    GIT_WORKTREE_REMOVE_FAIL="${GIT_WORKTREE_REMOVE_FAIL:-false}" \
    GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE="${GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE:-}" \
    GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE="${GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE:-}" \
    SHELLCHECK_VERSION_LINE="${SHELLCHECK_VERSION_LINE:-}" \
    CODEX_REVIEW_EXIT="${CODEX_REVIEW_EXIT:-0}" \
    CODEX_REVIEW_STUB_OUTPUT="${CODEX_REVIEW_STUB_OUTPUT:-}" \
    CODEX_REVIEW_STUB_SUMMARY="${CODEX_REVIEW_STUB_SUMMARY:-}" \
    CODEX_REVIEW_MUTATE_HEAD="${CODEX_REVIEW_MUTATE_HEAD:-}" \
    GIT_LOCAL_BRANCH_HEAD="${GIT_LOCAL_BRANCH_HEAD:-pr-head-oid}" \
    PREFLIGHT_CALLS_FILE="${PREFLIGHT_CALLS_FILE:-}" \
    TEST_CURRENT_WORKTREE="${TEST_CURRENT_WORKTREE:-$DEFAULT_FAKE_WORKTREE}" \
    TOUCHSTONE_REVIEW_LOG="$TEST_DIR/touchstone-review-log" \
    TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS="${TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS:-24}" \
    bash "$MERGE_SCRIPT_DIR/merge-pr.sh" "$@" >"$output_file" 2>&1
}

write_fail_open_review_log() {
  local branch="${1:-feature/test}"
  local sha="${2:-pr-head-oid}"
  local reason="${3:-FAIL_OPEN_TIMEOUT}"
  local detail="${4:-fail-open:timeout waiting for hosted reviewer}"
  local timestamp="${5:-}"

  if [ -z "$timestamp" ]; then
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$timestamp" "$DEFAULT_FAKE_WORKTREE" "$branch" "$sha" "$reason" "$detail" \
    >"$TEST_DIR/touchstone-review-log"
}

install_preflight_counter_fixture() {
  mkdir -p "$TEST_DIR/lib"
  cat >"$TEST_DIR/lib/preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

touchstone_preflight_main_sanitized() {
  printf '%s\n' "$*" >> "$PREFLIGHT_CALLS_FILE"
}

touchstone_preflight_main() {
  touchstone_preflight_main_sanitized "$@"
}
EOF
}

install_toml_parser_fixture() {
  mkdir -p "$TEST_DIR/lib"
  cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$TEST_DIR/lib/toml.sh"
}

write_pr_triggered_config() {
  local skip_merge_review="${1:-true}"
  local timeout_sec="${2:-0}"
  local poll_sec="${3:-0}"

  install_toml_parser_fixture
  mkdir -p "$DEFAULT_FAKE_WORKTREE"
  cat >"$DEFAULT_FAKE_WORKTREE/.touchstone-review.toml" <<EOF
[review.pr_triggered]
required = true
provider = "github-codex"
timeout_sec = $timeout_sec
poll_sec = $poll_sec
trusted_review_authors = ["chatgpt-codex-connector", "chatgpt-codex-connector[bot]"]
trusted_reaction_author = "chatgpt-codex-connector[bot]"
skip_merge_review = $skip_merge_review
EOF
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

echo "==> Test: clean preflight marker reuses exact merge-gate inputs"
install_preflight_counter_fixture
reset_case_files
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-first.txt" 123; then
  echo "FAIL: first cache fixture run should stop at review failure" >&2
  exit 1
fi
if CODEX_REVIEW_EXIT=1 \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-second.txt" 123; then
  echo "FAIL: second cache fixture run should stop at review failure" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "1" ] \
  && grep -q 'Deterministic preflight clean (cached=false' "$TEST_DIR/output-preflight-cache-first.txt" \
  && grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-second.txt"; then
  echo "==> PASS: exact preflight inputs reused clean marker"
else
  echo "FAIL: exact preflight inputs should reuse the clean marker" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-first.txt" >&2
  cat "$TEST_DIR/output-preflight-cache-second.txt" >&2
  exit 1
fi

echo "==> Test: preflight cache reruns when PR head changes"
install_preflight_counter_fixture
reset_case_files
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-head-first.txt" 123; then
  echo "FAIL: first head-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
if CODEX_REVIEW_EXIT=1 \
  GH_PR_HEAD_OID="next-head-oid" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-head-second.txt" 123; then
  echo "FAIL: second head-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "2" ] \
  && grep -q 'Deterministic preflight clean (cached=false' "$TEST_DIR/output-preflight-cache-head-second.txt" \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-head-second.txt"; then
  echo "==> PASS: changed PR head forced preflight rerun"
else
  echo "FAIL: changed PR head should force preflight rerun" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-head-second.txt" >&2
  exit 1
fi

echo "==> Test: preflight cache reruns when base or merge-base changes"
install_preflight_counter_fixture
reset_case_files
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-base-first.txt" 123; then
  echo "FAIL: first base-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
if CODEX_REVIEW_EXIT=1 \
  GIT_BASE_OID="new-base-oid" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-base-second.txt" 123; then
  echo "FAIL: second base-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
if CODEX_REVIEW_EXIT=1 \
  GIT_MERGE_BASE_OID="new-merge-base-oid" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-merge-base.txt" 123; then
  echo "FAIL: merge-base-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "3" ] \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-base-second.txt" \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-merge-base.txt"; then
  echo "==> PASS: base and merge-base changes forced preflight reruns"
else
  echo "FAIL: base or merge-base changes should force preflight reruns" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-base-second.txt" >&2
  cat "$TEST_DIR/output-preflight-cache-merge-base.txt" >&2
  exit 1
fi

echo "==> Test: preflight cache reruns when checker or config hashes change"
install_preflight_counter_fixture
reset_case_files
CACHE_WORKTREE="$TEST_DIR/cache-worktree"
mkdir -p "$CACHE_WORKTREE"
printf '[review]\npreflight_required = true\n' >"$CACHE_WORKTREE/.codex-review.toml"
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  TEST_CURRENT_WORKTREE="$CACHE_WORKTREE" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-hash-first.txt" 123; then
  echo "FAIL: first hash-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
printf '\n# checker hash changed\n' >>"$TEST_DIR/lib/preflight.sh"
if CODEX_REVIEW_EXIT=1 \
  TEST_CURRENT_WORKTREE="$CACHE_WORKTREE" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-checker-second.txt" 123; then
  echo "FAIL: checker-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
printf 'comment_on_clean = false\n' >>"$CACHE_WORKTREE/.codex-review.toml"
if CODEX_REVIEW_EXIT=1 \
  TEST_CURRENT_WORKTREE="$CACHE_WORKTREE" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-config-third.txt" 123; then
  echo "FAIL: config-mismatch fixture run should stop at review failure" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "3" ] \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-checker-second.txt" \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-config-third.txt"; then
  echo "==> PASS: checker and config changes forced preflight reruns"
else
  echo "FAIL: checker or config changes should force preflight reruns" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-checker-second.txt" >&2
  cat "$TEST_DIR/output-preflight-cache-config-third.txt" >&2
  exit 1
fi

echo "==> Test: preflight cache ignores unrelated untracked file contents"
install_preflight_counter_fixture
reset_case_files
UNTRACKED_FILE="$TEST_DIR/untracked-local-test.sh"
printf 'echo pass\n' >"$UNTRACKED_FILE"
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  GIT_UNTRACKED_PATH="$UNTRACKED_FILE" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-untracked-first.txt" 123; then
  echo "FAIL: first untracked-content fixture run should stop at review failure" >&2
  exit 1
fi
printf 'echo fail\n' >"$UNTRACKED_FILE"
if CODEX_REVIEW_EXIT=1 \
  GIT_UNTRACKED_PATH="$UNTRACKED_FILE" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-untracked-second.txt" 123; then
  echo "FAIL: second unrelated-untracked fixture run should stop at review failure" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "1" ] \
  && grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-untracked-second.txt"; then
  echo "==> PASS: unrelated untracked file contents did not force preflight rerun"
else
  echo "FAIL: unrelated untracked file contents should reuse the preflight cache" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-untracked-second.txt" >&2
  exit 1
fi

echo "==> Test: preflight cache reruns when changed-path untracked file contents change"
install_preflight_counter_fixture
reset_case_files
printf 'echo pass\n' >"$DEFAULT_FAKE_WORKTREE/example.txt"
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  GIT_UNTRACKED_PATH="example.txt" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-relevant-untracked-first.txt" 123; then
  echo "FAIL: first relevant-untracked fixture run should stop at review failure" >&2
  exit 1
fi
printf 'echo fail\n' >"$DEFAULT_FAKE_WORKTREE/example.txt"
if CODEX_REVIEW_EXIT=1 \
  GIT_UNTRACKED_PATH="example.txt" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-relevant-untracked-second.txt" 123; then
  echo "FAIL: second relevant-untracked fixture run should stop at review failure" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "2" ] \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-relevant-untracked-second.txt"; then
  echo "==> PASS: changed-path untracked file contents forced preflight rerun"
else
  echo "FAIL: changed-path untracked file contents should force preflight rerun" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-relevant-untracked-second.txt" >&2
  exit 1
fi

echo "==> Test: preflight cache hashes root worktree state from subdirs"
install_preflight_counter_fixture
reset_case_files
ROOT_HASH_WORKTREE="$TEST_DIR/root-hash-worktree"
mkdir -p "$ROOT_HASH_WORKTREE/nested"
printf 'root one\n' >"$ROOT_HASH_WORKTREE/root-only.log"
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  TEST_CURRENT_WORKTREE="$ROOT_HASH_WORKTREE" \
  GIT_CHANGED_PATHS="root-only.log" \
  GIT_UNTRACKED_PATH="root-only.log" \
  GIT_REQUIRE_ROOT_FOR_UNTRACKED=true \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-root-first.txt" 123; then
  echo "FAIL: first root-state fixture run should stop at review failure" >&2
  exit 1
fi
printf 'root two\n' >"$ROOT_HASH_WORKTREE/root-only.log"
(
  cd "$ROOT_HASH_WORKTREE/nested"
  if CODEX_REVIEW_EXIT=1 \
    TEST_CURRENT_WORKTREE="$ROOT_HASH_WORKTREE" \
    GIT_CHANGED_PATHS="root-only.log" \
    GIT_UNTRACKED_PATH="root-only.log" \
    GIT_REQUIRE_ROOT_FOR_UNTRACKED=true \
    PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
    run_merge_pr "$TEST_DIR/output-preflight-cache-root-second.txt" 123; then
    echo "FAIL: second root-state fixture run should stop at review failure" >&2
    exit 1
  fi
)
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "2" ] \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-root-second.txt"; then
  echo "==> PASS: subdir launch still hashes root worktree state"
else
  echo "FAIL: subdir launch should not reuse stale root worktree cache" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-root-second.txt" >&2
  exit 1
fi

echo "==> Test: preflight cache reruns when full tool version output changes"
install_preflight_counter_fixture
reset_case_files
cat >"$FAKE_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\n'
  printf 'version: %s\n' "${SHELLCHECK_VERSION_LINE:-0.10.0}"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/shellcheck"
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  SHELLCHECK_VERSION_LINE="0.10.0" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-tool-first.txt" 123; then
  echo "FAIL: first tool-version fixture run should stop at review failure" >&2
  exit 1
fi
if CODEX_REVIEW_EXIT=1 \
  SHELLCHECK_VERSION_LINE="0.11.0" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-preflight-cache-tool-second.txt" 123; then
  echo "FAIL: second tool-version fixture run should stop at review failure" >&2
  exit 1
fi
rm -f "$FAKE_BIN/shellcheck"
rm -rf "${TEST_DIR:?}/lib"
if [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "2" ] \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$TEST_DIR/output-preflight-cache-tool-second.txt"; then
  echo "==> PASS: full tool version output change forced preflight rerun"
else
  echo "FAIL: full tool version output change should force preflight rerun" >&2
  cat "$TEST_DIR/preflight-calls" >&2
  cat "$TEST_DIR/output-preflight-cache-tool-second.txt" >&2
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
  && grep -q '^CODEX_REVIEW_MODE=fix$' "$TEST_DIR/codex-review.log" \
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

echo "==> Test: PR-triggered review skips duplicate merge review after deterministic preflight"
reset_case_files
install_preflight_counter_fixture
write_pr_triggered_config true 0 0
GH_REJECT_UNBALANCED_GRAPHQL=true \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/1' \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-skip.txt" 123
rm -rf "${TEST_DIR:?}/lib"
if grep -q '==> Trusted PR-visible AI review found for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-skip.txt" \
  && grep -q '==> Skipping merge review because \[review.pr_triggered\]\.required=true' "$TEST_DIR/output-pr-triggered-skip.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "1" ]; then
  echo "==> PASS: PR-triggered review can satisfy the merge gate without duplicate LLM review"
else
  echo "FAIL: PR-triggered review did not skip duplicate merge review after preflight" >&2
  cat "$TEST_DIR/output-pr-triggered-skip.txt" >&2
  [ ! -f "$TEST_DIR/preflight-calls" ] || cat "$TEST_DIR/preflight-calls" >&2
  exit 1
fi

echo "==> Test: PR-triggered review rejects a head change after the trusted signal"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/1' \
  GH_HEAD_REF_CHANGE_AFTER=4 \
  GH_HEAD_REF_CHANGED_OID="new-pr-head" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-head-changed.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly accepted a head change after PR-triggered review" >&2
  exit 1
fi
if grep -q 'head changed after the trusted PR-triggered AI review signal' "$TEST_DIR/output-pr-triggered-head-changed.txt" \
  && grep -q 'reviewed head: pr-head-oid' "$TEST_DIR/output-pr-triggered-head-changed.txt" \
  && grep -q 'current head:  new-pr-head' "$TEST_DIR/output-pr-triggered-head-changed.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: head changes after PR-triggered review force a rerun"
else
  echo "FAIL: head change after PR-triggered review should fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-head-changed.txt" >&2
  exit 1
fi

echo "==> Test: PR-triggered review policy is read from refreshed trusted base config"
reset_case_files
install_toml_parser_fixture
cat >"$TEST_DIR/stale-trusted-base-review.toml" <<'EOF'
[review.pr_triggered]
required = false
EOF
cat >"$TEST_DIR/fresh-trusted-base-review.toml" <<'EOF'
[review.pr_triggered]
required = true
provider = "github-codex"
timeout_sec = 0
poll_sec = 0
trusted_review_authors = ["chatgpt-codex-connector", "chatgpt-codex-connector[bot]"]
trusted_reaction_author = "chatgpt-codex-connector[bot]"
skip_merge_review = true
EOF
cat >"$DEFAULT_FAKE_WORKTREE/.touchstone-review.toml" <<'EOF'
[review.pr_triggered]
required = false
EOF
if GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE="$TEST_DIR/stale-trusted-base-review.toml" \
  GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE="$TEST_DIR/fresh-trusted-base-review.toml" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-trusted-base.txt" 123; then
  echo "FAIL: merge-pr.sh honored stale trusted config instead of refreshed trusted base config" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-trusted-base.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: PR-triggered policy is loaded from refreshed trusted base config"
else
  echo "FAIL: refreshed trusted base config should control PR-triggered policy" >&2
  cat "$TEST_DIR/output-pr-triggered-trusted-base.txt" >&2
  exit 1
fi

echo "==> Test: PR-triggered review timeout fails closed before merge review"
reset_case_files
write_pr_triggered_config true 0 0
if run_merge_pr "$TEST_DIR/output-pr-triggered-timeout.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly succeeded without a trusted PR-triggered review" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-timeout.txt" \
  && grep -q "@codex review" "$TEST_DIR/output-pr-triggered-timeout.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: missing PR-triggered review fails closed with actionable guidance"
else
  echo "FAIL: missing PR-triggered review should fail before local review or merge" >&2
  cat "$TEST_DIR/output-pr-triggered-timeout.txt" >&2
  exit 1
fi

echo "==> Test: stale PR-triggered +1 reaction is ignored"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REACTIONS=$'chatgpt-codex-connector[bot]\t+1\t1970-01-01T00:00:00Z' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-stale-reaction.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly accepted a stale PR-triggered reaction" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-stale-reaction.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: stale PR-triggered reaction does not satisfy the merge gate"
else
  echo "FAIL: stale PR-triggered reaction should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-stale-reaction.txt" >&2
  exit 1
fi

echo "==> Test: fresh PR-triggered +1 reaction is accepted"
reset_case_files
write_pr_triggered_config true 0 0
GH_REACTIONS=$'chatgpt-codex-connector[bot]\t+1\t9999-01-01T00:00:00Z' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-fresh-reaction.txt" 123
if grep -q 'fresh +1 reaction by @chatgpt-codex-connector\[bot\]' "$TEST_DIR/output-pr-triggered-fresh-reaction.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: fresh PR-triggered reaction can satisfy the merge gate"
else
  echo "FAIL: fresh PR-triggered reaction should satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-fresh-reaction.txt" >&2
  exit 1
fi

echo "==> Test: prior clean PR-triggered Codex issue comment is accepted"
reset_case_files
write_pr_triggered_config true 0 0
GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/1\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-clean-comment.txt" 123
if grep -q 'clean Codex review comment by @chatgpt-codex-connector' "$TEST_DIR/output-pr-triggered-clean-comment.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: prior clean Codex issue comment can satisfy the merge gate"
else
  echo "FAIL: prior clean Codex issue comment should satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-clean-comment.txt" >&2
  exit 1
fi

echo "==> Test: non-clean PR-triggered Codex issue comment is rejected"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/2\tCodex Review: Found major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-non-clean-comment.txt" 123; then
  echo "FAIL: non-clean Codex issue comment unexpectedly satisfied the merge gate" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-non-clean-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: non-clean Codex issue comment does not satisfy the merge gate"
else
  echo "FAIL: non-clean Codex issue comment should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-non-clean-comment.txt" >&2
  exit 1
fi

echo "==> Test: delayed PR-triggered review is polled before merge"
reset_case_files
write_pr_triggered_config true 2 1
GH_TRUSTED_REVIEWS_SECOND=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/2' \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-delayed.txt" 123
if grep -q 'Trusted PR-visible AI review found for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-delayed.txt" \
  && [ "$(cat "$TEST_DIR/gh-reviews-graphql-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: delayed PR-triggered review is polled until available"
else
  echo "FAIL: delayed PR-triggered review should be polled and accepted" >&2
  cat "$TEST_DIR/output-pr-triggered-delayed.txt" >&2
  [ ! -f "$TEST_DIR/gh-reviews-graphql-calls" ] || cat "$TEST_DIR/gh-reviews-graphql-calls" >&2
  exit 1
fi

echo "==> Test: transient PR-triggered review lookup failure does not abort polling"
reset_case_files
write_pr_triggered_config true 2 1
GH_REVIEWS_GRAPHQL_FAIL_FIRST=true \
  GH_TRUSTED_REVIEWS_SECOND=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/3' \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-transient.txt" 123
if grep -q 'Trusted PR-visible AI review found for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-transient.txt" \
  && [ "$(cat "$TEST_DIR/gh-reviews-graphql-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: transient review lookup failure is retried within the wait window"
else
  echo "FAIL: transient review lookup failure should not abort polling" >&2
  cat "$TEST_DIR/output-pr-triggered-transient.txt" >&2
  [ ! -f "$TEST_DIR/gh-reviews-graphql-calls" ] || cat "$TEST_DIR/gh-reviews-graphql-calls" >&2
  exit 1
fi

echo "==> Test: review-fix push requires a fresh PR-triggered review on the new head"
reset_case_files
install_preflight_counter_fixture
write_pr_triggered_config false 2 1
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/4' \
  GH_TRUSTED_REVIEWS_SECOND=$'chatgpt-codex-connector[bot]\treview-fixed-head\tCOMMENTED\t2026-06-23T00:01:00Z\thttps://example.test/review/5' \
  CODEX_REVIEW_MUTATE_HEAD="review-fixed-head" \
  GH_EXPECT_MERGE_HEAD="review-fixed-head" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-review-fix.txt" 123
rm -rf "${TEST_DIR:?}/lib"
if grep -q '==> Merge review changed HEAD:' "$TEST_DIR/output-pr-triggered-review-fix.txt" \
  && grep -q '==> Waiting for trusted PR-visible AI review for PR #123 (after review fixes)' "$TEST_DIR/output-pr-triggered-review-fix.txt" \
  && grep -q '^review-fixed-head$' "$TEST_DIR/gh-merge-head" \
  && grep -q '^review-fixed-head$' "$TEST_DIR/git-push-head" \
  && grep -q '^CODEX_REVIEW_MODE=fix$' "$TEST_DIR/codex-review.log" \
  && [ "$(cat "$TEST_DIR/gh-reviews-graphql-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "2" ]; then
  echo "==> PASS: review-fix commits require a PR-visible re-review before merge"
else
  echo "FAIL: review-fix commit should require PR-triggered re-review on the new head" >&2
  cat "$TEST_DIR/output-pr-triggered-review-fix.txt" >&2
  [ ! -f "$TEST_DIR/preflight-calls" ] || cat "$TEST_DIR/preflight-calls" >&2
  [ ! -f "$TEST_DIR/gh-reviews-graphql-calls" ] || cat "$TEST_DIR/gh-reviews-graphql-calls" >&2
  exit 1
fi

echo "==> Test: review fix commits are postflighted, pushed, and merged by exact head"
reset_case_files
mkdir -p "$TEST_DIR/lib"
cat >"$TEST_DIR/lib/preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

touchstone_preflight_main_sanitized() {
  printf '%s\n' "$*" >> "$PREFLIGHT_CALLS_FILE"
}

touchstone_preflight_main() {
  touchstone_preflight_main_sanitized "$@"
}
EOF
CODEX_REVIEW_MUTATE_HEAD="review-fixed-head" \
  GH_EXPECT_MERGE_HEAD="review-fixed-head" \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-review-fix.txt" 123
rm -rf "${TEST_DIR:?}/lib"
if grep -q '==> Merge review changed HEAD:' "$TEST_DIR/output-review-fix.txt" \
  && grep -q '==> Running deterministic postflight after review fixes' "$TEST_DIR/output-review-fix.txt" \
  && grep -q '==> Pushing review fix commit(s) to PR branch feature/test' "$TEST_DIR/output-review-fix.txt" \
  && grep -q '^review-fixed-head$' "$TEST_DIR/git-push-head" \
  && grep -q '^review-fixed-head$' "$TEST_DIR/gh-merge-head" \
  && [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "2" ]; then
  echo "==> PASS: review fix loop pushes the postflighted head before merge"
else
  echo "FAIL: review fix commits were not postflighted/pushed/merged correctly" >&2
  cat "$TEST_DIR/output-review-fix.txt" >&2
  [ ! -f "$TEST_DIR/preflight-calls" ] || cat "$TEST_DIR/preflight-calls" >&2
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

echo "==> Test: draft PR blocks before review"
reset_case_files
if GH_IS_DRAFT=true run_merge_pr "$TEST_DIR/output-draft-feedback.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged a draft PR" >&2
  exit 1
fi
if grep -q 'is still a draft; refusing to merge' "$TEST_DIR/output-draft-feedback.txt" \
  && grep -q 'Mark it ready for review' "$TEST_DIR/output-draft-feedback.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: draft PR blocks before review"
else
  echo "FAIL: draft PR should stop before review/merge" >&2
  cat "$TEST_DIR/output-draft-feedback.txt" >&2
  exit 1
fi

echo "==> Test: draft-state inspection failure fails closed before review"
reset_case_files
if GH_PR_VIEW_FAIL_FIELD=isDraft run_merge_pr "$TEST_DIR/output-draft-state-fail.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged when draft-state inspection failed" >&2
  exit 1
fi
if grep -q 'Could not inspect draft state for PR #123' "$TEST_DIR/output-draft-state-fail.txt" \
  && grep -q 'Refusing to merge without draft-state confirmation' "$TEST_DIR/output-draft-state-fail.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: draft-state inspection failure fails closed before review"
else
  echo "FAIL: draft-state inspection failure should stop before review/merge" >&2
  cat "$TEST_DIR/output-draft-state-fail.txt" >&2
  exit 1
fi

echo "==> Test: requested-changes review decision blocks before review"
reset_case_files
if GH_REVIEW_DECISION=CHANGES_REQUESTED run_merge_pr "$TEST_DIR/output-requested-changes.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged with requested changes" >&2
  exit 1
fi
if grep -q 'active CHANGES_REQUESTED review decision' "$TEST_DIR/output-requested-changes.txt" \
  && grep -q 'Address the requested changes' "$TEST_DIR/output-requested-changes.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: requested-changes review decision blocks before review"
else
  echo "FAIL: requested changes should stop before review/merge" >&2
  cat "$TEST_DIR/output-requested-changes.txt" >&2
  exit 1
fi

echo "==> Test: review-decision inspection failure fails closed before review"
reset_case_files
if GH_PR_VIEW_FAIL_FIELD=reviewDecision run_merge_pr "$TEST_DIR/output-review-decision-fail.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged when review-decision inspection failed" >&2
  exit 1
fi
if grep -q 'Could not inspect review decision for PR #123' "$TEST_DIR/output-review-decision-fail.txt" \
  && grep -q 'Refusing to merge without review-decision confirmation' "$TEST_DIR/output-review-decision-fail.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: review-decision inspection failure fails closed before review"
else
  echo "FAIL: review-decision inspection failure should stop before review/merge" >&2
  cat "$TEST_DIR/output-review-decision-fail.txt" >&2
  exit 1
fi

echo "==> Test: unresolved review threads block before review"
reset_case_files
if GH_UNRESOLVED_THREADS=$'thread-1\tscripts/merge-pr.sh\t123\tfalse\treviewer\thttps://example.test/thread/1\tPlease fix the PR feedback gate.' \
  run_merge_pr "$TEST_DIR/output-unresolved-thread.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged with unresolved review threads" >&2
  exit 1
fi
if grep -q 'has unresolved review thread(s)' "$TEST_DIR/output-unresolved-thread.txt" \
  && grep -q 'scripts/merge-pr.sh:123 by @reviewer' "$TEST_DIR/output-unresolved-thread.txt" \
  && grep -q 'https://example.test/thread/1' "$TEST_DIR/output-unresolved-thread.txt" \
  && grep -q 'Resolve or explicitly answer every actionable thread' "$TEST_DIR/output-unresolved-thread.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: unresolved review threads block before review"
else
  echo "FAIL: unresolved review threads should stop before review/merge" >&2
  cat "$TEST_DIR/output-unresolved-thread.txt" >&2
  exit 1
fi

echo "==> Test: PR feedback thread inspection failure fails closed"
reset_case_files
if GH_GRAPHQL_FAIL=true run_merge_pr "$TEST_DIR/output-graphql-fail.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged when review thread inspection failed" >&2
  exit 1
fi
if grep -q 'Could not inspect PR #123 review threads via GitHub GraphQL' "$TEST_DIR/output-graphql-fail.txt" \
  && grep -q 'Refusing to merge without thread-level review state' "$TEST_DIR/output-graphql-fail.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: PR feedback inspection failure fails closed"
else
  echo "FAIL: GraphQL inspection failure should stop before review/merge" >&2
  cat "$TEST_DIR/output-graphql-fail.txt" >&2
  exit 1
fi

echo "==> Test: post-review head inspection failure fails closed before merge"
reset_case_files
if GH_HEAD_REF_FAIL_AFTER=2 run_merge_pr "$TEST_DIR/output-post-review-head-fail.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged when post-review head inspection failed" >&2
  exit 1
fi
if grep -q 'Checking PR-visible review feedback for PR #123 (after merge review)' "$TEST_DIR/output-post-review-head-fail.txt" \
  && grep -q 'Could not inspect PR #123 head commit' "$TEST_DIR/output-post-review-head-fail.txt" \
  && grep -q 'Refusing to merge without exact-head confirmation' "$TEST_DIR/output-post-review-head-fail.txt" \
  && [ -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: post-review head inspection failure fails closed before merge"
else
  echo "FAIL: post-review head inspection failure should stop after review but before merge" >&2
  cat "$TEST_DIR/output-post-review-head-fail.txt" >&2
  exit 1
fi

echo "==> Test: post-review unresolved thread blocks exact-head merge"
reset_case_files
if GH_UNRESOLVED_THREADS_SECOND=$'thread-2\tREADME.md\t44\tfalse\treviewer\thttps://example.test/thread/2\tNew feedback after review.' \
  run_merge_pr "$TEST_DIR/output-post-review-thread.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged after post-review thread appeared" >&2
  exit 1
fi
if grep -q 'Checking PR-visible review feedback for PR #123 (before merge review)' "$TEST_DIR/output-post-review-thread.txt" \
  && grep -q 'Checking PR-visible review feedback for PR #123 (after merge review)' "$TEST_DIR/output-post-review-thread.txt" \
  && grep -q 'README.md:44 by @reviewer' "$TEST_DIR/output-post-review-thread.txt" \
  && grep -q 'New feedback after review' "$TEST_DIR/output-post-review-thread.txt" \
  && [ -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: post-review unresolved thread blocks exact-head merge"
else
  echo "FAIL: post-review unresolved thread should stop after review but before merge" >&2
  cat "$TEST_DIR/output-post-review-thread.txt" >&2
  exit 1
fi

echo "==> Test: provider outage review failure prints exact retry command"
install_preflight_counter_fixture
reset_case_files
: >"$TEST_DIR/preflight-calls"
if CODEX_REVIEW_EXIT=1 \
  CODEX_REVIEW_STUB_SUMMARY='{"reviewer":"Conductor","provider":"gemini","findings":0,"fallback_attempted":true,"fallback_primary_provider":"gemini","fallback_retry_provider":"","fallback_excluded_providers":"gemini","fallback_reason":"timeout after 60s","exit_reason":"timeout"}' \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-provider-outage.txt" 123; then
  echo "FAIL: provider outage fixture should fail closed" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if grep -q 'No concrete review findings were reported; this is a provider/infrastructure outage path' "$TEST_DIR/output-provider-outage.txt" \
  && grep -q 'concrete findings: 0' "$TEST_DIR/output-provider-outage.txt" \
  && grep -q 'failed/stalled provider(s): gemini' "$TEST_DIR/output-provider-outage.txt" \
  && grep -q 'retry command: TOUCHSTONE_CONDUCTOR_WITH=openrouter bash scripts/merge-pr.sh 123' "$TEST_DIR/output-provider-outage.txt" \
  && grep -q 'alternate route: TOUCHSTONE_CONDUCTOR_WITH=<configured-hosted-provider> bash scripts/merge-pr.sh 123' "$TEST_DIR/output-provider-outage.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: provider outage path printed exact retry guidance"
else
  echo "FAIL: expected provider outage retry guidance" >&2
  cat "$TEST_DIR/output-provider-outage.txt" >&2
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
LOCAL_DELETE_MAIN_WORKTREE="$TEST_DIR/touchstone-main-worktree"
LOCAL_DELETE_FEATURE_WORKTREE="$TEST_DIR/touchstone-feature-worktree"
mkdir -p "$LOCAL_DELETE_MAIN_WORKTREE" "$LOCAL_DELETE_FEATURE_WORKTREE"
TEST_CURRENT_WORKTREE="$LOCAL_DELETE_FEATURE_WORKTREE"
GIT_WORKTREE_LIST="$(
  cat <<EOF
worktree $LOCAL_DELETE_MAIN_WORKTREE
HEAD main-oid
branch refs/heads/main

worktree $LOCAL_DELETE_FEATURE_WORKTREE
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

echo "==> Test: primary checkout is not treated as removable feature worktree"
reset_case_files
PRIMARY_WORKTREE="$TEST_DIR/primary-checkout"
mkdir -p "$PRIMARY_WORKTREE"
TEST_CURRENT_WORKTREE="$PRIMARY_WORKTREE"
run_merge_pr "$TEST_DIR/output-primary-checkout.txt" 123
if grep -q "==> Local branch 'feature/test' deleted." "$TEST_DIR/output-primary-checkout.txt" \
  && ! grep -q "No separate default-branch worktree is available" "$TEST_DIR/output-primary-checkout.txt" \
  && ! grep -q "Removing merged PR worktree" "$TEST_DIR/output-primary-checkout.txt" \
  && [ ! -f "$TEST_DIR/git-worktree-remove" ]; then
  echo "==> PASS: primary checkout was left in place without worktree cleanup warning"
else
  echo "FAIL: primary checkout should not be treated as removable feature worktree" >&2
  cat "$TEST_DIR/output-primary-checkout.txt" >&2
  exit 1
fi

echo "==> Test: merged feature worktree is removed from sibling default worktree"
reset_case_files
MERGE_MAIN_WORKTREE="$TEST_DIR/merge-main-worktree"
MERGE_FEATURE_WORKTREE="$TEST_DIR/merge-feature-worktree"
mkdir -p "$MERGE_MAIN_WORKTREE" "$MERGE_FEATURE_WORKTREE"
TEST_CURRENT_WORKTREE="$MERGE_FEATURE_WORKTREE"
GIT_WORKTREE_LIST="$(
  cat <<EOF
worktree $MERGE_MAIN_WORKTREE
HEAD main-oid
branch refs/heads/main

worktree $MERGE_FEATURE_WORKTREE
HEAD feature-oid
branch refs/heads/feature/test

EOF
)"
run_merge_pr "$TEST_DIR/output-worktree-remove.txt" 123
if grep -q "==> Removing merged PR worktree '$MERGE_FEATURE_WORKTREE'" "$TEST_DIR/output-worktree-remove.txt" \
  && grep -q "==> Merged PR worktree removed." "$TEST_DIR/output-worktree-remove.txt" \
  && [ "$(cat "$TEST_DIR/git-worktree-remove")" = "$MERGE_FEATURE_WORKTREE" ]; then
  echo "==> PASS: merged feature worktree removed after verified merge"
else
  echo "FAIL: merged feature worktree should be removed from sibling default worktree" >&2
  cat "$TEST_DIR/output-worktree-remove.txt" >&2
  exit 1
fi

echo "==> Test: dirty merged feature worktree is preserved with warning"
reset_case_files
DIRTY_MAIN_WORKTREE="$TEST_DIR/dirty-main-worktree"
DIRTY_FEATURE_WORKTREE="$TEST_DIR/dirty-feature-worktree"
mkdir -p "$DIRTY_MAIN_WORKTREE" "$DIRTY_FEATURE_WORKTREE"
TEST_CURRENT_WORKTREE="$DIRTY_FEATURE_WORKTREE"
GIT_WORKTREE_STATUS=' M scratch.txt'
GIT_WORKTREE_LIST="$(
  cat <<EOF
worktree $DIRTY_MAIN_WORKTREE
HEAD main-oid
branch refs/heads/main

worktree $DIRTY_FEATURE_WORKTREE
HEAD feature-oid
branch refs/heads/feature/test

EOF
)"
run_merge_pr "$TEST_DIR/output-worktree-dirty.txt" 123
if grep -q "WARNING: Merged PR worktree '$DIRTY_FEATURE_WORKTREE' has uncommitted changes; leaving it in place." "$TEST_DIR/output-worktree-dirty.txt" \
  && grep -q "cleanup-worktrees.sh --execute" "$TEST_DIR/output-worktree-dirty.txt" \
  && [ ! -f "$TEST_DIR/git-worktree-remove" ]; then
  echo "==> PASS: dirty merged feature worktree was preserved"
else
  echo "FAIL: dirty merged feature worktree should be preserved with cleanup guidance" >&2
  cat "$TEST_DIR/output-worktree-dirty.txt" >&2
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

echo "==> Test: fail-open marker bypass requires explicit allow flag"
reset_case_files
write_fail_open_review_log
if run_merge_pr "$TEST_DIR/output-fail-open-no-flag.txt" 123 --bypass-with-disclosure="fail-open reviewer timeout"; then
  echo "FAIL: fail-open marker bypass without allow flag unexpectedly succeeded" >&2
  exit 1
fi
if grep -q "No prior clean review marker matches branch 'feature/test' at head 'pr-head-oid' and merge base 'base-oid'" "$TEST_DIR/output-fail-open-no-flag.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ] \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: fail-open marker is ignored unless explicitly allowed"
else
  echo "FAIL: fail-open marker without allow flag did not fail safely" >&2
  cat "$TEST_DIR/output-fail-open-no-flag.txt" >&2
  exit 1
fi

echo "==> Test: fail-open marker bypass requires outage disclosure"
reset_case_files
write_fail_open_review_log
if run_merge_pr "$TEST_DIR/output-fail-open-vague.txt" 123 --bypass-with-disclosure="manual override" --allow-fail-open-marker; then
  echo "FAIL: fail-open marker bypass with vague disclosure unexpectedly succeeded" >&2
  exit 1
fi
if grep -q -- '--allow-fail-open-marker requires a disclosure reason' "$TEST_DIR/output-fail-open-vague.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ] \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: fail-open marker bypass rejects vague disclosure"
else
  echo "FAIL: vague fail-open disclosure did not fail safely" >&2
  cat "$TEST_DIR/output-fail-open-vague.txt" >&2
  exit 1
fi

echo "==> Test: fail-open marker bypass requires matching current head"
reset_case_files
write_fail_open_review_log feature/test old-head
if run_merge_pr "$TEST_DIR/output-fail-open-stale.txt" 123 --bypass-with-disclosure="fail-open reviewer infrastructure outage" --allow-fail-open-marker; then
  echo "FAIL: fail-open marker bypass with stale head unexpectedly succeeded" >&2
  exit 1
fi
if grep -q "No recent fail-open review-log marker matches branch 'feature/test' at head 'pr-head-oid'" "$TEST_DIR/output-fail-open-stale.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ] \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: stale fail-open marker rejected"
else
  echo "FAIL: stale fail-open marker did not fail safely" >&2
  cat "$TEST_DIR/output-fail-open-stale.txt" >&2
  exit 1
fi

echo "==> Test: fail-open marker bypass records evidence and audit log"
reset_case_files
write_fail_open_review_log
run_merge_pr "$TEST_DIR/output-fail-open-bypass.txt" 123 --bypass-with-disclosure="fail-open reviewer infrastructure outage; deterministic checks clean" --allow-fail-open-marker
if grep -q 'BYPASSING REVIEWER GATE' "$TEST_DIR/output-fail-open-bypass.txt" \
  && grep -q 'marker: fail-open' "$TEST_DIR/output-fail-open-bypass.txt" \
  && grep -q 'reason: fail-open reviewer infrastructure outage; deterministic checks clean' "$TEST_DIR/output-fail-open-bypass.txt" \
  && grep -q 'Reviewer bypassed via `--bypass-with-disclosure`. Marker: fail-open. Reason: fail-open reviewer infrastructure outage; deterministic checks clean' "$TEST_DIR/gh-comment" \
  && grep -q 'Fail-open evidence: timestamp=' "$TEST_DIR/gh-comment" \
  && grep -q 'reason=FAIL_OPEN_TIMEOUT' "$TEST_DIR/gh-comment" \
  && grep -q '^Reviewer-bypass: fail-open reviewer infrastructure outage; deterministic checks clean$' "$TEST_DIR/gh-merge-body" \
  && grep -q $'\treview-bypass\t' "$TEST_DIR/touchstone-review-log" \
  && grep -q 'marker=fail-open' "$TEST_DIR/touchstone-review-log" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: fail-open bypass is disclosed, audited, and merged"
else
  echo "FAIL: fail-open bypass path did not disclose and merge as expected" >&2
  cat "$TEST_DIR/output-fail-open-bypass.txt" >&2
  exit 1
fi

echo "==> Test: bypass after clean marker records disclosure and trailer"
reset_case_files
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=base-oid\n' >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
run_merge_pr "$TEST_DIR/output-bypass.txt" 123 --bypass-with-disclosure="reviewer timed out after prior clean review"
if grep -q 'BYPASSING REVIEWER GATE' "$TEST_DIR/output-bypass.txt" \
  && grep -q 'marker: clean-review' "$TEST_DIR/output-bypass.txt" \
  && grep -q 'reason: reviewer timed out after prior clean review' "$TEST_DIR/output-bypass.txt" \
  && grep -q 'Reviewer bypassed via `--bypass-with-disclosure`. Marker: clean-review. Reason: reviewer timed out after prior clean review' "$TEST_DIR/gh-comment" \
  && grep -q '^Reviewer-bypass: reviewer timed out after prior clean review$' "$TEST_DIR/gh-merge-body" \
  && grep -q $'\treview-bypass\t' "$TEST_DIR/touchstone-review-log" \
  && grep -q 'marker=clean-review' "$TEST_DIR/touchstone-review-log" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: bypass is disclosed and merged with trailer"
else
  echo "FAIL: bypass path did not disclose and merge as expected" >&2
  cat "$TEST_DIR/output-bypass.txt" >&2
  exit 1
fi

echo "==> Test: bypass skips unavailable PR-triggered reviewer with clean marker"
reset_case_files
write_pr_triggered_config true 0 0
mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=base-oid\n' >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean"
run_merge_pr "$TEST_DIR/output-bypass-pr-triggered.txt" 123 --bypass-with-disclosure="reviewer unavailable after prior clean review"
if grep -q 'BYPASSING REVIEWER GATE' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q 'marker: clean-review' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q 'reason: reviewer unavailable after prior clean review' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q 'Reviewer bypassed via `--bypass-with-disclosure`. Marker: clean-review. Reason: reviewer unavailable after prior clean review' "$TEST_DIR/gh-comment" \
  && grep -q '^Reviewer-bypass: reviewer unavailable after prior clean review$' "$TEST_DIR/gh-merge-body" \
  && ! grep -q 'Timed out waiting for trusted PR-visible AI review' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ ! -f "$TEST_DIR/codex-review.log" ]; then
  echo "==> PASS: bypass can skip unavailable PR-triggered reviewer after clean marker"
else
  echo "FAIL: bypass should not wait on unavailable PR-triggered reviewer" >&2
  cat "$TEST_DIR/output-bypass-pr-triggered.txt" >&2
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
