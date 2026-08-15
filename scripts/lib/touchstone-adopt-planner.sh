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
  local block_consumer claude="$PLAN_ROOT/claude-block.md" proposed file relative rendered_principle
  render_consumer_steering "$consumer"
  plan_managed_file .touchstone/TOUCHSTONE.md "$consumer" "$refresh"
  block_consumer="$consumer"
  if [ "$refresh" = false ] && [ -f "$PROJECT_ROOT/.touchstone/TOUCHSTONE.md" ] \
    && [ ! -L "$PROJECT_ROOT/.touchstone/TOUCHSTONE.md" ]; then
    block_consumer="$PROJECT_ROOT/.touchstone/TOUCHSTONE.md"
  fi
  for file in "$SCRIPT_ROOT"/principles/*.md; do
    [ "$(basename "$file")" != README.md ] || continue
    relative=".touchstone/principles/$(basename "$file")"
    rendered_principle="$PLAN_ROOT/principle-$(basename "$file")"
    render_consumer_markdown "$file" "$rendered_principle"
    plan_managed_file "$relative" "$rendered_principle" "$refresh"
  done
  render_inline_block "$block_consumer" "$inline"
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
        git diff --no-index --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ -- /dev/null "new/$path"
      ) | sed \
        -e 's#^diff --git a/new/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    else
      (
        cd "$PLAN_ROOT"
        git diff --no-index --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ -- "old/$path" "new/$path"
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
    [ "${#MANUAL_TASK_ARGS[@]}" -eq 0 ] || contract_refusal "--task cannot replace an existing .touchstone.toml declaration"
    validate_existing_contract
    PROFILE="declared-v1"
    contract_existed=true
  elif [ "$OPERATION" = upgrade ]; then
    contract_refusal "repository is not adopted; run touchstone adopt first"
  else
    require_compiler_inputs_tracked
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
