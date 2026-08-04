#!/usr/bin/env bash
#
# Preserve project-owned Gitleaks configuration while installing Touchstone's
# managed wrapper. Callers must source lib/safe-write.sh first.
# shellcheck disable=SC2034 # state is consumed by the sourcing bootstrap script

TOUCHSTONE_GITLEAKS_MIGRATED=false

touchstone_gitleaks_config_is_managed() {
  local config_file="$1"
  local first_line=""
  [ -f "$config_file" ] || return 1
  IFS= read -r first_line <"$config_file" || true
  [ "$first_line" = '# touchstone:managed-gitleaks-config' ]
}

touchstone_gitleaks_prepare_project_config() {
  local project_dir="$1"
  local dry_run="${2:-false}"
  local root_config="$project_dir/.gitleaks.toml"
  local local_config="$project_dir/.gitleaks.local.toml"

  TOUCHSTONE_GITLEAKS_MIGRATED=false

  if ! touchstone_ensure_safe_dest "$root_config" "$project_dir" "$dry_run" \
    || ! touchstone_ensure_safe_dest "$local_config" "$project_dir" "$dry_run"; then
    return 1
  fi

  if [ ! -e "$root_config" ] || touchstone_gitleaks_config_is_managed "$root_config"; then
    return 0
  fi

  if [ ! -f "$root_config" ]; then
    echo "ERROR: existing .gitleaks.toml is not a regular file; refusing migration." >&2
    return 1
  fi
  if [ -e "$local_config" ]; then
    echo "ERROR: both a project-owned .gitleaks.toml and .gitleaks.local.toml exist." >&2
    echo "       Merge them into .gitleaks.local.toml, remove .gitleaks.toml, then rerun Touchstone." >&2
    return 1
  fi

  if [ "$dry_run" = true ]; then
    echo "    ~ would preserve project Gitleaks config as .gitleaks.local.toml"
    return 0
  fi

  mv "$root_config" "$local_config"
  TOUCHSTONE_GITLEAKS_MIGRATED=true
  echo "    ~ preserved project Gitleaks config as .gitleaks.local.toml"
}
