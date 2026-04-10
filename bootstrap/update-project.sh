#!/usr/bin/env bash
#
# bootstrap/update-project.sh — pull latest toolkit files into a project.
#
# Usage:
#   cd ~/Repos/my-project
#   ~/Repos/toolkit/bootstrap/update-project.sh
#   ~/Repos/toolkit/bootstrap/update-project.sh --dry-run   # show what would change
#
# What this does:
#   1. Reads .toolkit-version from the project to know what version is installed
#   2. Shows the toolkit changelog since the last update
#   3. Updates toolkit-owned files (principles/*.md, scripts/*.sh)
#      - Unchanged files: skipped
#      - Changed files: backs up as .bak, copies new version
#   4. Does NOT touch project-owned files (CLAUDE.md, AGENTS.md, .codex-review.toml,
#      .pre-commit-config.yaml) — prints a "consider reviewing" hint
#   5. Updates .toolkit-version to current toolkit SHA
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(pwd)"
DRY_RUN=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true; shift ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Verify we're in a project with .toolkit-version.
if [ ! -f "$PROJECT_DIR/.toolkit-version" ]; then
  echo "ERROR: No .toolkit-version file found in $PROJECT_DIR" >&2
  echo "       This project hasn't been bootstrapped with the toolkit." >&2
  echo "       Run: $(dirname "$0")/new-project.sh $PROJECT_DIR" >&2
  exit 1
fi

OLD_SHA="$(cat "$PROJECT_DIR/.toolkit-version" | tr -d '[:space:]')"
CURRENT_SHA="$(git -C "$TOOLKIT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"

echo "==> Updating project: $PROJECT_DIR"
echo "    Toolkit: $OLD_SHA → $CURRENT_SHA"

if [ "$OLD_SHA" = "$CURRENT_SHA" ]; then
  echo "==> Already up to date."
  exit 0
fi

# Show changelog between versions.
echo ""
echo "==> Changes in toolkit since last update:"
if git -C "$TOOLKIT_ROOT" log --oneline "$OLD_SHA..$CURRENT_SHA" 2>/dev/null; then
  echo ""
else
  echo "    (couldn't compute changelog — old SHA may have been garbage collected)"
  echo ""
fi

# --------------------------------------------------------------------------
# Toolkit-owned files — update with .bak backup if locally modified
# --------------------------------------------------------------------------

ADDED=0
UPDATED=0
UNCHANGED=0

update_file() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"

  if [ ! -f "$dst" ]; then
    # File doesn't exist in project — add it.
    if [ "$DRY_RUN" = true ]; then
      echo "    + would add: $dst"
    else
      mkdir -p "$dst_dir"
      cp "$src" "$dst"
      echo "    + added: $dst"
    fi
    ADDED=$((ADDED + 1))
    return
  fi

  # File exists — compare.
  if diff -q "$src" "$dst" >/dev/null 2>&1; then
    UNCHANGED=$((UNCHANGED + 1))
    return
  fi

  # File differs — back up and update.
  if [ "$DRY_RUN" = true ]; then
    echo "    ! would update (with .bak): $dst"
  else
    cp "$dst" "$dst.bak"
    cp "$src" "$dst"
    echo "    ! updated (backed up as .bak): $dst"
  fi
  UPDATED=$((UPDATED + 1))
}

echo "==> Updating toolkit-owned files:"

# Principles
if [ -d "$TOOLKIT_ROOT/principles" ]; then
  mkdir -p "$PROJECT_DIR/principles"
  for f in "$TOOLKIT_ROOT/principles/"*.md; do
    update_file "$f" "$PROJECT_DIR/principles/$(basename "$f")"
  done
fi

# Scripts
update_file "$TOOLKIT_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
update_file "$TOOLKIT_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
update_file "$TOOLKIT_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
update_file "$TOOLKIT_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"

# Ensure scripts are executable.
if [ "$DRY_RUN" = false ] && [ -d "$PROJECT_DIR/scripts" ]; then
  chmod +x "$PROJECT_DIR/scripts/"*.sh 2>/dev/null || true
fi

# Update .toolkit-version.
if [ "$DRY_RUN" = false ]; then
  echo "$CURRENT_SHA" > "$PROJECT_DIR/.toolkit-version"
fi

echo ""
echo "==> Summary: $ADDED added, $UPDATED updated, $UNCHANGED unchanged"

if [ "$UPDATED" -gt 0 ] && [ "$DRY_RUN" = false ]; then
  echo ""
  echo "    Review .bak files to see what changed. Delete them when satisfied:"
  echo "      find . -name '*.bak' -delete"
fi

# Hint about project-owned files.
echo ""
echo "==> Project-owned files (not auto-updated):"
echo "    Consider reviewing these against the latest toolkit templates:"
echo "      diff $TOOLKIT_ROOT/templates/CLAUDE.md ./CLAUDE.md"
echo "      diff $TOOLKIT_ROOT/templates/AGENTS.md ./AGENTS.md"
echo "      diff $TOOLKIT_ROOT/templates/pre-commit-config.yaml ./.pre-commit-config.yaml"
echo ""
echo "==> Done."
