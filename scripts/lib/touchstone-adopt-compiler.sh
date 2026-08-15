# shellcheck shell=bash

command_has_control_byte() {
  printf '%s' "$1" | LC_ALL=C awk '
    /[[:cntrl:]]/ { found=1 }
    END { exit !found }
  '
}

record_target() {
  local name="$1" path="$2" profile="$3"
  valid_identifier "$name" || contract_refusal "invalid target name '$name'"
  valid_relative_path "$path" || contract_refusal "target '$name' escapes the repository: $path"
  if awk -F '\t' -v value="$name" '$1 == value { found=1 } END { exit !found }' "$TARGETS_FILE"; then
    contract_refusal "duplicate target '$name'"
  fi
  printf '%s\t%s\t%s\n' "$name" "$path" "$profile" >>"$TARGETS_FILE"
}

record_task() {
  local name="$1" target="$2" command="$3"
  valid_identifier "$name" || contract_refusal "invalid task name '$name'"
  [ -n "$(trim "$command")" ] || contract_refusal "task '$name' has an empty command"
  case "$command" in *"$TAB"* | *"$CR"* | *"$LF"*)
    contract_refusal "task '$name' must be a single-line command"
    ;;
  esac
  command_has_control_byte "$command" \
    && contract_refusal "task '$name' contains a control byte forbidden in a TOML command"
  if awk -F '\t' -v value="$name" '$1 == value { found=1 } END { exit !found }' "$TASKS_FILE"; then
    contract_refusal "duplicate task '$name'"
  fi
  printf '%s\t%s\ttrue\t%s\n' "$name" "$target" "$command" >>"$TASKS_FILE"
}

record_setup() {
  local directory="$1" command="$2" relative existing
  relative="${directory#"$PROJECT_ROOT"/}"
  [ "$directory" != "$PROJECT_ROOT" ] || relative=.
  valid_relative_path "$relative" || contract_refusal "setup path escapes the repository: $relative"
  case "$command" in "" | *"$TAB"* | *"$CR"* | *"$LF"*)
    contract_refusal "setup for '$relative' must be a non-empty single-line command"
    ;;
  esac
  command_has_control_byte "$command" \
    && contract_refusal "setup for '$relative' contains a control byte forbidden in a TOML command"
  existing="$(awk -F '\t' -v path="$relative" '$1 == path { print substr($0, index($0, "\t") + 1); exit }' "$SETUPS_FILE")"
  if [ -n "$existing" ]; then
    [ "$existing" = "$command" ] \
      || contract_refusal "target '$relative' requires conflicting setup commands"
    return 0
  fi
  printf '%s\t%s\n' "$relative" "$command" >>"$SETUPS_FILE"
}

legacy_value() {
  local key="$1" file="$2"
  awk -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    {
      split($0, parts, "=")
      name = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != wanted) next
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      answer = value
      seen = 1
    }
    END { if (seen) print answer }
  ' "$file"
}

profile_adapter_available() {
  case "$1" in
    node) declare -F tasks_for_node >/dev/null ;;
    python) declare -F tasks_for_python >/dev/null ;;
    swift) declare -F validate_swift_manifest >/dev/null ;;
    rust) declare -F validate_cargo_lock >/dev/null ;;
    go) declare -F validate_go_mod_document >/dev/null ;;
    generic | ambiguous:* | manual) return 0 ;;
    *) return 1 ;;
  esac
}

