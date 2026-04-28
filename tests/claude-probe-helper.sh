#!/usr/bin/env bash
#
# Shared helpers for tests that shell out to Claude Code. These probes spend
# real provider quota and depend on local auth, so they must fail visibly but
# never hang the whole test suite indefinitely.

run_claude_probe() {
  local prompt="$1"
  local timeout_secs="${TOUCHSTONE_CLAUDE_PROBE_TIMEOUT:-90}"

  case "$timeout_secs" in
    ''|*[!0-9]*) timeout_secs=90 ;;
  esac

  if [ "$timeout_secs" -le 0 ] 2>/dev/null; then
    claude -p "$prompt"
    return $?
  fi

  local out_file timed_out_file claude_pid watchdog_pid rc
  out_file="$(mktemp -t touchstone-claude-probe-output.XXXXXX)"
  timed_out_file="$(mktemp -t touchstone-claude-probe-timeout.XXXXXX)"
  rm -f "$timed_out_file"

  claude -p "$prompt" >"$out_file" 2>&1 &
  claude_pid=$!

  (
    sleep "$timeout_secs"
    if kill -0 "$claude_pid" 2>/dev/null; then
      printf 'timeout\n' > "$timed_out_file"
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

  rm -f "$out_file" "$timed_out_file"
  return "$rc"
}
