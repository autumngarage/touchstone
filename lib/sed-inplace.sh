#!/usr/bin/env bash
#
# lib/sed-inplace.sh — portable in-place sed for Touchstone shell workflows.
#
# There is no portable spelling of `sed -i`. BSD/macOS requires the backup
# suffix as a SEPARATE argument, so an empty suffix is written `sed -i '' …`.
# GNU requires the suffix ATTACHED (`sed -i.bak`), and reads a detached '' as
# the script — which pushes the real script into the filename slot. That is why
#
#     sed -i '' 's/NNNN/0001/g' file
#
# fails on Linux with "sed: can't read s/NNNN/0001/g: No such file or
# directory". Git for Windows ships GNU sed, so Git Bash behaves like Linux
# rather than like macOS — a BSD-only spelling breaks two of the three
# platforms Touchstone supports.
#
# So this helper does not use -i at all. It writes a temp file and renames it
# over the target, which is the standard safe-replace idiom: the rename is
# atomic, so an interrupted or failing write can never leave the destination
# truncated or half-rewritten. A reader either sees the old file or the new
# one.
#
# Two details make that guarantee real rather than nominal:
#
#   * The temp file is created in the SAME DIRECTORY as the target, not in
#     $TMPDIR. rename(2) is only atomic within a filesystem; a temp in /tmp
#     would make `mv` a copy-then-delete across devices and reintroduce the
#     torn-write window this is here to close.
#   * The target's mode is copied onto the temp file BEFORE the rename, so
#     permissions survive. The inode does not, which is the accepted trade —
#     these are config and instruction files, not anything holding an open
#     descriptor across the write.
#
# Failures are loud. The call sites this replaced ended in `2>/dev/null ||
# true`, so every one of them had been silently doing nothing on Linux.

# Read a file's permission bits as an octal string, portably. `stat` is one of
# the sharpest BSD/GNU splits in the userland: GNU spells it `-c '%a'`, BSD
# spells it `-f '%OLp'`, and each rejects the other's flag. Git for Windows
# ships the GNU spelling. Try GNU first, fall back to BSD, fail loudly if
# neither answers with something that looks like a mode.
_touchstone_sed_file_mode() {
  local file="$1" mode

  mode="$(stat -c '%a' "$file" 2>/dev/null)" \
    || mode="$(stat -f '%OLp' "$file" 2>/dev/null)" \
    || return 1

  case "$mode" in
    [0-7] | [0-7][0-7] | [0-7][0-7][0-7] | [0-7][0-7][0-7][0-7]) ;;
    *) return 1 ;;
  esac

  printf '%s\n' "$mode"
}

# Read a file's owner as `uid:gid`, portably. Same BSD/GNU split as the mode:
# GNU wants `-c`, BSD wants `-f`, and the format specifier happens to agree.
_touchstone_sed_file_owner() {
  local file="$1" owner

  owner="$(stat -c '%u:%g' "$file" 2>/dev/null)" \
    || owner="$(stat -f '%u:%g' "$file" 2>/dev/null)" \
    || return 1

  case "$owner" in
    [0-9]*:[0-9]*) printf '%s\n' "$owner" ;;
    *) return 1 ;;
  esac
}

# touchstone_sed_inplace <sed-script> <file> [file...]
#   Applies one sed script in place to each file. Every file must exist and be
#   a regular file; callers that legitimately tolerate a missing file must test
#   for it explicitly, so that "the file was absent" cannot be confused with
#   "the substitution silently did nothing".
touchstone_sed_inplace() {
  local script="${1-}"
  shift 2>/dev/null || true

  if [ -z "$script" ]; then
    echo "ERROR: touchstone_sed_inplace requires a sed script." >&2
    return 2
  fi

  if [ "$#" -eq 0 ]; then
    echo "ERROR: touchstone_sed_inplace requires at least one file." >&2
    return 2
  fi

  local file tmp dir mode
  for file in "$@"; do
    if [ ! -f "$file" ]; then
      echo "ERROR: touchstone_sed_inplace: not a regular file: $file" >&2
      return 1
    fi

    if [ -L "$file" ]; then
      echo "ERROR: touchstone_sed_inplace: refusing to rewrite through a symlink: $file" >&2
      return 1
    fi

    # Each file is rewritten inside a SUBSHELL that owns a cleanup trap for its
    # own temp. A trap installed in this sourced function would belong to the
    # caller's process and clobber whatever EXIT/INT/TERM handler the bootstrap
    # scripts already rely on; a subshell's traps are its own, and a signal
    # delivered to the process group reaches it too — so an interrupt between
    # mktemp and the rename cleans up instead of leaving a stray
    # `.touchstone-sed.*` beside the target (PR #747 review).
    (
      tmp=""
      trap 'if [ -n "$tmp" ]; then rm -f "$tmp"; fi' EXIT INT TERM

      # Same directory as the target: rename(2) is only atomic within one
      # filesystem, so a temp in $TMPDIR would silently degrade `mv` into
      # copy-then-delete and reopen the torn-write window.
      dir="$(dirname "$file")"
      tmp="$(mktemp "$dir/.touchstone-sed.XXXXXX")" || {
        echo "ERROR: touchstone_sed_inplace: could not create a temp file in $dir." >&2
        exit 1
      }

      if ! sed "$script" "$file" >"$tmp"; then
        echo "ERROR: touchstone_sed_inplace: sed failed on $file" >&2
        echo "       script: $script" >&2
        exit 1
      fi

      # Carry the target's permissions onto the replacement before the rename.
      # chmod --reference is GNU-only, so read the mode portably instead.
      if ! mode="$(_touchstone_sed_file_mode "$file")"; then
        echo "ERROR: touchstone_sed_inplace: could not read the mode of $file" >&2
        exit 1
      fi
      if ! chmod "$mode" "$tmp"; then
        echo "ERROR: touchstone_sed_inplace: could not set mode $mode on the replacement for $file" >&2
        exit 1
      fi

      # Ownership does not ride along with the rename the way it did with the
      # previous truncate-and-copy, so a privileged run against a file owned by
      # another UID would silently hand it to the invoking user. Only act when
      # the owner actually differs, and fail rather than change it silently.
      if owner="$(_touchstone_sed_file_owner "$file")" \
        && tmp_owner="$(_touchstone_sed_file_owner "$tmp")"; then
        if [ "$owner" != "$tmp_owner" ] && ! chown "$owner" "$tmp" 2>/dev/null; then
          echo "ERROR: touchstone_sed_inplace: $file is owned by $owner and the" >&2
          echo "       replacement could not be given the same owner. Refusing to" >&2
          echo "       rewrite it, because the rename would transfer ownership to" >&2
          echo "       $tmp_owner. Original left untouched." >&2
          exit 1
        fi
      else
        echo "ERROR: touchstone_sed_inplace: could not read ownership for $file" >&2
        exit 1
      fi

      # Atomic. The original is never truncated: either the rename succeeds and
      # the new content is fully in place, or it fails and the original is
      # untouched.
      if ! mv -f "$tmp" "$file"; then
        echo "ERROR: touchstone_sed_inplace: could not replace $file" >&2
        exit 1
      fi

      # Renamed away; nothing left for the trap to remove.
      tmp=""
    ) || return 1
  done
}
