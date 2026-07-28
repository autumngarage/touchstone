#!/usr/bin/env bash
#
# scripts/worker.sh — first-class Touchstone worker lifecycle commands.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOUCHSTONE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/worker-state.sh
source "$TOUCHSTONE_ROOT/lib/worker-state.sh"
# shellcheck source=../lib/worker-ship-job.sh
source "$TOUCHSTONE_ROOT/lib/worker-ship-job.sh"
# shellcheck source=../lib/worker-review-fix.sh
source "$TOUCHSTONE_ROOT/lib/worker-review-fix.sh"
if [ -f "$TOUCHSTONE_ROOT/lib/events.sh" ]; then
  # shellcheck source=../lib/events.sh
  source "$TOUCHSTONE_ROOT/lib/events.sh"
else
  touchstone_emit_event() { :; }
  touchstone_json_string() {
    local value="${1-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    printf '"%s"' "$value"
  }
fi

usage() {
  cat <<'EOF'
Usage:
  touchstone worker spawn --task "<description>" --type fix|feat|chore|refactor|docs [--json]
  touchstone worker status --worktree <path> [--json] [--show-log] [--log-lines <n>]
  touchstone worker ship --worktree <path> [--detach] [--review-fix] [--cleanup]
                         [--max-fix-iterations <n>] [--max-fix-minutes <n>]
                         [--validation-command <command>] [--events-json <path>]
  touchstone worker takeover --worktree <path> [--force]
  touchstone worker abandon --worktree <path> [--dry-run] [--force]
  touchstone worker list [--repo <path>] [--json]
EOF
}

json_bool() {
  if [ -n "${1:-}" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

json_field() {
  local key="$1" value="$2"
  printf '"%s":%s' "$key" "$(touchstone_json_string "$value")"
}

json_number_or_null_field() {
  local key="$1" value="$2"
  if [ -n "$value" ]; then
    printf '"%s":%s' "$key" "$value"
  else
    printf '"%s":null' "$key"
  fi
}

sanitize_task_slug() {
  local raw="$1" slug
  slug="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  printf '%s' "${slug:-worker-task}"
}

require_worker_type() {
  case "$1" in
    fix | feat | chore | refactor | docs) return 0 ;;
    *)
      echo "ERROR: --type must be one of fix, feat, chore, refactor, docs." >&2
      return 1
      ;;
  esac
}

repo_root_or_die() {
  if ! git rev-parse --show-toplevel 2>/dev/null; then
    echo "ERROR: must run inside a git repository." >&2
    return 1
  fi
}

