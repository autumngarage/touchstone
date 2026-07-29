#!/usr/bin/env bash
#
# Durable state helpers for detached worker shipping jobs.

touchstone_ship_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

touchstone_ship_common_dir() {
  local worktree_path="$1" common_dir
  common_dir="$(git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common_dir" in
    /*) printf '%s\n' "$common_dir" ;;
    *) (cd "$worktree_path/$common_dir" && pwd -P) ;;
  esac
}

touchstone_ship_normalize_worktree_path() {
  local worktree_path="$1" parent base
  if [ -d "$worktree_path" ]; then
    (cd "$worktree_path" && pwd -P)
    return
  fi
  parent="$(dirname "$worktree_path")"
  base="$(basename "$worktree_path")"
  [ -d "$parent" ] || return 1
  parent="$(cd "$parent" && pwd -P)" || return 1
  printf '%s/%s\n' "$parent" "$base"
}

touchstone_ship_find_job_dir() {
  local common_dir="$1" worktree_path="$2" candidate recorded_path
  [ -d "$common_dir/touchstone/ship-jobs" ] || return 1
  for candidate in "$common_dir"/touchstone/ship-jobs/*; do
    [ -d "$candidate" ] || continue
    recorded_path="$(touchstone_ship_read "$candidate" worktree-path)"
    if [ "$recorded_path" = "$worktree_path" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

touchstone_ship_job_key() {
  local worktree_path="$1"
  printf 'touchstone-worker-ship-v1\0%s' "$worktree_path" \
    | git -C "$worktree_path" hash-object --stdin 2>/dev/null
}

touchstone_ship_job_dir() {
  local worktree_path="$1" branch common_dir key normalized_path
  normalized_path="$(touchstone_ship_normalize_worktree_path "$worktree_path")" || return 1
  if [ -d "$normalized_path" ]; then
    branch="$(git -C "$normalized_path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] || return 1
    common_dir="$(touchstone_ship_common_dir "$normalized_path")" || return 1
    key="$(touchstone_ship_job_key "$normalized_path")" || return 1
    printf '%s\n' "$common_dir/touchstone/ship-jobs/$key"
    return 0
  fi

  common_dir="$(touchstone_ship_common_dir .)" || return 1
  touchstone_ship_find_job_dir "$common_dir" "$normalized_path"
}

touchstone_ship_read() {
  local job_dir="$1" name="$2"
  [ -f "$job_dir/$name" ] || return 0
  cat "$job_dir/$name"
}

touchstone_ship_write() {
  local job_dir="$1" name="$2" value="${3-}" tmp
  mkdir -p "$job_dir"
  tmp="$job_dir/.$name.$$.${RANDOM:-0}.tmp"
  printf '%s\n' "$value" >"$tmp"
  mv "$tmp" "$job_dir/$name"
}

touchstone_ship_claim() {
  local job_dir="$1" owner_pid="${2:-$$}" token record
  mkdir -p "$job_dir"
  token="$owner_pid-$(date +%s)-${RANDOM:-0}"
  record="$job_dir/.active.$token.tmp"
  {
    printf 'owner-pid=%s\n' "$owner_pid"
    printf 'owner-token=%s\n' "$token"
  } >"$record"
  if ln "$record" "$job_dir/active" 2>/dev/null; then
    rm -f "$record"
    printf '%s\n' "$token"
    return 0
  fi
  rm -f "$record"
  return 1
}

touchstone_ship_claim_exists() {
  local job_dir="$1"
  [ -f "$job_dir/active" ] || [ -d "$job_dir/active" ]
}

touchstone_ship_claim_value() {
  local job_dir="$1" key="$2"
  [ -f "$job_dir/active" ] || return 0
  sed -n "s/^$key=//p" "$job_dir/active" 2>/dev/null | head -n 1
}

touchstone_ship_claim_matches() {
  local job_dir="$1" expected_token="$2" actual_token
  [ -n "$expected_token" ] || return 1
  actual_token="$(touchstone_ship_claim_value "$job_dir" owner-token)"
  [ -n "$actual_token" ] && [ "$actual_token" = "$expected_token" ]
}

touchstone_ship_claim_owner_alive() {
  local job_dir="$1" owner_pid
  owner_pid="$(touchstone_ship_claim_value "$job_dir" owner-pid)"
  case "$owner_pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$owner_pid" 2>/dev/null
}

touchstone_ship_release_claim() {
  local job_dir="$1" expected_token="${2-}"
  if [ -f "$job_dir/active" ]; then
    touchstone_ship_claim_matches "$job_dir" "$expected_token" || return 1
    rm -f "$job_dir/active"
    return
  fi
  if [ -d "$job_dir/active" ]; then
    [ -z "$expected_token" ] || return 1
    rm -f "$job_dir/active/claimed-epoch"
    rmdir "$job_dir/active"
  fi
}

touchstone_ship_pid_is_runner() {
  local job_dir="$1" pid="$2" command_line
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  printf '%s' "$command_line" | grep -Fq '_ship-run' \
    && printf '%s' "$command_line" | grep -Fq "$job_dir"
}

touchstone_ship_child_pids() {
  local parent_pid="$1"
  ps -axo pid=,ppid= 2>/dev/null \
    | awk -v parent="$parent_pid" '$2 == parent { print $1 }'
}

touchstone_ship_signal_tree() {
  local pid="$1" signal="$2" child
  case "$pid" in
    '' | *[!0-9]*) return 0 ;;
  esac
  for child in $(touchstone_ship_child_pids "$pid"); do
    touchstone_ship_signal_tree "$child" "$signal"
  done
  kill "-$signal" "$pid" 2>/dev/null || true
}

touchstone_ship_mark_stale() {
  local job_dir="$1" claim_token="${2-}"
  touchstone_ship_write "$job_dir" exit-code 125
  touchstone_ship_write "$job_dir" reason stale-runner
  touchstone_ship_write "$job_dir" finished-at "$(touchstone_ship_now)"
  touchstone_ship_write "$job_dir" status failed
  touchstone_ship_release_claim "$job_dir" "$claim_token" 2>/dev/null || true
}

touchstone_ship_refresh() {
  local job_dir="$1" status pid started_epoch now_epoch claim_token
  [ -d "$job_dir" ] || return 0
  status="$(touchstone_ship_read "$job_dir" status)"
  claim_token="$(touchstone_ship_claim_value "$job_dir" owner-token)"
  case "$status" in
    starting)
      pid="$(touchstone_ship_read "$job_dir" pid)"
      started_epoch="$(touchstone_ship_read "$job_dir" started-epoch)"
      now_epoch="$(date +%s)"
      case "$pid" in
        '' | *[!0-9]*)
          if [ -n "$claim_token" ]; then
            touchstone_ship_claim_owner_alive "$job_dir" && return 0
            touchstone_ship_mark_stale "$job_dir" "$claim_token"
            return 0
          fi
          case "$started_epoch" in
            '' | *[!0-9]*) return 0 ;;
          esac
          if [ $((now_epoch - started_epoch)) -ge 5 ]; then
            touchstone_ship_mark_stale "$job_dir"
          fi
          return 0
          ;;
      esac
      if ! touchstone_ship_pid_is_runner "$job_dir" "$pid"; then
        if [ -n "$claim_token" ]; then
          touchstone_ship_claim_owner_alive "$job_dir" && return 0
          touchstone_ship_mark_stale "$job_dir" "$claim_token"
          return 0
        fi
        case "$started_epoch" in
          '' | *[!0-9]*) ;;
          *)
            if [ $((now_epoch - started_epoch)) -lt 5 ]; then
              return 0
            fi
            ;;
        esac
        touchstone_ship_mark_stale "$job_dir"
      fi
      ;;
    running | review-waiting | fixing | finishing)
      pid="$(touchstone_ship_read "$job_dir" pid)"
      if ! touchstone_ship_pid_is_runner "$job_dir" "$pid"; then
        touchstone_ship_mark_stale "$job_dir" "$claim_token"
      fi
      ;;
    *)
      if [ -n "$claim_token" ]; then
        touchstone_ship_claim_owner_alive "$job_dir" \
          || touchstone_ship_release_claim "$job_dir" "$claim_token" 2>/dev/null \
          || true
      fi
      ;;
  esac
}

touchstone_ship_json() {
  local job_dir="$1" log_lines="${2:-0}"
  local status pid exit_code started_at finished_at reason log_path log_tail=""
  local mode iteration deadline_epoch handoff_invariant handoff_validation handoff_non_goals

  [ -d "$job_dir" ] || {
    printf 'null'
    return 0
  }

  touchstone_ship_refresh "$job_dir"
  status="$(touchstone_ship_read "$job_dir" status)"
  pid="$(touchstone_ship_read "$job_dir" pid)"
  exit_code="$(touchstone_ship_read "$job_dir" exit-code)"
  started_at="$(touchstone_ship_read "$job_dir" started-at)"
  finished_at="$(touchstone_ship_read "$job_dir" finished-at)"
  reason="$(touchstone_ship_read "$job_dir" reason)"
  mode="$(touchstone_ship_read "$job_dir" mode)"
  iteration="$(touchstone_ship_read "$job_dir" review-fix-iteration)"
  deadline_epoch="$(touchstone_ship_read "$job_dir" deadline-epoch)"
  handoff_invariant="$(touchstone_ship_read "$job_dir" handoff-invariant)"
  handoff_validation="$(touchstone_ship_read "$job_dir" handoff-validation)"
  handoff_non_goals="$(touchstone_ship_read "$job_dir" handoff-non-goals)"
  log_path="$job_dir/ship.log"
  case "$pid" in
    '' | *[!0-9]*) pid="" ;;
  esac
  case "$exit_code" in
    '' | *[!0-9]*) exit_code="" ;;
  esac
  if [ "$log_lines" -gt 0 ] && [ -f "$log_path" ]; then
    log_tail="$(tail -n "$log_lines" "$log_path")"
  fi

  printf '{'
  json_field status "$status"
  printf ','
  json_number_or_null_field pid "$pid"
  printf ','
  json_number_or_null_field exit_code "$exit_code"
  printf ','
  json_field started_at "$started_at"
  printf ','
  json_field finished_at "$finished_at"
  printf ','
  json_field reason "$reason"
  printf ','
  json_field mode "$mode"
  printf ','
  json_number_or_null_field review_fix_iteration "$iteration"
  printf ','
  json_number_or_null_field deadline_epoch "$deadline_epoch"
  printf ','
  json_field handoff_invariant "$handoff_invariant"
  printf ','
  json_field handoff_validation "$handoff_validation"
  printf ','
  json_field handoff_non_goals "$handoff_non_goals"
  printf ','
  json_field log_path "$log_path"
  if [ "$log_lines" -gt 0 ]; then
    printf ','
    json_field log_tail "$log_tail"
  fi
  printf '}'
}
