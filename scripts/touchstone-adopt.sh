#!/usr/bin/env bash
# scripts/touchstone-adopt.sh — plan-first repository adoption and upgrade.
# shellcheck disable=SC2034 # globals are consumed by sourced adoption modules.

set -euo pipefail

OUTPUT_SCHEMA='touchstone.adoption/v1'
OPERATION="${1:-}"
[ "$#" -gt 0 ] && shift
MODE=apply
JSON_MODE=false
PROJECT_ARG=""
TRACKER_TYPE=""
TRACKER_PREFIX=""
MANUAL_TASK_COUNT=0
MANUAL_TASK_ARGS=()
PROFILE=""
DETECTED_PROFILE=""
PLAN_STATUS=""
KEEP_PLAN=false
APPLY_IN_PROGRESS=false
PLAN_ROOT=""
TAB="$(printf '\t')"
CR="$(printf '\r')"
LF="$(printf '\n_')"
LF="${LF%_}"
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck disable=SC1091 # installed CLI modules resolve from SCRIPT_ROOT.
source "$SCRIPT_ROOT/scripts/lib/touchstone-worktree-lock.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  touchstone adopt [--check|--dry-run] [--json] [--project DIR]
    [--tracker github|linear] [--tracker-prefix KEY] [--task NAME=COMMAND ...]
  touchstone upgrade [--check|--dry-run] [--json] [--project DIR]
EOF
  exit 2
}

json_string() {
  printf '"'
  printf '%s' "$1" | awk 'BEGIN { ORS="" }
    {
      if (NR > 1) printf "\\n"
      for (position = 1; position <= length($0); position++) {
        character = substr($0, position, 1)
        if (character == "\\") printf "\\\\"
        else if (character == "\"") printf "\\\""
        else {
          control = 0
          for (code = 1; code < 32; code++) {
            if (character == sprintf("%c", code)) {
              printf "\\u%04x", code
              control = 1
              break
            }
          }
          if (!control) printf "%s", character
        }
      }
    }'
  printf '"'
}

emit_failure() {
  local status="$1" reason="$2" remedy="$3"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":' "$OUTPUT_SCHEMA"
    json_string "$OPERATION"
    printf ',"status":"%s","reason":' "$status"
    json_string "$reason"
    printf ',"remedy":'
    json_string "$remedy"
    printf '}\n'
  else
    printf 'ERROR: %s\n' "$reason" >&2
    [ -z "$remedy" ] || printf '       %s\n' "$remedy" >&2
  fi
}

invalid_invocation() {
  emit_failure invalid-invocation "$1" "$2"
  exit 2
}
contract_refusal() {
  emit_failure contract-refusal "$1" "Pass explicit --task commands or repair the named repository fact."
  exit 4
}
safety_refusal() {
  emit_failure safety-refusal "$1" "Use a clean feature branch and rerun the plan."
  exit 5
}
operational_failure() {
  emit_failure operational-failure "$1" "Repair the local filesystem or tool failure, then rerun."
  exit 6
}

require_option_value() {
  local option="${1:-}" value="${2:-}"
  [ "$#" -ge 2 ] || invalid_invocation "missing value for $option" "Pass a non-empty value after $option."
  case "$value" in '' | --*) invalid_invocation "missing value for $option" "Pass a non-empty value after $option." ;; esac
}

cleanup() {
  if [ "$APPLY_IN_PROGRESS" = true ]; then
    if restore_plan_after_failure; then
      APPLY_IN_PROGRESS=false
      printf 'ERROR: interrupted adoption apply restored the original repository bytes\n' >&2
    else
      KEEP_PLAN=true
      APPLY_IN_PROGRESS=false
      printf 'ERROR: interrupted adoption apply requires recovery snapshots at %s\n' \
        "$PLAN_ROOT" >&2
    fi
  fi
  if [ -n "$TOUCHSTONE_WORKTREE_LOCK_DIR" ] \
    && ! touchstone_worktree_lock_release; then
    printf 'ERROR: could not release adoption transaction: %s\n' \
      "$TOUCHSTONE_WORKTREE_LOCK_ERROR" >&2
  fi
  [ -z "$PLAN_ROOT" ] || [ "$KEEP_PLAN" = true ] || rm -rf -- "$PLAN_ROOT"
}
trap cleanup EXIT

