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
TOUCHSTONE_AUTO_UPDATE_REEXEC_EXIT=75

touchstone_auto_update_version_gte() {
  local current="${1#v}" latest="${2#v}"
  awk -v current="$current" -v latest="$latest" '
    function parse_version(version, parts, count, i) {
      count = split(version, parts, ".")
      if (count < 2 || count > 3) {
        return 0
      }
      for (i = 1; i <= count; i++) {
        if (parts[i] !~ /^[0-9]+$/) {
          return 0
        }
        parts[i] += 0
      }
      for (i = count + 1; i <= 3; i++) {
        parts[i] = 0
      }
      return 1
    }

    BEGIN {
      if (!parse_version(current, cur) || !parse_version(latest, lat)) {
        exit 1
      }
      for (i = 1; i <= 3; i++) {
        if (cur[i] > lat[i]) {
          exit 0
        }
        if (cur[i] < lat[i]) {
          exit 1
        }
      }
      exit 0
    }'
}

touchstone_auto_update() {
  # Skip if disabled.
  if [ "${TOUCHSTONE_NO_AUTO_UPDATE:-}" = "1" ] \
    || [ "${TOUCHSTONE_AUTO_UPDATE_REEXECED:-}" = "1" ]; then
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

  # Only upgrade when the published latest release is newer than this install.
  if touchstone_auto_update_version_gte "$current_version" "$latest_version"; then
    return 0
  fi

  # Installed version is older — try to upgrade.
  echo "==> touchstone v${current_version} is outdated (latest: v${latest_version}). Updating..." >&2

  if command -v brew >/dev/null 2>&1 && brew list touchstone &>/dev/null; then
    # Installed via brew — upgrade that way.
    if brew upgrade touchstone 2>&1 | sed 's/^/    /' >&2; then
      echo "==> Updated to v${latest_version} via brew." >&2
      TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH="$(command -v touchstone 2>/dev/null || true)"
      export TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH
      return "$TOUCHSTONE_AUTO_UPDATE_REEXEC_EXIT"
    fi
    echo "WARNING: touchstone auto-update via brew failed; continuing with current version." >&2
  elif [ -d "$TOUCHSTONE_ROOT/.git" ]; then
    # Running from a git clone — pull.
    if git -C "$TOUCHSTONE_ROOT" pull --rebase 2>&1 | sed 's/^/    /' >&2; then
      echo "==> Updated to latest via git pull." >&2
      TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH="$TOUCHSTONE_ROOT/bin/touchstone"
      export TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH
      return "$TOUCHSTONE_AUTO_UPDATE_REEXEC_EXIT"
    fi
    echo "WARNING: touchstone auto-update via git pull failed; continuing with current version." >&2
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

touchstone_auto_project_sync_config_enabled() {
  local project_dir="$1" config value
  config="$project_dir/.touchstone-config"
  [ -f "$config" ] || return 0

  value="$(awk '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        s = substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      line = trim(line)
      if (line == "") {
        next
      }
      if (line ~ /^\[[^]]+\]$/) {
        section = substr(line, 2, length(line) - 2)
        next
      }
      eq = index(line, "=")
      if (eq == 0) {
        next
      }
      key = trim(substr(line, 1, eq - 1))
      val = unquote(substr(line, eq + 1))
      if (key == "sync_auto" || key == "auto_sync" || key == "auto_project_sync") {
        print val
      } else if (section == "sync" && key == "auto") {
        print val
      }
    }
  ' "$config" 2>/dev/null | tail -1)"

  case "$value" in
    false | False | FALSE | 0 | no | No | NO | off | Off | OFF)
      return 1
      ;;
  esac

  return 0
}

touchstone_semver_major_minor() {
  local version="$1"

  case "$version" in
    v*) version="${version#v}" ;;
  esac

  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-+].*)?$ ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

touchstone_auto_project_sync_should_sync() {
  local project_id="$1" installed_id="$2"
  local project_mm installed_mm

  [ -n "$project_id" ] || return 1
  [ -n "$installed_id" ] || return 1
  [ "$project_id" != "$installed_id" ] || return 1

  if project_mm="$(touchstone_semver_major_minor "$project_id")" \
    && installed_mm="$(touchstone_semver_major_minor "$installed_id")"; then
    [ "$project_mm" != "$installed_mm" ]
    return
  fi

  # Source checkouts record git SHAs instead of semver. Any SHA drift means the
  # managed project files may differ, so keep the existing sync-on-drift rule.
  return 0
}

touchstone_auto_project_sync_command_skips() {
  local command="${1:-}" subcommand="${2:-}"

  case "$command" in
    "" | help | -h | --help | version | --version | status | list | ls | diff | changelog | doctor | review-stats | detect | skills | update | update-all | sync | new | init | migrate-from-toolkit | migrate-review-config | release)
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

  case " $command $* " in
    *" --no-auto-sync "*) return 0 ;;
  esac

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

  if ! touchstone_auto_project_sync_config_enabled "$project_dir"; then
    return 0
  fi

  local project_id installed_id
  project_id="$(tr -d '[:space:]' <"$project_dir/.touchstone-version" 2>/dev/null || true)"
  installed_id="$(touchstone_installed_id)"
  [ -n "$project_id" ] || return 0
  [ -n "$installed_id" ] || return 0

  if ! touchstone_auto_project_sync_should_sync "$project_id" "$installed_id"; then
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
