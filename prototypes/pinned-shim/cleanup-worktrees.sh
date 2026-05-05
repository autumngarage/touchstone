#!/usr/bin/env bash
#
# Prototype project-local shim for ADR-0001.
#
# A generated production shim would replace PROJECT_TOUCHSTONE_ID with the
# .touchstone-version value reviewed in that project.
set -euo pipefail

PROJECT_TOUCHSTONE_ID="${PROJECT_TOUCHSTONE_ID:-}"
if [ -z "$PROJECT_TOUCHSTONE_ID" ]; then
  if [ -f .touchstone-version ]; then
    PROJECT_TOUCHSTONE_ID="$(tr -d '[:space:]' < .touchstone-version)"
  else
    echo "ERROR: PROJECT_TOUCHSTONE_ID is not set and .touchstone-version is missing." >&2
    exit 1
  fi
fi

exec touchstone run-script cleanup-worktrees \
  --project-version "$PROJECT_TOUCHSTONE_ID" \
  -- "$@"

