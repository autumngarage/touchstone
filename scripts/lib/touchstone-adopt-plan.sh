# shellcheck shell=bash
# shellcheck disable=SC2034 # KEEP_PLAN is consumed by the sourcing entrypoint trap.
toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

render_contract() {
  local output="$1" name path _profile task target required command
  local setup_command="" setup_path setup_value setup_entry quoted_path
  {
    printf 'schema = 1\n\n'
    printf '[validation]\n'
    printf 'runtime = "bash"\n'
    while IFS="$(printf '\t')" read -r setup_path setup_value; do
      [ -n "$setup_path" ] || continue
      if [ "$setup_path" = . ]; then
        setup_entry="$setup_value"
      else
        printf -v quoted_path '%q' "$setup_path"
        setup_entry="(cd $quoted_path && $setup_value)"
      fi
      setup_command="${setup_command:+$setup_command && }$setup_entry"
    done <"$SETUPS_FILE"
    if [ -n "$setup_command" ]; then
      printf 'setup = "%s"\n' "$(toml_escape "$setup_command")"
    fi
    while IFS="$(printf '\t')" read -r name path _profile; do
      [ -n "$name" ] || continue
      printf '\n[[validation.targets]]\n'
      printf 'name = "%s"\n' "$(toml_escape "$name")"
      printf 'path = "%s"\n' "$(toml_escape "$path")"
    done <"$TARGETS_FILE"
    while IFS="$(printf '\t')" read -r task target required command; do
      [ -n "$task" ] || continue
      printf '\n[[validation.tasks]]\n'
      printf 'name = "%s"\n' "$(toml_escape "$task")"
      printf 'target = "%s"\n' "$(toml_escape "$target")"
      printf 'command = "%s"\n' "$(toml_escape "$command")"
      printf 'required = %s\n' "$required"
    done <"$TASKS_FILE"
  } >"$output" || operational_failure "could not render .touchstone.toml"
}

render_tracker_contract() {
  local output="$1"
  {
    printf 'schema = 1\n'
    printf 'type = "%s"\n' "$(toml_escape "$TRACKER_TYPE")"
    if [ "$TRACKER_TYPE" = linear ]; then
      printf 'key_prefix = "%s"\n' "$(toml_escape "$TRACKER_PREFIX")"
    fi
  } >"$output" || operational_failure "could not render .touchstone-tracker.toml"
}

safe_managed_path() {
  local relative="$1" destination parent
  valid_plan_path "$relative" || contract_refusal "managed path escapes the repository: $relative"
  destination="$PROJECT_ROOT/$relative"
  [ ! -L "$destination" ] || contract_refusal "managed path is a symlink: $relative"
  parent="$(dirname "$destination")"
  while [ "$parent" != "$PROJECT_ROOT" ] && [ "$parent" != / ]; do
    [ ! -L "$parent" ] \
      || contract_refusal "managed path traverses a symlink: ${parent#"$PROJECT_ROOT"/}"
    [ ! -e "$parent" ] || [ -d "$parent" ] \
      || contract_refusal "managed path traverses a non-directory: ${parent#"$PROJECT_ROOT"/}"
    parent="$(dirname "$parent")"
  done
}

require_managed_output_available() {
  local relative="$1" status=0
  safe_managed_path "$relative"
  if git -C "$PROJECT_ROOT" check-ignore -q -- "$relative"; then
    contract_refusal "managed output is ignored: $relative"
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || operational_failure "could not inspect ignore state for $relative"
  if [ -e "$PROJECT_ROOT/$relative" ]; then
    [ -f "$PROJECT_ROOT/$relative" ] || contract_refusal "managed path is not a regular file: $relative"
    git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
      || contract_refusal "existing managed output is not tracked: $relative"
  fi
}

plan_file() {
  local relative="$1" proposed="$2" ownership="$3" action old_file new_file destination
  require_managed_output_available "$relative"
  destination="$PROJECT_ROOT/$relative"
  old_file="$PLAN_ROOT/old/$relative"
  new_file="$PLAN_ROOT/new/$relative"
  mkdir -p "$(dirname "$old_file")" "$(dirname "$new_file")" \
    || operational_failure "could not stage plan directories for $relative"
  if [ -e "$destination" ]; then
    cp -p "$destination" "$old_file" || operational_failure "could not snapshot $relative"
    action=update
    cp -p "$destination" "$new_file" || operational_failure "could not preserve metadata for $relative"
    cp "$proposed" "$new_file" || operational_failure "could not stage proposed $relative"
  else
    : >"$old_file" || operational_failure "could not stage empty snapshot for $relative"
    action=create
    cp -p "$proposed" "$new_file" || operational_failure "could not stage proposed $relative"
  fi
  cmp -s "$old_file" "$new_file" && return 0
  printf '%s\t%s\t%s\n' "$action" "$relative" "$ownership" >>"$CHANGES_FILE" \
    || operational_failure "could not record planned change for $relative"
}

plan_managed_file() {
  local relative="$1" proposed="$2" refresh="$3"
  require_managed_output_available "$relative"
  if [ "$refresh" = true ] || [ ! -e "$PROJECT_ROOT/$relative" ]; then
    plan_file "$relative" "$proposed" touchstone-managed
  fi
}

git_plan_diff() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 \
    GIT_ATTR_NOSYSTEM=1 GIT_DIFF_OPTS='' \
    git -c core.attributesFile=/dev/null -c diff.algorithm=myers \
    -c diff.indentHeuristic=false -c diff.compactionHeuristic=false \
    -c diff.renames=false -c core.quotePath=true -c diff.mnemonicPrefix=false \
    diff --no-textconv "$@"
}

