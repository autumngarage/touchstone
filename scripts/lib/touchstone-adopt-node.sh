# shellcheck shell=bash

tasks_for_node() {
  local directory="$1" target="$2" suffix="$3" inherited="${4:-}" workspace_member="${5:-false}" effective_inherited="" manager setup_directory setup_command npm_lock="" yarn_kind="" yarn_name="" name_status=0 task config found=false
  [ -f "$directory/package.json" ] || contract_refusal "Node target '$target' has no package.json"
  if [ "$workspace_member" = true ]; then effective_inherited="$inherited"; fi
  node_package_manager "$directory" "$effective_inherited"
  for task in validate verify lint typecheck test build; do
    if node_has_script "$directory/package.json" "$task"; then :; fi
  done
  node_has_local_dependency "$directory/package.json" \
    && contract_refusal "Node target '$target' declares a local file dependency this portable compiler cannot verify within the checkout; pass --task NAME=COMMAND"
  manager="$NODE_MANAGER"
  if [ "$workspace_member" = true ]; then setup_directory="$PROJECT_ROOT"; else setup_directory="$directory"; fi
  node_has_declared_dependency "$directory/package.json" \
    && contract_refusal "Node target '$target' declares dependencies whose lock compatibility this portable compiler cannot verify; pass --task NAME=COMMAND"
  if [ "$setup_directory" != "$directory" ]; then
    node_has_declared_dependency "$setup_directory/package.json" \
      && contract_refusal "Node workspace root declares dependencies whose lock compatibility this portable compiler cannot verify; pass --task NAME=COMMAND"
  fi
  node_validate_package_manager_spec "$manager" "$directory" "$workspace_member"
  if [ "$manager" = npm ]; then
    for config in "$directory/.npmrc" "$setup_directory/.npmrc"; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        contract_refusal "npm target '$target' has project-controlled config '${config#"$PROJECT_ROOT"/}'; pass --task NAME=COMMAND"
      fi
    done
    if [ -f "$setup_directory/npm-shrinkwrap.json" ]; then
      npm_lock="$setup_directory/npm-shrinkwrap.json"
    elif [ -f "$setup_directory/package-lock.json" ]; then
      npm_lock="$setup_directory/package-lock.json"
    fi
    if [ -n "$npm_lock" ]; then
      npm_lock_valid "$npm_lock" \
        || contract_refusal "Node target '$target' has an npm lockfile outside the dependency-free portable subset; regenerate a schema-v2/v3 lock or pass --task NAME=COMMAND"
    fi
  fi
  if [ "$manager" = pnpm ]; then
    for config in "$directory/.pnpmfile.cjs" "$directory/.pnpmfile.js" \
      "$setup_directory/.pnpmfile.cjs" "$setup_directory/.pnpmfile.js" \
      "$directory/.npmrc" "$setup_directory/.npmrc"; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        contract_refusal "pnpm target '$target' has project-controlled pnpm hook or config '${config#"$PROJECT_ROOT"/}'; pass --task NAME=COMMAND"
      fi
    done
  fi
  if [ "$manager" = pnpm ] && [ -f "$setup_directory/pnpm-lock.yaml" ]; then
    pnpm_lock_valid "$setup_directory/pnpm-lock.yaml" \
      || contract_refusal "Node target '$target' has a pnpm lockfile outside the dependency-free portable subset; pass --task NAME=COMMAND"
  fi
  if [ "$manager" = yarn ]; then
    for config in "$directory/.yarnrc.yml" "$directory/.yarnrc" \
      "$setup_directory/.yarnrc.yml" "$setup_directory/.yarnrc"; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        contract_refusal "Yarn target '$target' has project-controlled config '${config#"$PROJECT_ROOT"/}'; pass --task NAME=COMMAND"
      fi
    done
    if [ -f "$setup_directory/yarn.lock" ]; then
      if grep -q '^# yarn lockfile v1$' "$setup_directory/yarn.lock"; then
        yarn_kind=classic
      elif grep -q '^__metadata:$' "$setup_directory/yarn.lock"; then
        yarn_kind=berry
      fi
      if yarn_name="$(json_root_string_value "$setup_directory/package.json" name)"; then
        :
      else
        name_status=$?
        [ "$name_status" -eq 1 ] \
          || contract_refusal "Node target '$target' has a malformed or non-string package name"
        yarn_name=""
      fi
      yarn_lock_valid "$setup_directory/yarn.lock" "$yarn_kind" "$yarn_name" \
        || contract_refusal "Node target '$target' has a Yarn lockfile outside the dependency-free portable subset; pass --task NAME=COMMAND"
    fi
  fi
  if [ "$manager" = bun ] && { [ -f "$setup_directory/bun.lock" ] || [ -f "$setup_directory/bun.lockb" ]; }; then
    contract_refusal "Node target '$target' has a Bun lockfile this portable compiler cannot validate; pass --task NAME=COMMAND"
  fi
  setup_command="$(node_setup_command "$manager" "$setup_directory")"
  if [ -n "$setup_command" ]; then record_setup "$setup_directory" "$setup_command"; fi
  for task in validate verify; do
    if node_has_script "$directory/package.json" "$task"; then
      record_task "$task$suffix" "$target" "$(node_command "$manager" "$task")"
      return 0
    fi
  done
  for task in lint typecheck test build; do
    if node_has_script "$directory/package.json" "$task"; then
      record_task "$task$suffix" "$target" "$(node_command "$manager" "$task")"
      found=true
    fi
  done
  [ "$found" = true ] || contract_refusal "Node target '$target' declares no validate, verify, lint, typecheck, test, or build script; pass --task NAME=COMMAND"
}
