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
    printf '.claude/settings.json\n'
    printf 'principles/\n'
    printf 'scripts/codex-review.sh\n'
    printf 'scripts/branch-guard.sh\n'
    printf 'scripts/emergency-disclosure.sh\n'
    printf 'scripts/cortex-pr-merged-hook.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    printf 'scripts/spawn-worktree.sh\n'
    printf 'scripts/cleanup-worktrees.sh\n'
    printf 'scripts/worker.sh\n'
    printf 'lib/toml.sh\n'
    printf 'lib/events.sh\n'
    printf 'lib/worker-state.sh\n'
    printf 'lib/preflight.sh\n'
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

    if [ -f "$project_dir/.codex-review.toml" ]; then
      if grep -qE '^[[:space:]]*reviewers[[:space:]]*=[[:space:]]*\[' "$project_dir/.codex-review.toml" \
        || grep -qE '^\[review\.local\]' "$project_dir/.codex-review.toml" \
        || grep -qE '^\[review\.assist\]' "$project_dir/.codex-review.toml" \
        || grep -qE '^[[:space:]]*(small|large)_reviewers[[:space:]]*=[[:space:]]*\[' "$project_dir/.codex-review.toml"; then
        printf '.codex-review.toml\n'
      fi
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
