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

touchstone_gitleaks_config_has_path_extend() {
  local config_file="$1"

  awk '
    /^[[:space:]]*\[extend\][[:space:]]*(#.*)?$/ {
      in_extend = 1
      next
    }
    /^[[:space:]]*\[/ { in_extend = 0 }
    in_extend && /^[[:space:]]*path[[:space:]]*=/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$config_file"
}

touchstone_gitleaks_validate_project_config() {
  local project_dir="$1"
  local require_tracked_local="${2:-false}"
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

  if touchstone_gitleaks_config_is_managed "$root_config" \
    && [ ! -f "$local_config" ]; then
    echo "ERROR: managed .gitleaks.toml requires a tracked .gitleaks.local.toml, but the local config is missing." >&2
    echo "       Restore and track .gitleaks.local.toml, then rerun Touchstone." >&2
    return 1
  fi

  if [ -f "$root_config" ] \
    && ! touchstone_gitleaks_config_is_managed "$root_config" \
    && touchstone_gitleaks_config_has_path_extend "$root_config"; then
    echo "ERROR: project-owned .gitleaks.toml uses extend.path; refusing to add another config layer." >&2
    echo "       Flatten the referenced rules into this file, then rerun Touchstone." >&2
    return 1
  fi
  if [ -f "$local_config" ] \
    && touchstone_gitleaks_config_has_path_extend "$local_config"; then
    echo "ERROR: project-owned .gitleaks.local.toml uses extend.path; refusing an unsupported nested config chain." >&2
    echo "       Keep extend.useDefault or inline the referenced rules, then rerun Touchstone." >&2
    return 1
  fi

  if [ -f "$root_config" ] \
    && ! touchstone_gitleaks_config_is_managed "$root_config" \
    && [ -f "$local_config" ]; then
    echo "ERROR: both a project-owned .gitleaks.toml and .gitleaks.local.toml exist." >&2
    echo "       Merge them into .gitleaks.local.toml, remove .gitleaks.toml, then rerun Touchstone." >&2
    return 1
  fi

  if [ "$require_tracked_local" = true ] \
    && [ -f "$local_config" ] \
    && ! git -C "$project_dir" ls-files --error-unmatch -- .gitleaks.local.toml >/dev/null 2>&1; then
    echo "ERROR: .gitleaks.local.toml exists but is not tracked; refusing to install a wrapper that depends on it." >&2
    echo "       Track the file or remove it, then rerun Touchstone." >&2
    return 1
  fi

  return 0
}

touchstone_gitleaks_prepare_project_config() {
  local project_dir="$1"
  local dry_run="${2:-false}"
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

  # Keep the original root in place until the managed overwrite succeeds.
  # Update rollback therefore classifies it as pre-existing, and bootstrap
  # failures before that overwrite leave the auto-discovered root untouched.
  cp "$root_config" "$local_config"
  TOUCHSTONE_GITLEAKS_MIGRATED=true
  echo "    ~ preserved project Gitleaks config as .gitleaks.local.toml"
}
