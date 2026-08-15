#!/usr/bin/env bash
#
# scripts/touchstone-adopt.sh — compile repository facts into an adoption plan.
#
# Detectors are read-only adapters. They write records into one common plan
# model; only apply_plan writes repository files.

# shellcheck disable=SC2034 # globals are consumed by sourced compiler modules

set -euo pipefail
LC_ALL=C
export LC_ALL

OPERATION="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi

case "$OPERATION" in
  adopt | upgrade) ;;
  *)
    echo "ERROR: expected 'adopt' or 'upgrade'" >&2
    exit 2
    ;;
esac
usage() {
  if [ "$OPERATION" = adopt ]; then
    cat <<'EOF'
Usage:
  bash scripts/touchstone-adopt.sh adopt [--check|--dry-run] [--json] [--project DIR] [--task NAME=COMMAND]
EOF
  else
    cat <<'EOF'
Usage:
  bash scripts/touchstone-adopt.sh upgrade [--check|--dry-run] [--json] [--project DIR]
EOF
  fi
}

MODE=apply
JSON_MODE=false
PROJECT_ARG=""
MANUAL_TASK_ARGS=()
MANUAL_TASK_COUNT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      [ "$MODE" = apply ] || {
        echo "ERROR: --check and --dry-run are mutually exclusive" >&2
        exit 2
      }
      MODE=check
      shift
      ;;
    --dry-run)
      [ "$MODE" = apply ] || {
        echo "ERROR: --check and --dry-run are mutually exclusive" >&2
        exit 2
      }
      MODE=dry-run
      shift
      ;;
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
    --task)
      [ "$OPERATION" = adopt ] || {
        echo "ERROR: --task is valid only with adopt" >&2
        exit 2
      }
      [ "$#" -ge 2 ] || {
        echo "ERROR: --task requires NAME=COMMAND" >&2
        exit 2
      }
      MANUAL_TASK_ARGS+=("$2")
      MANUAL_TASK_COUNT=$((MANUAL_TASK_COUNT + 1))
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ -n "$PROJECT_ARG" ]; then
  PROJECT_INPUT="$PROJECT_ARG"
else
  PROJECT_INPUT="."
fi
PROJECT_ROOT="$(cd "$PROJECT_INPUT" 2>/dev/null && pwd -P)" || {
  echo "ERROR: project directory does not exist: $PROJECT_INPUT" >&2
  exit 2
}
case "$PROJECT_ROOT" in *$'\t'* | *$'\r'* | *$'\n'*)
  echo "ERROR: project directory contains a tab or newline that cannot be represented safely in an adoption transaction" >&2
  exit 2
  ;;
esac

early_operational_failure() {
  local reason="$1"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":1,"operation":"%s","status":"operational-failure","profile":"unknown","changes":[],"remotePolicy":{"status":"separate-operation","required":true,"mutated":false},"diff":"","reason":"%s"}\n' \
      "$OPERATION" "$reason"
  else
    printf 'ERROR: %s\n' "$reason" >&2
  fi
  exit 6
}

EARLY_GIT_ROOT="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$EARLY_GIT_ROOT" ]; then
  EARLY_GIT_ROOT="$(cd "$EARLY_GIT_ROOT" 2>/dev/null && pwd -P)" || EARLY_GIT_ROOT=""
