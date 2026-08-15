# shellcheck shell=bash
# shellcheck disable=SC2034 # status globals are consumed by the main entrypoint

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
  } >"$output" || operational_failure "could not render the adoption contract"
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
    if [ -e "$parent" ] && [ ! -d "$parent" ]; then
      contract_refusal "managed path traverses a non-directory: ${parent#"$PROJECT_ROOT"/}"
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
    : >"$old_file" || operational_failure "could not stage an empty snapshot for $relative"
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
  printf '%s\t%s\t%s\n' "$action" "$relative" "$ownership" >>"$CHANGES_FILE" \
    || operational_failure "could not record planned change for $relative"
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

git_plan_diff() {
  GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=0 \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_DIFF_OPTS='' \
    git -c core.attributesFile=/dev/null \
    -c diff.algorithm=myers \
    -c diff.indentHeuristic=false \
    -c diff.compactionHeuristic=false \
    -c diff.renames=false \
    -c core.quotePath=true \
    -c diff.mnemonicPrefix=false \
    -c diff.noprefix=false \
    diff --no-textconv "$@"
}

render_diff() {
  local action path ownership diff_status renderer_status
  local -a pipeline_status
  : >"$DIFF_FILE" || operational_failure "could not initialize the adoption diff"
  while IFS="$(printf '\t')" read -r action path ownership; do
    [ -n "$path" ] || continue
    set +e
    if [ "$action" = create ]; then
      (
        cd "$PLAN_ROOT"
        git_plan_diff --no-index --no-ext-diff --no-color --unified=3 --src-prefix=a/ --dst-prefix=b/ -- /dev/null "new/$path"
      ) | sed \
        -e 's#^diff --git a/new/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    else
      (
        cd "$PLAN_ROOT"
        git_plan_diff --no-index --no-ext-diff --no-color --unified=3 --src-prefix=a/ --dst-prefix=b/ -- "old/$path" "new/$path"
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

require_unignored_compiler_output() {
  local path="$1" status
  safe_owned_path "$path"
  if git -C "$PROJECT_ROOT" check-ignore -q -- "$path"; then
    contract_refusal "adoption compiler input '$path' is not tracked; commit it or remove it before planning"
  else
    status=$?
  fi
  [ "$status" -eq 1 ] \
    || operational_failure "could not determine whether adoption output '$path' is ignored"
}

require_compiler_inputs_tracked() {
  local directory relative name resolved_directory resolved_relative
  local -a inputs=(
    .touchstone-config
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
}

require_compiler_outputs_unignored() {
  local output
  for output in .touchstone.toml AGENTS.md CLAUDE.md GEMINI.md .touchstone/TOUCHSTONE.md; do
    require_unignored_compiler_output "$output"
  done
  for output in "$SCRIPT_ROOT"/principles/*.md; do
    [ "$(basename "$output")" != README.md ] || continue
    require_unignored_compiler_output ".touchstone/principles/$(basename "$output")"
  done
}

compile_plan() {
  local proposed_contract="$PLAN_ROOT/proposed-contract.toml" contract_existed=false
  require_compiler_outputs_unignored
  if [ -f "$PROJECT_ROOT/.touchstone.toml" ]; then
    [ "$MANUAL_TASK_COUNT" -eq 0 ] || contract_refusal "--task cannot replace an existing .touchstone.toml declaration"
    validate_existing_contract
    PROFILE="declared-v1"
    contract_existed=true
  elif [ "$OPERATION" = upgrade ]; then
    contract_refusal "repository is not adopted; run touchstone adopt first"
  else
    if [ "$MANUAL_TASK_COUNT" -gt 0 ]; then
      compile_manual_tasks
    elif [ -f "$PROJECT_ROOT/.touchstone-config" ]; then
      require_compiler_inputs_tracked
      compile_legacy
    else
      require_compiler_inputs_tracked
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
