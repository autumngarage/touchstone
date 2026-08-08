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
chmod +x "$MERGE_SCRIPT_DIR/merge-pr.sh"
# The issue #658 substitution executes the claim verifier from the TRUSTED
# BASE revision via `git show`; the fake git serves that content (keyed by
# CLAIM_DIRECT_EXIT / GIT_CLAIM_CHECKER_SHOW_FAIL), so no PR-head copy is
# installed here — running one would mask the self-weakening hazard.

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

gh_field_value() {
  local field_name="$1"
  shift
  local previous="" arg

  for arg in "$@"; do
    if [ "$previous" = "-f" ] && [[ "$arg" = "$field_name="* ]]; then
      printf '%s' "${arg#*=}"
      return 0
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
  "api user")
    echo "${GH_AUTHENTICATED_ACTOR:-henrymodisett}"
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
      baseRefName) echo "${GH_BASE_REF_NAME:-main}" ;;
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
        if [ -f "${GH_REVISION_CHANGE_AFTER_TRIGGER_FILE:-/dev/null/never}" ]; then
          echo "${GH_HEAD_REF_AFTER_TRIGGER:-${GH_PR_HEAD_OID:-pr-head-oid}}"
        elif [ -n "${GH_HEAD_REF_CHANGE_AFTER:-}" ] && [ "$head_ref_call_count" -ge "$GH_HEAD_REF_CHANGE_AFTER" ]; then
          echo "${GH_HEAD_REF_CHANGED_OID:-changed-pr-head}"
        elif [ -f "${GH_HEAD_REF_FILE:-/dev/null/never}" ]; then
          cat "$GH_HEAD_REF_FILE"
        else
          echo "${GH_PR_HEAD_OID:-pr-head-oid}"
        fi
        ;;
      isDraft) echo "${GH_IS_DRAFT:-false}" ;;
      reviewDecision) echo "${GH_REVIEW_DECISION:-}" ;;
      mergeStateStatus,mergeable)
        merge_state_attempt="$(increment_counter_file "${GH_MERGE_ATTEMPTS_FILE:-}")"
        if [ -n "${GH_MERGE_STATE_IMMEDIATE:-}" ]; then
          echo "$GH_MERGE_STATE_IMMEDIATE"
        elif [ "$merge_state_attempt" -le "${GH_MERGE_STATE_PENDING_ATTEMPTS:-0}" ]; then
          echo "${GH_MERGE_STATE_PENDING_VALUE:-UNSTABLE MERGEABLE}"
        elif [ "$merge_state_attempt" -le "${GH_MERGE_STATE_UNKNOWN_ATTEMPTS:-0}" ]; then
          echo "UNKNOWN UNKNOWN"
        else
          echo "${GH_MERGE_STATE:-CLEAN MERGEABLE}"
        fi
        ;;
      *)
        echo "unexpected gh pr view args: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "pr checks")
    case "$*" in
      *'ne .bucket'*)
        # Outstanding-bucket scan (issue #658). Mirrors real gh semantics:
        # rendering a failing check exits nonzero with EMPTY stderr, while a
        # true inspection failure writes stderr. Substitution must key on
        # stderr, not exit status.
        if [ "${GH_PENDING_CHECKS_FAIL:-false}" = "true" ]; then
          echo "check inspection unavailable" >&2
          exit 1
        fi
        if [ -n "${GH_PENDING_CHECKS:-}" ]; then
          printf '%s\n' "$GH_PENDING_CHECKS"
        fi
        exit 1
        ;;
      *'{{.bucket}}'*)
        # Full bucket listing (issue #593): name TAB bucket per check.
        if [ "${GH_BUCKET_LIST_FAIL:-false}" = "true" ]; then
          echo "bucket listing unavailable" >&2
          exit 1
        fi
        if [ -n "${GH_CHECK_BUCKETS:-}" ]; then
          printf '%s\n' "$GH_CHECK_BUCKETS"
        fi
        exit 0
        ;;
      *)
        if [ -n "${GH_FAILED_CHECKS:-}" ]; then
          printf '%s\n' "$GH_FAILED_CHECKS"
        else
          echo "no failed checks reported on the branch" >&2
          exit 1
        fi
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
    if [ -n "${GH_REVIEW_REQUEST_FILE:-}" ] \
      && printf '%s' "${5:-}" | grep -q 'touchstone:pr-review-request'; then
      printf '%s\n' "${5:-}" >>"$GH_REVIEW_REQUEST_FILE"
    else
      printf '%s\n' "${5:-}" >"$GH_COMMENT_FILE"
    fi
    echo "commented"
    ;;
  "pr merge")
    if [ "${4:-}" = "--disable-auto" ]; then
      printf 'disable-auto\n' >>"$GH_MERGE_ARGS_FILE"
      exit 0
    fi
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
    # GH_MERGE_LEAVES_OPEN=true models a required-checks merge queue: the
    # command is accepted (auto-merge armed) but the PR does not merge.
    if [ -n "${GH_MERGED_MARKER:-}" ] && [ "${GH_MERGE_LEAVES_OPEN:-false}" != "true" ]; then
      touch "$GH_MERGED_MARKER"
    fi
    if [ "${GH_PR_MERGE_FAIL_LOCAL:-false}" = "true" ]; then
      echo "failed to delete local branch feature/test: failed to run git: error: cannot delete branch 'feature/test' used by worktree at '/tmp/touchstone-feature-worktree'" >&2
      exit 1
    fi
    echo "merged"
    ;;
  "api repos/"*)
    case "${2:-}" in
      */actions/jobs/*)
        # Job-level step count (PR #680): mirrors the run-level knob.
        echo "${GH_CLAIM_RUN_REAL_STEPS:-5}"
        ;;
      */actions/runs/*/jobs)
        # Step count for the claim-check run inspection (issue #658):
        # 0 simulates a zero-step infrastructure failure. When the query
        # asks for job IDS (issue #631 annotation walk), emit one job id.
        case "$*" in
          *'.jobs[].id'*) echo "9101" ;;
          *) echo "${GH_CLAIM_RUN_REAL_STEPS:-5}" ;;
        esac
        ;;
      */check-runs/*/annotations)
        # Check-run annotations for zero-step failures (issue #631).
        if [ -n "${GH_CHECK_ANNOTATIONS:-}" ]; then
          printf '%s\n' "$GH_CHECK_ANNOTATIONS"
        fi
        ;;
      */collaborators/*/permission)
        status_creator="${2#*/collaborators/}"
        status_creator="${status_creator%/permission}"
        if [ -z "$status_creator" ]; then
          echo "blank status creator must not be inspected" >&2
          exit 1
        elif [ "$status_creator" = "untrusted-app" ]; then
          echo "read"
        else
          echo "write"
        fi
        ;;
      */pulls/*)
        base_ref_call_count=1
        if [ -n "${GH_BASE_REF_CALLS_FILE:-}" ]; then
          if [ -f "$GH_BASE_REF_CALLS_FILE" ]; then
            base_ref_call_count="$(cat "$GH_BASE_REF_CALLS_FILE" 2>/dev/null || echo 0)"
            base_ref_call_count=$((base_ref_call_count + 1))
          fi
          printf '%s\n' "$base_ref_call_count" >"$GH_BASE_REF_CALLS_FILE"
        fi
        if [ -n "${GH_BASE_REF_FAIL_AFTER:-}" ] && [ "$base_ref_call_count" -ge "$GH_BASE_REF_FAIL_AFTER" ]; then
          echo "pull request base unavailable" >&2
          exit 1
        fi
        if [ -f "${GH_REVISION_CHANGE_AFTER_TRIGGER_FILE:-/dev/null/never}" ]; then
          printf '%s\t%s\n' \
            "${GH_BASE_REF_NAME_AFTER_TRIGGER:-${GH_BASE_REF_NAME:-main}}" \
            "${GH_BASE_REF_OID_AFTER_TRIGGER:-${GH_BASE_REF_OID:-base-oid}}"
        elif [ -n "${GH_BASE_REF_CHANGE_AFTER:-}" ] && [ "$base_ref_call_count" -ge "$GH_BASE_REF_CHANGE_AFTER" ]; then
          printf '%s\t%s\n' "${GH_BASE_REF_CHANGED_NAME:-${GH_BASE_REF_NAME:-main}}" "${GH_BASE_REF_CHANGED_OID:-changed-base-oid}"
        else
          printf '%s\t%s\n' "${GH_BASE_REF_NAME:-main}" "${GH_BASE_REF_OID:-base-oid}"
        fi
        ;;
      */commits/*)
        if [[ "$*" = *".commit.committer.date"* ]]; then
          echo "${GH_HEAD_COMMIT_DATE:-2026-07-29T00:00:00Z}"
          exit 0
        fi
        if [ "${GH_COMMENT_COMMIT_RESOLUTION_FAIL:-false}" = "true" ]; then
          echo "reviewed commit is ambiguous or unavailable" >&2
          exit 1
        fi
        echo "${GH_RESOLVED_COMMENT_COMMIT:-${GH_PR_HEAD_OID:-pr-head-oid}}"
        ;;
      *)
        echo "unexpected gh api args: $*" >&2
        exit 1
        ;;
    esac
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
      if [ "${GH_REVIEWS_GRAPHQL_FAIL:-false}" = "true" ]; then
        echo "reviews graphql unavailable" >&2
        exit 1
      fi
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
      */commits/*/check-runs*)
        # Commit check-run rollup (issue #593): name TAB status TAB
        # conclusion per run, cancelled predecessors alongside their
        # successful replacements.
        if [ -n "${GH_CHECK_ROLLUP:-}" ]; then
          printf '%s\n' "$GH_CHECK_ROLLUP"
        fi
        ;;
      */statuses | */statuses\?*)
        query_head="${3#*/commits/}"
        query_head="${query_head%%/*}"
        if [[ "${5:-}" = *"touchstone/review-result-clean"* ]]; then
          if [ "${GH_RESULT_LOOKUP_FAIL:-false}" = "true" ]; then
            echo "review result records unavailable" >&2
            exit 1
          fi
          if [ -n "${GH_RESULT_RECORDS:-}" ]; then
            printf '%s\n' "$GH_RESULT_RECORDS"
          fi
          if [ -s "${GH_STATUS_RECORDS_FILE:-/dev/null/never}" ]; then
            while IFS="$(printf '\t')" read -r record_head context _created_at creator description; do
              [ "$record_head" = "$query_head" ] || continue
              [ "$context" = "touchstone/review-result-clean" ] || continue
              printf '%s\t%s\n' "$creator" "$description"
            done <"$GH_STATUS_RECORDS_FILE"
          fi
          exit 0
        fi
        request_lookup_call_count="$(increment_counter_file "${GH_REQUEST_LOOKUP_CALLS_FILE:-}")"
        if [ "${GH_REQUEST_LOOKUP_FAIL:-false}" = "true" ] \
          || { [ "${GH_REQUEST_LOOKUP_FAIL_FIRST:-false}" = "true" ] && [ "$request_lookup_call_count" -eq 1 ]; }; then
          echo "review request records unavailable" >&2
          exit 1
        fi
        if [[ "${5:-}" != *"touchstone/review-request-intent"* ]] \
          || [[ "${5:-}" != *"touchstone/review-request-complete"* ]] \
          || [[ "${5:-}" != *'.state == "success"'* ]] \
          || [[ "${5:-}" != *"creator.login"* ]]; then
          echo "request lookup must filter durable status records" >&2
          exit 1
        fi
        if [ -n "${GH_REQUEST_RECORDS:-}" ] \
          && [ "$query_head" = "${GH_REQUEST_RECORDS_HEAD:-${GH_PR_HEAD_OID:-pr-head-oid}}" ]; then
          printf '%s\n' "$GH_REQUEST_RECORDS"
        fi
        if [ -s "${GH_STATUS_RECORDS_FILE:-/dev/null/never}" ]; then
          while IFS="$(printf '\t')" read -r record_head context created_at creator description; do
            [ "$record_head" = "$query_head" ] || continue
            printf '%s\t%s\t%s\t%s\n' "$context" "$created_at" "$creator" "$description"
          done <"$GH_STATUS_RECORDS_FILE"
        fi
        ;;
      */comments | */comments\?*)
        comments_call_count="$(increment_counter_file "${GH_COMMENTS_CALLS_FILE:-}")"
        if [ "${GH_COMMENTS_FAIL:-false}" = "true" ]; then
          echo "review comments unavailable" >&2
          exit 1
        fi
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
  "api -X")
    if [ "${3:-}" != "POST" ]; then
      echo "unexpected gh api POST args: $*" >&2
      exit 1
    fi
    case "${4:-}" in
      repos/*/issues/*/comments)
        if [ "${5:-}" != "-f" ] || [[ "${6:-}" != body=* ]]; then
          echo "unexpected gh api POST body: $*" >&2
          exit 1
        fi
        printf '%s\n' "${6#body=}" >>"$GH_REVIEW_REQUEST_FILE"
        if [ -n "${GH_REVISION_CHANGE_AFTER_TRIGGER_FILE:-}" ]; then
          touch "$GH_REVISION_CHANGE_AFTER_TRIGGER_FILE"
        fi
        printf '%s\n' "${GH_COMMENT_CREATED_AT:-${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}}"
        ;;
      repos/*/statuses/*)
        status_context="$(gh_field_value context "$@")"
        status_description="$(gh_field_value description "$@")"
        case "$status_context" in
          touchstone/review-request-intent | touchstone/review-request-complete)
            if [[ "$status_description" != pr=*" base="* ]]; then
              echo "unexpected durable review request status: $*" >&2
              exit 1
            fi
            if [ "$status_context" = "touchstone/review-request-intent" ]; then
              status_created_at="${GH_STATUS_INTENT_CREATED_AT:-${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}}"
            else
              status_created_at="${GH_STATUS_COMPLETE_CREATED_AT:-${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}}"
            fi
            ;;
          touchstone/review-result-clean)
            if [ "${GH_RESULT_STATUS_FAIL:-false}" = "true" ]; then
              echo "review result status unavailable" >&2
              exit 1
            fi
            if [[ "$status_description" != v=1\ pr=*" base="*" req="*" result="* ]]; then
              echo "unexpected durable clean-review status: $*" >&2
              exit 1
            fi
            status_created_at="${GH_STATUS_RESULT_CREATED_AT:-2026-06-23T00:00:01Z}"
            ;;
          *)
            echo "unexpected durable review status: $*" >&2
            exit 1
            ;;
        esac
        status_head="${4##*/}"
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$status_head" \
          "$status_context" \
          "$status_created_at" \
          "${GH_STATUS_CREATOR:-${GH_AUTHENTICATED_ACTOR:-henrymodisett}}" \
          "$status_description" >>"$GH_STATUS_RECORDS_FILE"
        printf '%s\n' "$status_created_at"
        ;;
      *)
        echo "unexpected gh api POST target: $*" >&2
        exit 1
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