fi
PLAN_TEMP_BASE=""
for candidate in "${TMPDIR:-/tmp}" /tmp /var/tmp; do
  [ -d "$candidate" ] && [ -w "$candidate" ] || continue
  candidate="$(cd "$candidate" 2>/dev/null && pwd -P)" || continue
  if [ -n "$EARLY_GIT_ROOT" ]; then
    case "$candidate" in "$EARLY_GIT_ROOT" | "$EARLY_GIT_ROOT"/*) continue ;; esac
  fi
  PLAN_TEMP_BASE="$candidate"
  break
done
[ -n "$PLAN_TEMP_BASE" ] \
  || early_operational_failure "could not find a writable adoption workspace outside the project"
PLAN_ROOT="$(mktemp -d "$PLAN_TEMP_BASE/touchstone-adopt.XXXXXX")" \
  || early_operational_failure "could not create adoption workspace"
unset EARLY_GIT_ROOT PLAN_TEMP_BASE candidate
APPLY_ACTIVE=false
APPLY_STAGE_FILE="$PLAN_ROOT/apply-stage"
APPLY_APPLIED_FILE="$PLAN_ROOT/apply-applied"
APPLY_DIRECTORIES_FILE="$PLAN_ROOT/apply-directories"

cleanup_on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$APPLY_ACTIVE" = true ]; then
    if ! rollback_apply "$APPLY_APPLIED_FILE" "$APPLY_STAGE_FILE" "$APPLY_DIRECTORIES_FILE"; then
      echo "ERROR: interrupted adoption could not fully roll back its apply transaction" >&2
      status=6
    fi
  fi
  rm -rf "$PLAN_ROOT"
  exit "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
TARGETS_FILE="$PLAN_ROOT/targets"
TASKS_FILE="$PLAN_ROOT/tasks"
SETUPS_FILE="$PLAN_ROOT/setups"
CHANGES_FILE="$PLAN_ROOT/changes"
DIFF_FILE="$PLAN_ROOT/diff"
OLD_ROOT="$PLAN_ROOT/old"
NEW_ROOT="$PLAN_ROOT/new"

PROFILE=unknown
NODE_MANAGER=""
PLAN_STATUS=current
REFUSAL_REASON=""
TAB=$'\t'
CR=$'\r'
LF=$'\n'
TOUCHSTONE_BLOCK_BEGIN='<!-- touchstone:steering:start -->'
TOUCHSTONE_BLOCK_END='<!-- touchstone:steering:end -->'

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

valid_identifier() {
  case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

valid_relative_path() {
  case "$1" in "" | /* | .. | ../* | */../* | */..) return 1 ;; esac
  case "$1" in *"$TAB"* | *"$CR"* | *"$LF"*) return 1 ;; esac
  return 0
}

json_string() {
  local value="$1"
  printf '"'
  printf '%s' "$value" | awk '
    {
      if (NR > 1) printf "\\n"
      for (position = 1; position <= length($0); position++) {
        character = substr($0, position, 1)
        if (character == "\\") printf "\\\\"
        else if (character == "\"") printf "\\\""
        else if (character == sprintf("%c", 8)) printf "\\b"
        else if (character == sprintf("%c", 9)) printf "\\t"
        else if (character == sprintf("%c", 12)) printf "\\f"
        else if (character == sprintf("%c", 13)) printf "\\r"
        else {
          control = 0
          for (code = 1; code < 32; code++) {
            if (character == sprintf("%c", code)) { control = code; break }
          }
          if (control) printf "\\u%04x", control
          else printf "%s", character
        }
      }
    }
  '
  printf '"'
}

change_count() {
  awk 'END { print NR + 0 }' "$CHANGES_FILE"
}

emit_json() {
  local status="$1" first=true action path ownership diff_content="" diff_read_failed=false
  if [ -f "$DIFF_FILE" ] && ! diff_content="$(cat "$DIFF_FILE" 2>/dev/null)"; then
    status=operational-failure
    REFUSAL_REASON="could not read adoption plan diff"
    diff_content=""
    diff_read_failed=true
  fi
  printf '{"schema":1,"operation":'
  json_string "$OPERATION"
  printf ',"status":'
  json_string "$status"
  printf ',"profile":'
  json_string "$PROFILE"
  printf ',"changes":['
  if [ -f "$CHANGES_FILE" ]; then
    while IFS="$(printf '\t')" read -r action path ownership; do
      [ -n "$path" ] || continue
      if [ "$first" = false ]; then printf ','; fi
      first=false
      printf '{"path":'
      json_string "$path"
      printf ',"action":'
      json_string "$action"
      printf ',"ownership":'
      json_string "$ownership"
      printf '}'
    done <"$CHANGES_FILE"
  fi
  printf '],"remotePolicy":{"status":"separate-operation","required":true,"mutated":false},"diff":'
  json_string "$diff_content"
  if [ -n "$REFUSAL_REASON" ]; then
    printf ',"reason":'
    json_string "$REFUSAL_REASON"
  fi
  printf '}\n'
  [ "$diff_read_failed" = false ] || exit 6
}

contract_refusal() {
  PROFILE="${PROFILE:-unknown}"
  REFUSAL_REASON="$*"
  if [ "$JSON_MODE" = true ]; then
    emit_json contract-refused
  else
    echo "ERROR: $*" >&2
  fi
  exit 4
}

safety_refusal() {
  REFUSAL_REASON="$*"
  if [ "$JSON_MODE" = true ]; then
    emit_json safety-refused
  else
    echo "ERROR: $*" >&2
  fi
  exit 5
}

