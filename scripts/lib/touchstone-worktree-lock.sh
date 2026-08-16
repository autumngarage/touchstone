# shellcheck shell=bash
# shellcheck disable=SC2034 # public status and error globals are consumed by callers.

TOUCHSTONE_WORKTREE_LOCK_DIR=""
TOUCHSTONE_WORKTREE_INDEX_LOCK=""
TOUCHSTONE_WORKTREE_LOCK_PID=""
TOUCHSTONE_WORKTREE_LOCK_ERROR=""
TOUCHSTONE_WORKTREE_LOCK_REFUSED=10
TOUCHSTONE_WORKTREE_LOCK_FAILED=11

touchstone_worktree_lock_error() {
  TOUCHSTONE_WORKTREE_LOCK_ERROR="$1"
  return "$2"
}

touchstone_worktree_lock_remove_owner() {
  local directory="$1"
  rm -f -- "$directory/pid" "$directory/token" || return 1
  rmdir -- "$directory"
}

touchstone_worktree_lock_read_process_id() {
  local pid_file process_id=""
  pid_file="$(mktemp "${TMPDIR:-/tmp}/touchstone-worktree-pid.XXXXXX")" || return 1
  if ! /bin/sh -c 'printf "%s\n" "$PPID"' >"$pid_file" \
    || ! IFS= read -r process_id <"$pid_file"; then
    rm -f -- "$pid_file"
    return 1
  fi
  rm -f -- "$pid_file" || return 1
  case "$process_id" in '' | *[!0-9]*) return 1 ;; esac
  TOUCHSTONE_WORKTREE_PROCESS_ID="$process_id"
}

touchstone_worktree_lock_release() {
  local owner=""
  [ -n "$TOUCHSTONE_WORKTREE_LOCK_DIR" ] || return 0
  if ! touchstone_worktree_lock_read_process_id; then
    touchstone_worktree_lock_error "could not identify the releasing process" \
      "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
    return
  fi
  if [ -f "$TOUCHSTONE_WORKTREE_LOCK_DIR/pid" ] \
    && [ ! -L "$TOUCHSTONE_WORKTREE_LOCK_DIR/pid" ]; then
    IFS= read -r owner <"$TOUCHSTONE_WORKTREE_LOCK_DIR/pid" || owner=""
  fi
  if [ "$owner" != "$TOUCHSTONE_WORKTREE_LOCK_PID" ] \
    || [ "$TOUCHSTONE_WORKTREE_PROCESS_ID" != "$TOUCHSTONE_WORKTREE_LOCK_PID" ] \
    || [ ! -f "$TOUCHSTONE_WORKTREE_LOCK_DIR/token" ] \
    || [ -L "$TOUCHSTONE_WORKTREE_LOCK_DIR/token" ] \
    || [ ! -f "$TOUCHSTONE_WORKTREE_INDEX_LOCK" ] \
    || [ -L "$TOUCHSTONE_WORKTREE_INDEX_LOCK" ] \
    || [ ! "$TOUCHSTONE_WORKTREE_INDEX_LOCK" -ef "$TOUCHSTONE_WORKTREE_LOCK_DIR/token" ]; then
    TOUCHSTONE_WORKTREE_LOCK_DIR=""
    TOUCHSTONE_WORKTREE_INDEX_LOCK=""
    TOUCHSTONE_WORKTREE_LOCK_PID=""
    touchstone_worktree_lock_error \
      "Git-native worktree-lock ownership changed before release" \
      "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
    return
  fi
  if ! rm -f -- "$TOUCHSTONE_WORKTREE_INDEX_LOCK"; then
    touchstone_worktree_lock_error \
      "could not release the Git-native index lock" \
      "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
    return
  fi
  if ! touchstone_worktree_lock_remove_owner "$TOUCHSTONE_WORKTREE_LOCK_DIR"; then
    touchstone_worktree_lock_error \
      "released the Git-native index lock but could not remove its owner record" \
      "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
    return
  fi
  TOUCHSTONE_WORKTREE_LOCK_DIR=""
  TOUCHSTONE_WORKTREE_INDEX_LOCK=""
  TOUCHSTONE_WORKTREE_LOCK_PID=""
  TOUCHSTONE_WORKTREE_LOCK_ERROR=""
}

