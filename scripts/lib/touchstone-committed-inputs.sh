#!/usr/bin/env bash
# Guard compiler inputs so a plan can only be derived from reviewable HEAD state.

touchstone_input_error() {
  printf "touchstone: compiler input rejected: path=%s reason=%s\n" "$1" "$2" >&2
  return 1
}

touchstone_validate_input_path() {
  local path="$1"

  case "$path" in
    "" | /* | */ | . | .. | ./* | ../* | */./* | */. | */../* | */.. | *//* | *[!A-Za-z0-9._/-]*)
      touchstone_input_error "$path" invalid-path
      return 1
      ;;
  esac
}

touchstone_head_entry() {
  git -C "$1" ls-tree HEAD -- "$2"
}

touchstone_reject_staged_input() {
  local status

  if git -C "$1" diff --cached --quiet HEAD -- "$2"; then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0) return 0 ;;
    1) touchstone_input_error "$2" staged ;;
    *) touchstone_input_error "$2" git-state-unavailable ;;
  esac
  return 1
}

touchstone_reject_hidden_index_flags() {
  local listing

  listing="$(git -C "$1" ls-files -v -- "$2")" || {
    touchstone_input_error "$2" git-state-unavailable
    return 1
  }
  if awk '
    substr($0, 1, 1) == "S" || substr($0, 1, 1) ~ /[a-z]/ { hidden=1 }
    END { exit hidden ? 0 : 1 }
  ' <<EOF; then
$listing
EOF
    touchstone_input_error "$2" hidden-index-state
    return 1
  fi
}

touchstone_reject_dirty_input() {
  local status

  if git -C "$1" diff --quiet -- "$2"; then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0) return 0 ;;
    1) touchstone_input_error "$2" dirty ;;
    *) touchstone_input_error "$2" git-state-unavailable ;;
  esac
  return 1
}

touchstone_reject_untracked_input() {
  local untracked

  # Consume the complete result. A short-circuiting grep here can SIGPIPE
  # git ls-files under pipefail when a project contains many compiler inputs.
  # Ignored paths still affect detection when they exist, so they are compiler
  # inputs too; do not hide them with --exclude-standard.
  untracked="$(git -C "$1" ls-files --others -- "$2")" || {
    touchstone_input_error "$2" git-state-unavailable
    return 1
  }
  if [ -n "$untracked" ]; then
    touchstone_input_error "$2" untracked
    return 1
  fi
}

touchstone_require_committed_file() {
  local repository="$1" path="$2" entry metadata mode type

  touchstone_validate_input_path "$path" || return 1
  git -C "$repository" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1 || {
    touchstone_input_error "$path" git-state-unavailable
    return 1
  }
  touchstone_reject_hidden_index_flags "$repository" "$path" || return 1
  touchstone_reject_staged_input "$repository" "$path" || return 1

  entry="$(touchstone_head_entry "$repository" "$path")" || {
    touchstone_input_error "$path" git-state-unavailable
    return 1
  }
  if [ -z "$entry" ]; then
    touchstone_reject_untracked_input "$repository" "$path" || return 1
    touchstone_input_error "$path" missing
    return 1
  fi

  IFS="	" read -r metadata _ <<EOF
$entry
EOF
  read -r mode type _ <<EOF
$metadata
EOF
  if [ "$mode" = 120000 ]; then
    touchstone_input_error "$path" symlink
    return 1
  fi
  if [ "$type" != blob ] || { [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; }; then
    touchstone_input_error "$path" nonregular
    return 1
  fi
  if [ -L "$repository/$path" ]; then
    touchstone_input_error "$path" symlink
    return 1
  fi
  if [ ! -e "$repository/$path" ]; then
    touchstone_input_error "$path" missing
    return 1
  fi
  if [ ! -f "$repository/$path" ]; then
    touchstone_input_error "$path" nonregular
    return 1
  fi
  touchstone_reject_dirty_input "$repository" "$path" || return 1

  return 0
}

touchstone_require_committed_directory() {
  local repository="$1" path="$2" root_entry entries metadata child_path
  local mode type

  touchstone_validate_input_path "$path" || return 1
  git -C "$repository" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1 || {
    touchstone_input_error "$path" git-state-unavailable
    return 1
  }
  touchstone_reject_hidden_index_flags "$repository" "$path" || return 1
  touchstone_reject_staged_input "$repository" "$path" || return 1

  root_entry="$(touchstone_head_entry "$repository" "$path")" || {
    touchstone_input_error "$path" git-state-unavailable
    return 1
  }
  if [ -z "$root_entry" ]; then
    touchstone_reject_untracked_input "$repository" "$path" || return 1
    touchstone_input_error "$path" missing
    return 1
  fi

  IFS="	" read -r metadata _ <<EOF
$root_entry
EOF
  read -r mode type _ <<EOF
$metadata
EOF
  if [ "$mode" = 120000 ]; then
    touchstone_input_error "$path" symlink
    return 1
  fi
  if [ "$type" != tree ]; then
    touchstone_input_error "$path" nonregular
    return 1
  fi
  if [ -L "$repository/$path" ]; then
    touchstone_input_error "$path" symlink
    return 1
  fi
  if [ ! -d "$repository/$path" ]; then
    touchstone_input_error "$path" missing
    return 1
  fi

  entries="$(git -C "$repository" ls-tree -r HEAD -- "$path")" || {
    touchstone_input_error "$path" git-state-unavailable
    return 1
  }
  if [ -z "$entries" ]; then
    touchstone_input_error "$path" missing
    return 1
  fi

  # Invariant: every accepted directory member is a regular HEAD blob whose
  # checked-out bytes and mode still match the index and HEAD.
  while IFS="	" read -r metadata child_path; do
    read -r mode type _ <<EOF
$metadata
EOF
    touchstone_validate_input_path "$child_path" || return 1
    if [ "$mode" = 120000 ] || [ -L "$repository/$child_path" ]; then
      touchstone_input_error "$child_path" symlink
      return 1
    fi
    if [ "$type" != blob ] \
      || { [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; } \
      || { [ -e "$repository/$child_path" ] && [ ! -f "$repository/$child_path" ]; }; then
      touchstone_input_error "$child_path" nonregular
      return 1
    fi
    if [ ! -e "$repository/$child_path" ]; then
      touchstone_input_error "$child_path" missing
      return 1
    fi
  done <<EOF
$entries
EOF

  touchstone_reject_dirty_input "$repository" "$path" || return 1
  touchstone_reject_untracked_input "$repository" "$path" || return 1

  return 0
}