render_plan_diff() {
  local action relative _ownership diff_status renderer_status
  local -a pipeline_status
  : >"$DIFF_FILE" || operational_failure "could not initialize adoption diff"
  while IFS="$(printf '\t')" read -r action relative _ownership; do
    [ -n "$relative" ] || continue
    set +e
    if [ "$action" = create ]; then
      (
        cd "$PLAN_ROOT"
        git_plan_diff --no-index --no-ext-diff --no-color --unified=3 \
          --src-prefix=a/ --dst-prefix=b/ -- /dev/null "new/$relative"
      ) | sed -e 's#^diff --git a/new/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    else
      (
        cd "$PLAN_ROOT"
        git_plan_diff --no-index --no-ext-diff --no-color --unified=3 \
          --src-prefix=a/ --dst-prefix=b/ -- "old/$relative" "new/$relative"
      ) | sed -e 's#^diff --git a/old/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^--- a/old/#--- a/#' -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    diff_status=${pipeline_status[0]}
    renderer_status=${pipeline_status[1]}
    set -e
    case "$diff_status" in 0 | 1) ;; *) operational_failure "could not render diff for $relative" ;; esac
    [ "$renderer_status" -eq 0 ] || operational_failure "could not render diff for $relative"
  done <"$CHANGES_FILE"
}

restore_plan_after_failure() {
  local action relative _ownership destination old_file new_file restore_failed=false
  local sorted_directories="$PLAN_ROOT/created-dirs-sorted"
  while IFS="$(printf '\t')" read -r action relative _ownership; do
    [ -n "$relative" ] || continue
    destination="$PROJECT_ROOT/$relative"
    old_file="$PLAN_ROOT/old/$relative"
    new_file="$PLAN_ROOT/new/$relative"
    if [ "$action" = create ]; then
      [ ! -e "$destination" ] && [ ! -L "$destination" ] && continue
      if [ -f "$destination" ] && cmp -s "$destination" "$new_file"; then
        rm -f -- "$destination" || restore_failed=true
      else
        restore_failed=true
      fi
    else
      if [ -f "$destination" ] && cmp -s "$destination" "$old_file"; then
        continue
      fi
      if { [ ! -e "$destination" ] && [ ! -L "$destination" ]; } \
        || { [ -f "$destination" ] && cmp -s "$destination" "$new_file"; }; then
        mkdir -p "$(dirname "$destination")" || restore_failed=true
        cp -p "$old_file" "$destination" || restore_failed=true
      else
        restore_failed=true
      fi
    fi
  done <"$CHANGES_FILE"
  awk '
      !seen[$0]++ { path[++count] = $0 }
      END {
        for (left = 1; left <= count; left++)
          for (right = left + 1; right <= count; right++)
            if (length(path[right]) > length(path[left])) {
              swap = path[left]; path[left] = path[right]; path[right] = swap
            }
        for (position = 1; position <= count; position++) print path[position]
      }
    ' "$CREATED_DIRS_FILE" >"$sorted_directories" || restore_failed=true
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    [ ! -d "$PROJECT_ROOT/$relative" ] \
      || rmdir -- "$PROJECT_ROOT/$relative" || restore_failed=true
  done <"$sorted_directories"
  [ "$restore_failed" = false ]
}

capture_missing_directories() {
  local action relative _ownership parent relative_parent
  : >"$CREATED_DIRS_FILE" || operational_failure "could not initialize apply recovery state"
  while IFS="$(printf '\t')" read -r action relative _ownership; do
    [ -n "$relative" ] || continue
    parent="$(dirname "$PROJECT_ROOT/$relative")"
    while [ "$parent" != "$PROJECT_ROOT" ]; do
      [ -e "$parent" ] && break
      relative_parent="${parent#"$PROJECT_ROOT"/}"
      printf '%s\n' "$relative_parent" >>"$CREATED_DIRS_FILE" \
        || operational_failure "could not record apply recovery directory"
      parent="$(dirname "$parent")"
    done
  done <"$CHANGES_FILE"
}

apply_plan() {
  local apply_output apply_status=0 action relative _ownership destination
  capture_missing_directories
  git -C "$PROJECT_ROOT" apply --check "$DIFF_FILE" >/dev/null 2>&1 \
    || safety_refusal "repository bytes changed after planning; run adoption again"
  apply_output="$(git -C "$PROJECT_ROOT" apply "$DIFF_FILE" 2>&1)" || apply_status=$?
  if [ "$apply_status" -ne 0 ]; then
    if ! restore_plan_after_failure; then
      KEEP_PLAN=true
      operational_failure "apply failed and unexpected concurrent content was preserved; recovery snapshots remain at $PLAN_ROOT"
    fi
    operational_failure "apply failed without retaining a partial Touchstone write: $apply_output"
  fi
  while IFS="$(printf '\t')" read -r action relative _ownership; do
    [ -n "$relative" ] || continue
    destination="$PROJECT_ROOT/$relative"
    if [ ! -f "$destination" ] || ! cmp -s "$destination" "$PLAN_ROOT/new/$relative"; then
      if ! restore_plan_after_failure; then
        KEEP_PLAN=true
        operational_failure "applied bytes could not be verified and recovery requires $PLAN_ROOT"
      fi
      operational_failure "applied bytes could not be verified; the original files were restored"
    fi
  done <"$CHANGES_FILE"
}