worker_branch() {
  git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

worker_head_sha() {
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

worker_has_uncommitted() {
  GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain 2>/dev/null || true
}

worker_pr_field() {
  local repo_path="$1" branch="$2" field="$3"
  (cd "$repo_path" && touchstone_worker_pr_field "$branch" "$field")
}

worker_status_json() {
  local worktree_path="$1" log_lines="${2:-0}"
  local state branch head_sha has_uncommitted pr_number pr_url merged_at job_dir=""

  state="$(derive_worker_state "$worktree_path")"
  branch=""
  head_sha=""
  has_uncommitted=""
  pr_number=""
  pr_url=""
  merged_at=""

  if [ -d "$worktree_path" ]; then
    branch="$(worker_branch "$worktree_path")"
    head_sha="$(worker_head_sha "$worktree_path")"
    has_uncommitted="$(worker_has_uncommitted "$worktree_path")"
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
      if (cd "$worktree_path" && touchstone_worker_remote_supports_github_prs); then
        if pr_number="$(worker_pr_field "$worktree_path" "$branch" number)"; then
          if ! pr_url="$(worker_pr_field "$worktree_path" "$branch" url)"; then
            pr_url=""
          fi
          if ! merged_at="$(worker_pr_field "$worktree_path" "$branch" mergedAt)"; then
            merged_at=""
          fi
        fi
      fi
    fi
  fi
  job_dir="$(touchstone_ship_job_dir "$worktree_path" || true)"

  printf '{'
  json_field state "$state"
  printf ','
  json_field branch "$branch"
  printf ','
  json_field head_sha "$head_sha"
  printf ',"has_uncommitted":'
  json_bool "$has_uncommitted"
  printf ','
  json_number_or_null_field pr_number "$pr_number"
  if [ -n "$pr_url" ]; then
    printf ','
    json_field pr_url "$pr_url"
  fi
  if [ -n "$merged_at" ]; then
    printf ','
    json_field merged_at "$merged_at"
  fi
  printf ',"ship":'
  if [ -n "$job_dir" ]; then
    touchstone_ship_json "$job_dir" "$log_lines"
  else
    printf 'null'
  fi
  printf '}\n'
}

cmd_spawn() {
  local task="" type="" json=false slug branch repo_root worktree_path base_ref base_branch output

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --task requires a value." >&2
          return 2
        }
        task="$2"
        shift 2
        ;;
      --type)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --type requires a value." >&2
          return 2
        }
        type="$2"
        shift 2
        ;;
      --json)
        json=true
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown worker spawn argument '$1'." >&2
        return 2
        ;;
    esac
  done

  [ -n "$task" ] || {
    echo "ERROR: worker spawn requires --task." >&2
    return 2
  }
  [ -n "$type" ] || {
    echo "ERROR: worker spawn requires --type." >&2
    return 2
  }
  require_worker_type "$type"

  repo_root="$(repo_root_or_die)"
  slug="$(sanitize_task_slug "$task")"
  branch="$type/$slug"
  if ! base_ref="$(cd "$repo_root" && touchstone_worker_default_ref)"; then
    echo "ERROR: could not resolve a default branch ref for worker spawn." >&2
    return 1
  fi
  base_branch="${base_ref#origin/}"

  output="$(cd "$repo_root" && bash "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" "$branch")"
  worktree_path="$(printf '%s\n' "$output" | awk '/^[[:space:]]*path:[[:space:]]*/ { sub(/^[[:space:]]*path:[[:space:]]*/, ""); value=$0 } END { print value }')"
  if [ -n "$worktree_path" ]; then
    worktree_path="$(cd "$repo_root" && cd "$worktree_path" && pwd)"
  fi

  touchstone_emit_event worker_spawned branch="$branch" worktree_path="$worktree_path" task="$task"

  if [ "$json" = true ]; then
    printf '{'
    json_field branch "$branch"
    printf ','
    json_field worktree_path "$worktree_path"
    printf ','
    json_field base_branch "$base_branch"
    printf '}\n'
  else
    printf '%s\n' "$output"
  fi
}