current_fake_base_oid() {
  local fetch_count=0

  if [ -n "${GIT_FETCH_MAIN_FILE:-}" ] && [ -f "$GIT_FETCH_MAIN_FILE" ]; then
    fetch_count="$(wc -l <"$GIT_FETCH_MAIN_FILE" | tr -d ' ')"
  fi
  if [ -n "${GIT_BASE_CHANGE_AFTER_FETCH:-}" ] && [ "$fetch_count" -ge "$GIT_BASE_CHANGE_AFTER_FETCH" ]; then
    printf '%s' "${GIT_BASE_CHANGED_OID:-changed-base-oid}"
  else
    printf '%s' "${GIT_BASE_OID:-base-oid}"
  fi
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
  check-ref-format\ --branch\ *)
    ;;
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
  rev-parse\ --verify\ origin/*^\{commit\})
    current_fake_base_oid
    printf '\n'
    ;;
  rev-parse\ --verify\ --quiet\ origin/*^\{commit\})
    current_fake_base_oid
    printf '\n'
    ;;
  "rev-parse feature/test")
    if [ -f "$GIT_BRANCH_DELETED_FILE" ]; then
      exit 1
    fi
    printf '%s\n' "${GIT_LOCAL_BRANCH_HEAD:-pr-head-oid}"
    ;;
  cat-file\ -e\ origin/*:.touchstone-review.toml)
    [ -z "${GIT_TRUSTED_LEGACY_CONFIG_FILE:-}" ] || exit 1
    [ -f "$(trusted_touchstone_config_file)" ] || exit 1
    ;;
  cat-file\ -e\ origin/*:.codex-review.toml)
    [ -n "${GIT_TRUSTED_LEGACY_CONFIG_FILE:-}" ] \
      && [ -f "$GIT_TRUSTED_LEGACY_CONFIG_FILE" ] || exit 1
    ;;
  "show-ref --verify --quiet refs/heads/feature/test")
    if [ -f "$GIT_BRANCH_DELETED_FILE" ]; then
      exit 1
    fi
    ;;
  show\ origin/*:.touchstone-review.toml)
    if [ "${GIT_TRUSTED_CONFIG_SHOW_FAIL:-false}" = "true" ]; then
      echo "trusted review config unavailable" >&2
      exit 1
    fi
    cat "$(trusted_touchstone_config_file)"
    ;;
  show\ origin/*:.codex-review.toml)
    cat "$GIT_TRUSTED_LEGACY_CONFIG_FILE"
    ;;
  show\ *:scripts/issue-claim-check.sh)
    # Trusted-base claim verifier for the issue #658 substitution fixtures.
    # CLAIM_DIRECT_BYPASS=true emits the documented [skip-claim-check]
    # bypass line so disclosures can be asserted truthful.
    # The trusted-base read MUST disable replacement objects: a local
    # refs/replace entry for the base SHA would otherwise substitute the
    # executed verifier (touchstone#677). Mirroring real git here makes
    # every substitution fixture a regression for the missing env.
    if [ "${GIT_NO_REPLACE_OBJECTS:-}" != "1" ]; then
      echo "trusted-base read ran with replacement objects enabled (touchstone#677)" >&2
      exit 97
    fi
    if [ "${GIT_CLAIM_CHECKER_SHOW_FAIL:-false}" = "true" ]; then
      echo "trusted claim checker unavailable" >&2
      exit 1
    fi
    if [ "${CLAIM_DIRECT_BYPASS:-false}" = "true" ]; then
      printf '#!/usr/bin/env bash\necho "[skip-claim-check] token found in PR body; bypassing issue claim check."\nexit 0\n'
    else
      printf '#!/usr/bin/env bash\necho "direct claim verification (trusted-base fake) for PR ${3:-?}"\nexit "${CLAIM_DIRECT_EXIT:-0}"\n'
    fi
    ;;
  cat-file\ -e\ *^\{commit\})
    ;;
  merge-base\ origin/*\ *)
    printf '%s\n' "${GIT_MERGE_BASE_OID:-base-oid}"
    ;;
  fetch\ origin\ +refs/heads/*:refs/remotes/origin/*)
    if [ -n "${GIT_FETCH_MAIN_FILE:-}" ]; then
      printf 'fetch\n' >>"$GIT_FETCH_MAIN_FILE"
    fi
    echo "fetched main"
    ;;
  status\ --porcelain\ --untracked-files=all\ --*)
    printf '%s' "${GIT_WORKTREE_STATUS:-}"
    ;;
  "status --porcelain" | "status --porcelain --untracked-files=all")
    printf '%s' "${GIT_WORKTREE_STATUS:-}"
    ;;
  "ls-files --others --exclude-standard -z")
    emit_untracked_path "$@"
    ;;
  ls-files\ --others\ --exclude-standard\ -z\ --*)
    emit_untracked_path "$@"
    ;;
  "diff --name-only origin/"*"...HEAD")
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
  rm -f "$TEST_DIR"/output*.txt \
    "$TEST_DIR"/gh-checkout* "$TEST_DIR"/gh-merge-head* \
    "$TEST_DIR"/gh-merge-args* "$TEST_DIR"/gh-merge-body* \
    "$TEST_DIR"/gh-comment* "$TEST_DIR"/gh-review-request* "$TEST_DIR"/gh-status-records* "$TEST_DIR"/git-checkout-main* \
    "$TEST_DIR"/git-detached-default* "$TEST_DIR"/git-branch-deleted* \
    "$TEST_DIR"/git-sibling-pull* "$TEST_DIR"/gh-merged-marker* \
    "$TEST_DIR"/git-review-head* "$TEST_DIR"/git-push-head* \
    "$TEST_DIR"/git-fetch-main* \
    "$TEST_DIR"/gh-head-ref* "$TEST_DIR"/preflight-calls* \
    "$TEST_DIR"/git-worktree-remove* "$TEST_DIR"/touchstone-review-log* \
    "$TEST_DIR"/gh-graphql-calls* "$TEST_DIR"/gh-head-ref-calls* "$TEST_DIR"/gh-base-ref-calls* \
    "$TEST_DIR"/gh-reviews-graphql-calls* "$TEST_DIR"/gh-reactions-calls* \
    "$TEST_DIR"/gh-comments-calls* "$TEST_DIR"/gh-request-lookup-calls*
  rm -f "$TEST_DIR/merge-events.ndjson"
  rm -f "$TEST_DIR/gh-merge-attempts"
  rm -f "$TEST_DIR/revision-changed-after-trigger"
  rm -rf "$GIT_PATH_ROOT"
  rm -rf "$DEFAULT_FAKE_WORKTREE"
  mkdir -p "$GIT_PATH_ROOT"
  mkdir -p "$DEFAULT_FAKE_WORKTREE"
  unset GIT_WORKTREE_LIST
  unset GIT_SIBLING_PULL_FAIL
  unset TEST_CURRENT_WORKTREE
  unset GH_PR_MERGE_FAIL_LOCAL
  unset GH_MERGE_STATE
  unset GH_MERGE_STATE_IMMEDIATE
  unset GH_MERGE_STATE_PENDING_ATTEMPTS
  unset GH_MERGE_STATE_PENDING_VALUE
  unset GH_MERGE_STATE_UNKNOWN_ATTEMPTS
  unset GH_FAILED_CHECKS
  unset GH_REPO_FULL_NAME
  unset GH_PR_VIEW_FAIL_FIELD
  unset GH_HEAD_REF_FAIL_AFTER
  unset GH_HEAD_REF_CHANGE_AFTER
  unset GH_HEAD_REF_CHANGED_OID
  unset GH_HEAD_REF_AFTER_TRIGGER
  unset GH_BASE_REF_OID
  unset GH_BASE_REF_NAME
  unset GH_BASE_REF_FAIL_AFTER
  unset GH_BASE_REF_CHANGE_AFTER
  unset GH_BASE_REF_CHANGED_NAME
  unset GH_BASE_REF_CHANGED_OID
  unset GH_BASE_REF_NAME_AFTER_TRIGGER
  unset GH_BASE_REF_OID_AFTER_TRIGGER
  unset GH_REVISION_CHANGE_AFTER_TRIGGER_FILE
  unset GH_IS_DRAFT
  unset GH_REVIEW_DECISION
  unset GH_UNRESOLVED_THREADS
  unset GH_UNRESOLVED_THREADS_SECOND
  unset GH_GRAPHQL_FAIL
  unset GH_REJECT_UNBALANCED_GRAPHQL
  unset GH_TRUSTED_REVIEWS
  unset GH_TRUSTED_REVIEWS_SECOND
  unset GH_REVIEWS_GRAPHQL_FAIL
  unset GH_REVIEWS_GRAPHQL_FAIL_FIRST
  unset GH_REACTIONS
  unset GH_REACTIONS_SECOND
  unset GH_ISSUE_COMMENTS
  unset GH_ISSUE_COMMENTS_SECOND
  unset GH_EXISTING_REQUEST_BODY
  unset GH_EXISTING_REQUEST_EDITED
  unset GH_EXISTING_REQUEST_TIMESTAMP
  unset GH_REQUEST_RECORDS
  unset GH_REQUEST_CREATED_AT
  unset GH_STATUS_INTENT_CREATED_AT
  unset GH_STATUS_COMPLETE_CREATED_AT
  unset GH_STATUS_RESULT_CREATED_AT
  unset GH_RESULT_STATUS_FAIL
  unset GH_RESULT_LOOKUP_FAIL
  unset GH_RESULT_RECORDS
  unset GH_STATUS_CREATOR
  unset GH_AUTHENTICATED_ACTOR
  unset GH_HEAD_COMMIT_DATE
  unset GH_COMMENT_CREATED_AT
  unset GH_REQUEST_LOOKUP_FAIL
  unset GH_REQUEST_LOOKUP_FAIL_FIRST
  unset GH_COMMENTS_FAIL
  unset GH_COMMENT_COMMIT_RESOLUTION_FAIL
  unset GH_RESOLVED_COMMENT_COMMIT
  unset MERGE_PR_SLEEP_OVERRIDE
  unset GIT_LOCAL_BRANCH_HEAD
  unset GH_EXPECT_MERGE_HEAD
  unset GH_PR_HEAD_OID
  unset GIT_BASE_OID
  unset GIT_BASE_CHANGE_AFTER_FETCH
  unset GIT_BASE_CHANGED_OID
  unset GIT_MERGE_BASE_OID
  unset GIT_CHANGED_PATHS
  unset GIT_WORKTREE_DIFF
  unset GIT_INDEX_DIFF
  unset GIT_UNTRACKED_PATH
  unset GIT_REQUIRE_ROOT_FOR_UNTRACKED
  unset GIT_WORKTREE_STATUS
  unset GIT_WORKTREE_REMOVE_FAIL
  unset GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE
  unset GIT_TRUSTED_LEGACY_CONFIG_FILE
  unset GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE
  unset GIT_TRUSTED_CONFIG_SHOW_FAIL
  unset SHELLCHECK_VERSION_LINE
  unset TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS
  unset TOUCHSTONE_PR_TRIGGERED_REVIEW_REQUEST_COUNT
}

run_merge_pr() {
  local output_file="$1"
  local base_ref_name="${GH_BASE_REF_NAME:-main}"
  local request_created_at="${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}"
  shift
  mkdir -p "$TEST_DIR/lib"
  cp "$TOUCHSTONE_ROOT/lib/events.sh" "$TEST_DIR/lib/events.sh"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GIT_PATH_ROOT="$GIT_PATH_ROOT" \
    GH_CHECKOUT_FILE="$TEST_DIR/gh-checkout" \
    GH_MERGE_HEAD_FILE="$TEST_DIR/gh-merge-head" \
    GH_MERGE_ARGS_FILE="$TEST_DIR/gh-merge-args" \
    GH_MERGE_BODY_FILE="$TEST_DIR/gh-merge-body" \
    GH_COMMENT_FILE="$TEST_DIR/gh-comment" \
    GH_REVIEW_REQUEST_FILE="$TEST_DIR/gh-review-request" \
    GH_STATUS_RECORDS_FILE="$TEST_DIR/gh-status-records" \
    GH_HEAD_REF_FILE="$TEST_DIR/gh-head-ref" \
    GH_PR_HEAD_OID="${GH_PR_HEAD_OID:-pr-head-oid}" \
    GH_MERGED_MARKER="$TEST_DIR/gh-merged-marker" \
    GH_EXPECT_MERGE_HEAD="${GH_EXPECT_MERGE_HEAD:-pr-head-oid}" \
    GH_PR_MERGE_FAIL_LOCAL="${GH_PR_MERGE_FAIL_LOCAL:-false}" \
    GH_MERGE_STATE="${GH_MERGE_STATE:-CLEAN MERGEABLE}" \
    GH_MERGE_STATE_IMMEDIATE="${GH_MERGE_STATE_IMMEDIATE:-}" \
    GH_MERGE_STATE_PENDING_ATTEMPTS="${GH_MERGE_STATE_PENDING_ATTEMPTS:-0}" \
    GH_MERGE_STATE_PENDING_VALUE="${GH_MERGE_STATE_PENDING_VALUE:-UNSTABLE MERGEABLE}" \
    GH_MERGE_STATE_UNKNOWN_ATTEMPTS="${GH_MERGE_STATE_UNKNOWN_ATTEMPTS:-0}" \
    GH_MERGE_ATTEMPTS_FILE="$TEST_DIR/gh-merge-attempts" \
    GH_FAILED_CHECKS="${GH_FAILED_CHECKS:-}" \
    GH_CLAIM_RUN_REAL_STEPS="${GH_CLAIM_RUN_REAL_STEPS:-5}" \
    GH_PENDING_CHECKS="${GH_PENDING_CHECKS:-}" \
    GH_PENDING_CHECKS_FAIL="${GH_PENDING_CHECKS_FAIL:-false}" \
    GH_CHECK_BUCKETS="${GH_CHECK_BUCKETS:-}" \
    GH_BUCKET_LIST_FAIL="${GH_BUCKET_LIST_FAIL:-false}" \
    GH_CHECK_ROLLUP="${GH_CHECK_ROLLUP:-}" \
    GH_CHECK_ANNOTATIONS="${GH_CHECK_ANNOTATIONS:-}" \
    GH_MERGE_LEAVES_OPEN="${GH_MERGE_LEAVES_OPEN:-false}" \
    GIT_CLAIM_CHECKER_SHOW_FAIL="${GIT_CLAIM_CHECKER_SHOW_FAIL:-false}" \
    CLAIM_DIRECT_BYPASS="${CLAIM_DIRECT_BYPASS:-false}" \
    CLAIM_DIRECT_EXIT="${CLAIM_DIRECT_EXIT:-0}" \
    GH_REPO_FULL_NAME="${GH_REPO_FULL_NAME:-autumngarage/touchstone}" \
    GH_PR_VIEW_FAIL_FIELD="${GH_PR_VIEW_FAIL_FIELD:-}" \
    GH_HEAD_REF_FAIL_AFTER="${GH_HEAD_REF_FAIL_AFTER:-}" \
    GH_HEAD_REF_CHANGE_AFTER="${GH_HEAD_REF_CHANGE_AFTER:-}" \
    GH_HEAD_REF_CHANGED_OID="${GH_HEAD_REF_CHANGED_OID:-changed-pr-head}" \
    GH_HEAD_REF_AFTER_TRIGGER="${GH_HEAD_REF_AFTER_TRIGGER:-}" \
    GH_HEAD_REF_CALLS_FILE="$TEST_DIR/gh-head-ref-calls" \
    GH_BASE_REF_OID="${GH_BASE_REF_OID:-base-oid}" \
    GH_BASE_REF_NAME="$base_ref_name" \
    GH_BASE_REF_FAIL_AFTER="${GH_BASE_REF_FAIL_AFTER:-}" \
    GH_BASE_REF_CHANGE_AFTER="${GH_BASE_REF_CHANGE_AFTER:-}" \
    GH_BASE_REF_CHANGED_NAME="${GH_BASE_REF_CHANGED_NAME:-$base_ref_name}" \
    GH_BASE_REF_CHANGED_OID="${GH_BASE_REF_CHANGED_OID:-changed-base-oid}" \
    GH_BASE_REF_NAME_AFTER_TRIGGER="${GH_BASE_REF_NAME_AFTER_TRIGGER:-}" \
    GH_BASE_REF_OID_AFTER_TRIGGER="${GH_BASE_REF_OID_AFTER_TRIGGER:-}" \
    GH_REVISION_CHANGE_AFTER_TRIGGER_FILE="${GH_REVISION_CHANGE_AFTER_TRIGGER_FILE:-}" \
    GH_BASE_REF_CALLS_FILE="$TEST_DIR/gh-base-ref-calls" \
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
    GH_REVIEWS_GRAPHQL_FAIL="${GH_REVIEWS_GRAPHQL_FAIL:-false}" \
    GH_REVIEWS_GRAPHQL_FAIL_FIRST="${GH_REVIEWS_GRAPHQL_FAIL_FIRST:-false}" \
    GH_REACTIONS="${GH_REACTIONS:-}" \
    GH_REACTIONS_SECOND="${GH_REACTIONS_SECOND:-}" \
    GH_REACTIONS_CALLS_FILE="$TEST_DIR/gh-reactions-calls" \
    GH_ISSUE_COMMENTS="${GH_ISSUE_COMMENTS:-}" \
    GH_ISSUE_COMMENTS_SECOND="${GH_ISSUE_COMMENTS_SECOND:-}" \
    GH_EXISTING_REQUEST_BODY="${GH_EXISTING_REQUEST_BODY:-}" \
    GH_EXISTING_REQUEST_EDITED="${GH_EXISTING_REQUEST_EDITED:-false}" \
    GH_EXISTING_REQUEST_TIMESTAMP="${GH_EXISTING_REQUEST_TIMESTAMP:-1969-01-01T00:00:00Z}" \
    GH_REQUEST_RECORDS="${GH_REQUEST_RECORDS-$(durable_request_records "1969-01-01T00:00:00Z" "${GH_BASE_REF_OID:-base-oid}")}" \
    GH_REQUEST_CREATED_AT="$request_created_at" \
    GH_STATUS_INTENT_CREATED_AT="${GH_STATUS_INTENT_CREATED_AT:-}" \
    GH_STATUS_COMPLETE_CREATED_AT="${GH_STATUS_COMPLETE_CREATED_AT:-}" \
    GH_STATUS_RESULT_CREATED_AT="${GH_STATUS_RESULT_CREATED_AT:-}" \
    GH_RESULT_STATUS_FAIL="${GH_RESULT_STATUS_FAIL:-false}" \
    GH_RESULT_LOOKUP_FAIL="${GH_RESULT_LOOKUP_FAIL:-false}" \
    GH_RESULT_RECORDS="${GH_RESULT_RECORDS:-}" \
    GH_STATUS_CREATOR="${GH_STATUS_CREATOR:-henrymodisett}" \
    GH_AUTHENTICATED_ACTOR="${GH_AUTHENTICATED_ACTOR:-henrymodisett}" \
    GH_HEAD_COMMIT_DATE="${GH_HEAD_COMMIT_DATE:-2026-07-29T00:00:00Z}" \
    GH_COMMENT_CREATED_AT="${GH_COMMENT_CREATED_AT:-$request_created_at}" \
    GH_REQUEST_LOOKUP_FAIL="${GH_REQUEST_LOOKUP_FAIL:-false}" \
    GH_REQUEST_LOOKUP_FAIL_FIRST="${GH_REQUEST_LOOKUP_FAIL_FIRST:-false}" \
    GH_REQUEST_LOOKUP_CALLS_FILE="$TEST_DIR/gh-request-lookup-calls" \
    GH_COMMENTS_FAIL="${GH_COMMENTS_FAIL:-false}" \
    GH_COMMENT_COMMIT_RESOLUTION_FAIL="${GH_COMMENT_COMMIT_RESOLUTION_FAIL:-false}" \
    GH_RESOLVED_COMMENT_COMMIT="${GH_RESOLVED_COMMENT_COMMIT:-}" \
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
    GIT_BASE_CHANGE_AFTER_FETCH="${GIT_BASE_CHANGE_AFTER_FETCH:-}" \
    GIT_BASE_CHANGED_OID="${GIT_BASE_CHANGED_OID:-changed-base-oid}" \
    GIT_MERGE_BASE_OID="${GIT_MERGE_BASE_OID:-base-oid}" \
    GIT_CHANGED_PATHS="${GIT_CHANGED_PATHS:-example.txt}" \
    GIT_WORKTREE_DIFF="${GIT_WORKTREE_DIFF:-}" \
    GIT_INDEX_DIFF="${GIT_INDEX_DIFF:-}" \
    GIT_UNTRACKED_PATH="${GIT_UNTRACKED_PATH:-}" \
    GIT_REQUIRE_ROOT_FOR_UNTRACKED="${GIT_REQUIRE_ROOT_FOR_UNTRACKED:-false}" \
    GIT_WORKTREE_STATUS="${GIT_WORKTREE_STATUS:-}" \
    GIT_WORKTREE_REMOVE_FAIL="${GIT_WORKTREE_REMOVE_FAIL:-false}" \
    GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE="${GIT_TRUSTED_TOUCHSTONE_CONFIG_FILE:-}" \
    GIT_TRUSTED_LEGACY_CONFIG_FILE="${GIT_TRUSTED_LEGACY_CONFIG_FILE:-}" \
    GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE="${GIT_TRUSTED_TOUCHSTONE_CONFIG_FRESH_FILE:-}" \
    GIT_TRUSTED_CONFIG_SHOW_FAIL="${GIT_TRUSTED_CONFIG_SHOW_FAIL:-false}" \
    SHELLCHECK_VERSION_LINE="${SHELLCHECK_VERSION_LINE:-}" \
    GIT_LOCAL_BRANCH_HEAD="${GIT_LOCAL_BRANCH_HEAD:-pr-head-oid}" \
    PREFLIGHT_CALLS_FILE="${PREFLIGHT_CALLS_FILE:-}" \
    TEST_CURRENT_WORKTREE="${TEST_CURRENT_WORKTREE:-$DEFAULT_FAKE_WORKTREE}" \
    TOUCHSTONE_REVIEW_LOG="$TEST_DIR/touchstone-review-log" \
    TOUCHSTONE_EVENTS_FILE="$TEST_DIR/merge-events.ndjson" \
    TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS="${TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS:-24}" \
    TOUCHSTONE_PR_TRIGGERED_REVIEW_REQUEST_COUNT="${TOUCHSTONE_PR_TRIGGERED_REVIEW_REQUEST_COUNT:-0}" \
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
  local required="${4:-true}"
  local request_on_push="${5:-true}"

  install_toml_parser_fixture
  mkdir -p "$DEFAULT_FAKE_WORKTREE"
  cat >"$DEFAULT_FAKE_WORKTREE/.touchstone-review.toml" <<EOF
[review.pr_triggered]
required = $required
provider = "github-codex"
request_on_push = $request_on_push
timeout_sec = $timeout_sec
poll_sec = $poll_sec
trusted_review_authors = ["chatgpt-codex-connector", "chatgpt-codex-connector[bot]"]
skip_merge_review = $skip_merge_review
EOF
}

durable_request_records() {
  local intent_at="$1"
  local base_oid="$2"
  local creator="${3:-henrymodisett}"
  local trigger_at="${4:-$intent_at}"

  printf 'touchstone/review-request-intent\t%s\t%s\tpr=123 base=%s\n' \
    "$intent_at" "$creator" "$base_oid"
  printf 'touchstone/review-request-complete\t%s\t%s\tpr=123 base=%s intent=%s\n' \
    "$trigger_at" "$creator" "$base_oid" "$intent_at trigger=$trigger_at"
}

CLEAN_TRUSTED_REVIEW=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/clean'

write_established_boolean_alias_config() {
  install_toml_parser_fixture
  mkdir -p "$DEFAULT_FAKE_WORKTREE"
  cat >"$DEFAULT_FAKE_WORKTREE/.touchstone-review.toml" <<'EOF'
[review]
preflight_required = on
comment_on_clean = off
comment_findings_history = 1

[review.pr_triggered]
required = false
skip_merge_review = true
EOF
}

echo "==> Test: PR-visible exact-revision review authorizes merge after preflight"
echo "==> Test: PR-triggered review skips duplicate merge review after deterministic preflight"
reset_case_files
install_preflight_counter_fixture
write_pr_triggered_config true 0 0
GH_REJECT_UNBALANCED_GRAPHQL=true \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/1' \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-skip.txt" 123
rm -rf "${TEST_DIR:?}/lib"
if grep -q '==> Trusted PR-visible AI review found for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-skip.txt" \
  && grep -q '==> Trusted PR-visible review covers the current head and base' "$TEST_DIR/output-pr-triggered-skip.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ "$(wc -l <"$TEST_DIR/preflight-calls" | tr -d ' ')" = "1" ]; then
  echo "==> PASS: exact-revision PR review plus deterministic preflight satisfies the merge gate"
else
  echo "FAIL: exact-revision PR review did not satisfy the merge gate after preflight" >&2
  cat "$TEST_DIR/output-pr-triggered-skip.txt" >&2
  [ ! -f "$TEST_DIR/preflight-calls" ] || cat "$TEST_DIR/preflight-calls" >&2
  exit 1
fi

echo "==> Test: ancestor-base retarget cannot reuse head-only trusted review"
reset_case_files
write_pr_triggered_config true 0 0
if GH_BASE_REF_NAME="release/ancestor" \
  GH_BASE_REF_OID="new-ancestor-base" \
  GIT_BASE_OID="new-ancestor-base" \
  GIT_MERGE_BASE_OID="new-ancestor-base" \
  GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "old-base-oid")" \
  GH_REQUEST_CREATED_AT="2026-06-24T00:00:00Z" \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/pre-retarget' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-ancestor-retarget.txt" 123; then
  echo "FAIL: ancestor-base retarget reused a head-only clean result" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has trusted review requests for multiple base revisions' "$TEST_DIR/output-pr-triggered-ancestor-retarget.txt" \
  && grep -q 'current base:  new-ancestor-base' "$TEST_DIR/output-pr-triggered-ancestor-retarget.txt" \
  && grep -q 'prior base(s): old-base-oid' "$TEST_DIR/output-pr-triggered-ancestor-retarget.txt" \
  && [ ! -f "$TEST_DIR/gh-review-request" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: retargeted ancestor base requires a fresh PR head"
else
  echo "FAIL: retargeted ancestor base did not fail closed on ambiguous review evidence" >&2
  cat "$TEST_DIR/output-pr-triggered-ancestor-retarget.txt" >&2
  [ ! -f "$TEST_DIR/gh-review-request" ] || cat "$TEST_DIR/gh-review-request" >&2
  exit 1
fi

echo "==> Test: one head cannot accept review requests for multiple bases"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "old-base-oid")" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-conflicting-base-request.txt" 123; then
  echo "FAIL: merge-pr.sh accepted a review request for a reused head on a new base" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has trusted review requests for multiple base revisions' "$TEST_DIR/output-pr-triggered-conflicting-base-request.txt" \
  && grep -q 'current base:  base-oid' "$TEST_DIR/output-pr-triggered-conflicting-base-request.txt" \
  && grep -q 'prior base(s): old-base-oid' "$TEST_DIR/output-pr-triggered-conflicting-base-request.txt" \
  && [ "$(cat "$TEST_DIR/gh-request-lookup-calls" 2>/dev/null || echo 0)" -eq 1 ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: a base retarget fails immediately and requires a new PR head"
else
  echo "FAIL: conflicting base-bound requests did not fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-conflicting-base-request.txt" >&2
  exit 1
fi

echo "==> Test: legacy head-only review requests require a fresh PR head"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REQUEST_RECORDS="" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-legacy-request.txt" 123; then
  echo "FAIL: merge-pr.sh treated a legacy head-only request as base-bound" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has no durable review-request evidence' "$TEST_DIR/output-pr-triggered-legacy-request.txt" \
  && grep -q 'Run scripts/open-pr.sh against the current head to request review' "$TEST_DIR/output-pr-triggered-legacy-request.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: legacy unbound requests cannot cross the base-binding upgrade"
else
  echo "FAIL: legacy unbound review request did not fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-legacy-request.txt" >&2
  exit 1
fi

echo "==> Test: behind PR head cannot use PR-visible review"
reset_case_files
install_preflight_counter_fixture
write_pr_triggered_config true 0 0
if GH_BASE_REF_OID="new-base-oid" \
  GIT_BASE_OID="new-base-oid" \
  GIT_MERGE_BASE_OID="base-oid" \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/behind' \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-behind-base.txt" 123; then
  echo "FAIL: behind PR head unexpectedly merged" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if grep -q 'trusted PR-visible review does not cover the current base revision' "$TEST_DIR/output-pr-triggered-behind-base.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: behind PR head requires an updated branch and fresh review"
else
  echo "FAIL: behind PR head should fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-behind-base.txt" >&2
  exit 1
fi

echo "==> Test: base advance after PR-visible review requires fresh review"
reset_case_files
install_preflight_counter_fixture
write_pr_triggered_config true 0 0
GH_BASE_REF_CHANGE_AFTER=4 \
  GH_BASE_REF_CHANGED_OID="new-base-oid" \
  GIT_BASE_CHANGE_AFTER_FETCH=2 \
  GIT_BASE_CHANGED_OID="new-base-oid" \
  GIT_MERGE_BASE_OID="base-oid" \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/base-moved' \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-base-moved-before-review.txt" 123 \
  && {
    echo "FAIL: merge-pr.sh accepted PR-visible evidence bound to the prior base" >&2
    exit 1
  }
rm -rf "${TEST_DIR:?}/lib"
if grep -q 'trusted PR-visible review does not cover the current base revision' "$TEST_DIR/output-pr-triggered-base-moved-before-review.txt" \
  && grep -q 'reviewed base: base-oid' "$TEST_DIR/output-pr-triggered-base-moved-before-review.txt" \
  && grep -q 'current base:  new-base-oid' "$TEST_DIR/output-pr-triggered-base-moved-before-review.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: base movement invalidates the prior review"
else
  echo "FAIL: base movement after PR review should require fresh base-bound evidence" >&2
  cat "$TEST_DIR/output-pr-triggered-base-moved-before-review.txt" >&2
  exit 1
fi

echo "==> Test: base advance while polling requires a new base-bound request"
reset_case_files
write_pr_triggered_config true 2 1
if GH_BASE_REF_CHANGE_AFTER=4 \
  GH_BASE_REF_CHANGED_OID="new-base-oid" \
  GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "base-oid")" \
  GH_REQUEST_CREATED_AT="2026-06-24T00:00:00Z" \
  GH_TRUSTED_REVIEWS_SECOND=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/prior-base' \
  MERGE_PR_SLEEP_OVERRIDE=1 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-base-moved-during-poll.txt" 123; then
  echo "FAIL: merge-pr.sh reused the prior base request after the base advanced" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has trusted review requests for multiple base revisions' "$TEST_DIR/output-pr-triggered-base-moved-during-poll.txt" \
  && grep -q 'current base:  new-base-oid' "$TEST_DIR/output-pr-triggered-base-moved-during-poll.txt" \
  && grep -q 'prior base(s): base-oid' "$TEST_DIR/output-pr-triggered-base-moved-during-poll.txt" \
  && ! grep -q 'Trusted PR-visible AI review found' "$TEST_DIR/output-pr-triggered-base-moved-during-poll.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: base movement during polling requires a fresh PR head"
else
  echo "FAIL: base movement while polling did not invalidate the reused PR head" >&2
  cat "$TEST_DIR/output-pr-triggered-base-moved-during-poll.txt" >&2
  [ ! -f "$TEST_DIR/gh-review-request" ] || cat "$TEST_DIR/gh-review-request" >&2
  exit 1
fi

echo "==> Test: base advance after semantic review blocks final merge"
reset_case_files
install_preflight_counter_fixture
write_pr_triggered_config true 0 0
if GH_BASE_REF_CHANGE_AFTER=5 \
  GH_BASE_REF_CHANGED_OID="new-base-oid" \
  GIT_BASE_CHANGE_AFTER_FETCH=3 \
  GIT_BASE_CHANGED_OID="new-base-oid" \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/base-moved-final' \
  PREFLIGHT_CALLS_FILE="$TEST_DIR/preflight-calls" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-base-moved-final.txt" 123; then
  echo "FAIL: merge-pr.sh accepted a base change after review" >&2
  exit 1
fi
rm -rf "${TEST_DIR:?}/lib"
if grep -q 'base revision changed after semantic review' "$TEST_DIR/output-pr-triggered-base-moved-final.txt" \
  && grep -q 'reviewed base:       base-oid' "$TEST_DIR/output-pr-triggered-base-moved-final.txt" \
  && grep -q 'current base:        new-base-oid' "$TEST_DIR/output-pr-triggered-base-moved-final.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: final authorization rejects a changed base revision"
else
  echo "FAIL: final merge authorization should be bound to the reviewed base" >&2
  cat "$TEST_DIR/output-pr-triggered-base-moved-final.txt" >&2
  exit 1
fi

echo "==> Test: PR-triggered review rejects a head change after the trusted signal"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/1' \
  GH_HEAD_REF_CHANGE_AFTER=5 \
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
request_on_push = true
timeout_sec = 0
poll_sec = 0
trusted_review_authors = ["chatgpt-codex-connector", "chatgpt-codex-connector[bot]"]
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
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: PR-triggered policy is loaded from refreshed trusted base config"
else
  echo "FAIL: refreshed trusted base config should control PR-triggered policy" >&2
  cat "$TEST_DIR/output-pr-triggered-trusted-base.txt" >&2
  exit 1
fi

echo "==> Test: legacy trusted policy filename preserves its author allowlist"
reset_case_files
install_toml_parser_fixture
cat >"$TEST_DIR/legacy-trusted-review.toml" <<'EOF'
[review.pr_triggered]
required = true
provider = "github-codex"
request_on_push = true
timeout_sec = 0
poll_sec = 0
trusted_review_authors = ["legacy-reviewer"]
EOF
GIT_TRUSTED_LEGACY_CONFIG_FILE="$TEST_DIR/legacy-trusted-review.toml" \
  GH_TRUSTED_REVIEWS=$'legacy-reviewer\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/legacy' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-legacy-policy.txt" 123
rm -rf "${TEST_DIR:?}/lib"
if [ "$(cat "$TEST_DIR/gh-merge-head")" = "pr-head-oid" ]; then
  echo "==> PASS: legacy trusted policy filename preserves authorization"
else
  cat "$TEST_DIR/output-pr-triggered-legacy-policy.txt" >&2
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
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: missing PR-triggered review fails closed with actionable guidance"
else
  echo "FAIL: missing PR-triggered review should fail before local review or merge" >&2
  cat "$TEST_DIR/output-pr-triggered-timeout.txt" >&2
  exit 1
fi

echo "==> Test: PR-triggered review checks blocking feedback before waiting"
reset_case_files
write_pr_triggered_config true 1800 10
if GH_UNRESOLVED_THREADS=$'thread-before-wait\tscripts/example.sh\t12\tfalse\treviewer\thttps://example.test/thread-before-wait\tFix this before review' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-feedback-before-wait.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly waited despite existing blocking feedback" >&2
  exit 1
fi
if grep -q 'has unresolved review thread(s)' "$TEST_DIR/output-pr-triggered-feedback-before-wait.txt" \
  && ! grep -q 'Waiting for trusted PR-visible AI review' "$TEST_DIR/output-pr-triggered-feedback-before-wait.txt" \
  && [ ! -f "$TEST_DIR/gh-reviews-graphql-calls" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: blocking feedback fails before the PR-triggered review wait"
else
  echo "FAIL: blocking feedback should fail before the PR-triggered review wait" >&2
  cat "$TEST_DIR/output-pr-triggered-feedback-before-wait.txt" >&2
  exit 1
fi

echo "==> Test: COMMENTED formal review does not count as clean approval"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/findings' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-commented-review.txt" 123; then
  echo "FAIL: COMMENTED formal review unexpectedly satisfied the merge gate" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-commented-review.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: COMMENTED formal review does not count as clean approval"
else
  echo "FAIL: COMMENTED formal review should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-commented-review.txt" >&2
  exit 1
fi
# Issue #649: a findings failure must steer the driver toward one batched fix
# round, and report the enumeration state truthfully: a listed set, an
# explicit zero state (the mock's graphql succeeds with no threads, which is
# real findings_open=0 data), or a visible could-not-enumerate degradation.
if grep -q 'Address EVERY finding above in ONE batch' "$TEST_DIR/output-pr-triggered-commented-review.txt" \
  && grep -Eq 'could not enumerate unresolved threads|Every unresolved finding on this PR|findings_open=0' "$TEST_DIR/output-pr-triggered-commented-review.txt"; then
  echo "==> PASS: findings failure reports round economics and batch guidance"
else
  echo "FAIL: findings failure should include batch guidance and enumeration state" >&2
  cat "$TEST_DIR/output-pr-triggered-commented-review.txt" >&2
  exit 1
fi

echo "==> Test: positive PR-triggered timeout rejects zero poll interval"
reset_case_files
write_pr_triggered_config true 1 0
if run_merge_pr "$TEST_DIR/output-pr-triggered-zero-poll.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly accepted zero polling with a positive timeout" >&2
  exit 1
fi
if grep -q 'poll_sec must be positive when timeout_sec is positive' "$TEST_DIR/output-pr-triggered-zero-poll.txt" \
  && [ ! -f "$TEST_DIR/gh-reviews-graphql-calls" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: positive timeout requires a positive poll interval"
else
  echo "FAIL: positive timeout should reject a zero poll interval before polling" >&2
  cat "$TEST_DIR/output-pr-triggered-zero-poll.txt" >&2
  exit 1
fi

echo "==> Test: legacy request-on-push false is normalized to mandatory review"
reset_case_files
write_pr_triggered_config true 0 0 true false
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-request-disabled.txt" 123
if grep -q 'request_on_push=false is retired and ignored' "$TEST_DIR/output-pr-triggered-request-disabled.txt" \
  && [ "$(cat "$TEST_DIR/gh-merge-head")" = "pr-head-oid" ]; then
  echo "==> PASS: legacy request-on-push false is normalized to mandatory review"
else
  cat "$TEST_DIR/output-pr-triggered-request-disabled.txt" >&2
  exit 1
fi

echo "==> Test: legacy required false is normalized to mandatory review"
reset_case_files
write_pr_triggered_config true 0 0 false true
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-required-disabled.txt" 123
if grep -q 'required=false is retired and ignored' "$TEST_DIR/output-pr-triggered-required-disabled.txt" \
  && [ "$(cat "$TEST_DIR/gh-merge-head")" = "pr-head-oid" ]; then
  echo "==> PASS: legacy required false is normalized to mandatory review"
else
  cat "$TEST_DIR/output-pr-triggered-required-disabled.txt" >&2
  exit 1
fi

echo "==> Test: malformed required value fails closed during trusted config loading"
reset_case_files
write_pr_triggered_config true 0 0 ture
if run_merge_pr "$TEST_DIR/output-pr-triggered-invalid-required.txt" 123; then
  echo "FAIL: merge-pr.sh treated malformed required value as disabled" >&2
  exit 1
fi
if grep -q 'Invalid trusted review config: \[review.pr_triggered\].required must be true; got: ture' "$TEST_DIR/output-pr-triggered-invalid-required.txt" \
  && [ ! -f "$TEST_DIR/gh-reviews-graphql-calls" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: malformed required value fails closed during trusted config loading"
else
  echo "FAIL: malformed required value should abort before review or merge" >&2
  cat "$TEST_DIR/output-pr-triggered-invalid-required.txt" >&2
  exit 1
fi

echo "==> Test: statusless direct merge requires a fresh published head"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS="" run_merge_pr "$TEST_DIR/output-pr-triggered-direct-request.txt" 123; then
  echo "FAIL: direct merge bootstrapped ambiguous legacy review state" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has no durable review-request evidence' "$TEST_DIR/output-pr-triggered-direct-request.txt" \
  && grep -q 'Run scripts/open-pr.sh against the current head to request review' "$TEST_DIR/output-pr-triggered-direct-request.txt" \
  && [ ! -f "$TEST_DIR/gh-review-request" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: only the publishing path can bootstrap durable request evidence"
else
  echo "FAIL: statusless direct merge lacked fresh-head migration guidance" >&2
  cat "$TEST_DIR/output-pr-triggered-direct-request.txt" >&2
  [ ! -f "$TEST_DIR/gh-review-request" ] || cat "$TEST_DIR/gh-review-request" >&2
  exit 1
fi

echo "==> Test: review arriving before the trigger comment remains stale"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS="$(durable_request_records "2026-06-23T00:00:00Z" "base-oid" "prior-driver" "2026-06-23T00:00:02Z")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:01Z\thttps://example.test/review/request-race' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-request-race.txt" 123; then
  echo "FAIL: a review predating the trigger comment authorized the merge" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-request-race.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: request freshness is anchored to the trigger comment"
else
  echo "FAIL: pre-trigger review did not fail as stale evidence" >&2
  cat "$TEST_DIR/output-pr-triggered-request-race.txt" >&2
  exit 1
fi

echo "==> Test: orphaned review-request intent retries the trigger and completes"
reset_case_files
write_pr_triggered_config true 0 0 true true
GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-06-22T00:00:00Z\thenrymodisett\tpr=123 base=base-oid' \
  GH_COMMENT_CREATED_AT="2026-06-22T00:00:01Z" \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/orphan-retry' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-orphan-intent.txt" 123
if grep -q 'Requested GitHub Codex review for head pr-head-oid at base base-oid' "$TEST_DIR/output-pr-triggered-orphan-intent.txt" \
  && grep -q 'touchstone/review-request-complete' "$TEST_DIR/gh-status-records" \
  && ! grep -q 'touchstone/review-request-intent' "$TEST_DIR/gh-status-records" \
  && grep -q '"event":"review_requested".*"request_count":1' "$TEST_DIR/merge-events.ndjson" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: an orphaned intent is retried without moving the freshness boundary"
else
  echo "FAIL: orphaned intent recovery did not complete the durable request" >&2
  cat "$TEST_DIR/output-pr-triggered-orphan-intent.txt" >&2
  [ ! -f "$TEST_DIR/gh-status-records" ] || cat "$TEST_DIR/gh-status-records" >&2
  exit 1
fi

echo "==> Test: revision movement after the trigger cannot create stale completion evidence"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-06-22T00:00:00Z\thenrymodisett\tpr=123 base=base-oid' \
  GH_BASE_REF_OID_AFTER_TRIGGER="changed-base-oid" \
  GH_REVISION_CHANGE_AFTER_TRIGGER_FILE="$TEST_DIR/revision-changed-after-trigger" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-revision-race.txt" 123; then
  echo "FAIL: revision movement after the trigger should fail closed" >&2
  exit 1
fi
if grep -q 'revision changed while review was being requested' "$TEST_DIR/output-pr-triggered-revision-race.txt" \
  && grep -q '^@codex review$' "$TEST_DIR/gh-review-request" \
  && { [ ! -f "$TEST_DIR/gh-status-records" ] || ! grep -q 'touchstone/review-request-complete' "$TEST_DIR/gh-status-records"; } \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: changed revision receives no stale durable completion evidence"
else
  echo "FAIL: changed revision received stale durable completion evidence" >&2
  cat "$TEST_DIR/output-pr-triggered-revision-race.txt" >&2
  [ ! -f "$TEST_DIR/gh-status-records" ] || cat "$TEST_DIR/gh-status-records" >&2
  exit 1
fi

echo "==> Test: durable statuses survive driver handoff"
reset_case_files
write_pr_triggered_config true 0 0 true true
GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "base-oid" "prior-driver")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/untrusted-status' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-untrusted-status.txt" 123
if grep -q 'GitHub Codex review already requested for head pr-head-oid at base base-oid' "$TEST_DIR/output-pr-triggered-untrusted-status.txt" \
  && ! grep -q 'touchstone/review-request-' "$TEST_DIR/gh-status-records" \
  && [ "$(grep -c 'touchstone/review-result-clean' "$TEST_DIR/gh-status-records")" = "1" ] \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: another authenticated driver reuses request evidence and records the clean result"
else
  echo "FAIL: driver handoff duplicated or discarded durable request evidence" >&2
  cat "$TEST_DIR/output-pr-triggered-untrusted-status.txt" >&2
  [ ! -f "$TEST_DIR/gh-status-records" ] || cat "$TEST_DIR/gh-status-records" >&2
  exit 1
fi

echo "==> Test: another PR's durable records cannot authorize this PR"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-06-22T00:00:00Z\thenrymodisett\tpr=122 base=base-oid\ntouchstone/review-request-complete\t2026-06-22T00:00:01Z\thenrymodisett\tpr=122 base=base-oid intent=2026-06-22T00:00:00Z trigger=2026-06-22T00:00:01Z' \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/other-pr' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-other-pr.txt" 123; then
  echo "FAIL: another PR's durable request authorized this PR" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has no durable review-request evidence' "$TEST_DIR/output-pr-triggered-other-pr.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: durable requests are bound to PR identity"
else
  echo "FAIL: other-PR records did not follow the fresh-head migration path" >&2
  cat "$TEST_DIR/output-pr-triggered-other-pr.txt" >&2
  exit 1
fi

echo "==> Test: another PR's old-base records do not create a base conflict"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-06-22T00:00:00Z\thenrymodisett\tpr=122 base=old-base-oid' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-other-pr-old-base.txt" 123; then
  echo "FAIL: statusless current PR unexpectedly merged" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has no durable review-request evidence' "$TEST_DIR/output-pr-triggered-other-pr-old-base.txt" \
  && ! grep -q 'trusted review requests for multiple base revisions' "$TEST_DIR/output-pr-triggered-other-pr-old-base.txt"; then
  echo "==> PASS: base conflicts are scoped to the current PR"
else
  echo "FAIL: another PR's old base contaminated current-PR authorization" >&2
  cat "$TEST_DIR/output-pr-triggered-other-pr-old-base.txt" >&2
  exit 1
fi

echo "==> Test: unbound durable records remain legacy evidence"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-06-22T00:00:00Z\thenrymodisett\tbase=base-oid\ntouchstone/review-request-complete\t2026-06-22T00:00:01Z\thenrymodisett\tbase=base-oid intent=2026-06-22T00:00:00Z trigger=2026-06-22T00:00:01Z' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-unbound-records.txt" 123; then
  echo "FAIL: base-only legacy records authorized the merge" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has no durable review-request evidence' "$TEST_DIR/output-pr-triggered-unbound-records.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: base-only records require a fresh PR head"
else
  echo "FAIL: legacy base-only evidence did not fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-unbound-records.txt" >&2
  exit 1
fi

echo "==> Test: non-writer status creator cannot authorize review"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "base-oid" "untrusted-app")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/untrusted-status' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-untrusted-creator.txt" 123; then
  echo "FAIL: a non-writer status creator authorized the merge" >&2
  exit 1
fi
if grep -q "review-request status from untrusted creator 'untrusted-app'" "$TEST_DIR/output-pr-triggered-untrusted-creator.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: protocol status creators require repository write permission"
else
  echo "FAIL: non-writer protocol status did not fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-untrusted-creator.txt" >&2
  exit 1
fi

echo "==> Test: direct merge review request is idempotent for the exact current head"
reset_case_files
write_pr_triggered_config true 0 0 true true
GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "base-oid")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/direct-merge-existing' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-direct-request-existing.txt" 123
if grep -q '==> GitHub Codex review already requested for head pr-head-oid at base base-oid.' "$TEST_DIR/output-pr-triggered-direct-request-existing.txt" \
  && [ ! -f "$TEST_DIR/gh-review-request" ] \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: direct merge does not duplicate an exact-head review request"
else
  echo "FAIL: direct merge should reuse an existing exact-head review request" >&2
  cat "$TEST_DIR/output-pr-triggered-direct-request-existing.txt" >&2
  [ ! -f "$TEST_DIR/gh-review-request" ] || cat "$TEST_DIR/gh-review-request" >&2
  exit 1
fi

echo "==> Test: durable old-base request survives comment mutation"
reset_case_files
write_pr_triggered_config true 0 0 true true
if GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "old-base-oid")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-25T00:00:00Z\thttps://example.test/review/late-old-base' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-durable-request.txt" 123; then
  echo "FAIL: late old-base review bypassed the durable request record" >&2
  exit 1
fi
if grep -q 'head pr-head-oid has trusted review requests for multiple base revisions' "$TEST_DIR/output-pr-triggered-durable-request.txt" \
  && grep -q 'prior base(s): old-base-oid' "$TEST_DIR/output-pr-triggered-durable-request.txt" \
  && [ ! -f "$TEST_DIR/gh-review-request" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: durable old-base request requires a new head despite mutable comments"
else
  echo "FAIL: durable request status should survive edited or deleted trigger comments" >&2
  cat "$TEST_DIR/output-pr-triggered-durable-request.txt" >&2
  [ ! -f "$TEST_DIR/gh-review-request" ] || cat "$TEST_DIR/gh-review-request" >&2
  exit 1
fi

echo "==> Test: extracted trusted review config is removed on exit"
reset_case_files
write_pr_triggered_config true 0 0
config_tmp_dir="$TEST_DIR/config-tmp"
mkdir -p "$config_tmp_dir"
if TMPDIR="$config_tmp_dir" run_merge_pr "$TEST_DIR/output-pr-triggered-config-cleanup.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly succeeded without a trusted review" >&2
  exit 1
fi
if ! find "$config_tmp_dir" -name 'touchstone-merge-review-config.*' -print -quit | grep -q .; then
  echo "==> PASS: extracted trusted review config is removed on exit"
else
  echo "FAIL: extracted trusted review config leaked after merge-pr.sh exited" >&2
  find "$config_tmp_dir" -name 'touchstone-merge-review-config.*' -print >&2
  exit 1
fi

echo "==> Test: trusted review config extraction failure aborts the merge gate"
reset_case_files
write_pr_triggered_config true 0 0
if GIT_TRUSTED_CONFIG_SHOW_FAIL=true \
  run_merge_pr "$TEST_DIR/output-pr-triggered-config-extraction-fail.txt" 123; then
  echo "FAIL: merge-pr.sh ignored a trusted review config extraction failure" >&2
  exit 1
fi
if grep -q 'Failed to extract trusted review config' "$TEST_DIR/output-pr-triggered-config-extraction-fail.txt" \
  && grep -q 'source: origin/main:.touchstone-review.toml' "$TEST_DIR/output-pr-triggered-config-extraction-fail.txt" \
  && [ ! -f "$TEST_DIR/gh-reviews-graphql-calls" ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: trusted review config extraction failure aborts the merge gate"
else
  echo "FAIL: trusted review config extraction failure should fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-config-extraction-fail.txt" >&2
  exit 1
fi

echo "==> Test: PR-triggered +1 reaction is ignored"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REACTIONS=$'chatgpt-codex-connector[bot]\t+1\t9999-01-01T00:00:00Z' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-stale-reaction.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly accepted a PR-triggered reaction" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-stale-reaction.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: PR-triggered reaction does not satisfy the merge gate"
else
  echo "FAIL: PR-triggered reaction should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-stale-reaction.txt" >&2
  exit 1
fi

echo "==> Test: prior clean PR-triggered Codex issue comment is accepted"
reset_case_files
write_pr_triggered_config true 0 0
GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/1\tCodex Review: Didn'\''t find any major issues. Another round soon, please! **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-clean-comment.txt" 123
if grep -q 'clean Codex review comment by @chatgpt-codex-connector' "$TEST_DIR/output-pr-triggered-clean-comment.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && [ "$(grep -c $'^pr-head-oid\ttouchstone/review-result-clean\t' "$TEST_DIR/gh-status-records")" = "1" ] \
  && grep -q $'touchstone/review-result-clean\t.*\tv=1 pr=123 base=base-oid req=1969-01-01T00:00:00Z result=1970-01-01T00:00:00Z$' \
    "$TEST_DIR/gh-status-records"; then
  echo "==> PASS: prior clean Codex issue comment persists full-head evidence and satisfies the merge gate"
else
  echo "FAIL: prior clean Codex issue comment should persist evidence and satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-clean-comment.txt" >&2
  [ ! -f "$TEST_DIR/gh-status-records" ] || cat "$TEST_DIR/gh-status-records" >&2
  exit 1
fi

echo "==> Test: persisted result timestamp follows the accepted newer signal"
reset_case_files
write_pr_triggered_config true 0 0
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t1970-01-01T00:00:02Z\thttps://example.test/review/newer-clean' \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:01Z\thttps://example.test/comment/older-finding\tCodex Review: Actionable finding. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-newer-formal-result.txt" 123
if grep -q 'formal review by @chatgpt-codex-connector\[bot\] (APPROVED) at 1970-01-01T00:00:02Z' \
  "$TEST_DIR/output-pr-triggered-newer-formal-result.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head" \
  && grep -q $'touchstone/review-result-clean\t.*\tv=1 pr=123 base=base-oid req=1969-01-01T00:00:00Z result=1970-01-01T00:00:02Z$' \
    "$TEST_DIR/gh-status-records" \
  && grep -q '"result_at":"1970-01-01T00:00:02Z"' \
    "$TEST_DIR/merge-events.ndjson"; then
  echo "==> PASS: durable evidence records the timestamp of the selected clean signal"
else
  echo "FAIL: durable evidence recorded an unselected review-result timestamp" >&2
  cat "$TEST_DIR/output-pr-triggered-newer-formal-result.txt" >&2
  [ ! -f "$TEST_DIR/gh-status-records" ] || cat "$TEST_DIR/gh-status-records" >&2
  exit 1
fi

echo "==> Test: an existing trusted clean-result status is reused across merge runs"
reset_case_files
write_pr_triggered_config true 0 0
GH_RESULT_RECORDS=$'prior-driver\tv=1 pr=123 base=base-oid req=1969-01-01T00:00:00Z result=1970-01-01T00:00:00Z' \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/existing-result\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-existing-result.txt" 123
if grep -q 'Full-SHA clean-review evidence already persisted for head pr-head-oid' \
  "$TEST_DIR/output-pr-triggered-existing-result.txt" \
  && [ ! -f "$TEST_DIR/gh-status-records" ] \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: trusted clean-result evidence is idempotent across merge runs"
else
  echo "FAIL: an existing trusted clean-result status was duplicated or rejected" >&2
  cat "$TEST_DIR/output-pr-triggered-existing-result.txt" >&2
  [ ! -f "$TEST_DIR/gh-status-records" ] || cat "$TEST_DIR/gh-status-records" >&2
  exit 1
fi

echo "==> Test: clean review cannot merge when durable result persistence fails"
reset_case_files
write_pr_triggered_config true 0 0
if GH_RESULT_STATUS_FAIL=true \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/result-write-failure\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-result-write-failure.txt" 123; then
  echo "FAIL: merge proceeded without durable clean-review evidence" >&2
  exit 1
fi
if grep -q 'Failed to persist clean-review evidence for PR #123 head pr-head-oid' \
  "$TEST_DIR/output-pr-triggered-result-write-failure.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: clean-review result persistence fails closed"
else
  echo "FAIL: result-persistence failure did not block merge" >&2
  cat "$TEST_DIR/output-pr-triggered-result-write-failure.txt" >&2
  exit 1
fi

echo "==> Test: stale-head clean Codex issue comment is rejected"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/stale\tCodex Review: Didn'\''t find any major issues. Another round soon, please! **Reviewed commit:** `old-head-0`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-stale-clean-comment.txt" 123; then
  echo "FAIL: stale-head clean Codex issue comment unexpectedly satisfied the merge gate" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-stale-clean-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: stale-head clean Codex issue comment does not satisfy the merge gate"
else
  echo "FAIL: stale-head clean Codex issue comment should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-stale-clean-comment.txt" >&2
  exit 1
fi

echo "==> Test: colliding short marker must resolve to the full current head"
reset_case_files
write_pr_triggered_config true 0 0
if GH_RESOLVED_COMMENT_COMMIT=old-reviewed-head \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/collision\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-colliding-marker.txt" 123; then
  echo "FAIL: colliding short marker unexpectedly satisfied the exact-head gate" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-colliding-marker.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: short marker must resolve to the full current head"
else
  echo "FAIL: unresolved full commit mismatch should reject the clean comment" >&2
  cat "$TEST_DIR/output-pr-triggered-colliding-marker.txt" >&2
  exit 1
fi

echo "==> Test: malformed reviewed-commit token is rejected"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/malformed\tCodex Review: Didn'\''t find any major issues. Another round soon, please! **Reviewed commit:** `pr-head-oid-extra`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-malformed-clean-comment.txt" 123; then
  echo "FAIL: malformed reviewed-commit token unexpectedly satisfied the merge gate" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-malformed-clean-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: malformed reviewed-commit token does not satisfy the merge gate"
else
  echo "FAIL: malformed reviewed-commit token should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-malformed-clean-comment.txt" >&2
  exit 1
fi

echo "==> Test: untrusted-author clean Codex issue comment is rejected"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'untrusted-reviewer\t1970-01-01T00:00:00Z\thttps://example.test/comment/spoof\tCodex Review: Didn'\''t find any major issues. Another round soon, please! **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-untrusted-clean-comment.txt" 123; then
  echo "FAIL: untrusted-author clean Codex issue comment unexpectedly satisfied the merge gate" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-untrusted-clean-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: untrusted-author clean Codex issue comment does not satisfy the merge gate"
else
  echo "FAIL: untrusted-author clean Codex issue comment should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-untrusted-clean-comment.txt" >&2
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
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-non-clean-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: non-clean Codex issue comment does not satisfy the merge gate"
else
  echo "FAIL: non-clean Codex issue comment should not satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-non-clean-comment.txt" >&2
  exit 1
fi

echo "==> Test: clean phrase inside findings details does not count as a clean result"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t1970-01-01T00:00:00Z\thttps://example.test/comment/mixed\tCodex Review: Found a blocking issue. Quoted context: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-mixed-comment.txt" 123; then
  echo "FAIL: clean phrase inside findings details unexpectedly satisfied the merge gate" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-mixed-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: clean phrase inside findings details remains non-clean"
else
  echo "FAIL: only the canonical clean-result prefix should satisfy the merge gate" >&2
  cat "$TEST_DIR/output-pr-triggered-mixed-comment.txt" >&2
  exit 1
fi

echo "==> Test: later non-clean Codex comment overrides clean result for the same head"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/clean\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`\nchatgpt-codex-connector\t2026-06-23T00:01:00Z\thttps://example.test/comment/findings\tCodex Review: Found a blocking issue. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-later-non-clean-comment.txt" 123; then
  echo "FAIL: historical clean comment overrode a later non-clean Codex result" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-later-non-clean-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: latest Codex comment controls the exact-head result"
else
  echo "FAIL: latest non-clean Codex comment should block historical clean evidence" >&2
  cat "$TEST_DIR/output-pr-triggered-later-non-clean-comment.txt" >&2
  exit 1
fi

echo "==> Test: later COMMENTED formal review overrides earlier approval for the same head"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/approved\nchatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:01:00Z\thttps://example.test/review/findings' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-later-commented-review.txt" 123; then
  echo "FAIL: historical formal approval overrode a later COMMENTED review" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-later-commented-review.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: latest formal review controls the exact-head result"
else
  echo "FAIL: latest COMMENTED formal review should block historical approval" >&2
  cat "$TEST_DIR/output-pr-triggered-later-commented-review.txt" >&2
  exit 1
fi

echo "==> Test: conflicting same-time formal reviews fail closed regardless of API order"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/findings\nchatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/approved' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-same-time-reviews.txt" 123; then
  echo "FAIL: API order allowed tied formal approval to hide blocking review" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-same-time-reviews.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: conflicting same-time formal reviews fail closed"
else
  echo "FAIL: every formal review at the latest timestamp must be clean" >&2
  cat "$TEST_DIR/output-pr-triggered-same-time-reviews.txt" >&2
  exit 1
fi

echo "==> Test: conflicting same-time review comments fail closed regardless of API order"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/findings\tCodex Review: Found a blocking issue. **Reviewed commit:** `pr-head-oi`\nchatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/clean\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-same-time-comments.txt" 123; then
  echo "FAIL: API order allowed tied clean comment to hide findings" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-same-time-comments.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: conflicting same-time review comments fail closed"
else
  echo "FAIL: every review comment at the latest timestamp must be clean" >&2
  cat "$TEST_DIR/output-pr-triggered-same-time-comments.txt" >&2
  exit 1
fi

echo "==> Test: newer findings comment overrides older formal approval"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/approved' \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:01:00Z\thttps://example.test/comment/findings\tCodex Review: Found a blocking issue. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-comment-overrides-approval.txt" 123; then
  echo "FAIL: older formal approval overrode a newer findings comment" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-comment-overrides-approval.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: globally latest findings comment overrides older formal approval"
else
  echo "FAIL: globally latest findings comment should override older formal approval" >&2
  cat "$TEST_DIR/output-pr-triggered-comment-overrides-approval.txt" >&2
  exit 1
fi

echo "==> Test: newer COMMENTED formal review overrides older clean comment"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/clean\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:01:00Z\thttps://example.test/review/findings' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-review-overrides-clean-comment.txt" 123; then
  echo "FAIL: older clean comment overrode a newer COMMENTED formal review" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-review-overrides-clean-comment.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: globally latest COMMENTED review overrides older clean comment"
else
  echo "FAIL: globally latest COMMENTED review should override older clean comment" >&2
  cat "$TEST_DIR/output-pr-triggered-review-overrides-clean-comment.txt" >&2
  exit 1
fi

echo "==> Test: newer clean comment overrides older COMMENTED formal review"
reset_case_files
write_pr_triggered_config true 0 0
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tCOMMENTED\t2026-06-23T00:00:00Z\thttps://example.test/review/findings' \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:01:00Z\thttps://example.test/comment/clean\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-clean-comment-overrides-review.txt" 123
if grep -q 'clean Codex review comment by @chatgpt-codex-connector' "$TEST_DIR/output-pr-triggered-clean-comment-overrides-review.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: globally latest clean comment overrides older COMMENTED review"
else
  echo "FAIL: globally latest clean comment should override older COMMENTED review" >&2
  cat "$TEST_DIR/output-pr-triggered-clean-comment-overrides-review.txt" >&2
  exit 1
fi

echo "==> Test: formal review in the request timestamp second is ambiguous"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REQUEST_RECORDS="$(durable_request_records "2026-06-23T00:00:00Z" "base-oid")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/same-second' \
GH_COMMENT_CREATED_AT="2026-06-23T00:00:01Z" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-same-second-review.txt" 123; then
  echo "FAIL: same-second formal review unexpectedly authorized the merge" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-same-second-review.txt" \
  && [ "$(grep -c '^@codex review$' "$TEST_DIR/gh-review-request")" = "1" ] \
  && grep -q 'pr=123 base=base-oid intent=2026-06-23T00:00:00Z trigger=2026-06-23T00:00:01Z' "$TEST_DIR/gh-status-records" \
  && ! grep -q 'touchstone/review-request-intent' "$TEST_DIR/gh-status-records" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: same-second formal review appends one fresh request and fails closed"
else
  echo "FAIL: same-second formal review did not append exactly one recovery request" >&2
  cat "$TEST_DIR/output-pr-triggered-same-second-review.txt" >&2
  [ ! -f "$TEST_DIR/gh-status-records" ] || cat "$TEST_DIR/gh-status-records" >&2
  exit 1
fi

echo "==> Test: clean comment in the request timestamp second is ambiguous"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REQUEST_RECORDS="$(durable_request_records "2026-06-23T00:00:00Z" "base-oid")" \
GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/same-second\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
GH_COMMENT_CREATED_AT="2026-06-23T00:00:01Z" \
  run_merge_pr "$TEST_DIR/output-pr-triggered-same-second-comment.txt" 123; then
  echo "FAIL: same-second clean comment unexpectedly authorized the merge" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-same-second-comment.txt" \
  && [ "$(grep -c '^@codex review$' "$TEST_DIR/gh-review-request")" = "1" ] \
  && grep -q 'pr=123 base=base-oid intent=2026-06-23T00:00:00Z trigger=2026-06-23T00:00:01Z' "$TEST_DIR/gh-status-records" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: same-second clean comment appends one fresh request and fails closed"
else
  echo "FAIL: same-second clean comment did not append exactly one recovery request" >&2
  cat "$TEST_DIR/output-pr-triggered-same-second-comment.txt" >&2
  exit 1
fi

echo "==> Test: same-second ambiguity recovery can authorize a later review"
reset_case_files
write_pr_triggered_config true 2 1
GH_REQUEST_RECORDS="$(durable_request_records "2026-06-23T00:00:00Z" "base-oid")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/same-second' \
GH_TRUSTED_REVIEWS_SECOND=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:02Z\thttps://example.test/review/retry' \
GH_COMMENT_CREATED_AT="2026-06-23T00:00:01Z" \
MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-same-second-recovery.txt" 123
if [ "$(grep -c '^@codex review$' "$TEST_DIR/gh-review-request")" = "1" ] \
  && grep -q 'Trusted PR-visible AI review found for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-same-second-recovery.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: one append-only retry recovers from second-level ambiguity"
else
  echo "FAIL: same-second recovery did not accept the later exact-head review" >&2
  cat "$TEST_DIR/output-pr-triggered-same-second-recovery.txt" >&2
  exit 1
fi

echo "==> Test: review evidence before the request timestamp remains stale"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REQUEST_RECORDS="$(durable_request_records "2026-06-23T00:00:01Z" "base-oid")" \
GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/stale' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-before-request.txt" 123; then
  echo "FAIL: review evidence older than its request authorized the merge" >&2
  exit 1
fi
if grep -q 'Timed out waiting for trusted PR-visible AI review for PR #123' "$TEST_DIR/output-pr-triggered-before-request.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: pre-request review evidence remains stale"
else
  echo "FAIL: pre-request review evidence did not fail as an ordinary missing result" >&2
  cat "$TEST_DIR/output-pr-triggered-before-request.txt" >&2
  exit 1
fi

echo "==> Test: conflicting same-time trusted results fail closed"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/approved' \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/findings\tCodex Review: Found a blocking issue. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-conflicting-same-time.txt" 123; then
  echo "FAIL: conflicting same-time trusted results unexpectedly satisfied the merge gate" >&2
  exit 1
fi
if grep -q 'Trusted PR-visible AI review is not clean for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-conflicting-same-time.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: conflicting same-time trusted results fail closed"
else
  echo "FAIL: conflicting same-time trusted results should fail closed" >&2
  cat "$TEST_DIR/output-pr-triggered-conflicting-same-time.txt" >&2
  exit 1
fi

echo "==> Test: delayed PR-triggered review is polled before merge"
reset_case_files
write_pr_triggered_config true 2 1
GH_TRUSTED_REVIEWS_SECOND=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/2' \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  TOUCHSTONE_PR_TRIGGERED_REVIEW_REQUEST_COUNT=1 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-delayed.txt" 123
if grep -q 'Trusted PR-visible AI review found for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-delayed.txt" \
  && [ "$(cat "$TEST_DIR/gh-reviews-graphql-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && grep -q "\"event\":\"review_result\".*\"worktree_path\":\"$DEFAULT_FAKE_WORKTREE\".*\"base_sha\":\"base-oid\".*\"status\":\"clean\".*\"wait_seconds\":[0-9][0-9]*.*\"request_count\":1" \
    "$TEST_DIR/merge-events.ndjson" \
  && grep -q '"request_at":"1969-01-01T00:00:00Z".*"result_at":"2026-06-23T00:00:00Z"' \
    "$TEST_DIR/merge-events.ndjson" \
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
  GH_TRUSTED_REVIEWS_SECOND=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/3' \
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

echo "==> Test: transient review-request marker lookup failure is retried"
reset_case_files
write_pr_triggered_config true 2 1
GH_REQUEST_LOOKUP_FAIL_FIRST=true \
  GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "base-oid")" \
  GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/request-retry' \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-request-lookup-transient.txt" 123
if grep -q 'Trusted PR-visible AI review found for PR #123 head pr-head-oid' "$TEST_DIR/output-pr-triggered-request-lookup-transient.txt" \
  && [ "$(cat "$TEST_DIR/gh-request-lookup-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && [ ! -f "$TEST_DIR/gh-review-request" ] \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: transient marker lookup failure is retried without a duplicate request"
else
  echo "FAIL: transient marker lookup failure aborted or duplicated the request" >&2
  cat "$TEST_DIR/output-pr-triggered-request-lookup-transient.txt" >&2
  [ ! -f "$TEST_DIR/gh-request-lookup-calls" ] || cat "$TEST_DIR/gh-request-lookup-calls" >&2
  exit 1
fi

echo "==> Test: persistent review-request marker lookup failure reports inspection error"
reset_case_files
write_pr_triggered_config true 2 1
if GH_REQUEST_LOOKUP_FAIL=true \
  MERGE_PR_SLEEP_OVERRIDE=0.1 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-request-lookup-persistent.txt" 123; then
  echo "FAIL: persistent marker lookup failure unexpectedly authorized a merge" >&2
  exit 1
fi
if grep -q 'Failed to inspect trusted PR-visible AI review evidence for PR #123' "$TEST_DIR/output-pr-triggered-request-lookup-persistent.txt" \
  && grep -q 'last gh error: review request markers: review request records unavailable' "$TEST_DIR/output-pr-triggered-request-lookup-persistent.txt" \
  && [ "$(cat "$TEST_DIR/gh-request-lookup-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && ! grep -q 'Timed out waiting for trusted PR-visible AI review' "$TEST_DIR/output-pr-triggered-request-lookup-persistent.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: persistent marker lookup failure remains distinct from a missing review"
else
  echo "FAIL: persistent marker lookup failure was not retried and diagnosed" >&2
  cat "$TEST_DIR/output-pr-triggered-request-lookup-persistent.txt" >&2
  [ ! -f "$TEST_DIR/gh-request-lookup-calls" ] || cat "$TEST_DIR/gh-request-lookup-calls" >&2
  exit 1
fi

echo "==> Test: persistent PR head inspection failure reports the GitHub error"
reset_case_files
write_pr_triggered_config true 0 0
if GH_HEAD_REF_FAIL_AFTER=2 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-head-inspection-fail.txt" 123; then
  echo "FAIL: merge-pr.sh ignored a persistent PR head inspection failure" >&2
  exit 1
fi
if grep -q 'Failed to inspect PR #123 head or base revision while waiting for PR-triggered AI review' "$TEST_DIR/output-pr-triggered-head-inspection-fail.txt" \
  && grep -q 'last gh error: gh pr view headRefOid unavailable' "$TEST_DIR/output-pr-triggered-head-inspection-fail.txt" \
  && ! grep -q 'Timed out waiting for trusted PR-visible AI review' "$TEST_DIR/output-pr-triggered-head-inspection-fail.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: persistent PR head inspection failure reports the GitHub error"
else
  echo "FAIL: persistent PR head inspection failure should remain distinguishable from a missing review" >&2
  cat "$TEST_DIR/output-pr-triggered-head-inspection-fail.txt" >&2
  exit 1
fi

echo "==> Test: persistent PR base inspection failure reports the GitHub error"
reset_case_files
write_pr_triggered_config true 0 0
if GH_BASE_REF_FAIL_AFTER=2 \
  run_merge_pr "$TEST_DIR/output-pr-triggered-base-inspection-fail.txt" 123; then
  echo "FAIL: merge-pr.sh ignored a persistent PR base inspection failure" >&2
  exit 1
fi
if grep -q 'Failed to inspect PR #123 head or base revision while waiting for PR-triggered AI review' "$TEST_DIR/output-pr-triggered-base-inspection-fail.txt" \
  && grep -q 'last gh error: pull request base unavailable' "$TEST_DIR/output-pr-triggered-base-inspection-fail.txt" \
  && ! grep -q 'Timed out waiting for trusted PR-visible AI review' "$TEST_DIR/output-pr-triggered-base-inspection-fail.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: persistent PR base inspection failure reports the GitHub error"
else
  echo "FAIL: persistent PR base inspection failure should remain distinguishable from a missing review" >&2
  cat "$TEST_DIR/output-pr-triggered-base-inspection-fail.txt" >&2
  exit 1
fi

echo "==> Test: formal review inspection failure cannot fall back to a clean comment"
reset_case_files
write_pr_triggered_config true 0 0
if GH_REVIEWS_GRAPHQL_FAIL=true \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/clean\tCodex Review: Didn\'t find any major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-review-channel-fail.txt" 123; then
  echo "FAIL: clean comment bypassed a formal review inspection failure" >&2
  exit 1
fi
if grep -q 'Failed to inspect trusted PR-visible AI review evidence for PR #123' "$TEST_DIR/output-pr-triggered-review-channel-fail.txt" \
  && grep -q 'last gh error: formal reviews: reviews graphql unavailable' "$TEST_DIR/output-pr-triggered-review-channel-fail.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: formal review inspection failure blocks clean comment evidence"
else
  echo "FAIL: formal review inspection failure must remain distinct from an empty review channel" >&2
  cat "$TEST_DIR/output-pr-triggered-review-channel-fail.txt" >&2
  exit 1
fi

echo "==> Test: review comment inspection failure cannot fall back to formal approval"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/approved' \
  GH_COMMENTS_FAIL=true \
  run_merge_pr "$TEST_DIR/output-pr-triggered-comment-channel-fail.txt" 123; then
  echo "FAIL: formal approval bypassed a review comment inspection failure" >&2
  exit 1
fi
if grep -q 'Failed to inspect trusted PR-visible AI review evidence for PR #123' "$TEST_DIR/output-pr-triggered-comment-channel-fail.txt" \
  && grep -q 'last gh error: review comments: review comments unavailable' "$TEST_DIR/output-pr-triggered-comment-channel-fail.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: review comment inspection failure blocks formal approval evidence"
else
  echo "FAIL: review comment inspection failure must remain distinct from an empty comment channel" >&2
  cat "$TEST_DIR/output-pr-triggered-comment-channel-fail.txt" >&2
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
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: failed checks fail fast before review"
else
  echo "FAIL: failed checks should stop before review/merge" >&2
  cat "$TEST_DIR/output-check-failed.txt" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Issue #658: a claim-check that failed WITHOUT executing a step (Actions
# infrastructure class) is substitutable by a passing direct API claim
# verification — disclosed on the PR and in the squash body. Executed
# failures, failed direct verification, and any other failing check still
# block.
# ---------------------------------------------------------------------------
CLAIM_INFRA_CHECKS=$'claim-check\tFAILURE\thttps://example.test/actions/runs/999/job/1'

echo "==> Test: zero-step claim-check substitutes to direct API verification"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_PR_STATE="MERGED" GH_MERGED_AT="2026-08-07T02:00:00Z" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-claim-substitution.txt" 123; then
  if grep -q 'confirmed assigned to the PR author by direct API read' "$TEST_DIR/output-claim-substitution.txt" \
    && grep -q 'Claim-substitution' "$TEST_DIR/gh-merge-body" \
    && grep -q 'direct API read' "$TEST_DIR/gh-comment"; then
    echo "==> PASS: zero-step claim-check substitutes with full disclosure"
  else
    echo "FAIL: substitution must disclose in output, squash body, and PR comment" >&2
    cat "$TEST_DIR/output-claim-substitution.txt" >&2
    exit 1
  fi
else
  echo "FAIL: zero-step claim-check with passing direct verification should merge" >&2
  cat "$TEST_DIR/output-claim-substitution.txt" >&2
  exit 1
fi

echo "==> Test: substitution discloses a documented bypass as a bypass"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_PR_STATE="MERGED" GH_MERGED_AT="2026-08-07T02:00:00Z" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_BYPASS=true \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-claim-bypass-token.txt" 123; then
  if grep -q 'bypass honored' "$TEST_DIR/gh-merge-body" \
    && grep -q 'bypass honored' "$TEST_DIR/gh-comment" \
    && ! grep -q 'invariant verified' "$TEST_DIR/gh-merge-body"; then
    echo "==> PASS: bypass-based substitution is disclosed as a bypass, not a verification"
  else
    echo "FAIL: bypass substitution must not claim verification" >&2
    cat "$TEST_DIR/gh-merge-body" >&2
    exit 1
  fi
else
  echo "FAIL: bypass-token substitution should merge" >&2
  cat "$TEST_DIR/output-claim-bypass-token.txt" >&2
  exit 1
fi

echo "==> Test: zero-step claim-check with failing direct verification blocks"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=1 \
  run_merge_pr "$TEST_DIR/output-claim-direct-fail.txt" 123; then
  echo "FAIL: failed direct verification must block the merge" >&2
  exit 1
fi
if grep -q 'direct API claim verification failed' "$TEST_DIR/output-claim-direct-fail.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: failed direct verification blocks with its own reason"
else
  echo "FAIL: expected the direct-verification failure reason" >&2
  cat "$TEST_DIR/output-claim-direct-fail.txt" >&2
  exit 1
fi

echo "==> Test: claim-check that EXECUTED and failed still blocks"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=7 \
  CLAIM_DIRECT_EXIT=0 \
  run_merge_pr "$TEST_DIR/output-claim-executed.txt" 123; then
  echo "FAIL: an executed claim-check failure must block regardless of direct verification" >&2
  exit 1
fi
if grep -q 'has failed check(s); stopping automerge' "$TEST_DIR/output-claim-executed.txt" \
  && ! grep -q 'verified by direct API read' "$TEST_DIR/output-claim-executed.txt"; then
  echo "==> PASS: executed claim-check failure is a real failure from either surface"
else
  echo "FAIL: executed failure must not be substituted" >&2
  cat "$TEST_DIR/output-claim-executed.txt" >&2
  exit 1
fi

echo "==> Test: substitution waits while non-claim checks are still pending"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_PENDING_CHECKS="sha256-preflight" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  MERGE_PR_STATE_MAX_ATTEMPTS=2 \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-claim-pending.txt" 123; then
  echo "FAIL: substitution must not shortcut pending non-claim checks" >&2
  exit 1
fi
if ! grep -q 'verified by direct API read' "$TEST_DIR/output-claim-pending.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: substitution keeps waiting for pending non-claim checks"
else
  echo "FAIL: substitution ran despite pending checks" >&2
  cat "$TEST_DIR/output-claim-pending.txt" >&2
  exit 1
fi

echo "==> Test: bypass and claim substitution disclose together in the squash body"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_PR_STATE="MERGED" GH_MERGED_AT="2026-08-07T02:00:00Z" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-claim-bypass.txt" 123 --bypass-with-disclosure="review wedge test"; then
  if grep -q 'Reviewer-bypass: review wedge test' "$TEST_DIR/gh-merge-body" \
    && grep -q 'Claim-substitution' "$TEST_DIR/gh-merge-body"; then
    echo "==> PASS: both disclosures land in one squash body"
  else
    echo "FAIL: squash body must carry both disclosures" >&2
    cat "$TEST_DIR/gh-merge-body" >&2
    exit 1
  fi
else
  echo "FAIL: bypass with claim substitution should merge" >&2
  cat "$TEST_DIR/output-claim-bypass.txt" >&2
  exit 1
fi

echo "==> Test: substitution refuses when check inspection fails"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_PENDING_CHECKS_FAIL=true \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  MERGE_PR_STATE_MAX_ATTEMPTS=2 \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-claim-inspect-fail.txt" 123; then
  echo "FAIL: unverifiable check state must not authorize substitution" >&2
  exit 1
fi
if ! grep -q 'verified\|bypass honored' "$TEST_DIR/output-claim-inspect-fail.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: inspection failure counts as outstanding and defers substitution"
else
  echo "FAIL: substitution ran despite uninspectable check state" >&2
  cat "$TEST_DIR/output-claim-inspect-fail.txt" >&2
  exit 1
fi

echo "==> Test: a BEHIND PR keeps its rejection despite claim substitution"
reset_case_files
if GH_MERGE_STATE="BEHIND MERGEABLE" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  run_merge_pr "$TEST_DIR/output-claim-behind.txt" 123; then
  echo "FAIL: claim substitution must not waive the behind-state rejection" >&2
  exit 1
fi
if grep -q 'does not waive merge-state requirements' "$TEST_DIR/output-claim-behind.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: substitution records but merge-state guards still reject"
else
  echo "FAIL: expected the merge-state rejection after substitution" >&2
  cat "$TEST_DIR/output-claim-behind.txt" >&2
  exit 1
fi

echo "==> Test: substituted merge that leaves the PR open fails honestly"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_MERGE_LEAVES_OPEN=true \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-claim-open-after-merge.txt" 123; then
  echo "FAIL: a substituted merge that leaves the PR OPEN must not report success" >&2
  exit 1
fi
if grep -q 'cannot update GitHub.s required-check status' "$TEST_DIR/output-claim-open-after-merge.txt" \
  && grep -q 'disable-auto' "$TEST_DIR/gh-merge-args"; then
  echo "==> PASS: required-check substitution fails honestly and disarms auto-merge"
else
  echo "FAIL: expected honest failure plus auto-merge disarm" >&2
  cat "$TEST_DIR/output-claim-open-after-merge.txt" >&2
  exit 1
fi

echo "==> Test: non-authorizing merge state keeps waiting after substitution"
reset_case_files
if GH_MERGE_STATE="UNKNOWN UNKNOWN" \
  GH_FAILED_CHECKS="$CLAIM_INFRA_CHECKS" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  MERGE_PR_STATE_MAX_ATTEMPTS=2 \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-claim-unknown-state.txt" 123; then
  echo "FAIL: UNKNOWN state must not be authorized by claim substitution" >&2
  exit 1
fi
if grep -q 'continuing to wait for an authorizing state' "$TEST_DIR/output-claim-unknown-state.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ "$(grep -c 'Direct verification result' "$TEST_DIR/output-claim-unknown-state.txt")" = "1" ]; then
  echo "==> PASS: substitution allow-lists authorizing states and never re-runs"
else
  echo "FAIL: expected wait-and-no-reprocessing on UNKNOWN state" >&2
  cat "$TEST_DIR/output-claim-unknown-state.txt" >&2
  exit 1
fi

echo "==> Test: zero-step claim-check plus another failed check still blocks"
reset_case_files
if GH_MERGE_STATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS="$(printf 'claim-check\tFAILURE\thttps://example.test/actions/runs/999/job/1\nsha256-preflight\tFAILURE\thttps://example.test/actions/runs/998/job/1')" \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  CLAIM_DIRECT_EXIT=0 \
  run_merge_pr "$TEST_DIR/output-claim-plus-other.txt" 123; then
  echo "FAIL: substitution must not cover non-claim failed checks" >&2
  exit 1
fi
if grep -q 'has failed check(s); stopping automerge' "$TEST_DIR/output-claim-plus-other.txt"; then
  echo "==> PASS: substitution scope is exactly the unexecuted claim-check"
else
  echo "FAIL: expected the normal failed-check block" >&2
  cat "$TEST_DIR/output-claim-plus-other.txt" >&2
  exit 1
fi

echo "==> Test: transient UNKNOWN merge state retries past five attempts"
reset_case_files
GH_MERGE_STATE_UNKNOWN_ATTEMPTS=6 \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-unknown-then-clean.txt" 123
attempt_count="$(grep -c 'attempt [0-9][0-9]*: mergeStateStatus=' "$TEST_DIR/output-unknown-then-clean.txt")"
if [ "$attempt_count" -eq 7 ] \
  && grep -q 'attempt 7: mergeStateStatus=CLEAN mergeable=MERGEABLE' "$TEST_DIR/output-unknown-then-clean.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: UNKNOWN state uses the expanded retry budget"
else
  cat "$TEST_DIR/output-unknown-then-clean.txt" >&2
  exit 1
fi

echo "==> Test: definite conflict refuses immediately"
reset_case_files
if GH_MERGE_STATE_IMMEDIATE="DIRTY CONFLICTING" \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-conflict.txt" 123; then
  echo "FAIL: conflicting PR unexpectedly merged" >&2
  exit 1
fi
attempt_count="$(grep -c 'attempt [0-9][0-9]*: mergeStateStatus=' "$TEST_DIR/output-conflict.txt")"
if [ "$attempt_count" -eq 1 ] \
  && grep -q 'Final merge state: mergeStateStatus=DIRTY mergeable=CONFLICTING' "$TEST_DIR/output-conflict.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: definite conflict does not burn the retry budget"
else
  cat "$TEST_DIR/output-conflict.txt" >&2
  exit 1
fi

echo "==> Test: superseded cancelled run tolerates UNSTABLE (issue #593)"
reset_case_files
if ! GH_MERGE_STATE_IMMEDIATE="UNSTABLE MERGEABLE" \
  GH_CHECK_BUCKETS=$'delivery-protocol\tcancel\nclaim-check\tpass' \
  GH_CHECK_ROLLUP=$'delivery-protocol\tcompleted\tcancelled\t2026-01-01T10:00:00Z\tactions\t111\ndelivery-protocol\tcompleted\tsuccess\t2026-01-01T10:05:00Z\tactions\t222\nclaim-check\tcompleted\tsuccess\t2026-01-01T10:06:00Z\tactions\t222' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  MERGE_PR_STATE_MAX_ATTEMPTS=3 MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-superseded-cancel.txt" 123; then
  echo "FAIL: superseded-cancellation UNSTABLE did not merge" >&2
  cat "$TEST_DIR/output-superseded-cancel.txt" >&2
  exit 1
fi
if grep -q 'stems only from concurrency-cancelled runs' "$TEST_DIR/output-superseded-cancel.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: cancelled predecessor with successful replacement merges"
else
  cat "$TEST_DIR/output-superseded-cancel.txt" >&2
  exit 1
fi

echo "==> Test: cancelled run WITHOUT a successful replacement keeps waiting"
reset_case_files
if GH_MERGE_STATE_IMMEDIATE="UNSTABLE MERGEABLE" \
  GH_CHECK_BUCKETS=$'delivery-protocol\tcancel\nclaim-check\tpass' \
  GH_CHECK_ROLLUP=$'delivery-protocol\tcompleted\tcancelled\t2026-01-01T10:00:00Z\tactions\t111\nclaim-check\tcompleted\tsuccess\t2026-01-01T10:06:00Z\tactions\t222' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  MERGE_PR_STATE_MAX_ATTEMPTS=2 MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-unreplaced-cancel.txt" 123; then
  echo "FAIL: cancelled run without a successful replacement must not merge" >&2
  cat "$TEST_DIR/output-unreplaced-cancel.txt" >&2
  exit 1
fi
if [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: unreplaced cancellation never authorizes the merge"
else
  cat "$TEST_DIR/output-unreplaced-cancel.txt" >&2
  exit 1
fi

echo "==> Test: an older success does not supersede a newer cancellation"
reset_case_files
if GH_MERGE_STATE_IMMEDIATE="UNSTABLE MERGEABLE" \
  GH_CHECK_BUCKETS=$'delivery-protocol\tcancel\nclaim-check\tpass' \
  GH_CHECK_ROLLUP=$'delivery-protocol\tcompleted\tsuccess\t2026-01-01T09:00:00Z\tactions\t222\ndelivery-protocol\tcompleted\tcancelled\t2026-01-01T10:00:00Z\tactions\t111\nclaim-check\tcompleted\tsuccess\t2026-01-01T10:06:00Z\tactions\t222' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  MERGE_PR_STATE_MAX_ATTEMPTS=2 MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-stale-success.txt" 123; then
  echo "FAIL: an older success must not supersede a newer cancellation" >&2
  cat "$TEST_DIR/output-stale-success.txt" >&2
  exit 1
fi
if [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: supersession requires the success to be newer"
else
  exit 1
fi

echo "==> Test: a same-named check from another workflow does not supersede"
reset_case_files
if GH_MERGE_STATE_IMMEDIATE="UNSTABLE MERGEABLE" \
  GH_CHECK_BUCKETS=$'validate\tcancel\nclaim-check\tpass' \
  GH_CHECK_ROLLUP=$'validate\tcompleted\tcancelled\t2026-01-01T10:00:00Z\tactions\t111\nvalidate\tcompleted\tsuccess\t2026-01-01T10:05:00Z\tactions\t111\nclaim-check\tcompleted\tsuccess\t2026-01-01T10:06:00Z\tactions\t222' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  MERGE_PR_STATE_MAX_ATTEMPTS=2 MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-same-suite.txt" 123; then
  echo "FAIL: a success in the SAME suite as the cancellation must not supersede it" >&2
  cat "$TEST_DIR/output-same-suite.txt" >&2
  exit 1
fi
if [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: supersession requires a distinct check-suite lineage"
else
  cat "$TEST_DIR/output-same-suite.txt" >&2
  exit 1
fi

echo "==> Test: mixed infra and code failures classify as code (PR #680)"
reset_case_files
if GH_MERGE_STATE_IMMEDIATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS=$'validate\tfail\thttps://github.com/autumngarage/example/actions/runs/555/job/1\nunit-tests\tfail\t' \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  GH_CHECK_ANNOTATIONS='The job was not started because recent account payments have failed.' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-mixed-failure.txt" 123; then
  echo "FAIL: mixed failure must stop the merge" >&2
  exit 1
fi
if ! grep -q 'CLASSIFICATION: infrastructure startup failure' "$TEST_DIR/output-mixed-failure.txt" \
  && grep -q 'annotation: The job was not started' "$TEST_DIR/output-mixed-failure.txt"; then
  echo "==> PASS: a genuine code failure keeps the code classification"
else
  cat "$TEST_DIR/output-mixed-failure.txt" >&2
  exit 1
fi

echo "==> Test: zero-step check failure surfaces its annotation (issue #631)"
reset_case_files
if GH_MERGE_STATE_IMMEDIATE="UNSTABLE MERGEABLE" \
  GH_FAILED_CHECKS=$'validate\tfail\thttps://github.com/autumngarage/example/actions/runs/555/job/1' \
  GH_CLAIM_RUN_REAL_STEPS=0 \
  GH_CHECK_ANNOTATIONS='The job was not started because recent account payments have failed or your spending limit needs to be increased.' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  MERGE_PR_SLEEP_OVERRIDE=0 \
  run_merge_pr "$TEST_DIR/output-infra-annotation.txt" 123; then
  echo "FAIL: zero-step infrastructure failure must still stop the merge" >&2
  exit 1
fi
if grep -q 'annotation: The job was not started because recent account payments' "$TEST_DIR/output-infra-annotation.txt" \
  && grep -q 'CLASSIFICATION: infrastructure startup failure' "$TEST_DIR/output-infra-annotation.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: zero-step failure carries GitHub's own explanation and classification"
else
  cat "$TEST_DIR/output-infra-annotation.txt" >&2
  exit 1
fi

echo "==> Test: dirty path outside the PR diff does not block verification"
reset_case_files
GIT_WORKTREE_STATUS=$' M bootstrap/new-project.sh\n' \
  GIT_CHANGED_PATHS=$'scripts/merge-pr.sh\ntests/test-merge-pr.sh' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-dirty-outside.txt" 123
if grep -q 'Working tree has uncommitted changes outside PR #123' "$TEST_DIR/output-dirty-outside.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: unrelated dirty work does not block the merge gate"
else
  cat "$TEST_DIR/output-dirty-outside.txt" >&2
  exit 1
fi

echo "==> Test: dirty path overlapping the PR diff blocks verification"
reset_case_files
if GIT_WORKTREE_STATUS=$' M scripts/merge-pr.sh\n' \
  GIT_CHANGED_PATHS=$'scripts/merge-pr.sh\ntests/test-merge-pr.sh' \
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  run_merge_pr "$TEST_DIR/output-dirty-overlap.txt" 123; then
  echo "FAIL: overlapping dirty path unexpectedly merged" >&2
  exit 1
fi
if grep -q "uncommitted changes that overlap PR #123's diff" "$TEST_DIR/output-dirty-overlap.txt" \
  && grep -q 'scripts/merge-pr.sh' "$TEST_DIR/output-dirty-overlap.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: overlapping dirty work fails closed"
else
  cat "$TEST_DIR/output-dirty-overlap.txt" >&2
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
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: PR feedback inspection failure fails closed"
else
  echo "FAIL: GraphQL inspection failure should stop before review/merge" >&2
  cat "$TEST_DIR/output-graphql-fail.txt" >&2
  exit 1
fi

echo "==> Test: post-review unresolved thread blocks exact-head merge"
reset_case_files
write_pr_triggered_config true 0 0
if GH_TRUSTED_REVIEWS=$'chatgpt-codex-connector[bot]\tpr-head-oid\tAPPROVED\t2026-06-23T00:00:00Z\thttps://example.test/review/thread' \
  GH_UNRESOLVED_THREADS_SECOND=$'thread-2\tREADME.md\t44\tfalse\treviewer\thttps://example.test/thread/2\tNew feedback after review.' \
  run_merge_pr "$TEST_DIR/output-post-review-thread.txt" 123; then
  echo "FAIL: merge-pr.sh unexpectedly merged after post-review thread appeared" >&2
  exit 1
fi
if grep -q 'Checking PR-visible review feedback for PR #123 (before PR-triggered AI review)' "$TEST_DIR/output-post-review-thread.txt" \
  && grep -q 'Checking PR-visible review feedback for PR #123 (after PR-triggered AI review)' "$TEST_DIR/output-post-review-thread.txt" \
  && grep -q 'README.md:44 by @reviewer' "$TEST_DIR/output-post-review-thread.txt" \
  && grep -q 'New feedback after review' "$TEST_DIR/output-post-review-thread.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: post-review unresolved thread blocks exact-head merge"
else
  echo "FAIL: post-review unresolved thread should stop after review but before merge" >&2
  cat "$TEST_DIR/output-post-review-thread.txt" >&2
  exit 1
fi

echo "==> Test: newer non-clean Codex result during preflight blocks merge"
reset_case_files
write_pr_triggered_config true 0 0
if GH_ISSUE_COMMENTS=$'chatgpt-codex-connector\t2026-06-23T00:00:00Z\thttps://example.test/comment/clean-before-preflight\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  GH_ISSUE_COMMENTS_SECOND=$'chatgpt-codex-connector\t2026-06-23T00:01:00Z\thttps://example.test/comment/findings-during-preflight\tCodex Review: Found a blocking issue. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-pr-triggered-changed-during-preflight.txt" 123; then
  echo "FAIL: merge-pr.sh accepted stale clean evidence after a newer non-clean result" >&2
  exit 1
fi
if grep -q 'latest trusted PR-visible AI result is not clean' "$TEST_DIR/output-pr-triggered-changed-during-preflight.txt" \
  && [ "$(cat "$TEST_DIR/gh-comments-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && [ ! -f "$TEST_DIR/gh-merge-head" ]; then
  echo "==> PASS: latest PR-visible result is revalidated immediately before merge"
else
  echo "FAIL: newer non-clean result during preflight should block merge" >&2
  cat "$TEST_DIR/output-pr-triggered-changed-during-preflight.txt" >&2
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
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" run_merge_pr "$TEST_DIR/output-sibling-worktree.txt" 123
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
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
  GIT_LOCAL_BRANCH_HEAD="new-local-oid" \
  run_merge_pr "$TEST_DIR/output-moved-branch.txt" 123
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
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" run_merge_pr "$TEST_DIR/output-stale-worktree.txt" 123
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
  GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" \
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
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" run_merge_pr "$TEST_DIR/output-primary-checkout.txt" 123
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
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" run_merge_pr "$TEST_DIR/output-worktree-remove.txt" 123
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
GH_TRUSTED_REVIEWS="$CLEAN_TRUSTED_REVIEW" run_merge_pr "$TEST_DIR/output-worktree-dirty.txt" 123
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
if grep -q "No trusted PR-visible review matches branch 'feature/test' at head 'pr-head-oid' and base 'base-oid'" "$TEST_DIR/output-fresh.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ]; then
  echo "==> PASS: fresh-branch bypass rejected"
else
  echo "FAIL: fresh-branch bypass did not fail safely" >&2
  cat "$TEST_DIR/output-fresh.txt" >&2
  exit 1
fi

echo "==> Test: bypass derives eligibility from prior PR-triggered review"
reset_case_files
write_pr_triggered_config false 0 0
GH_REQUEST_RECORDS="$(durable_request_records "2026-06-22T00:00:00Z" "base-oid")" \
GH_ISSUE_COMMENTS=$'chatgpt-codex-connector[bot]\t2026-06-23T00:00:00Z\thttps://example.test/comment/bypass\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-bypass-pr-triggered.txt" 123 --bypass-with-disclosure="reviewer unavailable after prior clean review"
if grep -q 'BYPASSING REVIEWER GATE' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q 'marker: pr-triggered-review' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q 'reason: reviewer unavailable after prior clean review' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q 'Reviewer bypassed via `--bypass-with-disclosure`. Marker: pr-triggered-review. Reason: reviewer unavailable after prior clean review' "$TEST_DIR/gh-comment" \
  && grep -q '^Reviewer-bypass: reviewer unavailable after prior clean review$' "$TEST_DIR/gh-merge-body" \
  && ! grep -q 'Timed out waiting for trusted PR-visible AI review' "$TEST_DIR/output-bypass-pr-triggered.txt" \
  && grep -q '^pr-head-oid$' "$TEST_DIR/gh-merge-head"; then
  echo "==> PASS: rollout bypass derives eligibility from the prior exact-head PR review"
else
  echo "FAIL: rollout bypass should accept the prior exact-head PR review without a local marker" >&2
  cat "$TEST_DIR/output-bypass-pr-triggered.txt" >&2
  exit 1
fi

echo "==> Test: rollout bypass rejects PR review on a behind head"
reset_case_files
write_pr_triggered_config false 0 0
if GH_BASE_REF_OID="new-base-oid" \
  GIT_BASE_OID="new-base-oid" \
  GIT_MERGE_BASE_OID="base-oid" \
  GH_ISSUE_COMMENTS=$'chatgpt-codex-connector[bot]\t2026-06-23T00:00:00Z\thttps://example.test/comment/bypass-behind\tCodex Review: No major issues. **Reviewed commit:** `pr-head-oi`' \
  run_merge_pr "$TEST_DIR/output-bypass-pr-triggered-behind.txt" 123 --bypass-with-disclosure="reviewer unavailable after prior clean review"; then
  echo "FAIL: rollout bypass accepted review evidence that did not cover the current base" >&2
  exit 1
fi
if grep -q 'Refusing reviewer bypass for PR #123 because the reviewed head does not contain the current base' "$TEST_DIR/output-bypass-pr-triggered-behind.txt" \
  && grep -q 'current base: new-base-oid' "$TEST_DIR/output-bypass-pr-triggered-behind.txt" \
  && grep -q 'merge base:   base-oid' "$TEST_DIR/output-bypass-pr-triggered-behind.txt" \
  && [ ! -f "$TEST_DIR/gh-merge-head" ] \
  && [ ! -f "$TEST_DIR/gh-comment" ]; then
  echo "==> PASS: rollout bypass is bound to the current base revision"
else
  echo "FAIL: rollout bypass should enforce the reviewed-base invariant" >&2
  cat "$TEST_DIR/output-bypass-pr-triggered-behind.txt" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# respond-review.sh — the one-command review-finding response (issue #652).
# Folded into this suite because it is part of the PR review/merge surface:
# the merge gate requires resolved threads, and this script owns the
# reply + resolve + verify exchange. Self-contained mock; does not reuse the
# merge mocks above.
# ---------------------------------------------------------------------------
echo "==> respond-review: one-command finding response contract"
RR_SCRIPT="$TOUCHSTONE_ROOT/scripts/respond-review.sh"
RR_BIN="$TEST_DIR/respond-review-bin"
RR_GH_LOG="$TEST_DIR/respond-review-gh.log"
mkdir -p "$RR_BIN"
cat >"$RR_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RR_GH_LOG"
case "${1:-} ${2:-}" in
  "repo view")
    # A placeholder-like token in the real repository identity: textual
    # placeholder substitution would corrupt this (touchstone#676).
    echo "PRNUM-tools/PRNUM-example"
    ;;
  "api graphql")
    count_file="${RR_GRAPHQL_COUNT_FILE:?}"
    count="$(cat "$count_file" 2>/dev/null || echo 0)"
    count=$((count + 1))
    printf '%s' "$count" >"$count_file"
    if [ "$count" -le "${RR_FAIL_GRAPHQL_TIMES:-0}" ]; then
      echo "invalid character '<' looking for beginning of value" >&2
      exit 1
    fi
    case "$*" in
      *"resolveReviewThread"*) echo "${RR_RESOLVE_RESULT:-true}" ;;
      *"node(id:"*) echo "${RR_VERIFY_RESULT:-true}" ;;
      *"reviewThreads"*)
        if [ -n "${RR_THREADS_OUTPUT:-}" ]; then
          printf '%s\n' "$RR_THREADS_OUTPUT"
        fi
        ;;
      *) echo "unexpected graphql: $*" >&2; exit 1 ;;
    esac
    ;;
  "api --paginate")
    case "$*" in
      *"pulls/77/comments"*) printf '%s\n' "${RR_EXISTING_REPLIES:-}" ;;
      *) echo "unexpected paginated api: $*" >&2; exit 1 ;;
    esac
    ;;
  "api repos/PRNUM-tools/PRNUM-example/pulls/77/comments/9001/replies")
    echo "5555"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$RR_BIN/gh"
cat >"$RR_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$RR_BIN/sleep"

run_respond_review() {
  : >"$RR_GH_LOG"
  printf '0' >"$TEST_DIR/respond-review-graphql-count"
  PATH="$RR_BIN:/usr/bin:/bin" \
    RR_GH_LOG="$RR_GH_LOG" \
    RR_GRAPHQL_COUNT_FILE="$TEST_DIR/respond-review-graphql-count" \
    RR_THREADS_OUTPUT="${RR_THREADS_OUTPUT:-}" \
    RR_EXISTING_REPLIES="${RR_EXISTING_REPLIES:-}" \
    RR_RESOLVE_RESULT="${RR_RESOLVE_RESULT:-true}" \
    RR_VERIFY_RESULT="${RR_VERIFY_RESULT:-true}" \
    RR_FAIL_GRAPHQL_TIMES="${RR_FAIL_GRAPHQL_TIMES:-0}" \
    bash "$RR_SCRIPT" "$@"
}

RR_BODY_FILE="$TEST_DIR/respond-review-reply.md"
printf 'Fixed by hardening the check.\n' >"$RR_BODY_FILE"

# Happy path: reply posted, thread resolved, verification read passes, and
# the paginated thread scans are used.
RR_OUT="$TEST_DIR/respond-review-happy.out"
RC=0
RR_THREADS_OUTPUT="THREAD_NODE_1" run_respond_review 77 --comment-id 9001 --body-file "$RR_BODY_FILE" >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" = 0 ] \
  && grep -q 'reply id: 5555' "$RR_OUT" \
  && grep -q 'Replied and resolved' "$RR_OUT" \
  && grep -q -- '--paginate' "$RR_GH_LOG" \
  && grep -q 'resolveReviewThread' "$RR_GH_LOG"; then
  echo "    PASS: happy path replies, resolves, verifies via paginated scans"
else
  echo "FAIL: respond-review happy path (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi

# Fix-commit trailer and idempotency marker both land in the reply payload.
RC=0
RR_THREADS_OUTPUT="THREAD_NODE_1" run_respond_review 77 --comment-id 9001 --body-file "$RR_BODY_FILE" --fix-commit abc1234 >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" = 0 ] \
  && grep -q 'Fixed in abc1234' "$RR_GH_LOG" \
  && grep -q 'touchstone:respond-review comment=9001' "$RR_GH_LOG"; then
  echo "    PASS: fix-commit trailer and idempotency marker in reply"
else
  echo "FAIL: respond-review trailer/marker (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi

# Rerun after a posted reply: the marker suppresses a duplicate post.
RC=0
RR_THREADS_OUTPUT="THREAD_NODE_1" \
  RR_EXISTING_REPLIES="prior reply body
<!-- touchstone:respond-review comment=9001 -->" \
  run_respond_review 77 --comment-id 9001 --body-file "$RR_BODY_FILE" >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" = 0 ] \
  && grep -q 'already posted (marker found); skipping the reply step' "$RR_OUT" \
  && ! grep -q 'replies' "$RR_GH_LOG"; then
  echo "    PASS: rerun is idempotent after a posted reply"
else
  echo "FAIL: respond-review idempotent rerun (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi

# Verification failure exits nonzero (the mutation response alone cannot be
# trusted).
RC=0
RR_THREADS_OUTPUT="THREAD_NODE_1" RR_VERIFY_RESULT=false \
  run_respond_review 77 --comment-id 9001 --body-file "$RR_BODY_FILE" >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ] && grep -q 'still unresolved after the mutation' "$RR_OUT"; then
  echo "    PASS: verification failure exits nonzero"
else
  echo "FAIL: respond-review verification failure (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi

# Transient GraphQL failures retry then succeed.
RC=0
RR_THREADS_OUTPUT="THREAD_NODE_1" RR_FAIL_GRAPHQL_TIMES=1 \
  run_respond_review 77 --comment-id 9001 --body-file "$RR_BODY_FILE" >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" = 0 ] && grep -q 'retrying in' "$RR_OUT"; then
  echo "    PASS: transient GraphQL failure retries then succeeds"
else
  echo "FAIL: respond-review transient retry (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi

# --all-resolved-check gates on open threads and lists them.
RC=0
RR_THREADS_OUTPUT="" run_respond_review 77 --all-resolved-check >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ]; then
  echo "FAIL: respond-review clean resolved-check (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi
RC=0
RR_THREADS_OUTPUT="$(printf 'THREAD_NODE_2\t9002\tscripts/foo.sh')" \
  run_respond_review 77 --all-resolved-check >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ] && grep -q 'comment 9002 (scripts/foo.sh)' "$RR_OUT"; then
  echo "    PASS: --all-resolved-check gates on open threads"
else
  echo "FAIL: respond-review dirty resolved-check (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi

# Unknown comment id fails before any mutation.
RC=0
RR_THREADS_OUTPUT="" run_respond_review 77 --comment-id 9001 --body-file "$RR_BODY_FILE" >"$RR_OUT" 2>&1 || RC=$?
if [ "$RC" != 0 ] \
  && grep -q 'no review thread found' "$RR_OUT" \
  && ! grep -q 'resolveReviewThread' "$RR_GH_LOG"; then
  echo "    PASS: unknown comment id fails before any mutation"
else
  echo "FAIL: respond-review unknown comment (rc=$RC)" >&2
  cat "$RR_OUT" >&2
  exit 1
fi

# Propagation: the script must reach downstream projects through every
# distribution surface — bootstrap copy, update sync, the sync-discipline
# planned-write boundary, and preflight's delivery-only classification.
for propagation_file in \
  "bootstrap/new-project.sh" \
  "bootstrap/update-project.sh" \
  "lib/sync-discipline.sh" \
  "lib/preflight.sh"; do
  if ! grep -q 'scripts/respond-review\.sh' "$TOUCHSTONE_ROOT/$propagation_file"; then
    echo "FAIL: $propagation_file does not register scripts/respond-review.sh" >&2
    exit 1
  fi
done
echo "    PASS: respond-review registered across all distribution surfaces"

# Repository identity must travel as GraphQL variables — never substituted
# into the query text, where a PRNUM-like repo name gets corrupted.
if grep -q -- '-f owner=PRNUM-tools' "$RR_GH_LOG" \
  && grep -q -- '-f name=PRNUM-example' "$RR_GH_LOG" \
  && grep -q -- '-F pr=77' "$RR_GH_LOG" \
  && grep -q 'repository(owner:\$owner, name:\$name)' "$RR_GH_LOG" \
  && ! grep -q 'repository(owner:"PRNUM-tools"' "$RR_GH_LOG"; then
  echo "    PASS: repository identity travels as GraphQL variables"
else
  echo "FAIL: respond-review must pass owner/name/pr as GraphQL variables" >&2
  grep 'graphql' "$RR_GH_LOG" | head -3 >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> PASS: merge gate requires deterministic checks plus exact-revision PR review"