touchstone_worktree_lock_acquire() {
  local project="$1" git_dir owner_dir index_lock owner=""
  if [ -n "$TOUCHSTONE_WORKTREE_LOCK_DIR" ]; then
    touchstone_worktree_lock_error "this process already owns a Git-native worktree lock" \
      "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
    return
  fi
  if [ "${GIT_DIR+x}" = x ] || [ "${GIT_WORK_TREE+x}" = x ] \
    || [ "${GIT_COMMON_DIR+x}" = x ] || [ "${GIT_INDEX_FILE+x}" = x ]; then
    touchstone_worktree_lock_error \
      "ambient Git repository overrides are not supported during a worktree transaction" \
      "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
    return
  fi
  if ! git_dir="$(git -C "$project" rev-parse --absolute-git-dir)"; then
    touchstone_worktree_lock_error "could not locate repository metadata" \
      "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
    return
  fi
  owner_dir="$git_dir/touchstone-worktree.lock"
  index_lock="$git_dir/index.lock"
  if ! mkdir -- "$owner_dir" 2>/dev/null; then
    if [ ! -d "$owner_dir" ] || [ -L "$owner_dir" ]; then
      touchstone_worktree_lock_error "worktree-lock owner path is not a directory: $owner_dir" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
    fi
    if [ -f "$owner_dir/pid" ] && [ ! -L "$owner_dir/pid" ]; then
      IFS= read -r owner <"$owner_dir/pid" || owner=""
    fi
    case "$owner" in '' | *[!0-9]*)
      touchstone_worktree_lock_error \
        "worktree lock has no verifiable owner; after confirming no mutation is active and preserving any foreign $index_lock, remove $owner_dir/pid and $owner_dir/token, then remove $owner_dir" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
      ;;
    esac
    if [ -f "$owner_dir/token" ] && [ ! -L "$owner_dir/token" ] \
      && [ -f "$index_lock" ] && [ ! -L "$index_lock" ] \
      && [ "$index_lock" -ef "$owner_dir/token" ]; then
      touchstone_worktree_lock_error \
        "worktree lock records pid $owner and may be active or stale; wait if its mutation is active, or after verifying no Touchstone mutation is active, remove $index_lock, $owner_dir/pid, and $owner_dir/token, then remove $owner_dir" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
    else
      touchstone_worktree_lock_error \
        "stale worktree-lock state is incomplete or does not own Git's index lock; preserve foreign state and recover $owner_dir explicitly" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
    fi
    return
  fi
  if ! touchstone_worktree_lock_read_process_id \
    || ! printf '%s\n' "$TOUCHSTONE_WORKTREE_PROCESS_ID" >"$owner_dir/pid" \
    || ! printf 'touchstone-worktree-lock/v1 %s\n' "$TOUCHSTONE_WORKTREE_PROCESS_ID" >"$owner_dir/token"; then
    touchstone_worktree_lock_remove_owner "$owner_dir" 2>/dev/null || true
    touchstone_worktree_lock_error "could not record worktree-lock ownership" \
      "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
    return
  fi
  if ! ln "$owner_dir/token" "$index_lock" 2>/dev/null; then
    touchstone_worktree_lock_remove_owner "$owner_dir" 2>/dev/null || true
    if [ -e "$index_lock" ] || [ -L "$index_lock" ]; then
      touchstone_worktree_lock_error \
        "Git index lock already exists and was preserved; wait for the Git operation or recover its index.lock" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
    else
      touchstone_worktree_lock_error "could not acquire the Git-native index lock" \
        "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
    fi
    return
  fi
  TOUCHSTONE_WORKTREE_LOCK_DIR="$owner_dir"
  TOUCHSTONE_WORKTREE_INDEX_LOCK="$index_lock"
  TOUCHSTONE_WORKTREE_LOCK_PID="$TOUCHSTONE_WORKTREE_PROCESS_ID"
  TOUCHSTONE_WORKTREE_LOCK_ERROR=""
}
