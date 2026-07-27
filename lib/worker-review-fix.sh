#!/usr/bin/env bash
#
# Bounded autonomous repair of actionable GitHub PR review threads.

# shellcheck source=codex-auth.sh
source "$TOUCHSTONE_ROOT/lib/codex-auth.sh"

touchstone_review_fix_set_state() {
  local job_dir="$1" worktree_path="$2" status="$3"
  touchstone_ship_write "$job_dir" status "$status"
  touchstone_emit_event "${status//-/_}" worktree_path="$worktree_path"
}

touchstone_review_fix_need_attention() {
  local job_dir="$1" worktree_path="$2" reason="$3"
  TOUCHSTONE_REVIEW_FIX_REASON="$reason"
  touchstone_ship_write "$job_dir" reason "$reason"
  touchstone_review_fix_set_state "$job_dir" "$worktree_path" needs-attention
  return 1
}

touchstone_review_fix_pr_number() {
  local branch="$1"
  gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty'
}

touchstone_review_fix_pr_head() {
  local pr_number="$1"
  gh pr view "$pr_number" --json headRefOid --jq '.headRefOid'
}

touchstone_review_fix_repo_name() {
  gh repo view --json nameWithOwner --jq '.nameWithOwner'
}

touchstone_review_fix_viewer_login() {
  gh api user --jq '.login'
}

touchstone_review_fix_trusted_authors() {
  local worktree_path="$1" base_ref="$2"
  local config_file="" rel="" parsed_authors="" authors_configured=false

  for rel in .touchstone-review.toml .codex-review.toml; do
    if git -C "$worktree_path" cat-file -e "$base_ref:$rel" 2>/dev/null; then
      config_file="$(mktemp -t touchstone-review-fix-config.XXXXXX)" || return 1
      git -C "$worktree_path" show "$base_ref:$rel" >"$config_file" || {
        rm -f "$config_file"
        return 1
      }
      break
    fi
  done

  if [ -n "$config_file" ]; then
    # shellcheck source=toml.sh
    source "$TOUCHSTONE_ROOT/lib/toml.sh"
    touchstone_review_fix_config_callback() {
      local section="$1" key="$2" value="$3"
      if [ "$section" = "review.pr_triggered" ] && [ "$key" = "trusted_review_authors" ]; then
        authors_configured=true
        parsed_authors="$(toml_normalize_array "$value")"
      fi
    }
    toml_parse "$config_file" touchstone_review_fix_config_callback || {
      rm -f "$config_file"
      return 1
    }
    rm -f "$config_file"
  fi

  if [ "$authors_configured" = true ]; then
    printf '%s' "$parsed_authors"
  else
    printf '%s' "chatgpt-codex-connector,chatgpt-codex-connector[bot]"
  fi
}

touchstone_review_fix_author_is_trusted() {
  local author="$1" trusted_csv="$2" trusted=""
  local IFS=','

  for trusted in $trusted_csv; do
    [ "$author" = "$trusted" ] && return 0
  done
  return 1
}

