#!/usr/bin/env bash
#
# lib/safe-write.sh — shared symlink-safe write guard for touchstone's
# bootstrap/sync writers.
#
# cp, mkdir -p, and shell redirects all FOLLOW symlinks. When touchstone writes
# managed files into a project (or installs user-scoped skills), a symlink
# planted at a managed path — or at any ANCESTOR directory of one — could
# redirect the write outside the intended tree and clobber or create an
# arbitrary file. Managed paths are always regular files inside real
# directories, so this guard:
#   * hard-refuses a write whose path traverses a symlinked ANCESTOR directory
#     (between the destination and the trusted root) — an ancestor symlink
#     cannot be safely auto-removed;
#   * replaces a symlink at the FINAL path component with the real file (the
#     write then lands inside the project; git tracks the change, so it stays
#     recoverable).
#
# Call this BEFORE any mkdir/cp/redirect so the ancestor check also protects the
# directory creation.

# touchstone_ensure_safe_dest <dst> <root> [dry_run]
#   dst      absolute path that is about to be written
#   root     trusted boundary; ancestor symlinks are checked from dst up to (but
#            not including) root. The root itself is the user's chosen location
#            and is not second-guessed.
#   dry_run  "true" to skip the actual symlink removal (still reports/decides)
# Returns 0 when it is safe to write to "$dst", 1 when the write must be skipped.
touchstone_ensure_safe_dest() {
  local dst="$1"
  local root="$2"
  local dry_run="${3:-false}"
  local parent next

  parent="$(dirname "$dst")"
  while [ "$parent" != "$root" ] && [ "$parent" != "/" ] && [ "$parent" != "." ]; do
    if [ -L "$parent" ]; then
      echo "    ! refusing to write through symlinked directory: $parent" >&2
      return 1
    fi
    next="$(dirname "$parent")"
    [ "$next" = "$parent" ] && break
    parent="$next"
  done

  if [ -L "$dst" ]; then
    echo "    ! replacing unexpected symlink with managed file: $dst" >&2
    [ "$dry_run" != true ] && rm -f "$dst"
  fi
  return 0
}
