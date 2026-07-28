#!/usr/bin/env bash
#
# Shared helpers for tests that shell out to Claude Code. These probes spend
# real provider quota and depend on local auth, so they must fail visibly but
# never hang the whole test suite indefinitely.

claude_probe_provider_unavailable() {
  local output="$1"

  printf '%s\n' "$output" | grep -qiE \
    "hit your limit|rate.?limit|quota|too many requests|429|usage limit|provider unavailable|auth(entication)? (failed|required|expired)|oauth access token (has )?expired|not authenticated|not logged in|login required"
}

run_claude_probe() {
  local prompt="$1"
  local timeout_secs="${TOUCHSTONE_CLAUDE_PROBE_TIMEOUT:-90}"

  case "$timeout_secs" in
    '' | *[!0-9]*) timeout_secs=90 ;;
  esac

  if [ "$timeout_secs" -le 0 ] 2>/dev/null; then
    local direct_output direct_rc
    set +e
    direct_output="$(claude -p "$prompt" 2>&1)"
    direct_rc=$?
    set -e
    printf '%s\n' "$direct_output"
    if [ "$direct_rc" -ne 0 ] && claude_probe_provider_unavailable "$direct_output"; then
      return 125
    fi
    return "$direct_rc"
  fi

  local out_file timed_out_file claude_pid watchdog_pid rc
  out_file="$(mktemp -t touchstone-claude-probe-output.XXXXXX)"
  timed_out_file="$(mktemp -t touchstone-claude-probe-timeout.XXXXXX)"
  rm -f "$timed_out_file"

  claude -p "$prompt" >"$out_file" 2>&1 &
  claude_pid=$!

  (
    elapsed=0
    while [ "$elapsed" -lt "$timeout_secs" ]; do
      sleep 1
      if ! kill -0 "$claude_pid" 2>/dev/null; then
        exit 0
      fi
      elapsed=$((elapsed + 1))
    done

    if kill -0 "$claude_pid" 2>/dev/null; then
      printf 'timeout\n' >"$timed_out_file"
      kill "$claude_pid" 2>/dev/null || true
      sleep 2
      kill -9 "$claude_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  set +e
  wait "$claude_pid"
  rc=$?
  set -e

  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  cat "$out_file"
  if [ -f "$timed_out_file" ]; then
    rm -f "$out_file" "$timed_out_file"
    return 124
  fi

  if [ "$rc" -ne 0 ] && claude_probe_provider_unavailable "$(cat "$out_file")"; then
    rm -f "$out_file" "$timed_out_file"
    return 125
  fi

  rm -f "$out_file" "$timed_out_file"
  return "$rc"
}
