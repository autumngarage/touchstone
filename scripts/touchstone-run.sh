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
PROJECT_ARG=""
CONFIG_ARG=".touchstone.toml"

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
    if [ -z "$(trim "$BLOCK_COMMAND")" ]; then BLOCK_COMMAND=""; fi
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
      [ -n "$(trim "$SETUP_COMMAND")" ] || config_error "setup cannot be empty when declared"
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

resolve_target() {
  local target_name="$1" target_path="$2" resolved_target
  if [ ! -d "$PROJECT_ROOT/$target_path" ]; then
    progress "ERROR: target '$target_name' path not found: $target_path"
    record_failure target "$target_name" 2 missing-target
    return 1
  fi
  resolved_target="$(cd "$PROJECT_ROOT/$target_path" && pwd -P)"
  case "$resolved_target" in
    "$PROJECT_ROOT" | "$PROJECT_ROOT"/*) RESOLVED_TARGET="$resolved_target" ;;
    *)
      progress "ERROR: target '$target_name' resolves outside the project: $target_path"
      record_failure target "$target_name" 2 escaped-target
      return 1
      ;;
  esac
}

while IFS="$(printf '\t')" read -r target_name target_path; do
  resolve_target "$target_name" "$target_path" || true
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

declared_command_head() {
  local input="$1" character quote="" token=""
  local escaped=false assignment_candidate=true assignment_equals=false
  local token_quoted=false
  local index=0 length="${#1}"
  COMMAND_PATH_SET=false
  COMMAND_PATH_OVERRIDE=""

  while [ "$index" -lt "$length" ]; do
    while [ "$index" -lt "$length" ]; do
      character="${input:$index:1}"
      case "$character" in ' ' | "$(printf '\t')") index=$((index + 1)) ;; *) break ;; esac
    done
    token=""
    quote=""
    escaped=false
    assignment_candidate=true
    assignment_equals=false
    token_quoted=false
    while [ "$index" -lt "$length" ]; do
      character="${input:$index:1}"
      index=$((index + 1))
      if [ "$escaped" = true ]; then
        token="$token$character"
        token_quoted=true
        if [ "$assignment_equals" = false ]; then assignment_candidate=false; fi
        escaped=false
      elif [ "$quote" = single ]; then
        if [ "$character" = "'" ]; then quote=""; else token="$token$character"; fi
      elif [ "$quote" = double ]; then
        case "$character" in
          '"') quote="" ;;
          '\') escaped=true ;;
          '$' | '`') return 1 ;;
          *) token="$token$character" ;;
        esac
      else
        case "$character" in
          ' ' | "$(printf '\t')") break ;;
          "'")
            token_quoted=true
            if [ "$assignment_equals" = false ]; then assignment_candidate=false; fi
            quote=single
            ;;
          '"')
            token_quoted=true
            if [ "$assignment_equals" = false ]; then assignment_candidate=false; fi
            quote=double
            ;;
          '\')
            token_quoted=true
            if [ "$assignment_equals" = false ]; then assignment_candidate=false; fi
            escaped=true
            ;;
          '=')
            if [ "$assignment_equals" = false ] && [ -n "$token" ] && [ "$assignment_candidate" = true ]; then
              assignment_equals=true
            fi
            token="$token$character"
            ;;
          '$' | '`' | ';' | '&' | '|' | '(' | ')' | '<' | '>') return 1 ;;
          '#')
            if [ -z "$token" ]; then return 1; fi
            token="$token$character"
            ;;
          *)
            if [ "$assignment_equals" = false ]; then
              if [ -z "$token" ]; then
                case "$character" in [A-Za-z_]) ;; *) assignment_candidate=false ;; esac
              else
                case "$character" in [A-Za-z0-9_]) ;; *) assignment_candidate=false ;; esac
              fi
            fi
            token="$token$character"
            ;;
        esac
      fi
    done
    [ "$escaped" = false ] && [ -z "$quote" ] || return 1
    [ -n "$token" ] || return 1
    if [ "$assignment_candidate" = true ] && [ "$assignment_equals" = true ]; then
      case "$token" in
        PATH=*)
          COMMAND_PATH_SET=true
          COMMAND_PATH_OVERRIDE="${token#PATH=}"
          ;;
      esac
      continue
    fi
    COMMAND_HEAD="$token"
    COMMAND_HEAD_QUOTED="$token_quoted"
    return 0
  done
  return 1
}

declared_command_unrunnable_code() {
  local command="$1" directory="$2" head
  local executable="" first_line shebang interpreter effective_path="$PATH"
  local env_command word env_index
  local -a shebang_words
  declared_command_head "$command" || return 0
  head="$COMMAND_HEAD"
  if [ "$COMMAND_PATH_SET" = true ]; then effective_path="$COMMAND_PATH_OVERRIDE"; fi
  [ -n "$head" ] || return 0
  case "$head" in
    */*)
      case "$head" in /*) executable="$head" ;; *) executable="$directory/$head" ;; esac
      if [ -d "$executable" ] || { [ -e "$executable" ] && [ ! -x "$executable" ]; }; then
        printf '126\n'
        return 0
      fi
      ;;
    *)
      if [ "$COMMAND_HEAD_QUOTED" = true ] \
        && [ "$(cd "$directory" && PATH="$effective_path" type -t -- "$head" 2>/dev/null || true)" = keyword ]; then
        executable="$(cd "$directory" && PATH="$effective_path" type -P -- "$head" 2>/dev/null)" || true
      else
        executable="$(cd "$directory" && PATH="$effective_path" command -v -- "$head" 2>/dev/null)" || true
      fi
      ;;
  esac
  if [ -z "$executable" ]; then
    printf '127\n'
    return 0
  fi
  case "$executable" in /*) ;; */*) executable="$directory/$executable" ;; *) return 0 ;; esac
  if [ ! -e "$executable" ]; then
    printf '127\n'
    return 0
  fi
  [ -x "$executable" ] || return 0
  IFS= read -r first_line <"$executable" || true
  case "$first_line" in
    '#!'*)
      shebang="$(trim "${first_line#\#!}")"
      read -r -a shebang_words <<<"$shebang"
      interpreter="${shebang_words[0]:-}"
      if [ -z "$interpreter" ] || ! PATH="$effective_path" command -v -- "$interpreter" >/dev/null 2>&1; then
        printf 'missing-interpreter\n'
        return 0
      fi
      case "${interpreter##*/}" in
        env)
          env_command=""
          env_index=1
          while [ "$env_index" -lt "${#shebang_words[@]}" ]; do
            word="${shebang_words[$env_index]}"
            case "$word" in
              -S | --split-string | -i | --ignore-environment | -0 | --null | --debug)
                env_index=$((env_index + 1))
                ;;
              -u | --unset | -C | --chdir)
                env_index=$((env_index + 2))
                ;;
              --unset=* | --chdir=* | *=*)
                env_index=$((env_index + 1))
                ;;
              --)
                env_index=$((env_index + 1))
                ;;
              -*)
                return 0
                ;;
              *)
                env_command="$word"
                break
                ;;
            esac
          done
          if [ -z "$env_command" ] \
            || ! (cd "$directory" && PATH="$effective_path" type -P -- "$env_command" >/dev/null 2>&1); then
            printf 'missing-interpreter\n'
            return 0
          fi
          ;;
      esac
      ;;
  esac
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