tasks_for_profile() {
  local directory="$1" target="$2" profile="$3" suffix="$4" inherited_node_manager="${5:-}" workspace_member="${6:-false}"
  profile_adapter_available "$profile" \
    || contract_refusal "automatic $profile adoption is unavailable in this Touchstone build; pass --task NAME=COMMAND"
  case "$profile" in
    node) tasks_for_node "$directory" "$target" "$suffix" "$inherited_node_manager" "$workspace_member" ;;
    python) tasks_for_python "$directory" "$target" "$suffix" ;;
    swift)
      swift_has_dependency_source "$directory/Package.swift" remote \
        && contract_refusal "Swift target '$target' declares a remote package dependency that can fetch during validation; use checkout-local dependencies with a manual contract or pass --task NAME=COMMAND"
      swift_has_dependency_source "$directory/Package.swift" path \
        && contract_refusal "Swift target '$target' declares a local package path this portable compiler cannot verify; pass --task NAME=COMMAND"
      validate_swift_manifest "$directory/Package.swift" "$directory"
      record_task "test$suffix" "$target" "swift test --disable-automatic-resolution --skip-update"
      ;;
    rust)
      local cargo_lock_path="Cargo.lock" cargo_command="cargo test --frozen"
      validate_toml_document "$directory/Cargo.toml" Cargo.toml
      if [ "$directory" = "$PROJECT_ROOT" ]; then
        validate_cargo_workspace_members
        if [ -n "$(cargo_workspace_values members)" ]; then
          cargo_command="cargo test --workspace --frozen"
        fi
      fi
      toml_has_local_path_reference "$directory/Cargo.toml" \
        && contract_refusal "Rust target '$target' declares a local path dependency this portable compiler cannot verify within the checkout; pass --task NAME=COMMAND"
      if [ "$workspace_member" != true ] && [ "$directory" != "$PROJECT_ROOT" ]; then
        cargo_lock_path="${directory#"$PROJECT_ROOT"/}/Cargo.lock"
      fi
      [ -f "$PROJECT_ROOT/$cargo_lock_path" ] \
        || contract_refusal "Rust target '$target' has no Cargo.lock; commit one or pass --task NAME=COMMAND"
      git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$cargo_lock_path" >/dev/null 2>&1 \
        || contract_refusal "Rust target '$target' has no tracked Cargo.lock; commit it or pass --task NAME=COMMAND"
      validate_cargo_lock "$PROJECT_ROOT/$cargo_lock_path"
      require_tracked_rust_source "$directory"
      verify_cargo_lock_compatibility "$directory"
      record_task "test$suffix" "$target" "$cargo_command"
      ;;
    go)
      [ ! -f "$directory/go.work" ] \
        || contract_refusal "Go target '$target' declares a go.work workspace this portable compiler cannot verify within the checkout; pass --task NAME=COMMAND"
      go_has_local_replace "$directory/go.mod" \
        && contract_refusal "Go target '$target' declares a local replacement this portable compiler cannot verify within the checkout; pass --task NAME=COMMAND"
      validate_go_mod_document "$directory/go.mod"
      require_tracked_go_source "$directory"
      verify_go_packages "$directory"
      record_task "test$suffix" "$target" "GOENV=off GOTOOLCHAIN=local GOWORK=off GOPROXY=off GOSUMDB=off go test ./..."
      ;;
    generic) contract_refusal "no supported project facts found; pass --task NAME=COMMAND for a manual declaration" ;;
    ambiguous:*) contract_refusal "ambiguous project facts for target '$target': ${profile#ambiguous:}" ;;
    *) contract_refusal "unsupported project profile '$profile'" ;;
  esac
}

profile_has_tasks() {
  local directory="$1" profile="$2" task
  profile_adapter_available "$profile" || return 1
  case "$profile" in
    node)
      [ -f "$directory/package.json" ] || return 1
      for task in validate verify lint typecheck test build; do
        if node_has_script "$directory/package.json" "$task"; then return 0; fi
      done
      return 1
      ;;
    python)
      [ -d "$directory/tests" ] && return 0
      [ -f "$directory/pyproject.toml" ] \
        && grep -Eq '^\[tool\.(ruff|mypy|pytest)(\.|\])' "$directory/pyproject.toml" && return 0
      for task in ruff mypy pytest; do
        if python_checker_declared "$directory" "$task"; then return 0; fi
      done
      return 1
      ;;
    swift | rust | go) return 0 ;;
    *) return 1 ;;
  esac
}

