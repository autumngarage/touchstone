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
# Use git SHA if this is a git clone, otherwise use VERSION (brew install).
if [ -d "$TOOLKIT_ROOT/.git" ]; then
  CURRENT_SHA="$(git -C "$TOOLKIT_ROOT" rev-parse HEAD)"
else
  CURRENT_SHA="$(cat "$TOOLKIT_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
fi

echo "==> Updating project: $PROJECT_DIR"
echo "    Toolkit: $OLD_SHA → $CURRENT_SHA"

if [ "$OLD_SHA" = "$CURRENT_SHA" ]; then
  echo "==> Already up to date."
  exit 0
fi

# Show changes between versions.
echo ""
echo "==> Changes in toolkit since last update:"
if git -C "$TOOLKIT_ROOT" log --oneline "$OLD_SHA..$CURRENT_SHA" 2>/dev/null; then
  echo ""
elif command -v gh >/dev/null 2>&1; then
  gh release list --repo henrymodisett/toolkit --limit 15 2>/dev/null | head -10 || true
  echo ""
else
  echo "    (couldn't compute changes — old SHA may have been garbage collected)"
  echo "    Run: toolkit changelog"
  echo ""
fi

# --------------------------------------------------------------------------
# Toolkit-owned files — update with .bak backup if locally modified
# --------------------------------------------------------------------------

ADDED=0
UPDATED=0
UNCHANGED=0

next_backup_path() {
  local dst="$1"
  local backup="$dst.bak"
  local i=1

  while [ -e "$backup" ]; do
    backup="$dst.bak.$i"
    i=$((i + 1))
  done

  printf '%s' "$backup"
}

update_file() {
  local src="$1"
  local dst="$2"
  local backup_path dst_dir
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
    backup_path="$(next_backup_path "$dst")"
    cp "$dst" "$backup_path"
    cp "$src" "$dst"
    echo "    ! updated (backed up as $(basename "$backup_path")): $dst"
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

# Read project type (default: generic for backward compatibility).
PROJECT_TYPE="generic"
if [ -f "$PROJECT_DIR/.toolkit-config" ]; then
  PROJECT_TYPE="$(grep '^project_type=' "$PROJECT_DIR/.toolkit-config" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
  PROJECT_TYPE="${PROJECT_TYPE:-generic}"
fi

# Scripts
update_file "$TOOLKIT_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
update_file "$TOOLKIT_ROOT/scripts/toolkit-run.sh" "$PROJECT_DIR/scripts/toolkit-run.sh"
update_file "$TOOLKIT_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
update_file "$TOOLKIT_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
update_file "$TOOLKIT_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"

if [ "$PROJECT_TYPE" = "python" ] || [ -f "$PROJECT_DIR/scripts/run-pytest-in-venv.sh" ]; then
  update_file "$TOOLKIT_ROOT/scripts/run-pytest-in-venv.sh" "$PROJECT_DIR/scripts/run-pytest-in-venv.sh"
fi

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

# Auto-install pre-commit hooks if pre-commit is available and hooks are missing.
if [ "$DRY_RUN" = false ] && [ -f "$PROJECT_DIR/.pre-commit-config.yaml" ]; then
  if command -v pre-commit >/dev/null 2>&1; then
    if [ ! -f "$PROJECT_DIR/.git/hooks/pre-push" ] || [ ! -f "$PROJECT_DIR/.git/hooks/pre-commit" ]; then
      echo ""
      echo "==> Installing pre-commit hooks..."
      # Clear core.hooksPath if set — it conflicts with pre-commit.
      (cd "$PROJECT_DIR" && git config --unset-all core.hooksPath 2>/dev/null || true)
      # Install shims only (not --install-hooks) to avoid python env issues.
      # Environments install lazily on first commit/push.
      (cd "$PROJECT_DIR" && pre-commit install 2>&1 | tail -1)
      (cd "$PROJECT_DIR" && pre-commit install --hook-type pre-push 2>&1 | tail -1)
      (cd "$PROJECT_DIR" && pre-commit install --hook-type commit-msg 2>&1 | tail -1)
      echo "    Hooks installed (environments install on first run)."
    fi
  fi
fi

# Hint about project-owned files.
echo ""
echo "==> Project-owned files (not auto-updated):"
echo "    Consider reviewing these against the latest toolkit templates:"
echo "      toolkit diff"
echo "      diff $TOOLKIT_ROOT/templates/CLAUDE.md ./CLAUDE.md"
echo "      diff $TOOLKIT_ROOT/templates/AGENTS.md ./AGENTS.md"
echo "      diff $TOOLKIT_ROOT/templates/pre-commit-config.yaml ./.pre-commit-config.yaml"
echo "      diff $TOOLKIT_ROOT/hooks/codex-review.config.example.toml ./.codex-review.toml"
echo ""
echo "==> Done."
