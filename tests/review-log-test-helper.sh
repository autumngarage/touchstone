#!/usr/bin/env bash
#
# Tests must never write synthetic review events to user-scoped audit state.
# Review and merge fixtures call this after creating their per-test directory.

if [ -n "${TOUCHSTONE_REVIEW_LOG_TEST_HELPER_SOURCED:-}" ]; then
  return 0
fi
TOUCHSTONE_REVIEW_LOG_TEST_HELPER_SOURCED=1

touchstone_isolate_review_log() {
  local fixture_root="$1"

  if [ -z "$fixture_root" ] || [ ! -d "$fixture_root" ]; then
    echo "touchstone_isolate_review_log: fixture directory is required" >&2
    return 1
  fi

  TOUCHSTONE_REVIEW_LOG="$fixture_root/touchstone-review.log"
  export TOUCHSTONE_REVIEW_LOG
}
