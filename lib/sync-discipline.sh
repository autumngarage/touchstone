#!/usr/bin/env bash
#
# Shared discipline for project sync safety checks and drift visibility.

touchstone_sync_project_type() {
  local project_dir="$1"
  local project_type="generic"

  if [ -f "$project_dir/.touchstone-config" ]; then
    project_type="$(grep '^project_type=' "$project_dir/.touchstone-config" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
  fi

  printf '%s\n' "${project_type:-generic}"
}

touchstone_sync_planned_write_paths() {
  local project_dir="$1" touchstone_root="$2"
  local project_type
  project_type="$(touchstone_sync_project_type "$project_dir")"

  {
    printf '.touchstone-manifest\n'
    printf '.touchstone-version\n'
    printf 'TOUCHSTONE.md\n'
    printf '.github/workflows/issue-claim-check.yml\n'
    printf '.claude/settings.json\n'
    printf 'principles/\n'
    printf 'scripts/branch-guard.sh\n'
    printf 'scripts/emergency-disclosure.sh\n'
    printf 'scripts/cortex-pr-merged-hook.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    # Retired paths remain planned writes so dirty local copies block deletion.
    printf 'scripts/conductor-review.sh\n'
    printf 'scripts/codex-review.sh\n'
    printf 'scripts/claim-issue.sh\n'
    printf 'scripts/issue-claim-check.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    printf 'scripts/spawn-worktree.sh\n'
    printf 'scripts/cleanup-worktrees.sh\n'
    printf 'scripts/worker.sh\n'
    printf 'lib/toml.sh\n'
    printf 'lib/events.sh\n'
    printf 'lib/codex-auth.sh\n'
    printf 'lib/worker-ship-job.sh\n'
    printf 'lib/worker-review-fix.sh\n'
    printf 'lib/worker-state.sh\n'
    printf 'lib/script-sync-guard.sh\n'
    printf 'lib/preflight.sh\n'
    printf 'lib/preflight-scope.sh\n'
    printf 'lib/review-comment.sh\n'

    if [ "$project_type" = "python" ] || [ -f "$project_dir/scripts/run-pytest-in-venv.sh" ]; then
      printf 'scripts/run-pytest-in-venv.sh\n'
    fi

    if [ -d "$touchstone_root/.claude/skills" ]; then
      local skill_dir skill_name f
      for skill_dir in "$touchstone_root/.claude/skills/"touchstone-*/; do
        [ -d "$skill_dir" ] || continue
        skill_name="$(basename "$skill_dir")"
        for f in "$skill_dir"*; do
          [ -f "$f" ] || continue
          printf '.claude/skills/%s/%s\n' "$skill_name" "$(basename "$f")"
        done
      done
    fi

    if [ "$project_type" = "swift" ] \
      && [ -f "$touchstone_root/templates/swift/.swiftlint.yml" ] \
      && [ ! -f "$project_dir/.swiftlint.yml" ]; then
      printf '.swiftlint.yml\n'
    fi

    if [ -f "$touchstone_root/templates/GEMINI.md" ] && [ ! -f "$project_dir/GEMINI.md" ]; then
      printf 'GEMINI.md\n'
    fi

    if [ -f "$project_dir/AGENTS.md" ]; then
      printf 'AGENTS.md\n'
    fi

  } | sort -u
}

touchstone_sync_dirty_paths() {
  local project_dir="$1"

  git -C "$project_dir" status --porcelain --untracked-files=all \
    | while IFS= read -r line; do
      [ -n "$line" ] || continue
      local path="${line#???}"
      case "$path" in
        *" -> "*)
          printf '%s\n' "${path%% -> *}"
          printf '%s\n' "${path##* -> }"
          ;;
        *)
          printf '%s\n' "$path"
          ;;
      esac
    done | sort -u
}

