#!/usr/bin/env bash
#
# bootstrap/new-project.sh — spin up a new project with toolkit files.
#
# Usage:
#   new-project.sh <project-dir>
#   new-project.sh <project-dir> --no-register   # skip adding to ~/.toolkit-projects
#
# What this does:
#   1. Creates the directory if it doesn't exist, initializes git
#   2. Copies templates, principles, hooks, and scripts into the project
#   3. Makes scripts executable
#   4. Writes .toolkit-version with the current toolkit commit SHA
#   5. Registers the project in ~/.toolkit-projects (for sync-all.sh)
#   6. Prints next steps
#
# After running, fill in the {{PLACEHOLDERS}} in CLAUDE.md and AGENTS.md.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTER=true

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <project-dir> [--no-register]" >&2
  exit 1
fi

PROJECT_DIR="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-register) REGISTER=false; shift ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Resolve to absolute path.
if [[ "$PROJECT_DIR" != /* ]]; then
  PROJECT_DIR="$(pwd)/$PROJECT_DIR"
fi

echo "==> Bootstrapping project at $PROJECT_DIR"

# Create directory if needed.
mkdir -p "$PROJECT_DIR"

# Init git if not already a repo.
if [ ! -d "$PROJECT_DIR/.git" ]; then
  echo "==> Initializing git repo ..."
  git -C "$PROJECT_DIR" init
fi

# Helper: copy a file, prompting if it would overwrite.
copy_file() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"

  if [ -f "$dst" ]; then
    echo "    exists (skipped): $(basename "$dst")"
  else
    cp "$src" "$dst"
    echo "    + $(basename "$dst")"
  fi
}

# Helper: copy a file, always overwrite (for toolkit-owned files).
copy_file_force() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"

  cp "$src" "$dst"
  echo "    + $(basename "$dst")"
}

echo ""
echo "==> Copying templates (project-owned, won't be auto-updated):"
copy_file "$TOOLKIT_ROOT/templates/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
copy_file "$TOOLKIT_ROOT/templates/AGENTS.md" "$PROJECT_DIR/AGENTS.md"
copy_file "$TOOLKIT_ROOT/templates/pre-commit-config.yaml" "$PROJECT_DIR/.pre-commit-config.yaml"
copy_file "$TOOLKIT_ROOT/templates/gitignore" "$PROJECT_DIR/.gitignore"
copy_file "$TOOLKIT_ROOT/templates/pull_request_template.md" "$PROJECT_DIR/.github/pull_request_template.md"
copy_file "$TOOLKIT_ROOT/hooks/codex-review.config.example.toml" "$PROJECT_DIR/.codex-review.toml"
copy_file "$TOOLKIT_ROOT/templates/setup.sh" "$PROJECT_DIR/setup.sh"
chmod +x "$PROJECT_DIR/setup.sh" 2>/dev/null || true

echo ""
echo "==> Copying principles (toolkit-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/principles"
for f in "$TOOLKIT_ROOT/principles/"*.md; do
  copy_file_force "$f" "$PROJECT_DIR/principles/$(basename "$f")"
done

echo ""
echo "==> Copying scripts (toolkit-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/scripts"
copy_file_force "$TOOLKIT_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
copy_file_force "$TOOLKIT_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
copy_file_force "$TOOLKIT_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
copy_file_force "$TOOLKIT_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
chmod +x "$PROJECT_DIR/scripts/"*.sh

# Write toolkit version.
# Use git SHA if this is a git clone, otherwise use VERSION (brew install).
if [ -d "$TOOLKIT_ROOT/.git" ]; then
  TOOLKIT_SHA="$(git -C "$TOOLKIT_ROOT" rev-parse HEAD)"
else
  TOOLKIT_SHA="$(cat "$TOOLKIT_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
fi
echo "$TOOLKIT_SHA" > "$PROJECT_DIR/.toolkit-version"
echo ""
echo "==> Wrote .toolkit-version: $TOOLKIT_SHA"

# Register in ~/.toolkit-projects for sync-all.sh.
PROJECTS_FILE="$HOME/.toolkit-projects"
if [ "$REGISTER" = true ]; then
  # Ensure file exists.
  touch "$PROJECTS_FILE"
  # Add if not already registered.
  if ! grep -qxF "$PROJECT_DIR" "$PROJECTS_FILE" 2>/dev/null; then
    echo "$PROJECT_DIR" >> "$PROJECTS_FILE"
    echo "==> Registered in $PROJECTS_FILE"
  else
    echo "==> Already registered in $PROJECTS_FILE"
  fi
fi

echo ""
echo "==> Done! Next steps:"
echo ""
echo "   1. Fill in {{PLACEHOLDERS}} in CLAUDE.md and AGENTS.md"
echo "   2. Configure .codex-review.toml with your high-scrutiny paths"
echo "   3. Install pre-commit hooks:"
echo "        cd $PROJECT_DIR"
echo "        pip install pre-commit  # if not installed"
echo "        pre-commit install --install-hooks"
echo "   4. Install Codex CLI (optional, for pre-push review):"
echo "        npm install -g @openai/codex && codex login"
echo ""
