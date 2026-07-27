#!/usr/bin/env bash
#
# Bounded autonomous repair of actionable GitHub PR review threads.

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

touchstone_review_fix_trusted_authors() {
  local worktree_path="$1" base_ref="$2"
  local config_file="" rel="" parsed_authors=""

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
        parsed_authors="$(toml_normalize_array "$value")"
      fi
    }
    toml_parse "$config_file" touchstone_review_fix_config_callback || {
      rm -f "$config_file"
      return 1
    }
    rm -f "$config_file"
  fi

  printf '%s' "${parsed_authors:-chatgpt-codex-connector,chatgpt-codex-connector[bot]}"
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
  local repo_full_name="$1" pr_number="$2" owner name query
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
          comments(first: 1) {
            nodes {
              author { login }
              body
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
  gh api graphql --paginate \
    -F owner="$owner" \
    -F name="$name" \
    -F number="$pr_number" \
    -f query="$query" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | [.id, .path, ((.line // .startLine // "") | tostring), (.isOutdated | tostring), (.comments.nodes[0].author.login // ""), (.comments.nodes[0].pullRequestReview.commit.oid // ""), (.comments.nodes[0].url // ""), ((.comments.nodes[0].body // "") | gsub("[\r\n\t]"; " ") | .[0:1000])] | @tsv'
}

touchstone_review_fix_thread_key() {
  printf '%s' "$1" | git hash-object --stdin
}

touchstone_review_fix_marker() {
  local source_head="$1" fix_head="$2" thread_id="$3"
  printf '<!-- touchstone-review-fix:%s:%s:%s -->' "$source_head" "$fix_head" "$thread_id"
}

touchstone_review_fix_thread_remote_state() {
  local thread_id="$1" marker="$2" query
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
  query='
query($id: ID!) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      isResolved
      comments(last: 100) { nodes { body } }
    }
  }
}'
  gh api graphql \
    -F id="$thread_id" \
    -f query="$query" \
    --jq "[.data.node.isResolved, (any(.data.node.comments.nodes[]?; .body | contains(\"$marker\")))] | @tsv"
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

Unresolved review threads (tab-separated id, path, line, outdated, author, review head, URL, body):
EOF
    cat "$threads_file"
  } >"$brief_file"
}

touchstone_review_fix_invoke_worker() {
  local worktree_path="$1" brief_file="$2" result_file="$3"
  local worker_command="${TOUCHSTONE_REVIEW_FIX_WORKER_COMMAND:-}"
  local login_status=""

  : >"$result_file"
  if [ -n "$worker_command" ]; then
    [ -x "$worker_command" ] || return 127
    TOUCHSTONE_REVIEW_FIX_RESULT_FILE="$result_file" \
      TOUCHSTONE_REVIEW_FIX_BRIEF_FILE="$brief_file" \
      "$worker_command" "$worktree_path" "$brief_file" "$result_file"
    return
  fi

  command -v codex >/dev/null 2>&1 || return 127
  login_status="$(codex login status 2>&1)" || return 127
  case "$login_status" in
    *"Logged in using ChatGPT"*) ;;
    *)
      echo "ERROR: autonomous review-fix requires a ChatGPT-authenticated Codex CLI." >&2
      echo "       Refusing API-key or unknown authentication to avoid metered review spend." >&2
      return 126
      ;;
  esac
  codex exec \
    --ephemeral \
    --sandbox workspace-write \
    -c 'approval_policy="never"' \
    -C "$worktree_path" \
    --output-last-message "$result_file" \
    - <"$brief_file"
}

touchstone_review_fix_result_is_complete() {
  local result_file="$1" threads_file="$2" expected_file actual_file
  grep -qx 'TOUCHSTONE_REVIEW_FIX_FIXED' "$result_file" || return 1
  expected_file="${result_file}.expected"
  actual_file="${result_file}.actual"
  cut -f1 "$threads_file" | sed '/^$/d' | LC_ALL=C sort -u >"$expected_file"
  sed -n 's/^thread_id=//p' "$result_file" | sed '/^$/d' | LC_ALL=C sort -u >"$actual_file"
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
  local worktree_path="$1" validation_command="$2" base_ref="$3"
  if [ -n "$validation_command" ]; then
    (cd "$worktree_path" && bash -lc "$validation_command")
    return
  fi
  [ -f "$worktree_path/lib/preflight.sh" ] || return 1
  (cd "$worktree_path" && bash lib/preflight.sh --diff "$base_ref" "$worktree_path")
}

touchstone_review_fix_checkpoint_threads() {
  local job_dir="$1" source_head="$2" threads_file="$3"
  mkdir -p "$job_dir/review-fix"
  cp "$threads_file" "$job_dir/review-fix/threads.tsv"
  touchstone_ship_write "$job_dir/review-fix" source-head "$source_head"
  touchstone_ship_write "$job_dir/review-fix" fix-head ""
}

