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
# So this helper does not use -i at all. It writes through a temp file and
# copies the bytes back, which also preserves the destination's mode, owner
# and inode — `mv` would replace all three with the temp file's.
#
# Failures are loud. The call sites this replaced ended in `2>/dev/null ||
# true`, so every one of them had been silently doing nothing on Linux.

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

  local file tmp
  for file in "$@"; do
    if [ ! -f "$file" ]; then
      echo "ERROR: touchstone_sed_inplace: not a regular file: $file" >&2
      return 1
    fi

    if [ -L "$file" ]; then
      echo "ERROR: touchstone_sed_inplace: refusing to rewrite through a symlink: $file" >&2
      return 1
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/touchstone-sed.XXXXXX")" || {
      echo "ERROR: touchstone_sed_inplace: could not create a temp file." >&2
      return 1
    }

    if ! sed "$script" "$file" >"$tmp"; then
      rm -f "$tmp"
      echo "ERROR: touchstone_sed_inplace: sed failed on $file" >&2
      echo "       script: $script" >&2
      return 1
    fi

    if ! cat "$tmp" >"$file"; then
      rm -f "$tmp"
      echo "ERROR: touchstone_sed_inplace: could not write back to $file" >&2
      return 1
    fi

    rm -f "$tmp"
  done
}
