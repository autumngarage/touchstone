#!/usr/bin/env bash
#
# scripts/touchstone-adopt.sh — compile repository facts into an adoption plan.
#
# Detectors are read-only adapters. They write records into one common plan
# model; only apply_plan writes repository files.

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
  touchstone adopt [--check|--dry-run] [--json] [--project DIR] [--task NAME=COMMAND]
EOF
  else
    cat <<'EOF'
Usage:
  touchstone upgrade [--check|--dry-run] [--json] [--project DIR]
EOF
  fi
}

MODE=apply
JSON_MODE=false
PROJECT_ARG=""
MANUAL_TASK_ARGS=()

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

PLAN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-adopt.XXXXXX")" || {
  echo "ERROR: could not create adoption workspace" >&2
  exit 6
}
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
mkdir -p "$OLD_ROOT" "$NEW_ROOT" || {
  echo "ERROR: could not initialize adoption workspace" >&2
  exit 6
}
: >"$TARGETS_FILE"
: >"$TASKS_FILE"
: >"$SETUPS_FILE"
: >"$CHANGES_FILE"
: >"$DIFF_FILE"

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
  local status="$1" first=true action path ownership
  printf '{"schema":1,"operation":'
  json_string "$OPERATION"
  printf ',"status":'
  json_string "$status"
  printf ',"profile":'
  json_string "$PROFILE"
  printf ',"changes":['
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
  printf '],"remotePolicy":{"status":"separate-operation","required":true,"mutated":false},"diff":'
  json_string "$(cat "$DIFF_FILE")"
  if [ -n "$REFUSAL_REASON" ]; then
    printf ',"reason":'
    json_string "$REFUSAL_REASON"
  fi
  printf '}\n'
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

GIT_ROOT="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$GIT_ROOT" ] || contract_refusal "adoption requires a git repository: $PROJECT_ROOT"
GIT_ROOT="$(cd "$GIT_ROOT" 2>/dev/null && pwd -P)" \
  || operational_failure "could not resolve git repository root: $GIT_ROOT"
PROJECT_ROOT="$GIT_ROOT"

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

# Profile adapters are sourced as separate reviewable compiler units.
# shellcheck source=/dev/null
for adapter in parsers node python native; do
  adapter_path="$SCRIPT_ROOT/scripts/lib/touchstone-adopt-$adapter.sh"
  if [ -f "$adapter_path" ]; then
    . "$adapter_path"
  fi
done
unset adapter adapter_path

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

compile_legacy() {
  local file="$PROJECT_ROOT/.touchstone-config" configured_profile command key found=false
  configured_profile="$(legacy_value project_type "$file")"
  for key in validate_command validate_full_command; do
    command="$(legacy_value "$key" "$file")"
    if [ -n "$command" ]; then
      record_target root . "${configured_profile:-legacy}"
      record_task validate root "$command"
      PROFILE="legacy-${configured_profile:-manual}"
      return 0
    fi
  done
  record_target root . "${configured_profile:-legacy}"
  for key in lint_command typecheck_command test_command build_command; do
    command="$(legacy_value "$key" "$file")"
    if [ -n "$command" ]; then
      record_task "${key%_command}" root "$command"
      found=true
    fi
  done
  if [ "$found" = true ]; then
    PROFILE="legacy-${configured_profile:-manual}"
    return 0
  fi
  case "$configured_profile" in
    node | python | swift | rust | go) PROFILE="$configured_profile" ;;
    generic | "" | auto) PROFILE="$(detect_profile "$PROJECT_ROOT")" ;;
    *) contract_refusal "legacy .touchstone-config declares unsupported project_type '$configured_profile'" ;;
  esac
  tasks_for_profile "$PROJECT_ROOT" root "$PROFILE" ""
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

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

