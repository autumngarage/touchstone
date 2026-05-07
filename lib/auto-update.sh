#!/usr/bin/env bash
#
# lib/auto-update.sh — auto-update check for the Touchstone CLI.
#
# Checks if a newer version is available on GitHub. If yes, upgrades
# via brew (if installed that way) or git pull (if running from clone).
#
# Called on every `touchstone` invocation. Throttled to check at most
# once per hour to avoid slowing down every command.
#
# Env overrides:
#   TOUCHSTONE_NO_AUTO_UPDATE=1  — disable auto-update and auto-project-sync entirely
#   TOUCHSTONE_NO_AUTO_PROJECT_SYNC=1 — disable per-project file sync only
#   TOUCHSTONE_UPDATE_INTERVAL   — seconds between checks (default: 3600 = 1 hour)
#

TOUCHSTONE_SYNC_DISCIPLINE_PATH="$TOUCHSTONE_ROOT/lib/sync-discipline.sh"
if [ ! -f "$TOUCHSTONE_SYNC_DISCIPLINE_PATH" ]; then
  TOUCHSTONE_AUTO_UPDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  TOUCHSTONE_SYNC_DISCIPLINE_PATH="$TOUCHSTONE_AUTO_UPDATE_LIB_DIR/sync-discipline.sh"
fi
# shellcheck source=sync-discipline.sh
source "$TOUCHSTONE_SYNC_DISCIPLINE_PATH"

TOUCHSTONE_UPDATE_INTERVAL="${TOUCHSTONE_UPDATE_INTERVAL:-3600}"
TOUCHSTONE_STATE_DIR="${TOUCHSTONE_STATE_DIR:-$HOME/.touchstone}"
LAST_CHECK_FILE="$TOUCHSTONE_STATE_DIR/last-update-check"

touchstone_auto_update() {
  # Skip if disabled.
  if [ "${TOUCHSTONE_NO_AUTO_UPDATE:-}" = "1" ]; then
    return 0
  fi

  # Ensure state directory exists.
  mkdir -p "$TOUCHSTONE_STATE_DIR"

  # Throttle: skip if we checked recently.
  if [ -f "$LAST_CHECK_FILE" ]; then
    local last_check
    last_check="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)"
    local now
    now="$(date +%s)"
    local elapsed=$((now - last_check))
    if [ "$elapsed" -lt "$TOUCHSTONE_UPDATE_INTERVAL" ]; then
      return 0
    fi
  fi

  # Record that we're checking now (even if the check fails).
  date +%s >"$LAST_CHECK_FILE"

  # Get current version.
  local current_version
  current_version="$(cat "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$current_version" ]; then
    return 0
  fi

  # Fetch latest release version from GitHub (non-blocking, timeout 5s).
  local latest_version
  latest_version="$(curl -fsSL --max-time 5 \
    "https://api.github.com/repos/autumngarage/touchstone/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')" || return 0

  if [ -z "$latest_version" ]; then
    return 0
  fi

  # Compare versions (simple string compare — works for semver if we don't skip versions).
  if [ "$current_version" = "$latest_version" ]; then
    return 0
  fi

  # Version differs — try to upgrade.
  echo "==> touchstone v${current_version} is outdated (latest: v${latest_version}). Updating..." >&2

  if command -v brew >/dev/null 2>&1 && brew list touchstone &>/dev/null; then
    # Installed via brew — upgrade that way.
    brew upgrade touchstone 2>&1 | sed 's/^/    /' >&2
    echo "==> Updated to v${latest_version} via brew." >&2
  elif [ -d "$TOUCHSTONE_ROOT/.git" ]; then
    # Running from a git clone — pull.
    git -C "$TOUCHSTONE_ROOT" pull --rebase 2>&1 | sed 's/^/    /' >&2
    echo "==> Updated to latest via git pull." >&2
  else
    echo "==> Update available: v${latest_version}. Run: brew upgrade touchstone" >&2
  fi
}

touchstone_installed_id() {
  local current_version
  current_version="$(cat "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"

  # Mirror bootstrap/update-project.sh exactly: regular source checkouts record
  # the Touchstone git SHA, while brew installs and git-worktree checkouts
  # record VERSION. Comparing any other field would re-sync forever.
  if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
    git -C "$TOUCHSTONE_ROOT" rev-parse HEAD
  else
    printf '%s\n' "$current_version"
  fi
}

