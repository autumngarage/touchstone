#!/usr/bin/env bash
#
# scripts/touchstone-run.sh — execute schema-v1 .touchstone.toml declarations.
#
# Usage:
#   bash scripts/touchstone-run.sh validate [--json] [--project DIR] [--config FILE]
#
# This is the single validation engine used by the local CLI boundary and the
# organization-required workflow. It executes declarations; it never detects a
# project type, package manager, command, or target.

set -euo pipefail

ACTION="${1:-validate}"
if [ "$#" -gt 0 ]; then shift; fi

JSON_MODE=false
PROJECT_ARG="${TOUCHSTONE_PROJECT_ROOT:-}"
CONFIG_ARG="${TOUCHSTONE_CONFIG_FILE:-.touchstone.toml}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON_MODE=true
      shift
      ;;
    --project)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --project requires a directory" >&2
        exit 2
      }
      PROJECT_ARG="$2"
      shift 2
      ;;
    --config)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --config requires a file" >&2
        exit 2
      }
      CONFIG_ARG="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [ "$ACTION" != validate ]; then
  echo "ERROR: schema-v1 supports only 'validate'; tasks come from .touchstone.toml" >&2
  exit 2
fi

if [ -n "$PROJECT_ARG" ]; then
  PROJECT_ROOT="$(cd "$PROJECT_ARG" 2>/dev/null && pwd -P)" || {
    echo "ERROR: project directory does not exist: $PROJECT_ARG" >&2
    exit 2
  }
else
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
fi

case "$CONFIG_ARG" in
  /*) CONFIG_FILE="$CONFIG_ARG" ;;
  *) CONFIG_FILE="$PROJECT_ROOT/$CONFIG_ARG" ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-validate.XXXXXX")" || {
  echo "ERROR: could not create validation workspace" >&2
  exit 2
}
TARGETS_FILE="$TMP_DIR/targets"
TASKS_FILE="$TMP_DIR/tasks"
FAILURES_FILE="$TMP_DIR/failures"
: >"$TARGETS_FILE"
: >"$TASKS_FILE"
: >"$FAILURES_FILE"
trap 'rm -rf "$TMP_DIR"' EXIT

RAN=0
SKIPPED=0
FAILED=0
EXIT_STATUS=0
SCHEMA_VERSION=""
RUNTIME=""
SETUP_COMMAND=""
VALIDATION_SEEN=false

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

human() {
  if [ "$JSON_MODE" = false ]; then printf '%s\n' "$*"; fi
}

progress() { printf '%s\n' "$*" >&2; }

record_failure() {
  local task="$1" target="$2" status="$3" reason="$4"
  printf '%s\t%s\t%s\t%s\n' "$task" "$target" "$status" "$reason" >>"$FAILURES_FILE"
  FAILED=$((FAILED + 1))
  if [ "$EXIT_STATUS" -eq 0 ]; then EXIT_STATUS="$status"; fi
}

emit_report() {
  local verdict="$1" first=true task target status reason

  if [ "$JSON_MODE" = false ]; then
    printf '==> validate verdict: %s ran=%d skipped=%d failed=%d\n' \
      "$verdict" "$RAN" "$SKIPPED" "$FAILED"
    return 0
  fi

  printf '{"schema":1,"verdict":"%s","ran":%d,"skipped":%d,"failed":%d,"failures":[' \
    "$verdict" "$RAN" "$SKIPPED" "$FAILED"
  while IFS="$(printf '\t')" read -r task target status reason; do
    [ -n "$task" ] || continue
    if [ "$first" = false ]; then printf ','; fi
    first=false
    printf '{"task":"%s","target":"%s","status":%s,"reason":"%s"}' \
      "$task" "$target" "$status" "$reason"
  done <"$FAILURES_FILE"
  printf ']}\n'
}

config_error() {
  progress "ERROR: $*"
  record_failure config root 2 malformed-config
  emit_report failed
  exit 2
}

parse_string() {
  local raw character escaped=false closed=false output="" trailing="" index=1
  raw="$(trim "$1")"
  [ "${raw#\"}" != "$raw" ] || return 1

  while [ "$index" -lt "${#raw}" ]; do
    character="${raw:$index:1}"
    if [ "$escaped" = true ]; then
      case "$character" in
        '"' | '\') output="$output$character" ;;
        *) return 1 ;;
      esac
      escaped=false
    elif [ "$character" = '\' ]; then
      escaped=true
    elif [ "$character" = '"' ]; then
      closed=true
      trailing="$(trim "${raw:$((index + 1))}")"
      case "$trailing" in "" | \#*) ;; *) return 1 ;; esac
      break
    else
      case "$character" in
        "$(printf '\t')" | "$(printf '\r')") return 1 ;;
      esac
      output="$output$character"
    fi
    index=$((index + 1))
  done

  [ "$closed" = true ] && [ "$escaped" = false ] || return 1
  PARSED_VALUE="$output"
}

parse_scalar() {
  local raw
  raw="$(trim "${1%%#*}")"
  [ -n "$raw" ] || return 1
  PARSED_VALUE="$raw"
}

valid_identifier() {
  case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

valid_relative_path() {
  local path="$1"
  [ -n "$path" ] || return 1
  case "$path" in /* | .. | ../* | */../* | */..) return 1 ;; esac
  case "$path" in *"$(printf '\t')"* | *"$(printf '\r')"*) return 1 ;; esac
  return 0
}