render_contract() {
  local output="$1" name path _profile task target required command setup_command="" setup_entry quoted_path
  while IFS="$(printf '\t')" read -r path command; do
    [ -n "$path" ] || continue
    if [ "$path" = . ]; then
      setup_entry="$command"
    else
      printf -v quoted_path '%q' "$path"
      setup_entry="(cd $quoted_path && $command)"
    fi
    setup_command="${setup_command:+$setup_command && }$setup_entry"
  done <"$SETUPS_FILE"
  {
    printf 'schema = 1\n\n'
    printf '[validation]\n'
    printf 'runtime = "bash"\n'
    if [ -n "$setup_command" ]; then
      printf 'setup = "%s"\n' "$(toml_escape "$setup_command")"
    fi
    while IFS="$(printf '\t')" read -r name path _profile; do
      printf '\n[[validation.targets]]\n'
      printf 'name = "%s"\n' "$(toml_escape "$name")"
      printf 'path = "%s"\n' "$(toml_escape "$path")"
    done <"$TARGETS_FILE"
    while IFS="$(printf '\t')" read -r task target required command; do
      printf '\n[[validation.tasks]]\n'
      printf 'name = "%s"\n' "$(toml_escape "$task")"
      printf 'target = "%s"\n' "$(toml_escape "$target")"
      printf 'command = "%s"\n' "$(toml_escape "$command")"
      printf 'required = %s\n' "$required"
    done <"$TASKS_FILE"
  } >"$output"
}

safe_owned_path() {
  local relative="$1" destination parent
  destination="$PROJECT_ROOT/$relative"
  valid_relative_path "$relative" || contract_refusal "managed path escapes the repository: $relative"
  if [ -L "$destination" ]; then
    contract_refusal "managed path is a symlink: $relative"
  fi
  parent="$(dirname "$destination")"
  while [ "$parent" != "$PROJECT_ROOT" ] && [ "$parent" != / ]; do
    if [ -L "$parent" ]; then
      contract_refusal "managed path traverses a symlink: ${parent#"$PROJECT_ROOT"/}"
    fi
    parent="$(dirname "$parent")"
  done
}

plan_file() {
  local relative="$1" proposed="$2" ownership="$3" action destination old_file new_file
  safe_owned_path "$relative"
  destination="$PROJECT_ROOT/$relative"
  old_file="$OLD_ROOT/$relative"
  new_file="$NEW_ROOT/$relative"
  mkdir -p "$(dirname "$old_file")" "$(dirname "$new_file")" \
    || operational_failure "could not stage the plan for $relative"
  if [ -e "$destination" ]; then
    [ -f "$destination" ] || contract_refusal "managed path is not a regular file: $relative"
    cp -p "$destination" "$old_file" || operational_failure "could not read $relative"
    action=update
  else
    : >"$old_file"
    action=create
  fi
  if [ -e "$destination" ]; then
    if ! cp -p "$destination" "$new_file" || ! cat "$proposed" >"$new_file"; then
      operational_failure "could not stage proposed content for $relative"
    fi
  else
    cp -p "$proposed" "$new_file" || operational_failure "could not stage proposed content for $relative"
  fi
  if cmp -s "$old_file" "$new_file"; then return 0; fi
  printf '%s\t%s\t%s\n' "$action" "$relative" "$ownership" >>"$CHANGES_FILE"
}

plan_managed_file() {
  local relative="$1" proposed="$2" refresh="$3"
  if [ "$refresh" = true ] || [ ! -e "$PROJECT_ROOT/$relative" ]; then
    plan_file "$relative" "$proposed" touchstone-managed
    return 0
  fi
  safe_owned_path "$relative"
  [ -f "$PROJECT_ROOT/$relative" ] || contract_refusal "managed path is not a regular file: $relative"
}

render_consumer_markdown() {
  local source="$1" output="$2"
  sed \
    -e 's#Use the `touchstone-audit-weak-points` skill (Claude) or read `principles/audit-weak-points.md` (other drivers)\.#Read `principles/audit-weak-points.md`.#' \
    -e '/^Claude Code agents: the bundled `touchstone-\*` and `memory-audit` skills mirror this table in your session header\. Trust whichever surface fires first\.$/d' \
    -e 's#Use the `touchstone-audit-weak-points` skill\.#Follow the procedure in `principles/audit-weak-points.md`.#' \
    -e 's#^Claude Code agents have the `memory-audit` skill for this\. Run it when a$#Run this audit when a#' \
    -e 's#^user never agreed to the change\. Drivers without the `memory-audit` skill owe$#user never agreed to the change. Every driver owes#' \
    -e 's#principles/#.touchstone/principles/#g' \
    "$source" >"$output" || operational_failure "could not render consumer steering"
}

