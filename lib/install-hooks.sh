#!/usr/bin/env bash
#
# lib/install-hooks.sh — install pre-commit hooks in a project.
#
# Source this file and call touchstone_install_hooks <project_dir>.
# Callers running with `set -e` should guard the call with `|| rc=$?` because
# the helper encodes gap states (pre-commit missing, install failures) in the
# return status — they are not fatal errors for the caller's workflow.
#
# Installs pre-commit and pre-push hook types only. commit-msg is intentionally
# skipped — no commit-msg hooks are configured in any shipped config, so
# installing that type would create an empty shim that runs on every commit.
#
# Outputs progress to stdout. Returns:
#   0  hooks installed (idempotent — safe to re-run)
#   1  no .pre-commit-config.yaml in project_dir, nothing to do
#   2  pre-commit CLI is missing; gap printed, caller should surface in summary
#   3  pre-commit is present but one or more hook installs failed

touchstone_install_hooks() {
  local project_dir="$1"

  if [ -z "$project_dir" ]; then
    echo "ERROR: touchstone_install_hooks requires a project directory" >&2
    return 1
  fi

  if [ ! -f "$project_dir/.pre-commit-config.yaml" ]; then
    return 1
  fi

  if ! command -v pre-commit >/dev/null 2>&1; then
    echo "==> Git hooks skipped: pre-commit CLI is not installed."
    echo "    Install it:  brew install pre-commit  (or: pip install pre-commit)"
    echo "    Then run:    cd \"$project_dir\" && pre-commit install --hook-type pre-commit --hook-type pre-push"
    return 2
  fi

  echo "==> Installing git hooks"
  # core.hooksPath overrides .git/hooks, which conflicts with pre-commit's install target.
  (cd "$project_dir" && git config --unset-all core.hooksPath 2>/dev/null || true)

  local hook_type out status=0
  for hook_type in pre-commit pre-push; do
    if out="$(cd "$project_dir" && pre-commit install --hook-type "$hook_type" 2>&1)"; then
      printf '    %s\n' "$(printf '%s' "$out" | tail -1)"
    else
      printf '    FAILED: pre-commit install --hook-type %s\n' "$hook_type" >&2
      printf '%s\n' "$out" | sed 's/^/      /' >&2
      status=3
    fi
  done

  return "$status"
}