SECTION=root
BLOCK=""
BLOCK_NAME=""
BLOCK_PATH=""
BLOCK_TARGET=""
BLOCK_COMMAND=""
BLOCK_REQUIRED=""
SEEN_KEYS=""

key_seen() {
  case " $SEEN_KEYS " in
    *" $1 "*) return 0 ;;
    *)
      SEEN_KEYS="$SEEN_KEYS $1"
      return 1
      ;;
  esac
}

finalize_block() {
  if [ "$BLOCK" = target ]; then
    [ -n "$BLOCK_NAME" ] || config_error "target ending near line $LINE_NUMBER has no name"
    [ -n "$BLOCK_PATH" ] || config_error "target '$BLOCK_NAME' has no path"
    valid_identifier "$BLOCK_NAME" || config_error "invalid target name '$BLOCK_NAME'"
    valid_relative_path "$BLOCK_PATH" || config_error "target '$BLOCK_NAME' path must stay inside the project"
    if awk -F '\t' -v name="$BLOCK_NAME" '$1 == name { found=1 } END { exit !found }' "$TARGETS_FILE"; then
      config_error "duplicate target '$BLOCK_NAME'"
    fi
    printf '%s\t%s\n' "$BLOCK_NAME" "$BLOCK_PATH" >>"$TARGETS_FILE"
  elif [ "$BLOCK" = task ]; then
    [ -n "$BLOCK_NAME" ] || config_error "task ending near line $LINE_NUMBER has no name"
    [ -n "$BLOCK_TARGET" ] || config_error "task '$BLOCK_NAME' has no target"
    [ -n "$BLOCK_REQUIRED" ] || config_error "task '$BLOCK_NAME' must declare required = true or false"
    valid_identifier "$BLOCK_NAME" || config_error "invalid task name '$BLOCK_NAME'"
    valid_identifier "$BLOCK_TARGET" || config_error "invalid target reference '$BLOCK_TARGET'"
    case "$BLOCK_REQUIRED" in true | false) ;; *) config_error "task '$BLOCK_NAME' has invalid required value" ;; esac
    if [ "$BLOCK_REQUIRED" = true ] && [ -z "$BLOCK_COMMAND" ]; then
      config_error "required task '$BLOCK_NAME' has no command"
    fi
    if awk -F '\t' -v name="$BLOCK_NAME" '$1 == name { found=1 } END { exit !found }' "$TASKS_FILE"; then
      config_error "duplicate task '$BLOCK_NAME'"
    fi
    printf '%s\t%s\t%s\t%s\n' \
      "$BLOCK_NAME" "$BLOCK_TARGET" "$BLOCK_REQUIRED" "$BLOCK_COMMAND" >>"$TASKS_FILE"
  fi

  BLOCK=""
  BLOCK_NAME=""
  BLOCK_PATH=""
  BLOCK_TARGET=""
  BLOCK_COMMAND=""
  BLOCK_REQUIRED=""
  SEEN_KEYS=""
}

if [ ! -f "$CONFIG_FILE" ]; then
  if [ "$CONFIG_ARG" = .touchstone.toml ] && [ -f "$PROJECT_ROOT/.touchstone-config" ]; then
    config_error "legacy .touchstone-config is not a schema-v1 declaration; create .touchstone.toml from the validation contract"
  fi
  config_error "validation contract not found: $CONFIG_FILE"
fi