touchstone_sync_paths_overlap() {
  local dirty_path="$1" planned_path="$2"

  dirty_path="${dirty_path#./}"
  planned_path="${planned_path#./}"
  dirty_path="${dirty_path%/}"
  planned_path="${planned_path%/}"

  [ -n "$dirty_path" ] || return 1
  [ -n "$planned_path" ] || return 1

  if [ "$dirty_path" = "$planned_path" ]; then
    return 0
  fi
  case "$dirty_path/" in
    "$planned_path"/*) return 0 ;;
  esac
  case "$planned_path/" in
    "$dirty_path"/*) return 0 ;;
  esac

  return 1
}

touchstone_sync_dirty_overlap_paths() {
  local project_dir="$1" touchstone_root="$2"
  local tmp_dir dirty_file planned_file
  tmp_dir="$(mktemp -d -t touchstone-sync-discipline.XXXXXX)"
  dirty_file="$tmp_dir/dirty"
  planned_file="$tmp_dir/planned"

  touchstone_sync_dirty_paths "$project_dir" >"$dirty_file"
  touchstone_sync_planned_write_paths "$project_dir" "$touchstone_root" >"$planned_file"

  while IFS= read -r dirty_path; do
    [ -n "$dirty_path" ] || continue
    while IFS= read -r planned_path; do
      [ -n "$planned_path" ] || continue
      if touchstone_sync_paths_overlap "$dirty_path" "$planned_path"; then
        printf '%s\n' "$dirty_path"
        break
      fi
    done <"$planned_file"
  done <"$dirty_file" | sort -u

  rm -rf "$tmp_dir"
}

touchstone_sync_format_path_list() {
  awk 'BEGIN { first = 1 } { if (!first) printf ", "; printf "%s", $0; first = 0 } END { printf "\n" }'
}

touchstone_sync_git_dir() {
  local project_dir="$1"
  local git_dir

  git_dir="$(git -C "$project_dir" rev-parse --git-dir 2>/dev/null || true)"
  [ -n "$git_dir" ] || return 1
  case "$git_dir" in
    /*) printf '%s\n' "$git_dir" ;;
    *) printf '%s\n' "$project_dir/$git_dir" ;;
  esac
}

touchstone_sync_skip_log_file() {
  local project_dir="$1" git_dir

  git_dir="$(touchstone_sync_git_dir "$project_dir")" || return 1
  printf '%s\n' "$git_dir/touchstone/sync-skips.jsonl"
}

touchstone_sync_json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

touchstone_sync_paths_json_array() {
  local first=true escaped

  printf '['
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    escaped="$(printf '%s' "$path" | touchstone_sync_json_escape)"
    if [ "$first" = true ]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$escaped"
  done
  printf ']'
}

touchstone_sync_log_skip() {
  local project_dir="$1" from_version="$2" to_version="$3" reason="$4" paths="$5" command="$6"
  local log_file timestamp paths_json

  log_file="$(touchstone_sync_skip_log_file "$project_dir" 2>/dev/null || true)"
  [ -n "$log_file" ] || return 0
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  paths_json="$(printf '%s\n' "$paths" | touchstone_sync_paths_json_array)"

  printf '{"timestamp":"%s","from_version":"%s","to_version":"%s","reason":"%s","overlapping_paths":%s,"command":"%s"}\n' \
    "$(printf '%s' "$timestamp" | touchstone_sync_json_escape)" \
    "$(printf '%s' "$from_version" | touchstone_sync_json_escape)" \
    "$(printf '%s' "$to_version" | touchstone_sync_json_escape)" \
    "$(printf '%s' "$reason" | touchstone_sync_json_escape)" \
    "$paths_json" \
    "$(printf '%s' "$command" | touchstone_sync_json_escape)" >>"$log_file" 2>/dev/null || true
}

touchstone_sync_timestamp_epoch() {
  local timestamp="$1"

  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s' 2>/dev/null \
    || date -u -d "$timestamp" '+%s' 2>/dev/null \
    || printf '0\n'
}

touchstone_sync_warn_if_drift_skipped() {
  local project_dir="$1" installed_id="$2"

  [ "${TOUCHSTONE_NO_DRIFT_WARNING:-}" = "1" ] && return 0
  [ -n "$installed_id" ] || return 0
  [ -f "$project_dir/.touchstone-version" ] || return 0

  local project_id
  project_id="$(tr -d '[:space:]' <"$project_dir/.touchstone-version" 2>/dev/null || true)"
  [ -n "$project_id" ] || return 0
  [ "$project_id" != "$installed_id" ] || return 0

  local log_file
  log_file="$(touchstone_sync_skip_log_file "$project_dir" 2>/dev/null || true)"
  [ -n "$log_file" ] || return 0
  [ -s "$log_file" ] || return 0

  local threshold_days threshold_count skip_count last_line timestamp last_epoch now_epoch age_days reason paths_text
  threshold_count="${TOUCHSTONE_DRIFT_WARNING_SKIP_THRESHOLD:-3}"
  threshold_days="${TOUCHSTONE_DRIFT_WARNING_DAYS:-7}"
  skip_count="$(wc -l <"$log_file" | tr -d '[:space:]')"
  last_line="$(tail -n 1 "$log_file" 2>/dev/null || true)"
  [ -n "$last_line" ] || return 0

  timestamp="$(printf '%s\n' "$last_line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')"
  last_epoch="$(touchstone_sync_timestamp_epoch "$timestamp")"
  now_epoch="$(date -u '+%s')"
  if [ "$last_epoch" -gt 0 ] && [ "$now_epoch" -ge "$last_epoch" ]; then
    age_days="$(((now_epoch - last_epoch) / 86400))"
  else
    age_days="$threshold_days"
  fi

  if [ "$skip_count" -le "$threshold_count" ] && [ "$age_days" -le "$threshold_days" ]; then
    return 0
  fi

  reason="$(printf '%s\n' "$last_line" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')"
  reason="${reason:-unknown}"
  paths_text="$(printf '%s\n' "$last_line" \
    | sed -n 's/.*"overlapping_paths":\[\([^]]*\)\].*/\1/p' \
    | sed 's/"//g; s/,/, /g')"
  if [ -n "$paths_text" ]; then
    paths_text=" on $paths_text"
  fi

  echo "[touchstone drift] project at $project_id, current is $installed_id - $skip_count sync attempts skipped, last $age_days days ago ($reason$paths_text). Run \`touchstone update\` after committing or .gitignoring those paths." >&2
}
