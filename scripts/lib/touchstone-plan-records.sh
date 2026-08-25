# shellcheck shell=bash
# shellcheck disable=SC2034 # PROFILE is an output consumed by the adoption planner.

PLAN_IN_MEMORY="${PLAN_IN_MEMORY:-false}"

trim_plan_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

plan_records() {
  local storage="$1" record
  if [ "$PLAN_IN_MEMORY" = false ]; then
    cat "$storage" || operational_failure "could not read adoption plan records"
    return
  fi
  case "$storage" in
    "$TARGETS_FILE")
      for record in ${PLAN_TARGET_RECORDS[@]+"${PLAN_TARGET_RECORDS[@]}"}; do printf '%s\n' "$record"; done
      ;;
    "$TASKS_FILE")
      for record in ${PLAN_TASK_RECORDS[@]+"${PLAN_TASK_RECORDS[@]}"}; do printf '%s\n' "$record"; done
      ;;
    "$SETUPS_FILE")
      for record in ${PLAN_SETUP_RECORDS[@]+"${PLAN_SETUP_RECORDS[@]}"}; do printf '%s\n' "$record"; done
      ;;
    "$CHANGES_FILE")
      for record in ${PLAN_CHANGE_RECORDS[@]+"${PLAN_CHANGE_RECORDS[@]}"}; do printf '%s\n' "$record"; done
      ;;
    *) operational_failure "unknown in-memory adoption plan storage: $storage" ;;
  esac
}

plan_record_count() {
  local storage="$1"
  if [ "$PLAN_IN_MEMORY" = true ]; then
    case "$storage" in
      "$TARGETS_FILE") printf '%s\n' "${#PLAN_TARGET_RECORDS[@]}" ;;
      "$TASKS_FILE") printf '%s\n' "${#PLAN_TASK_RECORDS[@]}" ;;
      "$SETUPS_FILE") printf '%s\n' "${#PLAN_SETUP_RECORDS[@]}" ;;
      "$CHANGES_FILE") printf '%s\n' "${#PLAN_CHANGE_RECORDS[@]}" ;;
      *) operational_failure "unknown in-memory adoption plan storage: $storage" ;;
    esac
  else
    awk 'NF { count++ } END { print count + 0 }' "$storage" \
      || operational_failure "could not count adoption plan records"
  fi
}

valid_plan_identifier() {
  case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac
}

valid_plan_path() {
  case "$1" in "" | /* | .. | ../* | */../* | */.. | *\\*) return 1 ;; esac
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
  [ "$PLAN_IN_MEMORY" = true ] || [ -f "$file" ] \
    || operational_failure "could not inspect $label before recording '$name'"
  if { [ "$PLAN_IN_MEMORY" = true ] \
    && plan_records "$file" | awk -F '\t' -v value="$name" '$1 == value { found=1 } END { exit !found }'; } \
    || { [ "$PLAN_IN_MEMORY" = false ] \
      && awk -F '\t' -v value="$name" '$1 == value { found=1 } END { exit !found }' "$file"; }; then
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || operational_failure "could not inspect $label before recording '$name'"
  return 1
}

append_plan_record() {
  local output="$1" failure="$2" format="$3" record
  shift 3
  if [ "$PLAN_IN_MEMORY" = false ]; then
    printf "$format" "$@" >>"$output" || operational_failure "$failure"
    return
  fi
  printf -v record "$format" "$@" || operational_failure "$failure"
  record="${record%$LF}"
  case "$output" in
    "$TARGETS_FILE") PLAN_TARGET_RECORDS+=("$record") ;;
    "$TASKS_FILE") PLAN_TASK_RECORDS+=("$record") ;;
    "$SETUPS_FILE") PLAN_SETUP_RECORDS+=("$record") ;;
    "$CHANGES_FILE") PLAN_CHANGE_RECORDS+=("$record") ;;
    *) operational_failure "unknown in-memory adoption plan storage: $output" ;;
  esac
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
  { [ "$PLAN_IN_MEMORY" = true ] || [ -f "$SETUPS_FILE" ]; } \
    || operational_failure "could not inspect adoption setup before recording '$relative'"
  if [ "$PLAN_IN_MEMORY" = true ]; then
    existing="$(plan_records "$SETUPS_FILE" | awk -F '\t' -v path="$relative" \
      '$1 == path { print substr($0, index($0, "\t") + 1); exit }')" \
      || lookup_status=$?
  else
    existing="$(awk -F '\t' -v path="$relative" \
      '$1 == path { print substr($0, index($0, "\t") + 1); exit }' "$SETUPS_FILE")" \
      || lookup_status=$?
  fi
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
  local argument name command saw_task=false
  for argument in "$@"; do
    saw_task=true
    case "$argument" in *=*) ;; *) contract_refusal "--task requires NAME=COMMAND" ;; esac
  done
  [ "$saw_task" = true ] \
    || contract_refusal "manual adoption requires at least one --task NAME=COMMAND"
  record_plan_target root . manual
  for argument in "$@"; do
    name="${argument%%=*}"
    command="${argument#*=}"
    record_plan_task "$name" root "$command"
  done
  PROFILE=manual
}