LINE_NUMBER=0
while IFS= read -r line || [ -n "$line" ]; do
  LINE_NUMBER=$((LINE_NUMBER + 1))
  line="$(trim "$line")"
  [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac

  section_line="$(trim "${line%%#*}")"
  case "$section_line" in
    '[validation]')
      finalize_block
      [ "$VALIDATION_SEEN" = false ] || config_error "duplicate [validation] section at line $LINE_NUMBER"
      VALIDATION_SEEN=true
      SECTION=validation
      SEEN_KEYS=""
      continue
      ;;
    '[[validation.targets]]')
      finalize_block
      SECTION=target
      BLOCK=target
      continue
      ;;
    '[[validation.tasks]]')
      finalize_block
      SECTION=task
      BLOCK=task
      continue
      ;;
    '['*) config_error "unsupported table at line $LINE_NUMBER: $section_line" ;;
  esac

  case "$line" in *=*) ;; *) config_error "expected key = value at line $LINE_NUMBER" ;; esac
  key="$(trim "${line%%=*}")"
  raw_value="${line#*=}"
  key_seen "$key" && config_error "duplicate key '$key' near line $LINE_NUMBER"

  case "$SECTION:$key" in
    root:schema)
      parse_scalar "$raw_value" || config_error "schema must be an integer at line $LINE_NUMBER"
      SCHEMA_VERSION="$PARSED_VALUE"
      ;;
    validation:runtime)
      parse_string "$raw_value" || config_error "runtime must be a single-line basic string at line $LINE_NUMBER"
      RUNTIME="$PARSED_VALUE"
      ;;
    validation:setup)
      parse_string "$raw_value" || config_error "setup must be a single-line basic string at line $LINE_NUMBER"
      SETUP_COMMAND="$PARSED_VALUE"
      [ -n "$SETUP_COMMAND" ] || config_error "setup cannot be empty when declared"
      ;;
    target:name)
      parse_string "$raw_value" || config_error "target name must be a single-line basic string at line $LINE_NUMBER"
      BLOCK_NAME="$PARSED_VALUE"
      ;;
    target:path)
      parse_string "$raw_value" || config_error "target path must be a single-line basic string at line $LINE_NUMBER"
      BLOCK_PATH="$PARSED_VALUE"
      ;;
    task:name)
      parse_string "$raw_value" || config_error "task name must be a single-line basic string at line $LINE_NUMBER"
      BLOCK_NAME="$PARSED_VALUE"
      ;;
    task:target)
      parse_string "$raw_value" || config_error "task target must be a single-line basic string at line $LINE_NUMBER"
      BLOCK_TARGET="$PARSED_VALUE"
      ;;
    task:command)
      parse_string "$raw_value" || config_error "task command must be a single-line basic string at line $LINE_NUMBER"
      BLOCK_COMMAND="$PARSED_VALUE"
      ;;
    task:required)
      parse_scalar "$raw_value" || config_error "task required must be true or false at line $LINE_NUMBER"
      BLOCK_REQUIRED="$PARSED_VALUE"
      ;;
    *) config_error "unknown key '$key' in $SECTION at line $LINE_NUMBER" ;;
  esac
done <"$CONFIG_FILE"
finalize_block

[ "$SCHEMA_VERSION" = 1 ] || {
  if [ -z "$SCHEMA_VERSION" ]; then config_error "missing schema = 1"; fi
  config_error "unsupported schema '$SCHEMA_VERSION'; this runtime accepts schema 1"
}
[ "$VALIDATION_SEEN" = true ] || config_error "missing [validation] section"
[ "$RUNTIME" = bash ] || config_error "schema 1 requires runtime = \"bash\""
[ -s "$TARGETS_FILE" ] || config_error "schema 1 requires at least one explicit target"
[ -s "$TASKS_FILE" ] || config_error "schema 1 requires at least one explicit task"

while IFS="$(printf '\t')" read -r task_name task_target _task_required _task_command; do
  if ! awk -F '\t' -v name="$task_target" '$1 == name { found=1 } END { exit !found }' "$TARGETS_FILE"; then
    config_error "task '$task_name' references unknown target '$task_target'"
  fi
done <"$TASKS_FILE"