touchstone_review_fix_threads() {
  local repo_full_name="$1" pr_number="$2" owner name query raw_file
  local thread_id path line outdated author review_head truncated comment_count
  local comment_ids snapshot_encoded url body snapshot_digest
  owner="${repo_full_name%%/*}"
  name="${repo_full_name#*/}"
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
  query='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          comments(first: 100) {
            totalCount
            nodes {
              id
              author { login }
              body
              updatedAt
              url
              pullRequestReview { commit { oid } }
            }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'
  raw_file="$(mktemp -t touchstone-review-fix-threads.XXXXXX)" || return 1
  if ! gh api graphql --paginate \
    -F owner="$owner" \
    -F name="$name" \
    -F number="$pr_number" \
    -f query="$query" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | [.id, (.path // "<no-path>"), ((.line // .startLine // "<no-line>") | tostring), (.isOutdated | tostring), (.comments.nodes[0].author.login // "<no-author>"), (.comments.nodes[0].pullRequestReview.commit.oid // "<no-review-head>"), (((.comments.nodes[0].body // "") | length > 1000) | tostring), (.comments.totalCount | tostring), ((.comments.nodes | map(.id) | join(",")) | if length == 0 then "<no-comment-ids>" else . end), (.comments.nodes | map({id: .id, updatedAt: .updatedAt, body: (.body // "")}) | tojson | @base64), (.comments.nodes[0].url // "<no-url>"), (((.comments.nodes[0].body // "") | gsub("[\r\n\t]"; " ") | .[0:1000]) | if length == 0 then "<empty-body>" else . end)] | @tsv' \
    >"$raw_file"; then
    rm -f "$raw_file"
    return 1
  fi

  while IFS="$(printf '\t')" read -r thread_id path line outdated author review_head truncated \
    comment_count comment_ids snapshot_encoded url body || [ -n "$thread_id" ]; do
    [ -n "$thread_id" ] || continue
    snapshot_digest="$(printf '%s' "$snapshot_encoded" | git hash-object --stdin)" || {
      rm -f "$raw_file"
      return 1
    }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$thread_id" "$path" "$line" "$outdated" "$author" "$review_head" "$truncated" \
      "$comment_count" "$comment_ids" "$snapshot_digest" "$url" "$body"
  done <"$raw_file"
  rm -f "$raw_file"
}

touchstone_review_fix_thread_key() {
  printf '%s' "$1" | git hash-object --stdin
}

touchstone_review_fix_marker() {
  local source_head="$1" fix_head="$2" thread_id="$3"
  printf '<!-- touchstone-review-fix:%s:%s:%s -->' "$source_head" "$fix_head" "$thread_id"
}

touchstone_review_fix_thread_remote_state() {
  local thread_id="$1" marker="$2" expected_count="$3" expected_ids="$4" expected_digest="$5"
  local reply_author="$6"
  local query remote_state resolved total_count loaded_count nonmarker_count marker_count
  local nonmarker_ids snapshot_encoded snapshot_digest replied=false snapshot_matches=false
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
  query='
query($id: ID!) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      isResolved
      comments(first: 100) {
        totalCount
        nodes { id body updatedAt author { login } }
      }
    }
  }
}'
  remote_state="$(gh api graphql \
    -F id="$thread_id" \
    -f query="$query" \
    --jq "[.data.node.isResolved, (.data.node.comments.totalCount | tostring), (.data.node.comments.nodes | length | tostring), ([.data.node.comments.nodes[]? | select(((((.body // \"\") | endswith(\"$marker\")) and (.author.login == \"$reply_author\"))) | not)] | length | tostring), ([.data.node.comments.nodes[]? | select(((.body // \"\") | endswith(\"$marker\")) and (.author.login == \"$reply_author\"))] | length | tostring), (([.data.node.comments.nodes[]? | select(((((.body // \"\") | endswith(\"$marker\")) and (.author.login == \"$reply_author\"))) | not) | .id] | join(\",\")) | if length == 0 then \"<no-comment-ids>\" else . end), ([.data.node.comments.nodes[]? | select(((((.body // \"\") | endswith(\"$marker\")) and (.author.login == \"$reply_author\"))) | not) | {id: .id, updatedAt: .updatedAt, body: (.body // \"\")}] | tojson | @base64)] | @tsv")" || return 1

  IFS="$(printf '\t')" read -r resolved total_count loaded_count nonmarker_count marker_count \
    nonmarker_ids snapshot_encoded <<EOF
$remote_state
EOF
  snapshot_digest="$(printf '%s' "$snapshot_encoded" | git hash-object --stdin)" || return 1
  [ "$marker_count" = "1" ] && replied=true
  if [ "$total_count" = "$loaded_count" ] \
    && [ "$nonmarker_count" = "$expected_count" ] \
    && [ "$nonmarker_ids" = "$expected_ids" ] \
    && [ "$snapshot_digest" = "$expected_digest" ] \
    && { [ "$marker_count" = "0" ] || [ "$marker_count" = "1" ]; }; then
    snapshot_matches=true
  fi
  printf '%s\t%s\t%s\n' "$resolved" "$replied" "$snapshot_matches"
}

touchstone_review_fix_reply() {
  local thread_id="$1" body="$2" query
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
  query='
mutation($thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(
    input: { pullRequestReviewThreadId: $thread, body: $body }
  ) { comment { id } }
}'
  gh api graphql -F thread="$thread_id" -f body="$body" -f query="$query" >/dev/null
}

touchstone_review_fix_resolve() {
  local thread_id="$1" query
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
  query='
mutation($thread: ID!) {
  resolveReviewThread(input: { threadId: $thread }) {
    thread { id isResolved }
  }
}'
  gh api graphql -F thread="$thread_id" -f query="$query" >/dev/null
}

touchstone_review_fix_unresolve() {
  local thread_id="$1" query
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
  query='
mutation($thread: ID!) {
  unresolveReviewThread(input: { threadId: $thread }) {
    thread { id isResolved }
  }
}'
  gh api graphql -F thread="$thread_id" -f query="$query" >/dev/null
}

touchstone_review_fix_write_brief() {
  local brief_file="$1" worktree_path="$2" pr_number="$3" source_head="$4"
  local threads_file="$5" validation_command="$6"
  {
    cat <<EOF
You are the authorized code worker for a bounded Touchstone PR review-fix iteration.

Repository worktree: $worktree_path
Pull request: #$pr_number
Exact source head: $source_head
Validation command: $validation_command

Read AGENTS.md and every routed repository instruction that applies. Address
only the actionable review threads below with the smallest root-cause fixes.
If any feedback is ambiguous, conflicts with repository steering, or cannot be
fixed safely, do not guess: report TOUCHSTONE_REVIEW_FIX_NEEDS_ATTENTION.

Do not commit, push, reply to GitHub, or resolve threads. Touchstone owns those
credentialed and irreversible steps after it validates your edits. Do not edit
the persisted result file until your code changes are complete.

When every thread is fixed, make the final response exactly:
TOUCHSTONE_REVIEW_FIX_FIXED
thread_id=<id>

Include one thread_id line for every thread and no unknown IDs.

Unresolved review threads (tab-separated id, path, line, outdated, author, review head, body truncated, comment count, comment IDs, comment snapshot, URL, body):
EOF
    cat "$threads_file"
  } >"$brief_file"
}

touchstone_review_fix_invoke_worker() {
  local worktree_path="$1" brief_file="$2" result_file="$3"
  local worker_command="${TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND:-}"
  local auth_rc=0

  : >"$result_file"
  if [ -n "$worker_command" ]; then
    [ -x "$worker_command" ] || return 127
    TOUCHSTONE_REVIEW_FIX_RESULT_FILE="$result_file" \
      TOUCHSTONE_REVIEW_FIX_BRIEF_FILE="$brief_file" \
      "$worker_command" "$worktree_path" "$brief_file" "$result_file"
    return
  fi

  touchstone_codex_subscription_auth_check || auth_rc=$?
  if [ "$auth_rc" -ne 0 ]; then
    echo "ERROR: autonomous review-fix requires a ChatGPT-authenticated Codex CLI." >&2
    echo "       Refusing API-key, unknown, or unverifiable authentication to avoid metered review spend." >&2
    return "$auth_rc"
  fi
  codex exec \
    --ephemeral \
    --sandbox workspace-write \
    -c 'approval_policy="never"' \
    -C "$worktree_path" \
    --output-last-message "$result_file" \
    - <"$brief_file"
}

touchstone_review_fix_result_is_complete() {
  local result_file="$1" threads_file="$2" expected_file actual_file first_line
  expected_file="${result_file}.expected"
  actual_file="${result_file}.actual"
  IFS= read -r first_line <"$result_file" || return 1
  [ "$first_line" = "TOUCHSTONE_REVIEW_FIX_FIXED" ] || return 1
  cut -f1 "$threads_file" \
    | sed '/^$/d; s/^/thread_id=/' \
    | LC_ALL=C sort >"$expected_file"
  sed '1d' "$result_file" >"$actual_file"
  [ -s "$actual_file" ] || return 1
  if grep -Ev '^thread_id=.+$' "$actual_file" >/dev/null; then
    return 1
  fi
  LC_ALL=C sort -o "$actual_file" "$actual_file"
  cmp -s "$expected_file" "$actual_file"
}

touchstone_review_fix_changed_paths() {
  local worktree_path="$1"
  {
    git -C "$worktree_path" diff --no-renames --name-only -z
    git -C "$worktree_path" ls-files --others --exclude-standard -z
  }
}

touchstone_review_fix_commit() {
  local worktree_path="$1" paths_file="$2" path
  local -a paths=()
  while IFS= read -r -d '' path; do
    [ -n "$path" ] && paths+=("$path")
  done <"$paths_file"
  [ "${#paths[@]}" -gt 0 ] || return 1
  git -C "$worktree_path" add -- "${paths[@]}"
  git -C "$worktree_path" diff --cached --quiet && return 1
  git -C "$worktree_path" commit -m "fix: address PR review feedback"
}

touchstone_review_fix_validate() {
  local worktree_path="$1" validation_command="$2" base_ref="$3" paths_file="$4"
  if [ -n "$validation_command" ]; then
    (cd "$worktree_path" && bash -lc "$validation_command")
    return
  fi
  [ -f "$worktree_path/lib/preflight.sh" ] || return 1
  (
    cd "$worktree_path" || exit 1
    # shellcheck source=lib/preflight.sh
    source lib/preflight.sh
    compute_changed_paths_against() {
      local requested_base="$1" path
      git diff --name-only "$requested_base"...HEAD
      while IFS= read -r -d '' path; do
        case "$path" in
          *$'\n'*)
            echo "ERROR: preflight cannot safely scope a path containing a newline: $path" >&2
            return 2
            ;;
        esac
        printf '%s\n' "$path"
      done <"$paths_file"
    }
    export TOUCHSTONE_PREFLIGHT_DISABLE_CACHE=1
    touchstone_preflight_main --diff "$base_ref" "$worktree_path"
  )
}

touchstone_review_fix_checkpoint_threads() {
  local job_dir="$1" source_head="$2" threads_file="$3" repo_full_name="$4" pr_number="$5"
  local reply_author="$6"
  mkdir -p "$job_dir/review-fix"
  cp "$threads_file" "$job_dir/review-fix/threads.tsv"
  touchstone_ship_write "$job_dir/review-fix" source-head "$source_head"
  touchstone_ship_write "$job_dir/review-fix" fix-head ""
  touchstone_ship_write "$job_dir/review-fix" repo-full-name "$repo_full_name"
  touchstone_ship_write "$job_dir/review-fix" pr-number "$pr_number"
  touchstone_ship_write "$job_dir/review-fix" reply-author "$reply_author"
}

touchstone_review_fix_finish_threads() {
  local job_dir="$1" worktree_path="$2" pr_number="$3" source_head="$4" fix_head="$5"
  local threads_file="$job_dir/review-fix/threads.tsv"
  local thread_id path line _outdated _author _review_head _truncated comment_count
  local comment_ids comment_snapshot _url _body marker remote_state resolved replied
  local snapshot_matches key body location observed_head reply_author

  reply_author="$(touchstone_ship_read "$job_dir/review-fix" reply-author)"
  [ -n "$reply_author" ] || return 1

  observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || return 1
  [ "$observed_head" = "$fix_head" ] || return 3

  while IFS="$(printf '\t')" read -r thread_id path line _outdated _author _review_head _truncated \
    comment_count comment_ids comment_snapshot _url _body \
    || [ -n "$thread_id" ]; do
    [ -n "$thread_id" ] || continue
    key="$(touchstone_review_fix_thread_key "$thread_id")"
    [ -f "$job_dir/review-fix/resolved-$key" ] && continue
    marker="$(touchstone_review_fix_marker "$source_head" "$fix_head" "$thread_id")"

    observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || return 1
    [ "$observed_head" = "$fix_head" ] || return 3
    remote_state="$(touchstone_review_fix_thread_remote_state \
      "$thread_id" "$marker" "$comment_count" "$comment_ids" "$comment_snapshot" \
      "$reply_author")" || return 1
    IFS="$(printf '\t')" read -r resolved replied snapshot_matches <<EOF
$remote_state
EOF
    if [ "$resolved" = "true" ] && [ "$snapshot_matches" = "true" ]; then
      touchstone_ship_write "$job_dir/review-fix" "resolved-$key" "$fix_head"
      continue
    fi
    [ "$resolved" != "true" ] || return 5
    [ "$snapshot_matches" = "true" ] || return 5

    if [ "$replied" != "true" ]; then
      location="${path:-review thread}${line:+:$line}"
      body="Fixed $location in \`$(printf '%.12s' "$fix_head")\` and validated locally. $marker"
      touchstone_review_fix_reply "$thread_id" "$body" || return 1
      observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || return 1
      [ "$observed_head" = "$fix_head" ] || return 4
      remote_state="$(touchstone_review_fix_thread_remote_state \
        "$thread_id" "$marker" "$comment_count" "$comment_ids" "$comment_snapshot" \
        "$reply_author")" || return 1
      IFS="$(printf '\t')" read -r resolved replied snapshot_matches <<EOF
$remote_state
EOF
      if [ "$resolved" = "true" ] && [ "$snapshot_matches" = "true" ]; then
        touchstone_ship_write "$job_dir/review-fix" "resolved-$key" "$fix_head"
        continue
      fi
      [ "$resolved" != "true" ] || return 5
      [ "$replied" = "true" ] && [ "$snapshot_matches" = "true" ] || return 5
    fi

    touchstone_review_fix_resolve "$thread_id" || return 1
    observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || return 1
    if [ "$observed_head" != "$fix_head" ]; then
      touchstone_review_fix_unresolve "$thread_id" || true
      return 4
    fi
    remote_state="$(touchstone_review_fix_thread_remote_state \
      "$thread_id" "$marker" "$comment_count" "$comment_ids" "$comment_snapshot" \
      "$reply_author")" || {
      touchstone_review_fix_unresolve "$thread_id" || true
      return 1
    }
    IFS="$(printf '\t')" read -r resolved replied snapshot_matches <<EOF
$remote_state
EOF
    if [ "$resolved" != "true" ] \
      || [ "$replied" != "true" ] \
      || [ "$snapshot_matches" != "true" ]; then
      [ "$resolved" != "true" ] || touchstone_review_fix_unresolve "$thread_id" || return 1
      return 5
    fi
    observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || {
      touchstone_review_fix_unresolve "$thread_id" || true
      return 1
    }
    if [ "$observed_head" != "$fix_head" ]; then
      touchstone_review_fix_unresolve "$thread_id" || true
      return 4
    fi
    touchstone_ship_write "$job_dir/review-fix" "resolved-$key" "$fix_head"
  done <"$threads_file"

  observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || return 1
  [ "$observed_head" = "$fix_head" ] || return 4

  touchstone_emit_event fix_pushed \
    worktree_path="$worktree_path" pr_number="$pr_number" head_sha="$fix_head"
}

touchstone_review_fix_resume_checkpoint() {
  local job_dir="$1" worktree_path="$2" repo_full_name="$3" pr_number="$4" observed_head="$5"
  local source_head fix_head checkpoint_repo checkpoint_pr finish_rc=0
  local reply_author
  source_head="$(touchstone_ship_read "$job_dir/review-fix" source-head)"
  fix_head="$(touchstone_ship_read "$job_dir/review-fix" fix-head)"
  checkpoint_repo="$(touchstone_ship_read "$job_dir/review-fix" repo-full-name)"
  checkpoint_pr="$(touchstone_ship_read "$job_dir/review-fix" pr-number)"
  reply_author="$(touchstone_ship_read "$job_dir/review-fix" reply-author)"
  [ -n "$source_head" ] && [ -n "$fix_head" ] || return 1
  [ -n "$reply_author" ] || return 2
  [ "$checkpoint_repo" = "$repo_full_name" ] && [ "$checkpoint_pr" = "$pr_number" ] || return 2
  [ "$observed_head" = "$fix_head" ] || return 2
  touchstone_review_fix_finish_threads \
    "$job_dir" "$worktree_path" "$pr_number" "$source_head" "$fix_head" || finish_rc=$?
  [ "$finish_rc" -eq 0 ] || return "$finish_rc"
  rm -rf "$job_dir/review-fix"
}

touchstone_review_fix_run_child() {
  local job_dir="$1" deadline_epoch now_epoch exit_code monitor_was_enabled=false
  shift
  case "$-" in
    *m*) monitor_was_enabled=true ;;
    *) set -m ;;
  esac
  "$@" &
  child_pid=$!
  [ "$monitor_was_enabled" = true ] || set +m
  touchstone_ship_write "$job_dir" child-pid "$child_pid"
  deadline_epoch="$(touchstone_ship_read "$job_dir" deadline-epoch)"
  while kill -0 "$child_pid" 2>/dev/null; do
    case "$deadline_epoch" in
      '' | *[!0-9]*) ;;
      *)
        now_epoch="$(date +%s)"
        if [ "$now_epoch" -ge "$deadline_epoch" ]; then
          kill -TERM -- "-$child_pid" 2>/dev/null || true
          sleep 0.2
          kill -KILL -- "-$child_pid" 2>/dev/null || true
          wait "$child_pid" 2>/dev/null || true
          return 124
        fi
        ;;
    esac
    sleep 0.1
  done
  if wait "$child_pid"; then
    exit_code=0
  else
    exit_code=$?
  fi
  return "$exit_code"
}

touchstone_review_fix_in_worktree() {
  local worktree_path="$1"
  shift
  cd "$worktree_path" && "$@"
}

touchstone_review_fix_capture_phase() {
  local job_dir="$1" output_file="$2" worktree_path="$3"
  shift 3
  : >"$output_file"
  touchstone_review_fix_run_child \
    "$job_dir" touchstone_review_fix_in_worktree "$worktree_path" "$@" >"$output_file"
}

touchstone_review_fix_stop_for_phase() {
  local job_dir="$1" worktree_path="$2" exit_code="$3" failure_reason="$4"
  if [ "$exit_code" -eq 124 ]; then
    touchstone_review_fix_need_attention "$job_dir" "$worktree_path" time-budget-exhausted
  else
    touchstone_review_fix_need_attention "$job_dir" "$worktree_path" "$failure_reason"
  fi
}

touchstone_review_fix_wait_for_head() {
  local worktree_path="$1" pr_number="$2" expected_head="$3" deadline_epoch="$4"
  local wait_seconds="${TOUCHSTONE_REVIEW_FIX_HEAD_WAIT_SECONDS:-30}"
  local started_epoch now_epoch observed_head
  case "$wait_seconds" in
    '' | *[!0-9]*) wait_seconds=30 ;;
  esac
  started_epoch="$(date +%s)"
  while :; do
    observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || return 1
    [ "$observed_head" = "$expected_head" ] && return 0
    now_epoch="$(date +%s)"
    if [ "$now_epoch" -ge "$deadline_epoch" ] \
      || [ $((now_epoch - started_epoch)) -ge "$wait_seconds" ]; then
      return 1
    fi
    sleep 1
  done
}

touchstone_review_fix_run() {
  local job_dir="$1" worktree_path="$2" max_iterations="$3" deadline_epoch="$4"
  local validation_command="$5" cleanup="$6"
  local branch pr_number repo_full_name base_ref iteration observed_head source_head fix_head
  local threads_file brief_file result_file paths_file open_pr_exit now_epoch validation_display
  local trusted_authors thread_id _path _line thread_outdated thread_author thread_review_head
  local thread_body_truncated thread_comment_count _comment_ids _comment_snapshot _url _body
  local finish_rc resume_rc phase_rc phase_output reply_author
  local -a open_pr_args=(--auto-merge)

  # Dynamically scoped for cmd_ship_runner, which persists the terminal reason.
  # shellcheck disable=SC2034
  TOUCHSTONE_REVIEW_FIX_REASON=""
  branch="$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD)" || return 1
  base_ref="$(cd "$worktree_path" && touchstone_worker_default_ref)" || {
    touchstone_review_fix_need_attention "$job_dir" "$worktree_path" base-ref-unavailable
    return
  }
  [ "$cleanup" = true ] && open_pr_args+=(--cleanup-worktree)
  iteration="$(touchstone_ship_read "$job_dir" review-fix-iteration)"
  case "$iteration" in
    '' | *[!0-9]*) iteration=0 ;;
  esac

  while :; do
    now_epoch="$(date +%s)"
    if [ "$now_epoch" -ge "$deadline_epoch" ]; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" time-budget-exhausted
      return
    fi

    phase_output="$job_dir/pr-number.out"
    phase_rc=0
    touchstone_review_fix_capture_phase \
      "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_pr_number "$branch" \
      || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" pr-inspection-failed
      return
    fi
    pr_number="$(cat "$phase_output")"
    if [ -n "$pr_number" ]; then
      phase_rc=0
      touchstone_review_fix_capture_phase \
        "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_pr_head "$pr_number" \
        || phase_rc=$?
      if [ "$phase_rc" -ne 0 ]; then
        touchstone_review_fix_stop_for_phase \
          "$job_dir" "$worktree_path" "$phase_rc" head-inspection-failed
        return
      fi
      observed_head="$(cat "$phase_output")"
      if [ -d "$job_dir/review-fix" ]; then
        phase_rc=0
        touchstone_review_fix_capture_phase \
          "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_repo_name \
          || phase_rc=$?
        if [ "$phase_rc" -ne 0 ]; then
          touchstone_review_fix_stop_for_phase \
            "$job_dir" "$worktree_path" "$phase_rc" repository-inspection-failed
          return
        fi
        repo_full_name="$(cat "$phase_output")"
        resume_rc=0
        touchstone_review_fix_run_child \
          "$job_dir" touchstone_review_fix_resume_checkpoint \
          "$job_dir" "$worktree_path" "$repo_full_name" "$pr_number" "$observed_head" \
          || resume_rc=$?
        if [ "$resume_rc" -eq 0 ]; then
          :
        elif [ "$resume_rc" -eq 124 ]; then
          touchstone_review_fix_need_attention "$job_dir" "$worktree_path" time-budget-exhausted
          return
        elif [ "$resume_rc" -eq 3 ] || [ "$resume_rc" -eq 4 ]; then
          touchstone_review_fix_need_attention "$job_dir" "$worktree_path" head-changed-during-thread-update
          return
        elif [ "$resume_rc" -eq 5 ]; then
          touchstone_review_fix_need_attention "$job_dir" "$worktree_path" review-thread-changed
          return
        else
          touchstone_review_fix_need_attention "$job_dir" "$worktree_path" checkpoint-head-mismatch
          return
        fi
      fi
    fi

    touchstone_review_fix_set_state "$job_dir" "$worktree_path" review-waiting
    touchstone_emit_event review_requested \
      worktree_path="$worktree_path" pr_number="${pr_number:-}" head_sha="${observed_head:-}"
    open_pr_exit=0
    # shellcheck disable=SC2016 # Positional parameters belong to bash -c.
    touchstone_review_fix_run_child \
      "$job_dir" bash -c 'cd "$1" && shift && bash scripts/open-pr.sh "$@"' \
      _ "$worktree_path" "${open_pr_args[@]}" || open_pr_exit=$?
    if [ "$open_pr_exit" -eq 0 ]; then
      fix_head="$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || true)"
      touchstone_emit_event merged \
        worktree_path="$worktree_path" pr_number="${pr_number:-}" head_sha="$fix_head"
      return 0
    fi
    if [ "$open_pr_exit" -eq 124 ]; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" time-budget-exhausted
      return
    fi

    phase_rc=0
    touchstone_review_fix_capture_phase \
      "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_pr_number "$branch" \
      || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" pr-inspection-failed
      return
    fi
    pr_number="$(cat "$phase_output")"
    [ -n "$pr_number" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" pr-not-open
      return
    }
    phase_rc=0
    touchstone_review_fix_capture_phase \
      "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_repo_name \
      || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" repository-inspection-failed
      return
    fi
    repo_full_name="$(cat "$phase_output")"
    phase_rc=0
    touchstone_review_fix_capture_phase \
      "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_pr_head "$pr_number" \
      || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" head-inspection-failed
      return
    fi
    source_head="$(cat "$phase_output")"
    [ "$source_head" = "$(git -C "$worktree_path" rev-parse HEAD)" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" local-remote-head-mismatch
      return
    }
    [ -z "$(git -C "$worktree_path" status --porcelain)" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" dirty-worktree
      return
    }

    threads_file="$job_dir/threads-$source_head.tsv"
    phase_rc=0
    touchstone_review_fix_run_child \
      "$job_dir" touchstone_review_fix_in_worktree "$worktree_path" \
      touchstone_review_fix_threads "$repo_full_name" "$pr_number" >"$threads_file" \
      || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" thread-inspection-failed
      return
    fi
    [ -s "$threads_file" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" non-thread-merge-failure
      return
    }
    trusted_authors="$(touchstone_review_fix_trusted_authors "$worktree_path" "$base_ref")" || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" trusted-author-config-invalid
      return
    }
    while IFS="$(printf '\t')" read -r thread_id _path _line thread_outdated thread_author thread_review_head \
      thread_body_truncated thread_comment_count _comment_ids _comment_snapshot _url _body \
      || [ -n "$thread_id" ]; do
      [ -n "$thread_id" ] || continue
      if [ "$thread_outdated" = "true" ]; then
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" outdated-thread-ambiguous
        return
      fi
      if ! touchstone_review_fix_author_is_trusted "$thread_author" "$trusted_authors"; then
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" untrusted-review-author
        return
      fi
      if [ -z "$thread_review_head" ] || [ "$thread_review_head" != "$source_head" ]; then
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" stale-review-thread
        return
      fi
      if [ "$thread_body_truncated" = "true" ]; then
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" review-thread-body-truncated
        return
      fi
      if [ "$thread_comment_count" != "1" ]; then
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" review-thread-has-follow-ups
        return
      fi
    done <"$threads_file"
    phase_rc=0
    touchstone_review_fix_capture_phase \
      "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_pr_head "$pr_number" \
      || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" head-inspection-failed
      return
    fi
    observed_head="$(cat "$phase_output")"
    [ "$observed_head" = "$source_head" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" stale-review-head
      return
    }
    if [ "$iteration" -ge "$max_iterations" ]; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" iteration-budget-exhausted
      return
    fi

    iteration=$((iteration + 1))
    touchstone_ship_write "$job_dir" review-fix-iteration "$iteration"
    phase_rc=0
    touchstone_review_fix_capture_phase \
      "$job_dir" "$phase_output" "$worktree_path" touchstone_review_fix_viewer_login \
      || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" github-viewer-inspection-failed
      return
    fi
    reply_author="$(cat "$phase_output")"
    [ -n "$reply_author" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" github-viewer-inspection-failed
      return
    }
    touchstone_review_fix_checkpoint_threads \
      "$job_dir" "$source_head" "$threads_file" "$repo_full_name" "$pr_number" "$reply_author"
    brief_file="$job_dir/review-fix/brief.md"
    result_file="$job_dir/review-fix/result.txt"
    paths_file="$job_dir/review-fix/paths.zlist"
    validation_display="$validation_command"
    if [ -z "$validation_display" ]; then
      validation_display="bash lib/preflight.sh --diff $base_ref $worktree_path"
    fi
    touchstone_review_fix_write_brief \
      "$brief_file" "$worktree_path" "$pr_number" "$source_head" \
      "$threads_file" "$validation_display"
    touchstone_review_fix_set_state "$job_dir" "$worktree_path" fixing
    if ! touchstone_review_fix_run_child \
      "$job_dir" touchstone_review_fix_invoke_worker \
      "$worktree_path" "$brief_file" "$result_file"; then
      if [ "$(date +%s)" -ge "$deadline_epoch" ]; then
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" time-budget-exhausted
      else
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" code-worker-failed
      fi
      return
    fi
    if ! touchstone_review_fix_result_is_complete "$result_file" "$threads_file"; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" ambiguous-worker-result
      return
    fi
    [ "$source_head" = "$(git -C "$worktree_path" rev-parse HEAD)" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" worker-created-commit
      return
    }
    git -C "$worktree_path" diff --cached --quiet || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" worker-staged-changes
      return
    }
    touchstone_review_fix_changed_paths "$worktree_path" >"$paths_file"
    [ -s "$paths_file" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" worker-made-no-changes
      return
    }
    phase_rc=0
    touchstone_review_fix_run_child \
      "$job_dir" touchstone_review_fix_validate \
      "$worktree_path" "$validation_command" "$base_ref" "$paths_file" || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" validation-failed
      return
    fi
    phase_rc=0
    touchstone_review_fix_run_child \
      "$job_dir" touchstone_review_fix_commit "$worktree_path" "$paths_file" || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" fix-commit-failed
      return
    fi
    fix_head="$(git -C "$worktree_path" rev-parse HEAD)"
    touchstone_ship_write "$job_dir/review-fix" fix-head "$fix_head"
    phase_rc=0
    touchstone_review_fix_run_child \
      "$job_dir" git -C "$worktree_path" push origin "HEAD:$branch" || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" fix-push-failed
      return
    fi
    phase_rc=0
    touchstone_review_fix_run_child \
      "$job_dir" touchstone_review_fix_wait_for_head \
      "$worktree_path" "$pr_number" "$fix_head" "$deadline_epoch" || phase_rc=$?
    if [ "$phase_rc" -ne 0 ]; then
      touchstone_review_fix_stop_for_phase \
        "$job_dir" "$worktree_path" "$phase_rc" pushed-head-not-observed
      return
    fi
    finish_rc=0
    touchstone_review_fix_run_child \
      "$job_dir" touchstone_review_fix_finish_threads \
      "$job_dir" "$worktree_path" "$pr_number" "$source_head" "$fix_head" || finish_rc=$?
    if [ "$finish_rc" -eq 124 ]; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" time-budget-exhausted
      return
    elif [ "$finish_rc" -eq 3 ] || [ "$finish_rc" -eq 4 ]; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" head-changed-during-thread-update
      return
    elif [ "$finish_rc" -eq 5 ]; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" review-thread-changed
      return
    elif [ "$finish_rc" -ne 0 ]; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" thread-update-failed
      return
    fi
    rm -rf "$job_dir/review-fix"
    observed_head="$fix_head"
  done
}