case "$OPERATION" in adopt | upgrade) ;; -h | --help | help) usage ;; *) usage ;; esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      [ "$MODE" = apply ] || invalid_invocation "choose only one planning mode" "Use --check or --dry-run, not both."
      MODE=check
      shift
      ;;
    --dry-run)
      [ "$MODE" = apply ] || invalid_invocation "choose only one planning mode" "Use --check or --dry-run, not both."
      MODE=dry-run
      shift
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --project)
      require_option_value "$@"
      PROJECT_ARG="$2"
      shift 2
      ;;
    --tracker)
      require_option_value "$@"
      TRACKER_TYPE="$2"
      shift 2
      ;;
    --tracker-prefix)
      require_option_value "$@"
      TRACKER_PREFIX="$2"
      shift 2
      ;;
    --task)
      require_option_value "$@"
      MANUAL_TASK_ARGS+=("$2")
      MANUAL_TASK_COUNT=$((MANUAL_TASK_COUNT + 1))
      shift 2
      ;;
    -h | --help) usage ;;
    *) invalid_invocation "unknown argument '$1'" "Run 'touchstone $OPERATION --help'." ;;
  esac
done

if [ "$OPERATION" = upgrade ] && { [ "$MANUAL_TASK_COUNT" -gt 0 ] || [ -n "$TRACKER_TYPE$TRACKER_PREFIX" ]; }; then
  invalid_invocation "upgrade does not accept task or tracker replacement options" "Upgrade refreshes only Touchstone-owned steering."
fi
case "$TRACKER_TYPE" in '' | github | linear) ;; *) invalid_invocation "unsupported tracker '$TRACKER_TYPE'" "Use github or linear." ;; esac
if [ "$TRACKER_TYPE" = linear ]; then
  printf '%s' "$TRACKER_PREFIX" | grep -Eq '^[A-Z][A-Z0-9]*$' \
    || invalid_invocation "Linear adoption requires an uppercase --tracker-prefix" "For example: --tracker linear --tracker-prefix AUT."
elif [ -n "$TRACKER_PREFIX" ]; then
  invalid_invocation "--tracker-prefix applies only to Linear" "Remove it or select --tracker linear."
fi

if [ -n "$PROJECT_ARG" ]; then
  PROJECT_DIRECTORY="$(cd "$PROJECT_ARG" 2>/dev/null && pwd -P)" \
    || invalid_invocation "project directory does not exist: $PROJECT_ARG" "Pass an existing Git repository."
else
  PROJECT_DIRECTORY="$PWD"
fi
PROJECT_ROOT="$(git -C "$PROJECT_DIRECTORY" rev-parse --show-toplevel 2>/dev/null)" \
  || invalid_invocation "not inside a Git repository" "Run inside a project or pass --project DIR."
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
git -C "$PROJECT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 \
  || invalid_invocation "project has no committed HEAD" "Commit the repository facts before adoption."

