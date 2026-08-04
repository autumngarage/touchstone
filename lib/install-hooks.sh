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
#   4  core.hooksPath is configured and Touchstone will not overwrite it

touchstone_git_hook_path() {
  local project_dir="$1"
  local hook_type="$2"

  if [ -z "$project_dir" ] || [ -z "$hook_type" ]; then
    echo "ERROR: touchstone_git_hook_path requires a project directory and hook type" >&2
    return 1
  fi

  git -C "$project_dir" rev-parse --path-format=absolute --git-path "hooks/$hook_type"
}

touchstone_project_hooks_present() {
  local project_dir="$1"
  local pre_commit_hook pre_push_hook

  pre_commit_hook="$(touchstone_git_hook_path "$project_dir" pre-commit)" || return 2
  pre_push_hook="$(touchstone_git_hook_path "$project_dir" pre-push)" || return 2
  [ -f "$pre_commit_hook" ] && [ -f "$pre_push_hook" ]
}

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

  local configured_hooks_path=""
  configured_hooks_path="$(git -C "$project_dir" config --get core.hooksPath 2>/dev/null || true)"
  if [ -n "$configured_hooks_path" ]; then
    echo "==> Git hooks not changed: core.hooksPath is configured ($configured_hooks_path)." >&2
    echo "    Touchstone will not unset repository hook configuration." >&2
    echo "    Remove core.hooksPath and rerun touchstone init if Touchstone should manage pre-commit shims." >&2
    return 4
  fi

  echo "==> Installing git hooks"

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
