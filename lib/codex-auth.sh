#!/usr/bin/env bash
#
# Shared authentication boundary for subscription-backed Codex execution.

TOUCHSTONE_CODEX_AUTH_FAILURE=""

# shellcheck disable=SC2034 # Failure reason is an output consumed by callers.
touchstone_codex_subscription_auth_check() {
  local login_status=""

  TOUCHSTONE_CODEX_AUTH_FAILURE=""
  if ! command -v codex >/dev/null 2>&1; then
    TOUCHSTONE_CODEX_AUTH_FAILURE="cli-missing"
    return 127
  fi

  if ! login_status="$(codex login status 2>&1)"; then
    TOUCHSTONE_CODEX_AUTH_FAILURE="status-failed"
    return 127
  fi

  if printf '%s\n' "$login_status" | grep -Fqx 'Logged in using ChatGPT'; then
    return 0
  fi
  if printf '%s\n' "$login_status" | grep -Fqx 'Logged in using an API key'; then
    TOUCHSTONE_CODEX_AUTH_FAILURE="api-key"
    return 126
  fi

  TOUCHSTONE_CODEX_AUTH_FAILURE="unknown"
  return 126
}