plan_base="${TMPDIR:-/tmp}"
resolved_plan_base="$(cd "$plan_base" 2>/dev/null && pwd -P)" || resolved_plan_base=/tmp
case "$resolved_plan_base" in "$PROJECT_ROOT" | "$PROJECT_ROOT"/*) plan_base=/tmp ;; esac
PLAN_ROOT="$(mktemp -d "$plan_base/touchstone-adopt.XXXXXX")" \
  || operational_failure "could not create adoption workspace"
TARGETS_FILE="$PLAN_ROOT/targets"
TASKS_FILE="$PLAN_ROOT/tasks"
SETUPS_FILE="$PLAN_ROOT/setups"
CHANGES_FILE="$PLAN_ROOT/changes"
CREATED_DIRS_FILE="$PLAN_ROOT/created-dirs"
DIFF_FILE="$PLAN_ROOT/plan.diff"
if ! { : >"$TARGETS_FILE" && : >"$TASKS_FILE" && : >"$SETUPS_FILE" && : >"$CHANGES_FILE" && : >"$CREATED_DIRS_FILE"; }; then
  operational_failure "could not initialize adoption workspace"
fi

# shellcheck disable=SC1091 # sources resolve from the installed CLI root.
source "$SCRIPT_ROOT/scripts/lib/touchstone-plan-records.sh"
# shellcheck disable=SC1091 # sources resolve from the installed CLI root.
source "$SCRIPT_ROOT/scripts/lib/touchstone-legacy-config.sh"
# shellcheck disable=SC1091 # sources resolve from the installed CLI root.
source "$SCRIPT_ROOT/scripts/lib/touchstone-tracker-config.sh"
# shellcheck disable=SC1091 # sources resolve from the installed CLI root.
source "$SCRIPT_ROOT/scripts/lib/touchstone-adopt-plan.sh"
# shellcheck disable=SC1091 # sources resolve from the installed CLI root.
source "$SCRIPT_ROOT/scripts/lib/touchstone-adopt-steering.sh"

require_head_file() {
  local relative="$1" head_blob worktree_blob
  [ ! -L "$PROJECT_ROOT/$relative" ] || contract_refusal "compiler input is a symlink: $relative"
  [ -f "$PROJECT_ROOT/$relative" ] || contract_refusal "compiler input is not a regular file: $relative"
  git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
    || contract_refusal "compiler input is not tracked: $relative"
  git -C "$PROJECT_ROOT" cat-file -e "HEAD:$relative" 2>/dev/null \
    || contract_refusal "compiler input does not exist in HEAD: $relative"
  head_blob="$(git -C "$PROJECT_ROOT" rev-parse "HEAD:$relative")" \
    || operational_failure "could not read committed compiler input: $relative"
  worktree_blob="$(git -C "$PROJECT_ROOT" hash-object -- "$relative")" \
    || operational_failure "could not hash compiler input: $relative"
  [ "$head_blob" = "$worktree_blob" ] \
    || contract_refusal "compiler input differs from HEAD: $relative"
}

detect_profile() {
  local facts="" count=0
  if [ -e "$PROJECT_ROOT/package.json" ] || [ -L "$PROJECT_ROOT/package.json" ] \
    || [ -e "$PROJECT_ROOT/package-lock.json" ] || [ -L "$PROJECT_ROOT/package-lock.json" ]; then
    if { [ ! -e "$PROJECT_ROOT/package.json" ] && [ ! -L "$PROJECT_ROOT/package.json" ]; } \
      || { [ ! -e "$PROJECT_ROOT/package-lock.json" ] && [ ! -L "$PROJECT_ROOT/package-lock.json" ]; }; then
      contract_refusal "npm adoption requires both package.json and package-lock.json"
    fi
    facts="${facts:+$facts,}npm"
    count=$((count + 1))
  fi
  if [ -e "$PROJECT_ROOT/pyproject.toml" ]; then
    facts="${facts:+$facts,}python"
    count=$((count + 1))
  fi
  if [ -e "$PROJECT_ROOT/Package.swift" ]; then
    facts="${facts:+$facts,}swift"
    count=$((count + 1))
  fi
  [ "$count" -gt 0 ] || contract_refusal "no supported project evidence found"
  [ "$count" -eq 1 ] || contract_refusal "competing project evidence found: $facts"
  DETECTED_PROFILE="$facts"
}

compile_legacy_plan() {
  local file="$PROJECT_ROOT/.touchstone-config" command key task found=false
  require_head_file .touchstone-config
  if command="$(legacy_full_validation_command "$file")"; then
    record_plan_target root . legacy
    record_plan_task validate root "$command"
    PROFILE=legacy
    return 0
  fi
  for key in lint typecheck test build; do
    if command="$(legacy_config_value "$file" "${key}_command")"; then
      if [ "$found" = false ]; then
        record_plan_target root . legacy
        found=true
      fi
      task="$key"
      record_plan_task "$task" root "$command"
    fi
  done
  [ "$found" = true ]
}

compile_npm_plan() {
  local script scripts found=false
  require_head_file package.json
  require_head_file package-lock.json
  scripts="$(awk -f "$SCRIPT_ROOT/scripts/lib/touchstone-package-json.awk" \
    "$PROJECT_ROOT/package.json" 2>/dev/null)" \
    || contract_refusal "package.json is malformed or has no usable top-level scripts object"
  [ -n "$scripts" ] \
    || contract_refusal "package.json declares no non-empty validate, verify, lint, typecheck, test, or build script"
  record_plan_target root . npm
  record_plan_setup "$PROJECT_ROOT" 'npm ci --ignore-scripts'
  for script in validate verify; do
    if printf '%s\n' "$scripts" | grep -Fx "$script" >/dev/null; then
      record_plan_task "$script" root "npm run $script"
      PROFILE=npm
      return 0
    fi
  done
  for script in lint typecheck test build; do
    if printf '%s\n' "$scripts" | grep -Fx "$script" >/dev/null; then
      record_plan_task "$script" root "npm run $script"
      found=true
    fi
  done
  [ "$found" = true ] || contract_refusal "package.json has no supported validation script"
  PROFILE=npm
}

compile_python_plan() {
  local tool found=false grep_status
  require_head_file pyproject.toml
  [ -f "$PROJECT_ROOT/uv.lock" ] \
    || contract_refusal "automatic Python adoption requires uv.lock; pass explicit --task commands for an unlocked project"
  require_head_file uv.lock
  record_plan_target root . python
  record_plan_setup "$PROJECT_ROOT" 'uv sync --frozen'
  for tool in ruff mypy pytest; do
    if grep -Eq "^\\[tool\\.${tool}([.]|])" "$PROJECT_ROOT/pyproject.toml"; then
      case "$tool" in
        ruff) command='uv run --frozen ruff check .' ;;
        mypy) command='uv run --frozen mypy .' ;;
        pytest) command='uv run --frozen pytest' ;;
      esac
      record_plan_task "$tool" root "$command"
      found=true
    else
      grep_status=$?
      [ "$grep_status" -eq 1 ] || operational_failure "could not inspect pyproject.toml for $tool"
    fi
  done
  [ "$found" = true ] || contract_refusal "pyproject.toml declares no ruff, mypy, or pytest tool table"
  PROFILE=python
}

compile_swift_plan() {
  require_head_file Package.swift
  record_plan_target root . swift
  record_plan_task test root 'swift test --disable-automatic-resolution'
  PROFILE=swift
}

read_existing_contract() {
  local output status=0
  require_head_file .touchstone.toml
  output="$(bash "$SCRIPT_ROOT/scripts/touchstone-run.sh" validate --check-contract \
    --project "$PROJECT_ROOT" 2>&1)" || status=$?
  [ "$status" -eq 0 ] || contract_refusal "existing .touchstone.toml is invalid: $output"
  PROFILE=declared-v1
}

tracker_contract_failure() {
  contract_refusal "existing .touchstone-tracker.toml is invalid ($1): $2"
}

compile_new_contract() {
  local proposed="$PLAN_ROOT/proposed-contract.toml" detected
  if [ "$MANUAL_TASK_COUNT" -gt 0 ]; then
    compile_manual_plan "${MANUAL_TASK_ARGS[@]}"
  elif [ -e "$PROJECT_ROOT/.touchstone-config" ] || [ -L "$PROJECT_ROOT/.touchstone-config" ]; then
    if compile_legacy_plan; then :; else
      detect_profile
      detected="$DETECTED_PROFILE"
      case "$detected" in npm) compile_npm_plan ;; python) compile_python_plan ;; swift) compile_swift_plan ;; esac
    fi
  else
    detect_profile
    detected="$DETECTED_PROFILE"
    case "$detected" in npm) compile_npm_plan ;; python) compile_python_plan ;; swift) compile_swift_plan ;; esac
  fi
  render_contract "$proposed"
  plan_file .touchstone.toml "$proposed" project-contract
}

plan_tracker_contract() {
  local proposed="$PLAN_ROOT/proposed-tracker.toml"
  if [ -e "$PROJECT_ROOT/.touchstone-tracker.toml" ] || [ -L "$PROJECT_ROOT/.touchstone-tracker.toml" ]; then
    [ -z "$TRACKER_TYPE$TRACKER_PREFIX" ] \
      || invalid_invocation "an existing tracker declaration cannot be replaced by adoption options" "Edit project-owned values in a separate reviewed change."
    require_head_file .touchstone-tracker.toml
    load_tracker_contract "$PROJECT_ROOT/.touchstone-tracker.toml"
    return 0
  fi
  [ "$OPERATION" = adopt ] || return 0
  [ -n "$TRACKER_TYPE" ] || TRACKER_TYPE=github
  render_tracker_contract "$proposed"
  plan_file .touchstone-tracker.toml "$proposed" project-contract
}

plan_tracker_contract
if [ -e "$PROJECT_ROOT/.touchstone.toml" ] || [ -L "$PROJECT_ROOT/.touchstone.toml" ]; then
  [ "$MANUAL_TASK_COUNT" -eq 0 ] \
    || invalid_invocation "an existing validation declaration cannot be replaced by adoption options" "Edit project-owned values in a separate reviewed change."
  read_existing_contract
  plan_steering "$([ "$OPERATION" = upgrade ] && printf true || printf false)"
elif [ "$OPERATION" = upgrade ]; then
  contract_refusal "repository is not adopted; run touchstone adopt first"
else
  compile_new_contract
  plan_steering true
fi

render_plan_diff
CHANGE_COUNT="$(awk 'NF { count++ } END { print count + 0 }' "$CHANGES_FILE")"
[ "$CHANGE_COUNT" -gt 0 ] && PLAN_STATUS=changes-required || PLAN_STATUS=current

emit_result() {
  local status="$1" first=true action relative ownership diff
  diff="$(<"$DIFF_FILE")" || operational_failure "could not read adoption plan diff"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"%s","status":"%s","profile":' \
      "$OUTPUT_SCHEMA" "$OPERATION" "$status"
    json_string "$PROFILE"
    printf ',"changes":['
    while IFS="$(printf '\t')" read -r action relative ownership; do
      [ -n "$relative" ] || continue
      [ "$first" = true ] || printf ','
      first=false
      printf '{"action":"%s","path":' "$action"
      json_string "$relative"
      printf ',"ownership":"%s"}' "$ownership"
    done <"$CHANGES_FILE"
    printf '],"diff":'
    json_string "$diff"
    printf ',"remotePolicy":{"status":"separate-operation"}}\n'
  else
    printf '%s: %s; %s file change(s)\n' "$OPERATION" "$status" "$CHANGE_COUNT"
    [ -z "$diff" ] || printf '%s\n' "$diff"
    printf 'remote policy: separate operation\n'
  fi
}

case "$MODE" in
  check)
    emit_result "$PLAN_STATUS"
    [ "$CHANGE_COUNT" -eq 0 ] || exit 3
    ;;
  dry-run) emit_result "$([ "$CHANGE_COUNT" -eq 0 ] && printf current || printf planned)" ;;
  apply)
    if [ "$CHANGE_COUNT" -eq 0 ]; then
      emit_result current
      exit 0
    fi
    branch="$(git -C "$PROJECT_ROOT" branch --show-current)" \
      || operational_failure "could not read current branch"
    [ -n "$branch" ] || safety_refusal "detached HEAD cannot apply adoption"
    remotes_file="$PLAN_ROOT/remotes"
    git -C "$PROJECT_ROOT" remote >"$remotes_file" \
      || operational_failure "could not inspect the repository default branch"
    remote_default_count=0
    default_branch=""
    while IFS= read -r remote; do
      [ -n "$remote" ] || continue
      default_ref_status=0
      default_ref="$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)" \
        || default_ref_status=$?
      case "$default_ref_status" in
        0)
          remote_default_count=$((remote_default_count + 1))
          case "$default_ref" in
            "$remote"/*) default_branch="${default_ref#"$remote"/}" ;;
            *) safety_refusal "could not identify the repository default branch" ;;
          esac
          git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/remotes/$default_ref" \
            || safety_refusal "could not identify the repository default branch"
          ;;
        1) ;;
        *) operational_failure "could not inspect the repository default branch" ;;
      esac
    done <"$remotes_file"
    case "$remote_default_count" in
      0) ;;
      1) ;;
      *) safety_refusal "multiple remote default branches are configured" ;;
    esac
    if [ "$remote_default_count" -eq 0 ]; then
      default_candidates=""
      for candidate in main master; do
        if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$candidate"; then
          default_candidates="${default_candidates:+$default_candidates }$candidate"
        fi
      done
      case "$default_candidates" in
        main | master) default_branch="$default_candidates" ;;
        *) safety_refusal "could not identify the repository default branch" ;;
      esac
    fi
    [ "$branch" != "$default_branch" ] \
      || safety_refusal "adoption cannot apply on the default branch '$branch'"
    lock_status=0
    touchstone_worktree_lock_acquire "$PROJECT_ROOT" || lock_status=$?
    case "$lock_status" in
      0) ;;
      "$TOUCHSTONE_WORKTREE_LOCK_REFUSED") safety_refusal "$TOUCHSTONE_WORKTREE_LOCK_ERROR" ;;
      *) operational_failure "$TOUCHSTONE_WORKTREE_LOCK_ERROR" ;;
    esac
    locked_branch="$(git -C "$PROJECT_ROOT" branch --show-current)" \
      || operational_failure "could not bind the feature branch after locking"
    [ "$locked_branch" = "$branch" ] \
      || safety_refusal "repository branch changed before the apply transaction was locked"
    if ! worktree_status="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)"; then
      operational_failure "could not verify that the worktree is clean"
    fi
    [ -z "$worktree_status" ] \
      || safety_refusal "apply requires a clean worktree"
    if ! tracked_flags="$(git -C "$PROJECT_ROOT" ls-files -v)"; then
      operational_failure "could not inspect tracked-file flags"
    fi
    if printf '%s\n' "$tracked_flags" | awk '
      { tag=substr($0, 1, 1); if (tag == "S" || tag ~ /^[a-z]$/) hidden=1 }
      END { exit !hidden }
    '; then
      safety_refusal "apply does not accept assume-unchanged or skip-worktree files"
    fi
    printf '==> complete accepted plan before writes\n' >&2
    printf '%s\n' "$(<"$DIFF_FILE")" >&2
    apply_plan
    touchstone_worktree_lock_release \
      || operational_failure "$TOUCHSTONE_WORKTREE_LOCK_ERROR"
    emit_result applied
    ;;
esac
