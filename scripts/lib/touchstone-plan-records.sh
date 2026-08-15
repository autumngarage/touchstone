# shellcheck shell=bash
# shellcheck disable=SC2034 # PROFILE is an output consumed by the adoption planner.

trim_plan_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

valid_plan_identifier() {
  case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac
}

valid_plan_path() {
  case "$1" in "" | /* | .. | ../* | */../* | */..) return 1 ;; esac
}

plan_value_has_control_byte() {
  printf '%s' "$1" | LC_ALL=C awk '
    /[[:cntrl:]]/ { found=1 }
    END { exit !found }
  '
}

require_plan_record_shape() {
  local kind="$1" name="$2" path="$3" value="$4"
  valid_plan_identifier "$name" || contract_refusal "$kind has invalid name '$name'"
  valid_plan_path "$path" || contract_refusal "$kind '$name' has invalid path '$path'"
  case "$name$path$value" in *"$TAB"* | *"$CR"* | *"$LF"*)
    contract_refusal "$kind '$name' contains a plan-record delimiter"
    ;;
  esac
}

plan_name_exists() {
  local file="$1" name="$2" label="$3" status
  [ -f "$file" ] || operational_failure "could not inspect $label before recording '$name'"
  if awk -F '\t' -v value="$name" '$1 == value { found=1 } END { exit !found }' "$file"; then
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || operational_failure "could not inspect $label before recording '$name'"
  return 1
}

append_plan_record() {
  local output="$1" failure="$2" format="$3"
  shift 3
  printf "$format" "$@" >>"$output" || operational_failure "$failure"
}

record_plan_target() {
  local name="$1" path="$2" profile="$3"
  require_plan_record_shape target "$name" "$path" "$profile"
  valid_plan_identifier "$profile" || contract_refusal "target '$name' has invalid profile '$profile'"
  plan_name_exists "$TARGETS_FILE" "$name" "adoption targets" \
    && contract_refusal "duplicate target '$name'"
  append_plan_record "$TARGETS_FILE" "could not record adoption target '$name'" \
    '%s\t%s\t%s\n' "$name" "$path" "$profile"
}

record_plan_task() {
  local name="$1" target="$2" command="$3"
  require_plan_record_shape task "$name" . "$command"
  valid_plan_identifier "$target" || contract_refusal "task '$name' has invalid target '$target'"
  [ -n "$(trim_plan_value "$command")" ] || contract_refusal "task '$name' has an empty command"
  plan_value_has_control_byte "$command" \
    && contract_refusal "task '$name' contains a control byte forbidden in a TOML command"
  plan_name_exists "$TARGETS_FILE" "$target" "adoption targets" \
    || contract_refusal "task '$name' references unknown target '$target'"
  plan_name_exists "$TASKS_FILE" "$name" "adoption tasks" \
    && contract_refusal "duplicate task '$name'"
  append_plan_record "$TASKS_FILE" "could not record adoption task '$name'" \
    '%s\t%s\ttrue\t%s\n' "$name" "$target" "$command"
}

record_plan_setup() {
  local directory="$1" command="$2" relative existing lookup_status=0
  relative="${directory#"$PROJECT_ROOT"/}"
  [ "$directory" != "$PROJECT_ROOT" ] || relative=.
  valid_plan_path "$relative" || contract_refusal "setup has invalid path '$relative'"
  case "$relative$command" in *"$TAB"* | *"$CR"* | *"$LF"*)
    contract_refusal "setup for '$relative' contains a plan-record delimiter"
    ;;
  esac
  [ -n "$(trim_plan_value "$command")" ] \
    || contract_refusal "setup for '$relative' has an empty command"
  plan_value_has_control_byte "$command" \
    && contract_refusal "setup for '$relative' contains a control byte forbidden in a TOML command"
  [ -f "$SETUPS_FILE" ] \
    || operational_failure "could not inspect adoption setup before recording '$relative'"
  existing="$(awk -F '\t' -v path="$relative" \
    '$1 == path { print substr($0, index($0, "\t") + 1); exit }' "$SETUPS_FILE")" \
    || lookup_status=$?
  [ "$lookup_status" -eq 0 ] \
    || operational_failure "could not inspect adoption setup before recording '$relative'"
  if [ -n "$existing" ]; then
    [ "$existing" = "$command" ] \
      || contract_refusal "target '$relative' requires conflicting setup commands"
    return 0
  fi
  append_plan_record "$SETUPS_FILE" "could not record adoption setup for '$relative'" \
    '%s\t%s\n' "$relative" "$command"
}

compile_manual_plan() {
  local argument name command
  [ "${MANUAL_TASK_COUNT:-0}" -gt 0 ] \
    || contract_refusal "manual adoption requires at least one --task NAME=COMMAND"
  record_plan_target root . manual
  for argument in "${MANUAL_TASK_ARGS[@]}"; do
    case "$argument" in *=*) ;; *) contract_refusal "--task requires NAME=COMMAND" ;; esac
    name="${argument%%=*}"
    command="${argument#*=}"
    record_plan_task "$name" root "$command"
  done
  PROFILE=manual
}
