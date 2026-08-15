# shellcheck shell=bash

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

legacy_profile_value() {
  local file="$1"
  awk '
    /^[[:space:]]*#/ { next }
    {
      split($0, parts, "=")
      name = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != "project_type" && name != "profile") next
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      answer = value
      seen = 1
    }
    END { if (seen) print answer }
  ' "$file"
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
  ' "$TASKS_FILE" >"$filtered" \
    || operational_failure "could not filter legacy adoption tasks for '$action'"
  mv "$filtered" "$TASKS_FILE" \
    || operational_failure "could not replace legacy adoption tasks for '$action'"
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
    profile="$(legacy_profile_for_directory "$profile" "$directory")"
    record_target "$name" "$path" "$profile"
    suffix="-$name"
    tasks_for_profile "$directory" "$name" "$profile" "$suffix" "$package_manager"
  done
  PROFILE=monorepo
}

compile_legacy() {
  local file="$PROJECT_ROOT/.touchstone-config" configured_profile configured_targets package_manager command key action legacy_compiled_profile
  configured_profile="$(legacy_profile_value "$file")"
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