cmd_status() {
  local worktree_path="" json=false show_log=false log_lines=20
  local state branch head_sha has_uncommitted job_dir="" ship_status="" ship_pid="" ship_exit="" ship_log=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --worktree requires a path." >&2
          return 2
        }
        worktree_path="$2"
        shift 2
        ;;
      --json)
        json=true
        shift
        ;;
      --show-log)
        show_log=true
        shift
        ;;
      --log-lines)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --log-lines requires a value." >&2
          return 2
        }
        case "$2" in
          '' | *[!0-9]*)
            echo "ERROR: --log-lines must be a non-negative integer." >&2
            return 2
            ;;
        esac
        log_lines="$2"
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown worker status argument '$1'." >&2
        return 2
        ;;
    esac
  done

  [ -n "$worktree_path" ] || {
    echo "ERROR: worker status requires --worktree." >&2
    return 2
  }
  worktree_path="$(touchstone_ship_normalize_worktree_path "$worktree_path" || printf '%s' "$worktree_path")"

  if [ "$json" = true ]; then
    if [ "$show_log" = true ]; then
      worker_status_json "$worktree_path" "$log_lines"
    else
      worker_status_json "$worktree_path"
    fi
    return 0
  fi

  state="$(derive_worker_state "$worktree_path")"
  branch=""
  head_sha=""
  has_uncommitted=""
  if [ -d "$worktree_path" ]; then
    branch="$(worker_branch "$worktree_path")"
    head_sha="$(worker_head_sha "$worktree_path")"
    has_uncommitted="$(worker_has_uncommitted "$worktree_path")"
  fi
  job_dir="$(touchstone_ship_job_dir "$worktree_path" || true)"
  echo "Worker state: $state"
  [ -n "$branch" ] && echo "Branch: $branch"
  [ -n "$head_sha" ] && echo "Head: $head_sha"
  if [ -n "$has_uncommitted" ]; then
    echo "Uncommitted changes: yes"
  else
    echo "Uncommitted changes: no"
  fi
  if [ -n "$job_dir" ] && [ -d "$job_dir" ]; then
    touchstone_ship_refresh "$job_dir"
    ship_status="$(touchstone_ship_read "$job_dir" status)"
    ship_pid="$(touchstone_ship_read "$job_dir" pid)"
    ship_exit="$(touchstone_ship_read "$job_dir" exit-code)"
    ship_log="$job_dir/ship.log"
    echo "Ship job: ${ship_status:-unknown}"
    [ -n "$ship_pid" ] && echo "Ship PID: $ship_pid"
    [ -n "$ship_exit" ] && echo "Ship exit code: $ship_exit"
    echo "Ship log: $ship_log"
    if [ "$show_log" = true ] && [ -f "$ship_log" ]; then
      echo "--- Ship log (last $log_lines lines) ---"
      tail -n "$log_lines" "$ship_log"
    fi
  else
    echo "Ship job: none"
  fi
}

cmd_ship_runner() {
  local job_dir="" worktree_path="" claim_token="" cleanup=false events_json="" child_pid="" exit_code=0 branch=""
  local review_fix=false max_fix_iterations=3 max_fix_minutes=45 validation_command=""
  local deadline_epoch="" reason=""
  local args
  args=(--auto-merge)

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-dir)
        job_dir="$2"
        shift 2
        ;;
      --worktree)
        worktree_path="$2"
        shift 2
        ;;
      --claim-token)
        claim_token="$2"
        shift 2
        ;;
      --cleanup)
        cleanup=true
        shift
        ;;
      --events-json)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --events-json requires a path." >&2
          return 2
        }
        events_json="$2"
        shift 2
        ;;
      --review-fix)
        review_fix=true
        shift
        ;;
      --max-fix-iterations)
        max_fix_iterations="$2"
        shift 2
        ;;
      --max-fix-minutes)
        max_fix_minutes="$2"
        shift 2
        ;;
      --validation-command)
        validation_command="$2"
        shift 2
        ;;
      *)
        echo "ERROR: unknown detached ship runner argument '$1'." >&2
        exit 2
        ;;
    esac
  done

  [ -n "$job_dir" ] && [ -n "$worktree_path" ] && [ -n "$claim_token" ] || exit 2
  touchstone_ship_claim_matches "$job_dir" "$claim_token" || exit 1
  if [ -n "$events_json" ]; then
    export TOUCHSTONE_EVENTS_FILE="$events_json"
  fi

  finish_runner() {
    local status="$1" code="$2" reason="${3-}"
    if ! touchstone_ship_claim_matches "$job_dir" "$claim_token"; then
      echo "ERROR: detached ship runner lost its claim before publishing terminal state." >&2
      return 1
    fi
    touchstone_ship_write "$job_dir" exit-code "$code"
    touchstone_ship_write "$job_dir" reason "$reason"
    touchstone_ship_write "$job_dir" finished-at "$(touchstone_ship_now)"
    touchstone_ship_write "$job_dir" status finishing
    touchstone_emit_event worker_ship_finished \
      worktree_path="$worktree_path" status="$status" exit_code="$code"
    touchstone_ship_write "$job_dir" status "$status"
    touchstone_ship_release_claim "$job_dir" "$claim_token" 2>/dev/null || true
  }

  # shellcheck disable=SC2329 # Invoked by the TERM/INT trap below.
  stop_runner() {
    trap - TERM INT
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
      touchstone_ship_signal_tree "$child_pid" TERM
      wait "$child_pid" 2>/dev/null || true
    fi
    finish_runner stopped 143 takeover
    exit 143
  }
  trap stop_runner TERM INT

  touchstone_ship_write "$job_dir" pid "$$"
  branch="$(touchstone_ship_read "$job_dir" branch)"
  touchstone_emit_event worker_ship_started \
    worktree_path="$worktree_path" branch="$branch" pid="$$"
  touchstone_ship_write "$job_dir" status running
  touchstone_ship_write "$job_dir" reason ""
  if [ "$review_fix" = true ]; then
    deadline_epoch="$(touchstone_ship_read "$job_dir" deadline-epoch)"
    case "$deadline_epoch" in
      '' | *[!0-9]*)
        deadline_epoch="$(($(date +%s) + max_fix_minutes * 60))"
        touchstone_ship_write "$job_dir" deadline-epoch "$deadline_epoch"
        ;;
    esac
    if touchstone_review_fix_run \
      "$job_dir" "$worktree_path" "$max_fix_iterations" "$deadline_epoch" \
      "$validation_command" "$cleanup"; then
      finish_runner succeeded 0
      exit 0
    else
      exit_code=$?
    fi
    reason="${TOUCHSTONE_REVIEW_FIX_REASON:-review-fix-needs-attention}"
    finish_runner needs-attention "${exit_code:-1}" "$reason"
    exit "${exit_code:-1}"
  fi
  if [ "$cleanup" = true ]; then
    args+=(--cleanup-worktree)
  fi

  if [ -n "$events_json" ]; then
    TOUCHSTONE_EVENTS_FILE="$events_json" \
      bash -c 'cd "$1" && shift && bash scripts/open-pr.sh "$@"' _ "$worktree_path" "${args[@]}" &
  else
    (cd "$worktree_path" && bash scripts/open-pr.sh "${args[@]}") &
  fi
  child_pid=$!
  touchstone_ship_write "$job_dir" child-pid "$child_pid"
  if wait "$child_pid"; then
    exit_code=0
  else
    exit_code=$?
  fi
  if [ "$exit_code" -eq 0 ]; then
    finish_runner succeeded 0
  else
    finish_runner failed "$exit_code" open-pr-failed
  fi
  exit "$exit_code"
}