operational_failure() {
  REFUSAL_REASON="$*"
  if [ "$JSON_MODE" = true ]; then
    emit_json operational-failure
  else
    echo "ERROR: $*" >&2
  fi
  exit 6
}

mkdir -p "$OLD_ROOT" "$NEW_ROOT" \
  || operational_failure "could not initialize adoption workspace"
for plan_file in "$TARGETS_FILE" "$TASKS_FILE" "$SETUPS_FILE" "$CHANGES_FILE" "$DIFF_FILE"; do
  : >"$plan_file" || operational_failure "could not initialize adoption plan file: $(basename "$plan_file")"
done
unset plan_file

GIT_ROOT="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$GIT_ROOT" ] || contract_refusal "adoption requires a git repository: $PROJECT_ROOT"
GIT_ROOT="$(cd "$GIT_ROOT" 2>/dev/null && pwd -P)" \
  || operational_failure "could not resolve git repository root: $GIT_ROOT"
PROJECT_ROOT="$GIT_ROOT"

detect_profile() {
  local directory="$1" count=0 found=""
  if [ -f "$directory/package.json" ] || [ -f "$directory/tsconfig.json" ] || [ -f "$directory/pnpm-workspace.yaml" ]; then
    found=node
    count=$((count + 1))
  fi
  if [ -f "$directory/pyproject.toml" ] || [ -f "$directory/uv.lock" ] || [ -f "$directory/requirements.txt" ]; then
    found="${found:+$found,}python"
    count=$((count + 1))
  fi
  if [ -f "$directory/Package.swift" ]; then
    found="${found:+$found,}swift"
    count=$((count + 1))
  fi
  if [ -f "$directory/Cargo.toml" ]; then
    found="${found:+$found,}rust"
    count=$((count + 1))
  fi
  if [ -f "$directory/go.mod" ]; then
    found="${found:+$found,}go"
    count=$((count + 1))
  fi
  if [ "$count" -gt 1 ]; then
    printf 'ambiguous:%s\n' "$found"
  elif [ "$count" -eq 1 ]; then
    printf '%s\n' "$found"
  else
    printf 'generic\n'
  fi
}

# Compiler boundaries and profile adapters are separate reviewable units.
# shellcheck source=/dev/null
for component in compiler legacy planner steering transaction parsers node python native; do
  component_path="$SCRIPT_ROOT/scripts/lib/touchstone-adopt-$component.sh"
  if [ -f "$component_path" ]; then
    . "$component_path"
  fi
done
unset component component_path

compile_plan

present_plan_before_apply() {
  local diff_content
  [ "$PLAN_STATUS" != current ] || return 0
  diff_content="$(cat "$DIFF_FILE" 2>/dev/null)" \
    || operational_failure "could not read adoption plan diff"
  [ "$JSON_MODE" = false ] || return 0
  {
    printf '%s: %s file change(s) accepted for apply\n' "$OPERATION" "$(change_count)"
    printf '%s\n' "$diff_content"
    printf 'Remote policy: separate operation; no remote state was read or changed.\n'
  } >&2
}

case "$MODE" in
  check)
    if [ "$JSON_MODE" = true ]; then emit_json "$PLAN_STATUS"; fi
    if [ "$PLAN_STATUS" = current ]; then
      if [ "$JSON_MODE" = false ]; then printf '%s: current\n' "$OPERATION"; fi
      exit 0
    fi
    if [ "$JSON_MODE" = false ]; then
      printf '%s: %s file change(s) required\n' "$OPERATION" "$(change_count)"
      awk -F '\t' '{ printf "  %s %s\n", $1, $2 }' "$CHANGES_FILE"
    fi
    exit 3
    ;;
  dry-run)
    if [ "$JSON_MODE" = true ]; then
      emit_json "$PLAN_STATUS"
    else
      printf '%s: %s file change(s) proposed\n' "$OPERATION" "$(change_count)"
      cat "$DIFF_FILE"
      printf 'Remote policy: separate operation; no remote state was read or changed.\n'
    fi
    ;;
  apply)
    present_plan_before_apply
    apply_plan
    if [ "$JSON_MODE" = true ]; then
      if [ "$PLAN_STATUS" = current ]; then emit_json current; else emit_json applied; fi
    elif [ "$PLAN_STATUS" = current ]; then
      printf '%s: current; no files changed\n' "$OPERATION"
    else
      printf '%s: applied %s file change(s)\n' "$OPERATION" "$(change_count)"
      printf 'Remote policy: separate operation; no remote state was read or changed.\n'
    fi
    ;;
esac