compile_manual_tasks() {
  local argument name command
  record_target root . manual
  for argument in "${MANUAL_TASK_ARGS[@]}"; do
    case "$argument" in *=*) ;; *) contract_refusal "--task requires NAME=COMMAND" ;; esac
    name="${argument%%=*}"
    command="${argument#*=}"
    record_task "$name" root "$command"
  done
  PROFILE=manual
}

legacy_profile_for_directory() {
  local configured="$1" directory="$2" detected
  case "$configured" in
    node | typescript | ts) printf 'node\n' ;;
    python | swift | rust | go) printf '%s\n' "$configured" ;;
    generic | auto | "")
      detected="$(detect_profile "$directory")"
      printf '%s\n' "$detected"
      ;;
    *) contract_refusal "legacy .touchstone-config declares unsupported project_type '$configured'" ;;
  esac
}

remove_legacy_action_tasks() {
  local action="$1" filtered="$TASKS_FILE.filtered"
  awk -F '\t' -v action="$action" '
    $1 != action && index($1, action "-") != 1 { print }
  ' "$TASKS_FILE" >"$filtered"
  mv "$filtered" "$TASKS_FILE"
}

legacy_root_target() {
  local profile="$1"
  if ! awk -F '\t' '$1 == "root" { found=1 } END { exit !found }' "$TARGETS_FILE"; then
    record_target root . "$profile"
  fi
}

