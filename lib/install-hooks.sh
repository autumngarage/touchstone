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
  local hook_path project_root

  if [ -z "$project_dir" ] || [ -z "$hook_type" ]; then
    echo "ERROR: touchstone_git_hook_path requires a project directory and hook type" >&2
    return 1
  fi

  hook_path="$(git -C "$project_dir" rev-parse --git-path "hooks/$hook_type")" || return 1
  case "$hook_path" in
    /*) printf '%s\n' "$hook_path" ;;
    *)
      project_root="$(cd -P "$project_dir" && pwd)" || return 1
      printf '%s/%s\n' "$project_root" "$hook_path"
      ;;
  esac
}

touchstone_project_hooks_present() {
  local project_dir="$1"
  local pre_commit_hook pre_push_hook

  pre_commit_hook="$(touchstone_git_hook_path "$project_dir" pre-commit)" || return 2
  pre_push_hook="$(touchstone_git_hook_path "$project_dir" pre-push)" || return 2
  [ -f "$pre_commit_hook" ] && [ -f "$pre_push_hook" ]
}

# A hook shim is ready only when it is TYPED for the slot it occupies AND
# bound to this project's Touchstone config. The generic pre-commit.com
# marker is not sufficient: a pre-commit shim copied over pre-push still
# carries the marker but runs `--hook-type pre-commit`, silently bypassing
# every pre-push validation; and a shim installed with an alternate
# `--config other.yaml` runs none of this project's validation. The
# framework records both into the shim; require the recorded hook type to
# match the slot and the recorded config to be .pre-commit-config.yaml.
touchstone_pre_commit_hook_ready() {
  local hook_path="$1"
  local hook_type="$2"

  if [ -z "$hook_type" ]; then
    echo "ERROR: touchstone_pre_commit_hook_ready requires an expected hook type" >&2
    return 1
  fi
  [ -s "$hook_path" ] && [ -x "$hook_path" ] \
    && grep -q 'pre-commit\.com' "$hook_path" 2>/dev/null \
    && grep -Eq -- \
      "(--hook-type[= ]|HOOK_TYPE=)[\"']?${hook_type}[\"']?([^a-z-]|$)" \
      "$hook_path" 2>/dev/null \
    && grep -Eq -- \
      "--config[= ][\"']?\.pre-commit-config\.yaml[\"']?([^0-9A-Za-z._-]|$)" \
      "$hook_path" 2>/dev/null
}

touchstone_project_hooks_ready() {
  local project_dir="$1"
  local pre_commit_hook pre_push_hook

  pre_commit_hook="$(touchstone_git_hook_path "$project_dir" pre-commit)" || return 2
  pre_push_hook="$(touchstone_git_hook_path "$project_dir" pre-push)" || return 2
  touchstone_pre_commit_hook_ready "$pre_commit_hook" pre-commit \
    && touchstone_pre_commit_hook_ready "$pre_push_hook" pre-push
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

  # The configured hook boundary is checked BEFORE tool availability: a
  # project-owned core.hooksPath is a preservation decision that holds whether
  # or not the optional pre-commit CLI happens to be installed. Checking the
  # CLI first would misreport "hooks not installed, install pre-commit" for a
  # repo whose configured path already carries valid typed shims.
  local configured_hooks_path=""
  configured_hooks_path="$(git -C "$project_dir" config --get core.hooksPath 2>/dev/null || true)"
  if [ -n "$configured_hooks_path" ]; then
    echo "==> Git hooks not changed: core.hooksPath is configured ($configured_hooks_path)." >&2
    echo "    Touchstone will not unset repository hook configuration." >&2
    echo "    Remove core.hooksPath and rerun touchstone init if Touchstone should manage pre-commit shims." >&2
    return 4
  fi

  if ! command -v pre-commit >/dev/null 2>&1; then
    echo "==> Git hooks skipped: pre-commit CLI is not installed."
    echo "    Install it:  brew install pre-commit  (or: pip install pre-commit)"
    echo "    Then run:    cd \"$project_dir\" && pre-commit install --hook-type pre-commit --hook-type pre-push"
    return 2
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
