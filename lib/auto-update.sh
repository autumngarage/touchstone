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
#   TOUCHSTONE_NO_AUTO_UPDATE=1  — disable auto-update entirely
#   TOUCHSTONE_UPDATE_INTERVAL   — seconds between checks (default: 3600 = 1 hour)
#

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
  date +%s > "$LAST_CHECK_FILE"

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