touchstone_review_fix_finish_threads() {
  local job_dir="$1" worktree_path="$2" pr_number="$3" source_head="$4" fix_head="$5"
  local threads_file="$job_dir/review-fix/threads.tsv"
  local thread_id path line _outdated _author _review_head _url _body
  local marker remote_state resolved replied key body location

  while IFS="$(printf '\t')" read -r thread_id path line _outdated _author _review_head _url _body || [ -n "$thread_id" ]; do
    [ -n "$thread_id" ] || continue
    key="$(touchstone_review_fix_thread_key "$thread_id")"
    [ -f "$job_dir/review-fix/resolved-$key" ] && continue
    marker="$(touchstone_review_fix_marker "$source_head" "$fix_head" "$thread_id")"
    remote_state="$(touchstone_review_fix_thread_remote_state "$thread_id" "$marker")" || return 1
    resolved="${remote_state%%	*}"
    replied="${remote_state#*	}"
    if [ "$resolved" = "true" ]; then
      touchstone_ship_write "$job_dir/review-fix" "resolved-$key" "$fix_head"
      continue
    fi
    if [ "$replied" != "true" ]; then
      location="${path:-review thread}${line:+:$line}"
      body="Fixed $location in \`$(printf '%.12s' "$fix_head")\` and validated locally. $marker"
      touchstone_review_fix_reply "$thread_id" "$body" || return 1
    fi
    touchstone_review_fix_resolve "$thread_id" || return 1
    touchstone_ship_write "$job_dir/review-fix" "resolved-$key" "$fix_head"
  done <"$threads_file"

  touchstone_emit_event fix_pushed \
    worktree_path="$worktree_path" pr_number="$pr_number" head_sha="$fix_head"
}

touchstone_review_fix_resume_checkpoint() {
  local job_dir="$1" worktree_path="$2" pr_number="$3" observed_head="$4"
  local source_head fix_head
  source_head="$(touchstone_ship_read "$job_dir/review-fix" source-head)"
  fix_head="$(touchstone_ship_read "$job_dir/review-fix" fix-head)"
  [ -n "$source_head" ] && [ -n "$fix_head" ] || return 1
  [ "$observed_head" = "$fix_head" ] || return 2
  touchstone_review_fix_finish_threads \
    "$job_dir" "$worktree_path" "$pr_number" "$source_head" "$fix_head"
  rm -rf "$job_dir/review-fix"
}

touchstone_review_fix_run_child() {
  local job_dir="$1" deadline_epoch now_epoch exit_code
  shift
  "$@" &
  child_pid=$!
  touchstone_ship_write "$job_dir" child-pid "$child_pid"
  deadline_epoch="$(touchstone_ship_read "$job_dir" deadline-epoch)"
  while kill -0 "$child_pid" 2>/dev/null; do
    case "$deadline_epoch" in
      '' | *[!0-9]*) ;;
      *)
        now_epoch="$(date +%s)"
        if [ "$now_epoch" -ge "$deadline_epoch" ]; then
          touchstone_ship_signal_tree "$child_pid" TERM
          wait "$child_pid" 2>/dev/null || true
          return 124
        fi
        ;;
    esac
    sleep 1
  done
  if wait "$child_pid"; then
    exit_code=0
  else
    exit_code=$?
  fi
  return "$exit_code"
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
  local _url _body
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

    pr_number="$(cd "$worktree_path" && touchstone_review_fix_pr_number "$branch")" || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" pr-inspection-failed
      return
    }
    if [ -n "$pr_number" ]; then
      observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || {
        touchstone_review_fix_need_attention "$job_dir" "$worktree_path" head-inspection-failed
        return
      }
      if [ -d "$job_dir/review-fix" ]; then
        if touchstone_review_fix_resume_checkpoint \
          "$job_dir" "$worktree_path" "$pr_number" "$observed_head"; then
          :
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

    pr_number="$(cd "$worktree_path" && touchstone_review_fix_pr_number "$branch")" || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" pr-inspection-failed
      return
    }
    [ -n "$pr_number" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" pr-not-open
      return
    }
    repo_full_name="$(cd "$worktree_path" && touchstone_review_fix_repo_name)" || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" repository-inspection-failed
      return
    }
    source_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" head-inspection-failed
      return
    }
    [ "$source_head" = "$(git -C "$worktree_path" rev-parse HEAD)" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" local-remote-head-mismatch
      return
    }
    [ -z "$(git -C "$worktree_path" status --porcelain)" ] || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" dirty-worktree
      return
    }

    threads_file="$job_dir/threads-$source_head.tsv"
    if ! (cd "$worktree_path" && touchstone_review_fix_threads "$repo_full_name" "$pr_number") >"$threads_file"; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" thread-inspection-failed
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
    while IFS="$(printf '\t')" read -r thread_id _path _line thread_outdated thread_author thread_review_head _url _body \
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
    done <"$threads_file"
    observed_head="$(cd "$worktree_path" && touchstone_review_fix_pr_head "$pr_number")" || {
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" head-inspection-failed
      return
    }
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
    touchstone_review_fix_checkpoint_threads "$job_dir" "$source_head" "$threads_file"
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
    if ! touchstone_review_fix_validate "$worktree_path" "$validation_command" "$base_ref"; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" validation-failed
      return
    fi
    if ! touchstone_review_fix_commit "$worktree_path" "$paths_file"; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" fix-commit-failed
      return
    fi
    fix_head="$(git -C "$worktree_path" rev-parse HEAD)"
    touchstone_ship_write "$job_dir/review-fix" fix-head "$fix_head"
    if ! git -C "$worktree_path" push origin "HEAD:$branch"; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" fix-push-failed
      return
    fi
    if ! touchstone_review_fix_wait_for_head \
      "$worktree_path" "$pr_number" "$fix_head" "$deadline_epoch"; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" pushed-head-not-observed
      return
    fi
    if ! touchstone_review_fix_finish_threads \
      "$job_dir" "$worktree_path" "$pr_number" "$source_head" "$fix_head"; then
      touchstone_review_fix_need_attention "$job_dir" "$worktree_path" thread-update-failed
      return
    fi
    rm -rf "$job_dir/review-fix"
    observed_head="$fix_head"
  done
}