render_consumer_steering() {
  local output="$1"
  render_consumer_markdown "$SCRIPT_ROOT/TOUCHSTONE.md" "$output"
}

render_inline_block() {
  local steering="$1" output="$2"
  {
    printf '%s\n\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    printf '\n'
    cat "$steering"
    printf '\n%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output"
}

render_claude_block() {
  local output="$1"
  {
    printf '%s\n\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    printf '\n## Touchstone universal steering\n\n'
    printf '@.touchstone/TOUCHSTONE.md\n\n'
    printf '%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output"
}

merge_managed_block() {
  local destination="$1" block="$2" output="$3" default_heading="$4"
  local begin_count end_count begin_line end_line in_block=false inserted=false line comparison terminated
  if [ ! -e "$destination" ]; then
    {
      printf '# %s\n\n' "$default_heading"
      cat "$block"
    } >"$output"
    return 0
  fi
  [ -f "$destination" ] || contract_refusal "steering path is not a regular file: ${destination#"$PROJECT_ROOT"/}"
  begin_count="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  end_count="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  if [ "$begin_count" -ne "$end_count" ] || [ "$begin_count" -gt 1 ]; then
    contract_refusal "steering markers are malformed in ${destination#"$PROJECT_ROOT"/}"
  fi
  if [ "$begin_count" -eq 0 ]; then
    cat "$block" >"$output"
    if [ -s "$destination" ]; then
      printf '\n' >>"$output"
      cat "$destination" >>"$output"
    fi
    return 0
  fi
  begin_line="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  end_line="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  if [ "$begin_line" -ge "$end_line" ]; then
    contract_refusal "steering markers are out of order in ${destination#"$PROJECT_ROOT"/}"
  fi
  while true; do
    line=""
    if IFS= read -r line; then
      terminated=true
    else
      [ -n "$line" ] || break
      terminated=false
    fi
    comparison="${line%"$CR"}"
    if [ "$in_block" = true ]; then
      if [ "$comparison" = "$TOUCHSTONE_BLOCK_END" ]; then in_block=false; fi
      continue
    fi
    if [ "$comparison" = "$TOUCHSTONE_BLOCK_BEGIN" ]; then
      if [ "$inserted" = false ]; then
        cat "$block" >>"$output"
        inserted=true
      fi
      in_block=true
      continue
    fi
    if [ "$terminated" = true ]; then printf '%s\n' "$line" >>"$output"; else printf '%s' "$line" >>"$output"; fi
  done <"$destination"
}

managed_block_present() {
  local relative="$1" destination
  local begin_count end_count begin_line end_line
  destination="$PROJECT_ROOT/$relative"
  safe_owned_path "$relative"
  [ -e "$destination" ] || return 1
  [ -f "$destination" ] || contract_refusal "steering path is not a regular file: $relative"
  begin_count="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  end_count="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  if [ "$begin_count" -ne "$end_count" ] || [ "$begin_count" -gt 1 ]; then
    contract_refusal "steering markers are malformed in $relative"
  fi
  [ "$begin_count" -eq 1 ] || return 1
  begin_line="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  end_line="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  [ "$begin_line" -lt "$end_line" ] || contract_refusal "steering markers are out of order in $relative"
  return 0
}

plan_steering() {
  local refresh="$1"
  local consumer="$PLAN_ROOT/consumer-touchstone.md" inline="$PLAN_ROOT/inline-block.md"
  local claude="$PLAN_ROOT/claude-block.md" proposed file relative rendered_principle
  render_consumer_steering "$consumer"
  plan_managed_file .touchstone/TOUCHSTONE.md "$consumer" "$refresh"
  for file in "$SCRIPT_ROOT"/principles/*.md; do
    [ "$(basename "$file")" != README.md ] || continue
    relative=".touchstone/principles/$(basename "$file")"
    rendered_principle="$PLAN_ROOT/principle-$(basename "$file")"
    render_consumer_markdown "$file" "$rendered_principle"
    plan_managed_file "$relative" "$rendered_principle" "$refresh"
  done
  render_inline_block "$consumer" "$inline"
  render_claude_block "$claude"
  for file in AGENTS.md GEMINI.md; do
    if [ "$refresh" = false ] && managed_block_present "$file"; then continue; fi
    proposed="$PLAN_ROOT/proposed-$file"
    : >"$proposed"
    merge_managed_block "$PROJECT_ROOT/$file" "$inline" "$proposed" "$file instructions"
    plan_file "$file" "$proposed" marked-block
  done
  if [ "$refresh" = false ] && managed_block_present CLAUDE.md; then return 0; fi
  proposed="$PLAN_ROOT/proposed-CLAUDE.md"
  : >"$proposed"
  merge_managed_block "$PROJECT_ROOT/CLAUDE.md" "$claude" "$proposed" "Claude Code instructions"
  plan_file CLAUDE.md "$proposed" marked-block
}

render_diff() {
  local action path ownership diff_status renderer_status
  local -a pipeline_status
  : >"$DIFF_FILE"
  while IFS="$(printf '\t')" read -r action path ownership; do
    [ -n "$path" ] || continue
    set +e
    if [ "$action" = create ]; then
      (
        cd "$PLAN_ROOT"
        git diff --no-index --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -- /dev/null "new/$path"
      ) | sed \
        -e 's#^diff --git a/new/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    else
      (
        cd "$PLAN_ROOT"
        git diff --no-index --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -- "old/$path" "new/$path"
      ) | sed \
        -e 's#^diff --git a/old/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^--- a/old/#--- a/#' \
        -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    diff_status=${pipeline_status[0]}
    renderer_status=${pipeline_status[1]}
    set -e
    case "$diff_status" in 0 | 1) ;; *)
      echo "ERROR: could not render proposed diff for $path" >&2
      exit 6
      ;;
    esac
    if [ "$renderer_status" -ne 0 ]; then
      echo "ERROR: could not render proposed diff for $path" >&2
      exit 6
    fi
  done <"$CHANGES_FILE"
}

extract_schema() {
  awk '
    /^[[:space:]]*\[/ { in_root = 0 }
    BEGIN { in_root = 1 }
    in_root && /^[[:space:]]*schema[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*(#.*)?$/, "", value)
      print value
    }
  ' "$1"
}

validate_existing_contract() {
  local schema_output validation_output status
  [ ! -L "$PROJECT_ROOT/.touchstone.toml" ] || contract_refusal ".touchstone.toml must be a regular file inside the repository"
  schema_output="$(extract_schema "$PROJECT_ROOT/.touchstone.toml")"
  [ "$schema_output" = 1 ] || contract_refusal "unsupported or ambiguous .touchstone.toml schema '$schema_output'; this CLI accepts schema 1"
  set +e
  validation_output="$(bash "$SCRIPT_ROOT/scripts/touchstone-run.sh" validate --check-contract --project "$PROJECT_ROOT" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 0 ] || contract_refusal "existing .touchstone.toml is invalid: $validation_output"
}

require_tracked_compiler_input() {
  local path="$1"
  [ ! -L "$PROJECT_ROOT/$path" ] \
    || contract_refusal "adoption compiler input '$path' must be a regular file inside the repository"
  [ ! -e "$PROJECT_ROOT/$path" ] || require_tracked_compiler_path "$path"
}

require_tracked_compiler_path() {
  local path="$1"
  git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 \
    || contract_refusal "adoption compiler input '$path' is not tracked; commit it or remove it before planning"
}

require_compiler_inputs_tracked() {
  local directory relative name resolved_directory resolved_relative
  local -a inputs=(
    .touchstone.toml .touchstone-config AGENTS.md CLAUDE.md GEMINI.md TOUCHSTONE.md
    package.json package-lock.json npm-shrinkwrap.json pnpm-lock.yaml pnpm-workspace.yaml yarn.lock .yarnrc.yml bun.lock bun.lockb tsconfig.json
    pyproject.toml setup.py setup.cfg uv.lock requirements.txt Package.swift Package.resolved Cargo.toml Cargo.lock go.mod go.sum go.work go.work.sum
  )
  for name in "${inputs[@]}"; do require_tracked_compiler_input "$name"; done
  for directory in apps packages services; do
    [ -d "$PROJECT_ROOT/$directory" ] || continue
    for relative in "$PROJECT_ROOT/$directory"/*; do
      [ -d "$relative" ] || continue
      if [ -L "$relative" ]; then
        relative="${relative#"$PROJECT_ROOT"/}"
        require_tracked_compiler_path "$relative"
        resolved_directory="$(cd "$PROJECT_ROOT/$relative" 2>/dev/null && pwd -P)" \
          || contract_refusal "could not resolve monorepo target $relative"
        case "$resolved_directory" in
          "$PROJECT_ROOT") continue ;;
          "$PROJECT_ROOT"/*)
            resolved_relative="${resolved_directory#"$PROJECT_ROOT"/}"
            for name in "${inputs[@]}"; do require_tracked_compiler_input "$resolved_relative/$name"; done
            continue
            ;;
          *) continue ;;
        esac
      fi
      relative="${relative#"$PROJECT_ROOT"/}"
      for name in "${inputs[@]}"; do require_tracked_compiler_input "$relative/$name"; done
    done
  done
  if [ -d "$PROJECT_ROOT/.touchstone" ]; then
    while IFS= read -r relative; do
      [ -n "$relative" ] || continue
      relative="${relative#"$PROJECT_ROOT"/}"
      require_tracked_compiler_input "$relative"
    done < <(find "$PROJECT_ROOT/.touchstone" -type f -print)
  fi
}

compile_plan() {
  local proposed_contract="$PLAN_ROOT/proposed-contract.toml" contract_existed=false
  require_compiler_inputs_tracked
  if [ -f "$PROJECT_ROOT/.touchstone.toml" ]; then
    [ "${#MANUAL_TASK_ARGS[@]}" -eq 0 ] || contract_refusal "--task cannot replace an existing .touchstone.toml declaration"
    validate_existing_contract
    PROFILE="declared-v1"
    contract_existed=true
  elif [ "$OPERATION" = upgrade ]; then
    contract_refusal "repository is not adopted; run touchstone adopt first"
  else
    if [ "${#MANUAL_TASK_ARGS[@]}" -gt 0 ]; then
      compile_manual_tasks
    elif [ -f "$PROJECT_ROOT/.touchstone-config" ]; then
      compile_legacy
    else
      compile_detected
    fi
    render_contract "$proposed_contract"
    plan_file .touchstone.toml "$proposed_contract" project-contract
  fi
  if [ "$OPERATION" = upgrade ]; then
    plan_steering true
  elif [ "$contract_existed" = true ]; then
    plan_steering false
  else
    plan_steering true
  fi
  if [ -s "$CHANGES_FILE" ]; then PLAN_STATUS=changes-required; else PLAN_STATUS=current; fi
  render_diff
}

current_branch_is_default() {
  local branch remote_default=""
  branch="$(git -C "$PROJECT_ROOT" branch --show-current)" \
    || operational_failure "could not read the current branch"
  [ -n "$branch" ] || return 0
  remote_default="$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  remote_default="${remote_default#origin/}"
  case "$branch" in main | master) return 0 ;; esac
  [ -n "$remote_default" ] || return 2
  [ "$branch" = "$remote_default" ]
}

apply_plan() {
  local action path ownership destination source old_source parent temporary worktree_status default_status backup
  local expected_hash expected_mode current_hash current_mode
  local stage_file="$APPLY_STAGE_FILE" applied_file="$APPLY_APPLIED_FILE" directories_file="$APPLY_DIRECTORIES_FILE"
  [ -s "$CHANGES_FILE" ] || return 0
  worktree_status="$(git -C "$PROJECT_ROOT" status --porcelain=v1)" \
    || operational_failure "could not inspect worktree state"
  [ -z "$worktree_status" ] || safety_refusal "apply requires a clean worktree"
  if current_branch_is_default; then
    safety_refusal "apply requires a non-default branch"
  else
    default_status=$?
    [ "$default_status" -eq 1 ] \
      || safety_refusal "apply requires a known default branch; set refs/remotes/origin/HEAD before applying"
  fi
  : >"$stage_file"
  : >"$applied_file"
  : >"$directories_file"
  APPLY_ACTIVE=true
  while IFS="$(printf '\t')" read -r action path ownership; do
    [ -n "$path" ] || continue
    safe_owned_path "$path"
    destination="$PROJECT_ROOT/$path"
    source="$NEW_ROOT/$path"
    old_source="$OLD_ROOT/$path"
    parent="$(dirname "$destination")"
    record_missing_directories "$parent" "$directories_file"
    if ! mkdir -p "$parent"; then
      cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
        || operational_failure "could not clean transaction files after creating $parent failed"
      operational_failure "could not create $parent"
    fi
    temporary="$(mktemp "$parent/.touchstone-write.XXXXXX")" || {
      cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
        || operational_failure "could not clean transaction files after staging $path failed"
      operational_failure "could not stage $path"
    }
    expected_hash=-
    expected_mode=-
    if [ "$action" = update ]; then
      [ -f "$destination" ] && [ ! -L "$destination" ] || {
        rm -f "$temporary"
        cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
          || operational_failure "could not clean transaction files after $path changed during staging"
        operational_failure "$path changed during staging"
      }
      if ! expected_hash="$(git hash-object "$old_source")"; then
        rm -f "$temporary"
        cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
          || operational_failure "could not clean transaction files after snapshotting $path failed"
        operational_failure "could not read the planned snapshot for $path"
      fi
      if ! expected_mode="$(LC_ALL=C ls -ld "$old_source" | awk '{ print $1 }')"; then
        rm -f "$temporary"
        cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
          || operational_failure "could not clean transaction files after snapshotting $path metadata failed"
        operational_failure "could not read the planned metadata for $path"
      fi
      if ! current_hash="$(git hash-object "$destination")" \
        || ! current_mode="$(LC_ALL=C ls -ld "$destination" | awk '{ print $1 }')"; then
        rm -f "$temporary"
        cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
          || operational_failure "could not clean transaction files after rechecking $path failed"
        operational_failure "could not recheck $path before apply"
      fi
      if [ "$current_hash" != "$expected_hash" ] || [ "$current_mode" != "$expected_mode" ]; then
        rm -f "$temporary"
        cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
          || operational_failure "could not clean transaction files after $path changed since planning"
        operational_failure "$path changed since planning"
      fi
    fi
    if ! printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$destination" "$temporary" "$expected_hash" "$expected_mode" >>"$stage_file"; then
      rm -f "$temporary"
      cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
        || operational_failure "could not clean transaction files after recording $path failed"
      operational_failure "could not record staged write for $path"
    fi
    if [ -e "$destination" ]; then
      if ! cp -p "$destination" "$temporary" || ! cat "$source" >"$temporary"; then
        rm -f "$temporary"
        cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
          || operational_failure "could not clean transaction files after staging $path failed"
        operational_failure "could not stage $path"
      fi
    elif ! cp -p "$source" "$temporary"; then
      rm -f "$temporary"
      cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" \
        || operational_failure "could not clean transaction files after staging $path failed"
      operational_failure "could not stage $path"
    fi
  done <"$CHANGES_FILE"

  while IFS="$(printf '\t')" read -r action destination temporary expected_hash expected_mode; do
    path="${destination#"$PROJECT_ROOT"/}"
    backup=-
    if [ "$action" = update ]; then
      [ -f "$destination" ] && [ ! -L "$destination" ] || {
        rollback_apply "$applied_file" "$stage_file" "$directories_file" \
          || operational_failure "could not roll back after $path changed during apply"
        operational_failure "$path changed during apply"
      }
      if ! current_hash="$(git hash-object "$destination")"; then
        rollback_apply "$applied_file" "$stage_file" "$directories_file" \
          || operational_failure "could not roll back after rechecking $path failed"
        operational_failure "could not recheck $path during apply"
      fi
      if ! current_mode="$(LC_ALL=C ls -ld "$destination" | awk '{ print $1 }')"; then
        rollback_apply "$applied_file" "$stage_file" "$directories_file" \
          || operational_failure "could not roll back after rechecking $path metadata failed"
        operational_failure "could not recheck $path metadata during apply"
      fi
      if [ "$current_hash" != "$expected_hash" ] || [ "$current_mode" != "$expected_mode" ]; then
        rollback_apply "$applied_file" "$stage_file" "$directories_file" \
          || operational_failure "could not roll back after $path changed during apply"
        operational_failure "$path changed during apply"
      fi
      backup="$(mktemp "$(dirname "$destination")/.touchstone-backup.XXXXXX")" || {
        rollback_apply "$applied_file" "$stage_file" "$directories_file" \
          || operational_failure "could not roll back after staging $path failed"
        operational_failure "could not stage rollback data for $path"
      }
      rm -f "$backup" || operational_failure "could not prepare rollback path for $path"
    elif [ -e "$destination" ] || [ -L "$destination" ]; then
      rollback_apply "$applied_file" "$stage_file" "$directories_file" \
        || operational_failure "could not roll back after $path appeared during apply"
      operational_failure "$path appeared during apply"
    fi
    if ! printf '%s\t%s\t%s\n' "$action" "$destination" "$backup" >>"$applied_file"; then
      rollback_apply "$applied_file" "$stage_file" "$directories_file" \
        || operational_failure "could not roll back after transaction recording failed for $path"
      operational_failure "could not record applied write for $path"
    fi
    if [ "$action" = update ]; then
      if ! mv "$destination" "$backup"; then
        rollback_apply "$applied_file" "$stage_file" "$directories_file" \
          || operational_failure "could not roll back after backing up $path failed"
        operational_failure "could not prepare $path for apply"
      fi
    fi
    if ! mv "$temporary" "$destination"; then
      rollback_apply "$applied_file" "$stage_file" "$directories_file" \
        || operational_failure "could not roll back failed apply of $path"
      operational_failure "could not apply $path; all earlier writes were rolled back"
    fi
  done <"$stage_file"
  trap '' HUP INT TERM
  if ! cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file"; then
    APPLY_ACTIVE=false
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    operational_failure "adoption applied but temporary transaction files could not be removed"
  fi
  APPLY_ACTIVE=false
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

record_missing_directories() {
  local directory="$1" output="$2" missing="" entry
  while [ "$directory" != "$PROJECT_ROOT" ] && [ ! -e "$directory" ]; do
    missing="${missing}${missing:+$LF}${directory}"
    directory="$(dirname "$directory")"
  done
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    grep -Fqx "$entry" "$output" 2>/dev/null || printf '%s\n' "$entry" >>"$output"
  done < <(printf '%s\n' "$missing" | awk '{ lines[NR] = $0 } END { for (line = NR; line >= 1; line--) print lines[line] }')
}

cleanup_apply_artifacts() {
  local stage_file="$1" applied_file="$2" directories_file="$3" action destination artifact expected_hash expected_mode failed=false directory
  if [ -f "$stage_file" ]; then
    while IFS="$(printf '\t')" read -r action destination artifact expected_hash expected_mode; do
      [ -z "${artifact:-}" ] || [ ! -e "$artifact" ] || rm -f "$artifact" || failed=true
    done <"$stage_file"
  fi
  if [ -f "$applied_file" ]; then
    while IFS="$(printf '\t')" read -r action destination artifact; do
      [ "${artifact:-}" = - ] || [ -z "${artifact:-}" ] || [ ! -e "$artifact" ] || rm -f "$artifact" || failed=true
    done <"$applied_file"
  fi
  if [ -f "$directories_file" ]; then
    while IFS= read -r directory; do
      [ ! -d "$directory" ] || rmdir "$directory" 2>/dev/null || true
    done < <(awk '{ lines[NR] = $0 } END { for (line = NR; line >= 1; line--) print lines[line] }' "$directories_file")
  fi
  [ "$failed" = false ]
}

rollback_apply() {
  local applied_file="$1" stage_file="$2" directories_file="$3" action destination backup failed=false
  if [ -f "$applied_file" ]; then
    while IFS="$(printf '\t')" read -r action destination backup; do
      if [ "$action" = create ]; then
        [ ! -e "$destination" ] || rm -f "$destination" || failed=true
      else
        if [ -e "$backup" ]; then
          [ ! -e "$destination" ] || rm -f "$destination" || failed=true
          mv "$backup" "$destination" || failed=true
        fi
      fi
    done < <(awk '{ lines[NR] = $0 } END { for (line = NR; line >= 1; line--) print lines[line] }' "$applied_file")
  fi
  cleanup_apply_artifacts "$stage_file" "$applied_file" "$directories_file" || failed=true
  : >"$applied_file" || failed=true
  [ "$failed" = false ]
}

compile_plan

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