compile_legacy_defaults() {
  local configured_profile="$1" configured_targets="$2" package_manager="$3"
  local entry name path profile directory suffix
  local -a target_entries=()

  if [ -z "$configured_targets" ]; then
    profile="$(legacy_profile_for_directory "$configured_profile" "$PROJECT_ROOT")"
    record_target root . "$profile"
    tasks_for_profile "$PROJECT_ROOT" root "$profile" "" "$package_manager"
    PROFILE="$profile"
    return 0
  fi

  IFS=',' read -r -a target_entries <<<"$configured_targets"
  for entry in "${target_entries[@]}"; do
    entry="$(trim "$entry")"
    [ -n "$entry" ] || contract_refusal "legacy targets contains an empty entry"
    case "$entry" in *:*) ;; *) contract_refusal "legacy target '$entry' must be NAME:PATH[:PROFILE]" ;; esac
    name="$(trim "${entry%%:*}")"
    path="${entry#*:}"
    profile=""
    case "$path" in
      *:*)
        profile="$(trim "${path#*:}")"
        path="${path%%:*}"
        ;;
    esac
    path="$(trim "$path")"
    if [ "$name" = root ] && [ "$path" != . ]; then
      contract_refusal "legacy target name 'root' is reserved for the repository path '.'"
    fi
    [ -d "$PROJECT_ROOT/$path" ] || contract_refusal "legacy target '$name' path not found: $path"
    directory="$(cd "$PROJECT_ROOT/$path" 2>/dev/null && pwd -P)" \
      || contract_refusal "could not resolve legacy target '$name'"
    case "$directory" in "$PROJECT_ROOT" | "$PROJECT_ROOT"/*) ;; *)
      contract_refusal "legacy target '$name' resolves outside the repository"
      ;;
    esac
    profile="$(legacy_profile_for_directory "${profile:-$configured_profile}" "$directory")"
    record_target "$name" "$path" "$profile"
    suffix="-$name"
    tasks_for_profile "$directory" "$name" "$profile" "$suffix" "$package_manager"
  done
  PROFILE=monorepo
}

compile_legacy() {
  local file="$PROJECT_ROOT/.touchstone-config" configured_profile configured_targets package_manager command key action legacy_compiled_profile
  configured_profile="$(legacy_value project_type "$file")"
  [ -n "$configured_profile" ] || configured_profile="$(legacy_value profile "$file")"
  for key in validate_command validate_full_command; do
    command="$(legacy_value "$key" "$file")"
    if [ -n "$command" ]; then
      record_target root . "${configured_profile:-legacy}"
      record_task validate root "$command"
      PROFILE="legacy-${configured_profile:-manual}"
      return 0
    fi
  done

  configured_targets="$(legacy_value targets "$file")"
  package_manager="$(legacy_value package_manager "$file")"
  compile_legacy_defaults "$configured_profile" "$configured_targets" "$package_manager"

  for key in lint_command typecheck_command test_command build_command; do
    command="$(legacy_value "$key" "$file")"
    [ -n "$command" ] || continue
    action="${key%_command}"
    if [ "$action" = typecheck ] && [ "$command" = auto ]; then
      continue
    fi
    remove_legacy_action_tasks "$action"
    legacy_root_target "$(legacy_profile_for_directory "$configured_profile" "$PROJECT_ROOT")"
    record_task "$action" root "$command"
  done
  legacy_compiled_profile="${PROFILE:-$(legacy_profile_for_directory "$configured_profile" "$PROJECT_ROOT")}"
  PROFILE="legacy-$legacy_compiled_profile"
}

target_name_for_path() {
  local path="$1" name
  name="$(basename "$path" | tr -c 'A-Za-z0-9._-' '-')"
  name="${name%-}"
  valid_identifier "$name" || name=target
  printf '%s\n' "$name"
}

compile_detected() {
  local base directory relative profile target suffix found_targets=false workspace_node_manager resolved_directory root_profile workspace_member
  workspace_node_manager=""
  if profile_adapter_available node; then
    node_package_manager "$PROJECT_ROOT" "" ""
    workspace_node_manager="$NODE_MANAGER"
  fi
  for base in apps packages services; do
    [ -d "$PROJECT_ROOT/$base" ] || continue
    for directory in "$PROJECT_ROOT/$base"/*; do
      [ -d "$directory" ] || continue
      resolved_directory="$(cd "$directory" 2>/dev/null && pwd -P)" \
        || contract_refusal "could not resolve monorepo target ${directory#"$PROJECT_ROOT"/}"
      case "$resolved_directory" in "$PROJECT_ROOT"/*) ;; *)
        contract_refusal "monorepo target ${directory#"$PROJECT_ROOT"/} resolves outside the repository"
        ;;
      esac
      profile="$(detect_profile "$directory")"
      [ "$profile" = generic ] && continue
      relative="${directory#"$PROJECT_ROOT"/}"
      target="$(target_name_for_path "$base-$(basename "$relative")")"
      suffix="-$target"
      record_target "$target" "$relative" "$profile"
      workspace_member=false
      if [ "$profile" = node ] && node_workspace_contains "$relative" "$workspace_node_manager"; then workspace_member=true; fi
      if [ "$profile" = rust ] && cargo_workspace_contains "$relative"; then workspace_member=true; fi
      tasks_for_profile "$directory" "$target" "$profile" "$suffix" "$workspace_node_manager" "$workspace_member"
      found_targets=true
    done
  done
  if [ "$found_targets" = true ]; then
    root_profile="$(detect_profile "$PROJECT_ROOT")"
    case "$root_profile" in ambiguous:*)
      contract_refusal "ambiguous project facts for target 'root': ${root_profile#ambiguous:}"
      ;;
    esac
    if profile_has_tasks "$PROJECT_ROOT" "$root_profile"; then
      record_target root . "$root_profile"
      tasks_for_profile "$PROJECT_ROOT" root "$root_profile" ""
    fi
    PROFILE=monorepo
    return 0
  fi
  PROFILE="$(detect_profile "$PROJECT_ROOT")"
  record_target root . "$PROFILE"
  tasks_for_profile "$PROJECT_ROOT" root "$PROFILE" ""
}