while IFS="$(printf '\t')" read -r target_name target_path; do
  if [ ! -d "$PROJECT_ROOT/$target_path" ]; then
    progress "ERROR: target '$target_name' path not found: $target_path"
    record_failure target "$target_name" 2 missing-target
    continue
  fi
  resolved_target="$(cd "$PROJECT_ROOT/$target_path" && pwd -P)"
  case "$resolved_target" in
    "$PROJECT_ROOT" | "$PROJECT_ROOT"/*) ;;
    *)
      progress "ERROR: target '$target_name' resolves outside the project: $target_path"
      record_failure target "$target_name" 2 escaped-target
      ;;
  esac
done <"$TARGETS_FILE"

if [ "$FAILED" -ne 0 ]; then
  emit_report failed
  exit "$EXIT_STATUS"
fi

clear_git_hook_env() {
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  unset GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE
  unset GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE
  unset GIT_COMMON_DIR GIT_NAMESPACE GIT_INTERNAL_GETTEXT_SH_SCHEME PRE_COMMIT
  unset PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF PRE_COMMIT_LOCAL_BRANCH PRE_COMMIT_REMOTE_BRANCH
  unset PRE_COMMIT_REMOTE_NAME PRE_COMMIT_REMOTE_URL
}

declared_command_unrunnable_code() {
  local command="$1" directory="$2" head
  head="${command%%[[:space:]]*}"
  case "$head" in "" | *[^[:alnum:]_./+-]*) return 0 ;; esac
  case "$head" in
    */*)
      if [ -d "$directory/$head" ] || { [ -e "$directory/$head" ] && [ ! -x "$directory/$head" ]; }; then
        printf '126\n'
        return 0
      fi
      ;;
  esac
  (cd "$directory" && command -v -- "$head" >/dev/null 2>&1) && return 0
  printf '127\n'
}

run_command() {
  local command="$1" directory="$2" status
  clear_git_hook_env
  # This is the only intentionally fallible boundary. Disable errexit around
  # the child process itself, capture its exact status, then restore errexit so
  # parser/accounting failures cannot be mistaken for task outcomes.
  set +e
  if [ "$JSON_MODE" = true ]; then
    (cd "$directory" && bash -c "$command") >&2
    status=$?
  else
    (cd "$directory" && bash -c "$command")
    status=$?
  fi
  set -e
  RUN_COMMAND_STATUS="$status"
}

if [ -n "$SETUP_COMMAND" ]; then
  progress "==> setup (root): $SETUP_COMMAND"
  unrunnable="$(declared_command_unrunnable_code "$SETUP_COMMAND" "$PROJECT_ROOT")"
  run_command "$SETUP_COMMAND" "$PROJECT_ROOT"
  status="$RUN_COMMAND_STATUS"
  if [ "$status" -ne 0 ]; then
    reason="command-failed"
    if [ -n "$unrunnable" ] && [ "$status" -eq "$unrunnable" ]; then reason="command-not-started"; fi
    progress "ERROR: setup failed on root (exit $status, $reason)"
    record_failure setup root "$status" "$reason"
    emit_report failed
    exit "$EXIT_STATUS"
  fi
fi

while IFS="$(printf '\t')" read -r task_name task_target _task_required task_command; do
  target_path="$(awk -F '\t' -v name="$task_target" '$1 == name { print $2; exit }' "$TARGETS_FILE")"
  if [ -z "$task_command" ]; then
    SKIPPED=$((SKIPPED + 1))
    human "  SKIP $task_name ($task_target): optional task has no command"
    continue
  fi

  progress "==> $task_name ($task_target): $task_command"
  unrunnable="$(declared_command_unrunnable_code "$task_command" "$PROJECT_ROOT/$target_path")"
  RAN=$((RAN + 1))
  run_command "$task_command" "$PROJECT_ROOT/$target_path"
  status="$RUN_COMMAND_STATUS"
  if [ "$status" -eq 0 ]; then
    human "  PASS $task_name ($task_target)"
    continue
  fi

  reason="command-failed"
  if [ -n "$unrunnable" ] && [ "$status" -eq "$unrunnable" ]; then
    RAN=$((RAN - 1))
    reason="command-not-started"
  fi
  progress "ERROR: $task_name failed on $task_target (exit $status, $reason)"
  record_failure "$task_name" "$task_target" "$status" "$reason"
done <"$TASKS_FILE"

if [ "$RAN" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  progress "ERROR: NOTHING RAN; required validation cannot pass without executing a task"
  record_failure validation root 1 nothing-ran
fi

if [ "$FAILED" -ne 0 ]; then
  emit_report failed
  exit "$EXIT_STATUS"
fi
emit_report passed
exit 0
