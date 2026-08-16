# shellcheck shell=bash
# shellcheck disable=SC2034 # public status and error globals are consumed by callers.

TOUCHSTONE_WORKTREE_LOCK_DIR=""
TOUCHSTONE_WORKTREE_INDEX_LOCK=""
TOUCHSTONE_WORKTREE_LOCK_ERROR=""
TOUCHSTONE_WORKTREE_LOCK_REFUSED=10
TOUCHSTONE_WORKTREE_LOCK_FAILED=11

touchstone_worktree_lock_error() {
  TOUCHSTONE_WORKTREE_LOCK_ERROR="$1"
  return "$2"
}

touchstone_worktree_lock_remove_owner() {
  local directory="$1"
  rm -f -- "$directory/pid" "$directory/token" "$directory/reclaim" || return 1
  rmdir -- "$directory"
}

touchstone_worktree_lock_release() {
  local owner=""
  [ -n "$TOUCHSTONE_WORKTREE_LOCK_DIR" ] || return 0
  if [ -f "$TOUCHSTONE_WORKTREE_LOCK_DIR/pid" ] \
    && [ ! -L "$TOUCHSTONE_WORKTREE_LOCK_DIR/pid" ]; then
    IFS= read -r owner <"$TOUCHSTONE_WORKTREE_LOCK_DIR/pid" || owner=""
  fi
  if [ "$owner" != "$$" ] \
    || [ ! -f "$TOUCHSTONE_WORKTREE_LOCK_DIR/token" ] \
    || [ -L "$TOUCHSTONE_WORKTREE_LOCK_DIR/token" ] \
    || [ ! -f "$TOUCHSTONE_WORKTREE_INDEX_LOCK" ] \
    || [ -L "$TOUCHSTONE_WORKTREE_INDEX_LOCK" ] \
    || [ ! "$TOUCHSTONE_WORKTREE_INDEX_LOCK" -ef "$TOUCHSTONE_WORKTREE_LOCK_DIR/token" ]; then
    TOUCHSTONE_WORKTREE_LOCK_DIR=""
    TOUCHSTONE_WORKTREE_INDEX_LOCK=""
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
  TOUCHSTONE_WORKTREE_LOCK_ERROR=""
}