cmd_ship() {
  local worktree_path="" cleanup=false events_json="" detach=false review_fix=false
  local max_fix_iterations=3 max_fix_minutes=45 validation_command=""
  local job_dir="" runner_pid="" branch="" started_at="" claim_token="" args runner_args
  args=(--auto-merge)

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --worktree requires a path." >&2
          return 2
        }
        worktree_path="$2"
        shift 2
        ;;
      --auto-merge) shift ;;
      --detach)
        detach=true
        shift
        ;;
      --review-fix)
        review_fix=true
        shift
        ;;
      --max-fix-iterations)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --max-fix-iterations requires a value." >&2
          return 2
        }
        case "$2" in
          '' | *[!0-9]* | 0)
            echo "ERROR: --max-fix-iterations must be a positive integer." >&2
            return 2
            ;;
        esac
        max_fix_iterations="$2"
        shift 2
        ;;
      --max-fix-minutes)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --max-fix-minutes requires a value." >&2
          return 2
        }
        case "$2" in
          '' | *[!0-9]* | 0)
            echo "ERROR: --max-fix-minutes must be a positive integer." >&2
            return 2
            ;;
        esac
        max_fix_minutes="$2"
        shift 2
        ;;
      --validation-command)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --validation-command requires a value." >&2
          return 2
        }
        validation_command="$2"
        shift 2
        ;;
      --cleanup)
        cleanup=true
        shift
        ;;
      --events-json)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --events-json requires a path." >&2
          return 2
        }
        events_json="$2"
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown worker ship argument '$1'." >&2
        return 2
        ;;
    esac
  done

  [ -n "$worktree_path" ] || {
    echo "ERROR: worker ship requires --worktree." >&2
    return 2
  }
  [ -d "$worktree_path" ] || {
    echo "ERROR: worktree does not exist: $worktree_path" >&2
    return 1
  }
  worktree_path="$(touchstone_ship_normalize_worktree_path "$worktree_path")"
  if [ -n "$events_json" ]; then
    case "$events_json" in
      /*) ;;
      *) events_json="$(pwd -P)/$events_json" ;;
    esac
  fi
  if [ "$review_fix" = true ] && [ "$detach" != true ]; then
    echo "ERROR: --review-fix requires --detach." >&2
    return 2
  fi
  if [ "$cleanup" = true ]; then
    args+=(--cleanup-worktree)
  fi

  if [ "$detach" != true ]; then
    if [ -n "$events_json" ]; then
      TOUCHSTONE_EVENTS_FILE="$events_json" \
        bash -c 'cd "$1" && shift && bash scripts/open-pr.sh "$@"' _ "$worktree_path" "${args[@]}"
    else
      (cd "$worktree_path" && bash scripts/open-pr.sh "${args[@]}")
    fi
    return
  fi

  job_dir="$(touchstone_ship_job_dir "$worktree_path")" || {
    echo "ERROR: could not resolve detached ship state for $worktree_path" >&2
    return 1
  }
  touchstone_ship_refresh "$job_dir"
  claim_token="$(touchstone_ship_claim "$job_dir" "$$")" || {
    echo "ERROR: a detached ship job is already active for $worktree_path" >&2
    echo "       Inspect it with: touchstone worker status --worktree '$worktree_path' --show-log" >&2
    return 1
  }

  branch="$(worker_branch "$worktree_path")"
  started_at="$(touchstone_ship_now)"
  : >"$job_dir/ship.log"
  touchstone_ship_write "$job_dir" started-at "$started_at"
  touchstone_ship_write "$job_dir" started-epoch "$(date +%s)"
  touchstone_ship_write "$job_dir" finished-at ""
  touchstone_ship_write "$job_dir" exit-code ""
  touchstone_ship_write "$job_dir" reason ""
  touchstone_ship_write "$job_dir" pid ""
  touchstone_ship_write "$job_dir" child-pid ""
  if [ "$review_fix" = true ]; then
    touchstone_ship_write "$job_dir" deadline-epoch "$(($(date +%s) + max_fix_minutes * 60))"
    touchstone_ship_write "$job_dir" review-fix-iteration 0
    touchstone_ship_write "$job_dir" mode autonomous-review-fix
  else
    touchstone_ship_write "$job_dir" deadline-epoch ""
    touchstone_ship_write "$job_dir" review-fix-iteration ""
    touchstone_ship_write "$job_dir" mode wait-only
  fi
  touchstone_ship_write "$job_dir" branch "$branch"
  touchstone_ship_write "$job_dir" worktree-path "$worktree_path"
  touchstone_ship_write "$job_dir" status starting
  touchstone_ship_claim_matches "$job_dir" "$claim_token" || return 1

  runner_args=(_ship-run --job-dir "$job_dir" --worktree "$worktree_path" --claim-token "$claim_token")
  if [ "$review_fix" = true ]; then
    runner_args+=(--review-fix)
    runner_args+=(--max-fix-iterations "$max_fix_iterations")
    runner_args+=(--max-fix-minutes "$max_fix_minutes")
    [ -n "$validation_command" ] && runner_args+=(--validation-command "$validation_command")
  fi
  [ "$cleanup" = true ] && runner_args+=(--cleanup)
  [ -n "$events_json" ] && runner_args+=(--events-json "$events_json")
  nohup bash "$TOUCHSTONE_ROOT/scripts/worker.sh" "${runner_args[@]}" \
    >>"$job_dir/ship.log" 2>&1 </dev/null &
  runner_pid=$!
  touchstone_ship_write "$job_dir" pid "$runner_pid"

  echo "Detached ship started."
  echo "Worktree: $worktree_path"
  echo "PID: $runner_pid"
  echo "Status: touchstone worker status --worktree '$worktree_path' --show-log"
}

cmd_takeover() {
  local worktree_path="" force=false job_dir="" status="" pid="" waited=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --worktree requires a path." >&2
          return 2
        }
        worktree_path="$2"
        shift 2
        ;;
      --force)
        force=true
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown worker takeover argument '$1'." >&2
        return 2
        ;;
    esac
  done

  [ -n "$worktree_path" ] || {
    echo "ERROR: worker takeover requires --worktree." >&2
    return 2
  }
  [ -d "$worktree_path" ] || {
    echo "ERROR: worktree does not exist: $worktree_path" >&2
    return 1
  }
  job_dir="$(touchstone_ship_job_dir "$worktree_path")" || return 1
  [ -d "$job_dir" ] || {
    echo "No detached ship job exists for $worktree_path."
    return 0
  }

  touchstone_ship_refresh "$job_dir"
  status="$(touchstone_ship_read "$job_dir" status)"
  pid="$(touchstone_ship_read "$job_dir" pid)"
  case "$status" in
    finishing)
      echo "ERROR: detached ship runner is publishing its final state; retry takeover shortly." >&2
      return 1
      ;;
    starting | running | review-waiting | fixing)
      if ! touchstone_ship_pid_is_runner "$job_dir" "$pid"; then
        touchstone_ship_refresh "$job_dir"
        status="$(touchstone_ship_read "$job_dir" status)"
        if [ "$status" != "starting" ] && [ "$status" != "running" ] \
          && [ "$status" != "review-waiting" ] && [ "$status" != "fixing" ]; then
          echo "No active detached ship job exists for $worktree_path."
          return 0
        fi
        echo "ERROR: detached ship runner is still starting; retry takeover shortly." >&2
        return 1
      else
        if ! kill -TERM "$pid" 2>/dev/null; then
          touchstone_ship_refresh "$job_dir"
        fi
        while [ "$waited" -lt 50 ] && touchstone_ship_claim_exists "$job_dir"; do
          sleep 0.1
          waited=$((waited + 1))
        done
        if touchstone_ship_claim_exists "$job_dir"; then
          if [ "$force" != true ]; then
            echo "ERROR: detached ship runner did not stop; retry with --force." >&2
            return 1
          fi
          touchstone_ship_signal_tree "$pid" KILL
          touchstone_ship_write "$job_dir" exit-code 137
          touchstone_ship_write "$job_dir" reason forced-takeover
          touchstone_ship_write "$job_dir" finished-at "$(touchstone_ship_now)"
          touchstone_ship_write "$job_dir" status stopped
          touchstone_ship_release_claim \
            "$job_dir" "$(touchstone_ship_claim_value "$job_dir" owner-token)" 2>/dev/null || true
        fi
      fi
      ;;
    needs-attention)
      touchstone_ship_release_claim \
        "$job_dir" "$(touchstone_ship_claim_value "$job_dir" owner-token)" 2>/dev/null || true
      touchstone_emit_event worker_ship_takeover worktree_path="$worktree_path" pid="$pid"
      echo "Autonomous review-fix job needs attention."
      echo "Reason: $(touchstone_ship_read "$job_dir" reason)"
      echo "Worktree preserved for takeover: $worktree_path"
      return 0
      ;;
    *)
      echo "No active detached ship job exists for $worktree_path."
      return 0
      ;;
  esac

  touchstone_emit_event worker_ship_takeover worktree_path="$worktree_path" pid="$pid"
  echo "Detached shipping is no longer active."
  echo "Worktree preserved for takeover: $worktree_path"
}

branch_has_open_or_closed_pr() {
  local repo_path="$1" branch="$2" number
  if ! number="$(worker_pr_field "$repo_path" "$branch" number)"; then
    return 2
  fi
  [ -n "$number" ]
}

remote_branch_exists() {
  local repo_path="$1" branch="$2"
  git -C "$repo_path" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

abandon_remote_action() {
  local repo_path="$1" branch="$2" force="$3" pr_status

  if ! remote_branch_exists "$repo_path" "$branch"; then
    echo "none"
    return 0
  fi

  if ! (cd "$repo_path" && touchstone_worker_remote_supports_github_prs); then
    echo "delete"
    return 0
  fi

  if branch_has_open_or_closed_pr "$repo_path" "$branch"; then
    echo "keep_pr"
    return 0
  else
    pr_status=$?
  fi
  if [ "$pr_status" -ne 1 ]; then
    if [ "$force" = true ]; then
      echo "keep_unknown"
      return 0
    fi
    echo "ERROR: refusing to abandon $branch; could not inspect PRs before deleting origin/$branch." >&2
    echo "       Use --force only after confirming the branch is not backing a PR." >&2
    return 1
  fi

  echo "delete"
}

worktree_manager_path() {
  local worktree_path="$1"
  git -C "$worktree_path" worktree list --porcelain \
    | awk '/^worktree / { print substr($0, length("worktree ") + 1); exit }'
}

cmd_abandon() {
  local worktree_path="" dry_run=false force=false branch base unique_commits dirty_status manager_path remote_action
  local ship_job_dir="" ship_status=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --worktree requires a path." >&2
          return 2
        }
        worktree_path="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --force)
        force=true
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown worker abandon argument '$1'." >&2
        return 2
        ;;
    esac
  done

  [ -n "$worktree_path" ] || {
    echo "ERROR: worker abandon requires --worktree." >&2
    return 2
  }
  [ -d "$worktree_path" ] || {
    echo "ERROR: worktree does not exist: $worktree_path" >&2
    return 1
  }
  ship_job_dir="$(touchstone_ship_job_dir "$worktree_path" || true)"
  if [ -n "$ship_job_dir" ] && [ -d "$ship_job_dir" ]; then
    touchstone_ship_refresh "$ship_job_dir"
    ship_status="$(touchstone_ship_read "$ship_job_dir" status)"
    case "$ship_status" in
      starting | running | review-waiting | fixing | finishing)
        echo "ERROR: refusing to abandon $worktree_path while detached shipping is active." >&2
        echo "       Run: touchstone worker takeover --worktree '$worktree_path'" >&2
        return 1
        ;;
    esac
  fi

  branch="$(worker_branch "$worktree_path")"
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || {
    echo "ERROR: cannot abandon detached worktree." >&2
    return 1
  }
  if ! base="$(cd "$worktree_path" && touchstone_worker_default_ref)"; then
    if [ "$force" != true ]; then
      echo "ERROR: refusing to abandon $worktree_path; could not resolve a default branch ref." >&2
      echo "       Use --force only after confirming the work is disposable." >&2
      return 1
    fi
    base=""
    unique_commits=""
  elif ! unique_commits="$(git -C "$worktree_path" log "$base..HEAD" --oneline --max-count=1 2>/dev/null)"; then
    if [ "$force" != true ]; then
      echo "ERROR: refusing to abandon $worktree_path; could not compare branch '$branch' against $base." >&2
      echo "       Use --force only after confirming the work is disposable." >&2
      return 1
    fi
    unique_commits=""
  fi
  if ! dirty_status="$(git -C "$worktree_path" status --porcelain 2>/dev/null)"; then
    if [ "$force" != true ]; then
      echo "ERROR: refusing to abandon $worktree_path; could not inspect uncommitted changes." >&2
      echo "       Use --force only after confirming the dirty worktree is disposable." >&2
      return 1
    fi
    dirty_status=""
  fi

  if [ -n "$unique_commits" ] && [ "$force" != true ]; then
    echo "ERROR: refusing to abandon $worktree_path; branch '$branch' has commits not merged into $base." >&2
    echo "       Use --force only after confirming the work is disposable." >&2
    return 1
  fi
  if [ -n "$dirty_status" ] && [ "$force" != true ]; then
    echo "ERROR: refusing to abandon $worktree_path; worktree has uncommitted changes." >&2
    echo "       Use --force only after confirming the dirty worktree is disposable." >&2
    return 1
  fi

  if [ "$dry_run" = true ]; then
    if ! remote_action="$(abandon_remote_action "$worktree_path" "$branch" "$force")"; then
      return 1
    fi
    echo "Would remove worktree: $worktree_path"
    if [ "$remote_action" = "keep_pr" ]; then
      echo "Would keep remote branch because a PR exists for: $branch"
    elif [ "$remote_action" = "keep_unknown" ]; then
      echo "Would keep remote branch because PR state could not be inspected for: $branch"
    elif [ "$remote_action" = "delete" ]; then
      echo "Would delete remote branch: origin/$branch"
    fi
    return 0
  fi

  manager_path="$(worktree_manager_path "$worktree_path")"
  [ -n "$manager_path" ] || {
    echo "ERROR: could not find a git worktree manager for $worktree_path" >&2
    return 1
  }
  if ! remote_action="$(abandon_remote_action "$manager_path" "$branch" "$force")"; then
    return 1
  fi
  if [ "$force" = true ]; then
    git -C "$manager_path" worktree remove --force "$worktree_path"
  else
    git -C "$manager_path" worktree remove "$worktree_path"
  fi
  if [ "$remote_action" = "keep_pr" ]; then
    echo "Kept remote branch because a PR exists for: $branch"
  elif [ "$remote_action" = "keep_unknown" ]; then
    echo "Kept remote branch because PR state could not be inspected for: $branch"
  elif [ "$remote_action" = "delete" ]; then
    git -C "$manager_path" push origin --delete "$branch"
  fi
  touchstone_emit_event worker_abandoned worktree_path="$worktree_path" branch="$branch"
}

cmd_list() {
  local repo_path="" json=false repo_root list_output first=true path="" branch_ref="" branch=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || {
          echo "ERROR: --repo requires a path." >&2
          return 2
        }
        repo_path="$2"
        shift 2
        ;;
      --json)
        json=true
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown worker list argument '$1'." >&2
        return 2
        ;;
    esac
  done

  if [ -n "$repo_path" ]; then
    repo_root="$(cd "$repo_path" && git rev-parse --show-toplevel)"
  else
    repo_root="$(repo_root_or_die)"
  fi
  list_output="$(git -C "$repo_root" worktree list --porcelain)"

  if [ "$json" = true ]; then
    printf '['
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      if [ -n "$path" ] && [ -n "$branch_ref" ]; then
        branch="${branch_ref#refs/heads/}"
        case "$branch" in
          feat/* | fix/* | chore/* | refactor/* | docs/*)
            if [ "$json" = true ]; then
              [ "$first" = true ] || printf ','
              worker_status_json "$path" | tr -d '\n'
              first=false
            else
              printf '%s  %s\n' "$(derive_worker_state "$path")" "$path"
            fi
            ;;
        esac
      fi
      path=""
      branch_ref=""
      continue
    fi
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ *) branch_ref="${line#branch }" ;;
    esac
  done <<<"$list_output"

  if [ -n "$path" ] && [ -n "$branch_ref" ]; then
    branch="${branch_ref#refs/heads/}"
    case "$branch" in
      feat/* | fix/* | chore/* | refactor/* | docs/*)
        if [ "$json" = true ]; then
          [ "$first" = true ] || printf ','
          worker_status_json "$path" | tr -d '\n'
        else
          printf '%s  %s\n' "$(derive_worker_state "$path")" "$path"
        fi
        ;;
    esac
  fi

  if [ "$json" = true ]; then
    printf ']\n'
  fi
}

command="${1:-help}"
shift 2>/dev/null || true

case "$command" in
  spawn) cmd_spawn "$@" ;;
  status) cmd_status "$@" ;;
  ship) cmd_ship "$@" ;;
  takeover) cmd_takeover "$@" ;;
  abandon) cmd_abandon "$@" ;;
  list) cmd_list "$@" ;;
  _ship-run) cmd_ship_runner "$@" ;;
  help | -h | --help) usage ;;
  *)
    echo "ERROR: unknown worker command '$command'." >&2
    usage >&2
    exit 2
    ;;
esac