touchstone_find_project_root() {
  local dir
  dir="$(pwd)"

  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.touchstone-version" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

touchstone_auto_project_sync_command_skips() {
  local command="${1:-}" subcommand="${2:-}"

  case "$command" in
    "" | help | -h | --help | version | --version | status | list | ls | diff | changelog | doctor | detect | skills | update | sync | new | init | migrate-from-toolkit | migrate-review-config | release)
      return 0
      ;;
  esac

  case "$command:$subcommand" in
    adr:list | worker:status | worker:list | review:--dry-run | review:-n)
      return 0
      ;;
  esac

  return 1
}

touchstone_auto_project_sync() {
  local command="${1:-}"
  shift 2>/dev/null || true

  if [ "${TOUCHSTONE_NO_AUTO_UPDATE:-}" = "1" ] \
    || [ "${TOUCHSTONE_NO_AUTO_PROJECT_SYNC:-}" = "1" ]; then
    return 0
  fi

  if touchstone_auto_project_sync_command_skips "$command" "$@"; then
    return 0
  fi

  local project_dir
  if ! project_dir="$(touchstone_find_project_root)"; then
    return 0
  fi

  local project_realpath touchstone_realpath
  project_realpath="$(cd "$project_dir" 2>/dev/null && pwd -P || true)"
  touchstone_realpath="$(cd "$TOUCHSTONE_ROOT" 2>/dev/null && pwd -P || true)"
  if [ -n "$project_realpath" ] && [ "$project_realpath" = "$touchstone_realpath" ]; then
    return 0
  fi

  local project_id installed_id
  project_id="$(tr -d '[:space:]' <"$project_dir/.touchstone-version" 2>/dev/null || true)"
  installed_id="$(touchstone_installed_id)"
  [ -n "$project_id" ] || return 0
  [ -n "$installed_id" ] || return 0

  if [ "$project_id" = "$installed_id" ]; then
    return 0
  fi

  if ! git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "WARNING: touchstone auto-sync skipped for $project_dir (not a git repository)." >&2
    return 0
  fi

  local dirty_paths overlap_paths
  dirty_paths="$(touchstone_sync_dirty_paths "$project_dir")"
  overlap_paths="$(touchstone_sync_dirty_overlap_paths "$project_dir" "$TOUCHSTONE_ROOT")"

  if [ -n "$overlap_paths" ] && [ "${TOUCHSTONE_FORCE_OVERLAP:-}" != "1" ]; then
    echo "WARNING: touchstone auto-sync skipped for $project_dir (dirty paths overlap planned touchstone writes)." >&2
    printf '%s\n' "$overlap_paths" | sed 's/^/         - /' >&2
    touchstone_sync_log_skip "$project_dir" "$project_id" "$installed_id" "dirty-overlap" "$overlap_paths" "touchstone $command"
    return 0
  fi

  if [ -n "$overlap_paths" ]; then
    echo "WARNING: TOUCHSTONE_FORCE_OVERLAP=1 set; auto-sync proceeding despite dirty paths that overlap planned touchstone writes:" >&2
    printf '%s\n' "$overlap_paths" | sed 's/^/         - /' >&2
  elif [ -n "$dirty_paths" ]; then
    printf '==> Proceeding with sync past unrelated dirty paths: ' >&2
    printf '%s\n' "$dirty_paths" | touchstone_sync_format_path_list >&2
  fi

  local log_file
  log_file="$(mktemp -t touchstone-auto-project-sync.XXXXXX)"

  # Invariant: after any non-readonly `touchstone <subcmd>` in a
  # touchstone-aware project, the project's principles/hooks/scripts match the
  # installed Touchstone id, or the user opted out, or the tree was dirty.
  if (cd "$project_dir" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$log_file" 2>&1; then
    rm -f "$log_file"
    echo "==> auto-synced touchstone $project_id -> $installed_id" >&2
    return 0
  fi

  echo "WARNING: touchstone auto-sync failed for $project_dir; continuing. Log: $log_file" >&2
  touchstone_sync_log_skip "$project_dir" "$project_id" "$installed_id" "auto-sync-failed" "" "touchstone $command"
  return 0
}
