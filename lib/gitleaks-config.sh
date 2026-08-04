#!/usr/bin/env bash
#
# Preserve project-owned Gitleaks configuration while installing Touchstone's
# managed wrapper.
# shellcheck disable=SC2034 # state is consumed by the sourcing bootstrap script

TOUCHSTONE_GITLEAKS_MIGRATED=false

touchstone_gitleaks_config_is_managed() {
  local config_file="$1"
  local first_line=""
  [ -f "$config_file" ] || return 1
  IFS= read -r first_line <"$config_file" || true
  [ "$first_line" = '# touchstone:managed-gitleaks-config' ]
}

touchstone_gitleaks_validate_project_config() {
  local project_dir="$1"
  local root_config="$project_dir/.gitleaks.toml"
  local local_config="$project_dir/.gitleaks.local.toml"

  # These paths can contain project-owned rules. Unlike Touchstone-managed
  # destinations, never replace a final-component symlink automatically: doing
  # so would silently discard the project's chosen shared-config relationship.
  if [ -L "$root_config" ]; then
    echo "ERROR: project-owned .gitleaks.toml is a symlink; refusing migration." >&2
    return 1
  fi
  if [ -e "$root_config" ] && [ ! -f "$root_config" ]; then
    echo "ERROR: existing .gitleaks.toml is not a regular file; refusing migration." >&2
    return 1
  fi
  if [ -L "$local_config" ]; then
    echo "ERROR: project-owned .gitleaks.local.toml is a symlink; refusing to replace it." >&2
    return 1
  fi
  if [ -e "$local_config" ] && [ ! -f "$local_config" ]; then
    echo "ERROR: existing .gitleaks.local.toml is not a regular file; refusing to replace it." >&2
    return 1
  fi

  if [ -f "$root_config" ] \
    && ! touchstone_gitleaks_config_is_managed "$root_config" \
    && [ -f "$local_config" ]; then
    echo "ERROR: both a project-owned .gitleaks.toml and .gitleaks.local.toml exist." >&2
    echo "       Merge them into .gitleaks.local.toml, remove .gitleaks.toml, then rerun Touchstone." >&2
    return 1
  fi

  return 0
}

touchstone_gitleaks_prepare_project_config() {
  local project_dir="$1"
  local dry_run="${2:-false}"
  local migration_strategy="${3:-move}"
  local root_config="$project_dir/.gitleaks.toml"
  local local_config="$project_dir/.gitleaks.local.toml"

  TOUCHSTONE_GITLEAKS_MIGRATED=false

  if ! touchstone_gitleaks_validate_project_config "$project_dir"; then
    return 1
  fi

  if [ ! -e "$root_config" ] || touchstone_gitleaks_config_is_managed "$root_config"; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    echo "    ~ would preserve project Gitleaks config as .gitleaks.local.toml"
    return 0
  fi

  case "$migration_strategy" in
    copy)
      # Update rollback snapshots still need the original root path to exist
      # when update_file classifies it. The managed overwrite happens later.
      cp "$root_config" "$local_config"
      ;;
    move)
      mv "$root_config" "$local_config"
      ;;
    *)
      echo "ERROR: unsupported Gitleaks migration strategy: $migration_strategy" >&2
      return 1
      ;;
  esac
  TOUCHSTONE_GITLEAKS_MIGRATED=true
  echo "    ~ preserved project Gitleaks config as .gitleaks.local.toml"
}
