# shellcheck shell=bash

legacy_config_value() {
  local file="$1" key="$2" value status=0
  [ ! -L "$file" ] || contract_refusal "legacy configuration must not be a symbolic link: ${file##*/}"
  [ ! -e "$file" ] || [ -f "$file" ] \
    || contract_refusal "legacy configuration is not a regular file: ${file##*/}"
  [ -f "$file" ] || return 1
  value="$(awk -v wanted="$key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function unquote(value, first, last) {
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if (length(value) >= 2 && first == last && (first == "\"" || first == "\047")) {
        return substr(value, 2, length(value) - 2)
      }
      return value
    }
    /^[[:space:]]*#/ { next }
    index($0, "=") {
      name = trim(substr($0, 1, index($0, "=") - 1))
      if (name == wanted) {
        answer = unquote(trim(substr($0, index($0, "=") + 1)))
        found = 1
      }
    }
    END { if (found && length(answer)) print answer }
  ' "$file")" || status=$?
  [ "$status" -eq 0 ] \
    || operational_failure "could not read legacy configuration key '$key'"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

legacy_preferred_value() {
  local file="$1" key value
  shift
  for key in "$@"; do
    if value="$(legacy_config_value "$file" "$key")"; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

legacy_profile_value() {
  local file="$1" value status=0
  [ ! -L "$file" ] || contract_refusal "legacy configuration must not be a symbolic link: ${file##*/}"
  [ ! -e "$file" ] || [ -f "$file" ] \
    || contract_refusal "legacy configuration is not a regular file: ${file##*/}"
  [ -f "$file" ] || return 1
  value="$(awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    /^[[:space:]]*#/ { next }
    index($0, "=") {
      name = trim(substr($0, 1, index($0, "=") - 1))
      if (name == "project_type" || name == "profile") {
        answer = trim(substr($0, index($0, "=") + 1))
        found = 1
      }
    }
    END { if (found && length(answer)) print answer }
  ' "$file")" || status=$?
  [ "$status" -eq 0 ] || operational_failure "could not read legacy project profile"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

legacy_full_validation_command() {
  local file="$1" command
  if command="$(legacy_preferred_value "$file" \
    validate_full_command full_validate_command validate_command_full)"; then
    printf '%s\n' "$command"
    return 0
  fi
  legacy_config_value "$file" validate_command
}
