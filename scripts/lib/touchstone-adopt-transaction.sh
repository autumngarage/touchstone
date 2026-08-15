# shellcheck shell=bash
# shellcheck disable=SC2034 # transaction state is consumed by the main entrypoint

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
  worktree_status="$(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)" \
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