unrunnable_status() {
  case "$1" in
    126 | 127) printf '%s\n' "$1" ;;
    missing-interpreter) printf '127\n' ;;
    *) return 1 ;;
  esac
}

if [ -n "$SETUP_COMMAND" ]; then
  progress "==> setup (root): $SETUP_COMMAND"
  unrunnable="$(declared_command_unrunnable_code "$SETUP_COMMAND" "$PROJECT_ROOT")"
  if [ -n "$unrunnable" ]; then
    status="$(unrunnable_status "$unrunnable")"
    progress "ERROR: setup failed on root (exit $status, command-not-started)"
    record_failure setup root "$status" command-not-started
    emit_report failed
    exit "$EXIT_STATUS"
  fi
  run_command "$SETUP_COMMAND" "$PROJECT_ROOT"
  status="$RUN_COMMAND_STATUS"
  if [ "$status" -ne 0 ]; then
    progress "ERROR: setup failed on root (exit $status, command-failed)"
    record_failure setup root "$status" command-failed
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
  if ! resolve_target "$task_target" "$target_path"; then continue; fi
  target_directory="$RESOLVED_TARGET"
  unrunnable="$(declared_command_unrunnable_code "$task_command" "$target_directory")"
  if [ -n "$unrunnable" ]; then
    status="$(unrunnable_status "$unrunnable")"
    progress "ERROR: $task_name failed on $task_target (exit $status, command-not-started)"
    record_failure "$task_name" "$task_target" "$status" command-not-started
    continue
  fi
  RAN=$((RAN + 1))
  run_command "$task_command" "$target_directory"
  status="$RUN_COMMAND_STATUS"
  if [ "$status" -eq 0 ]; then
    human "  PASS $task_name ($task_target)"
    continue
  fi

  progress "ERROR: $task_name failed on $task_target (exit $status, command-failed)"
  record_failure "$task_name" "$task_target" "$status" command-failed
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
