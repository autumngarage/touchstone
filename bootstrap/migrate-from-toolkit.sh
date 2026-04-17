#!/usr/bin/env bash
#
# bootstrap/migrate-from-toolkit.sh — one-shot migration of legacy .toolkit-*
# dotfiles to their .touchstone-* equivalents for projects bootstrapped before
# the v1.0.0 toolkit -> touchstone rename.
#
# Behavior:
#   1. Refuses to run if not a git repo or working tree is dirty.
#   2. Renames .toolkit-{version,manifest,config} -> .touchstone-{version,manifest,config}
#      using `git mv` so history follows.
#   3. Rewrites path references inside .touchstone-manifest
#      (`.toolkit-*` -> `.touchstone-*`, `toolkit-run.sh` -> `touchstone-run.sh`).
#   4. Commits as "chore: migrate from toolkit to touchstone" on the current branch.
#   5. Idempotent: if no legacy files remain, exits 0 with a clear message.
#
# This script is a backwards-compat shim for the rename and can be deleted
# once every downstream project has migrated. It intentionally does NOT run
# `touchstone update` afterward — the user runs that as a separate step.
#
set -euo pipefail

PROJECT_DIR="$(pwd)"

LEGACY_PAIRS=(
  ".toolkit-version:.touchstone-version"
  ".toolkit-manifest:.touchstone-manifest"
  ".toolkit-config:.touchstone-config"
)

require_git_repo() {
  if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: touchstone migrate-from-toolkit requires a git repository." >&2
    exit 1
  fi
}

require_clean_tree() {
  if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "ERROR: Working tree is dirty. Commit, stash, or revert first." >&2
    exit 1
  fi
}

detect_legacy_state() {
  local pair old new conflict=0 legacy=0
  for pair in "${LEGACY_PAIRS[@]}"; do
    old="${pair%%:*}"
    new="${pair##*:}"
    if [ -f "$PROJECT_DIR/$old" ] && [ -f "$PROJECT_DIR/$new" ]; then
      echo "ERROR: Both $old and $new exist in $PROJECT_DIR." >&2
      echo "       Manual cleanup required: pick one and delete the other." >&2
      conflict=1
    fi
    if [ -f "$PROJECT_DIR/$old" ]; then
      legacy=1
    fi
  done
  [ "$conflict" -eq 0 ] || exit 1
  [ "$legacy" -eq 1 ]
}

rename_legacy_files() {
  local pair old new
  for pair in "${LEGACY_PAIRS[@]}"; do
    old="${pair%%:*}"
    new="${pair##*:}"
    if [ -f "$PROJECT_DIR/$old" ]; then
      git -C "$PROJECT_DIR" mv "$old" "$new"
      echo "    renamed $old -> $new"
    fi
  done
}

rewrite_manifest_paths() {
  local manifest="$PROJECT_DIR/.touchstone-manifest"
  [ -f "$manifest" ] || return 0
  if ! grep -qE '\.toolkit-|toolkit-run\.sh' "$manifest"; then
    return 0
  fi
  # sed -i.bak is portable across BSD/GNU; we remove the backup ourselves.
  sed -i.bak \
    -e 's/\.toolkit-/\.touchstone-/g' \
    -e 's/toolkit-run\.sh/touchstone-run.sh/g' \
    "$manifest"
  rm -f "$manifest.bak"
  git -C "$PROJECT_DIR" add .touchstone-manifest
  echo "    updated .touchstone-manifest path references"
}

main() {
  require_git_repo

  if ! detect_legacy_state; then
    echo "==> No legacy .toolkit-* files found. Nothing to migrate."
    exit 0
  fi

  require_clean_tree

  echo "==> Migrating legacy .toolkit-* files in $PROJECT_DIR"
  rename_legacy_files
  rewrite_manifest_paths

  git -C "$PROJECT_DIR" commit -m "chore: migrate from toolkit to touchstone

Renames legacy .toolkit-* dotfiles to .touchstone-* to match the v1.0.0
rename. Path references inside .touchstone-manifest are rewritten.
Run \`touchstone update\` next to pick up any newer touchstone-owned files." >/dev/null

  echo "==> Committed migration. Next: touchstone update"
}

main "$@"
