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
#
# A caller that REMOVES a path instead of writing one wants the first rule and
# not the second — see touchstone_ensure_safe_ancestors below.

# touchstone_ensure_safe_ancestors <dst> <root>
#   The ancestor half of the guard, on its own. A caller that is about to
#   REMOVE a path needs the traversal refusal but must not get the
#   final-component symlink replacement below: that unlink is a write-side
#   affordance, and firing it before the caller's own ownership and
#   dirty-state checks destroyed the link those checks existed to protect
#   (#801 review). Ancestors are checked from dst up to (but not including)
#   root; root itself is the user's chosen location and is not second-guessed.
# Returns 0 when no ancestor between dst and root is a symlink, 1 otherwise.
#
# Callers invoke this in a conditional, so `set -e` is inert inside it. Nothing
# here relies on errexit: the body is `dirname` and file tests only.
touchstone_ensure_safe_ancestors() {
  local dst="$1"
  local root="$2"
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
  return 0
}

# touchstone_ensure_safe_dest <dst> <root> [dry_run]
#   dst      absolute path that is about to be written
#   root     trusted boundary; see touchstone_ensure_safe_ancestors.
#   dry_run  "true" to skip the actual symlink removal (still reports/decides)
# Returns 0 when it is safe to write to "$dst", 1 when the write must be skipped.
touchstone_ensure_safe_dest() {
  local dst="$1"
  local root="$2"
  local dry_run="${3:-false}"

  if ! touchstone_ensure_safe_ancestors "$dst" "$root"; then
    return 1
  fi

  if [ -L "$dst" ]; then
    echo "    ! replacing unexpected symlink with managed file: $dst" >&2
    [ "$dry_run" != true ] && rm -f "$dst"
  fi
  return 0
}