touchstone_worktree_lock_acquire() {
  local project="$1" git_dir owner_dir index_lock owner="" confirmed_owner="" stale_dir
  local interrupted_dir="" candidate reclaimer
  if [ -n "$TOUCHSTONE_WORKTREE_LOCK_DIR" ]; then
    touchstone_worktree_lock_error "this process already owns a Git-native worktree lock" \
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
  if [ ! -e "$owner_dir" ] && [ ! -L "$owner_dir" ] \
    && { [ -e "$index_lock" ] || [ -L "$index_lock" ]; }; then
    for candidate in "$git_dir"/touchstone-worktree.lock.stale.*; do
      [ -d "$candidate" ] && [ ! -L "$candidate" ] \
        && [ -f "$candidate/token" ] && [ ! -L "$candidate/token" ] \
        && [ -f "$index_lock" ] && [ ! -L "$index_lock" ] \
        && [ "$index_lock" -ef "$candidate/token" ] || continue
      if [ -n "$interrupted_dir" ]; then
        touchstone_worktree_lock_error \
          "multiple interrupted worktree-lock recoveries own the Git index lock" \
          "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
        return
      fi
      interrupted_dir="$candidate"
    done
    if [ -n "$interrupted_dir" ]; then
      reclaimer="${interrupted_dir##*.}"
      case "$reclaimer" in '' | *[!0-9]*)
        touchstone_worktree_lock_error \
          "interrupted worktree-lock recovery has no verifiable reclaimer: $interrupted_dir" \
          "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
        return
        ;;
      esac
      if kill -0 "$reclaimer" 2>/dev/null; then
        touchstone_worktree_lock_error "worktree-lock recovery is active (pid $reclaimer)" \
          "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
        return
      fi
      if [ -f "$interrupted_dir/reclaim" ] && [ ! -L "$interrupted_dir/reclaim" ] \
        && [ -f "$interrupted_dir/token" ] \
        && [ "$interrupted_dir/reclaim" -ef "$interrupted_dir/token" ]; then
        rm -f -- "$interrupted_dir/reclaim" \
          || touchstone_worktree_lock_error "could not resume interrupted stale-lock recovery" \
            "$TOUCHSTONE_WORKTREE_LOCK_FAILED" || return
      fi
      if ! mv -- "$interrupted_dir" "$owner_dir" 2>/dev/null; then
        touchstone_worktree_lock_error "interrupted worktree-lock ownership changed; retry" \
          "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
        return
      fi
    fi
  fi
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
        "worktree lock has no verifiable owner; after confirming no mutation is active, remove $owner_dir" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
      ;;
    esac
    if kill -0 "$owner" 2>/dev/null; then
      touchstone_worktree_lock_error "another worktree mutation is active (pid $owner)" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
    fi
    if [ ! -f "$owner_dir/token" ] || [ -L "$owner_dir/token" ]; then
      touchstone_worktree_lock_error \
        "stale worktree lock has no verifiable token; after confirming no mutation is active, remove $owner_dir" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
    fi
    stale_dir="$owner_dir.stale.$$"
    if [ -e "$stale_dir" ] || [ -L "$stale_dir" ]; then
      touchstone_worktree_lock_error "stale-lock recovery path already exists: $stale_dir" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
    fi
    if ! ln "$owner_dir/token" "$owner_dir/reclaim" 2>/dev/null; then
      touchstone_worktree_lock_error \
        "stale worktree lock is already being reclaimed; retry the operation" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
    fi
    if [ ! "$owner_dir/reclaim" -ef "$owner_dir/token" ]; then
      touchstone_worktree_lock_error "stale worktree-lock claim lost token identity" \
        "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
      return
    fi
    if [ -f "$owner_dir/pid" ] && [ ! -L "$owner_dir/pid" ]; then
      IFS= read -r confirmed_owner <"$owner_dir/pid" || confirmed_owner=""
    fi
    if [ "$confirmed_owner" != "$owner" ] || kill -0 "$confirmed_owner" 2>/dev/null; then
      rm -f -- "$owner_dir/reclaim" 2>/dev/null || true
      touchstone_worktree_lock_error "worktree-lock ownership changed before stale reclamation" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
    fi
    if ! mv -- "$owner_dir" "$stale_dir" 2>/dev/null; then
      if [ -f "$owner_dir/reclaim" ] && [ ! -L "$owner_dir/reclaim" ] \
        && [ -f "$owner_dir/token" ] && [ "$owner_dir/reclaim" -ef "$owner_dir/token" ]; then
        rm -f -- "$owner_dir/reclaim" 2>/dev/null || true
      fi
      touchstone_worktree_lock_error "worktree-lock ownership changed; retry the operation" \
        "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
      return
    fi
    if [ -e "$index_lock" ] || [ -L "$index_lock" ]; then
      if [ ! -f "$index_lock" ] || [ -L "$index_lock" ] \
        || [ ! -f "$stale_dir/token" ] || [ -L "$stale_dir/token" ] \
        || [ ! "$index_lock" -ef "$stale_dir/token" ]; then
        if ! touchstone_worktree_lock_remove_owner "$stale_dir"; then
          touchstone_worktree_lock_error "stale worktree lock contains unexpected state: $stale_dir" \
            "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
          return
        fi
        touchstone_worktree_lock_error \
          "Git index lock is not owned by the stale Touchstone transaction and was preserved" \
          "$TOUCHSTONE_WORKTREE_LOCK_REFUSED"
        return
      fi
      if ! rm -f -- "$index_lock"; then
        touchstone_worktree_lock_error "could not reclaim the stale Git-native index lock" \
          "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
        return
      fi
    fi
    if ! touchstone_worktree_lock_remove_owner "$stale_dir"; then
      touchstone_worktree_lock_error "stale worktree lock contains unexpected state: $stale_dir" \
        "$TOUCHSTONE_WORKTREE_LOCK_FAILED"
      return
    fi
    touchstone_worktree_lock_acquire "$project"
    return
  fi
  if ! printf '%s\n' "$$" >"$owner_dir/pid" \
    || ! printf 'touchstone-worktree-lock/v1 %s\n' "$$" >"$owner_dir/token"; then
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
  TOUCHSTONE_WORKTREE_LOCK_ERROR=""
}
