#!/usr/bin/env bash
#
# bootstrap/update-project.sh — update toolkit-owned files in a project.
#
# Usage:
#   ~/Repos/toolkit/bootstrap/update-project.sh
#   ~/Repos/toolkit/bootstrap/update-project.sh --dry-run   # show what would change
#   ~/Repos/toolkit/bootstrap/update-project.sh --check     # report whether update is needed
#
# What this does:
#   1. Reads .toolkit-version from the project to know what toolkit is installed
#   2. Creates a chore/toolkit-* branch from a clean worktree
#   3. Updates toolkit-owned files without .bak backups; git is the backup
#   4. Updates .toolkit-version and .toolkit-manifest
#   5. Commits the update so it is reviewable and reversible as one unit
#   6. Leaves project-owned files untouched and prints a review hint
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(pwd)"
DRY_RUN=false
CHECK_ONLY=false
REQUESTED_BRANCH=""

usage() {
  echo "Usage: $0 [--dry-run|-n] [--check] [--branch <name>]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --branch)
      [ "$#" -ge 2 ] || { echo "ERROR: --branch requires a value" >&2; exit 1; }
      REQUESTED_BRANCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
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
CURRENT_VERSION="$(cat "$TOOLKIT_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"

# Use git SHA if this is a git clone, otherwise use VERSION (brew install).
if [ -d "$TOOLKIT_ROOT/.git" ]; then
  CURRENT_SHA="$(git -C "$TOOLKIT_ROOT" rev-parse HEAD)"
  CURRENT_SHORT="$(git -C "$TOOLKIT_ROOT" rev-parse --short HEAD)"
  if [ -n "$CURRENT_VERSION" ]; then
    CURRENT_LABEL="${CURRENT_VERSION}-${CURRENT_SHORT}"
  else
    CURRENT_LABEL="$CURRENT_SHORT"
  fi
else
  CURRENT_SHA="${CURRENT_VERSION:-unknown}"
  CURRENT_SHORT="$CURRENT_SHA"
  CURRENT_LABEL="$CURRENT_SHA"
fi

echo "==> Updating project: $PROJECT_DIR"
echo "    Toolkit: $OLD_SHA -> $CURRENT_SHA"

if [ "$OLD_SHA" = "$CURRENT_SHA" ]; then
  echo "==> Already up to date."
  exit 0
fi

if [ "$CHECK_ONLY" = true ]; then
  echo "==> Needs sync."
  echo "    Run: toolkit update"
  exit 0
fi

sanitize_branch_component() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

unique_branch_name() {
  local base="$1"
  local candidate="$base"
  local i=1

  while git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$candidate"; do
    candidate="${base}-${i}"
    i=$((i + 1))
  done

  printf '%s' "$candidate"
}

relative_project_path() {
  local path="$1"
  printf '%s' "${path#"$PROJECT_DIR"/}"
}

ADDED_PATHS=()
BRANCH_CREATED=false
COMMIT_CREATED=false
ORIGINAL_BRANCH=""
UPDATE_BRANCH=""
ROLLBACK_TMP_DIR=""

snapshot_toolkit_metadata() {
  ROLLBACK_TMP_DIR="$(mktemp -d -t toolkit-update-rollback.XXXXXX)"
  cp "$PROJECT_DIR/.toolkit-version" "$ROLLBACK_TMP_DIR/.toolkit-version"
  if [ -f "$PROJECT_DIR/.toolkit-manifest" ]; then
    cp "$PROJECT_DIR/.toolkit-manifest" "$ROLLBACK_TMP_DIR/.toolkit-manifest"
  elif [ -e "$PROJECT_DIR/.toolkit-manifest" ]; then
    : > "$ROLLBACK_TMP_DIR/.toolkit-manifest.nonfile"
  else
    : > "$ROLLBACK_TMP_DIR/.toolkit-manifest.missing"
  fi
}

restore_toolkit_metadata() {
  [ -n "$ROLLBACK_TMP_DIR" ] || return

  if [ -f "$ROLLBACK_TMP_DIR/.toolkit-version" ]; then
    cp "$ROLLBACK_TMP_DIR/.toolkit-version" "$PROJECT_DIR/.toolkit-version"
  fi

  if [ -f "$ROLLBACK_TMP_DIR/.toolkit-manifest.missing" ]; then
    if [ -f "$PROJECT_DIR/.toolkit-manifest" ]; then
      rm -f "$PROJECT_DIR/.toolkit-manifest"
    fi
  elif [ -f "$ROLLBACK_TMP_DIR/.toolkit-manifest" ]; then
    cp "$ROLLBACK_TMP_DIR/.toolkit-manifest" "$PROJECT_DIR/.toolkit-manifest"
  fi
}

rollback_failed_update() {
  local rc=$?

  if [ "$rc" -eq 0 ] || [ "$BRANCH_CREATED" != true ] || [ "$COMMIT_CREATED" = true ]; then
    if [ -n "$ROLLBACK_TMP_DIR" ]; then
      rm -rf "$ROLLBACK_TMP_DIR"
    fi
    return
  fi

  echo "" >&2
  echo "==> Update failed; rolling back $UPDATE_BRANCH" >&2
  git -C "$PROJECT_DIR" restore --staged --worktree . >/dev/null 2>&1 || true
  restore_toolkit_metadata

  local rel
  for rel in "${ADDED_PATHS[@]}"; do
    rm -f "$PROJECT_DIR/$rel" 2>/dev/null || true
  done

  if [ -n "$ORIGINAL_BRANCH" ]; then
    git -C "$PROJECT_DIR" checkout -f "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
  fi
  if [ -n "$UPDATE_BRANCH" ]; then
    git -C "$PROJECT_DIR" branch -D "$UPDATE_BRANCH" >/dev/null 2>&1 || true
  fi
  if [ -n "$ROLLBACK_TMP_DIR" ]; then
    rm -rf "$ROLLBACK_TMP_DIR"
  fi
}
trap rollback_failed_update EXIT

require_clean_git_repo() {
  if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: toolkit update requires a git repository." >&2
    echo "       Git is the backup and review boundary for toolkit updates." >&2
    exit 1
  fi

  if ! git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "ERROR: toolkit update requires at least one existing commit." >&2
    echo "       Commit the initial project state first, then run toolkit update." >&2
    exit 1
  fi

  ORIGINAL_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  if [ "$ORIGINAL_BRANCH" = "HEAD" ]; then
    echo "ERROR: toolkit update cannot run from a detached HEAD." >&2
    echo "       Check out a branch first, then run toolkit update." >&2
    exit 1
  fi

  if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "ERROR: Working tree is dirty. toolkit update needs a clean git boundary." >&2
    echo "       Commit, stash, or revert local changes, then run toolkit update." >&2
    echo "       Preview safely with: toolkit update --dry-run" >&2
    exit 1
  fi
}

if [ "$DRY_RUN" = false ]; then
  require_clean_git_repo

  if [ -n "$REQUESTED_BRANCH" ]; then
    UPDATE_BRANCH="$REQUESTED_BRANCH"
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$UPDATE_BRANCH"; then
      echo "ERROR: Branch already exists: $UPDATE_BRANCH" >&2
      exit 1
    fi
  else
    UPDATE_BRANCH="$(unique_branch_name "chore/toolkit-$(sanitize_branch_component "$CURRENT_LABEL")")"
  fi

  snapshot_toolkit_metadata
  echo "==> Creating update branch: $UPDATE_BRANCH"
  git -C "$PROJECT_DIR" checkout -b "$UPDATE_BRANCH" >/dev/null
  BRANCH_CREATED=true
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
# Toolkit-owned files
# --------------------------------------------------------------------------

ADDED=0
UPDATED=0
UNCHANGED=0

update_file() {
  local src="$1"
  local dst="$2"
  local dst_dir rel_path
  dst_dir="$(dirname "$dst")"
  rel_path="$(relative_project_path "$dst")"

  if [ ! -f "$dst" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "    + would add: $dst"
    else
      mkdir -p "$dst_dir"
      cp "$src" "$dst"
      ADDED_PATHS+=("$rel_path")
      echo "    + added: $dst"
    fi
    ADDED=$((ADDED + 1))
    return
  fi

  if diff -q "$src" "$dst" >/dev/null 2>&1; then
    UNCHANGED=$((UNCHANGED + 1))
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "    ! would update: $dst"
  else
    cp "$src" "$dst"
    echo "    ! updated: $dst"
  fi
  UPDATED=$((UPDATED + 1))
}

echo "==> Updating toolkit-owned files:"

# Principles
if [ -d "$TOOLKIT_ROOT/principles" ]; then
  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$PROJECT_DIR/principles"
  fi
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

write_toolkit_manifest() {
  local manifest="$PROJECT_DIR/.toolkit-manifest"
  {
    printf '# Managed by toolkit. These paths may be updated by `toolkit update`.\n'
    printf '.toolkit-manifest\n'
    printf '.toolkit-version\n'
    if [ -d "$TOOLKIT_ROOT/principles" ]; then
      for f in "$TOOLKIT_ROOT/principles/"*.md; do
        printf 'principles/%s\n' "$(basename "$f")"
      done
    fi
    printf 'scripts/codex-review.sh\n'
    printf 'scripts/toolkit-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    if [ "$PROJECT_TYPE" = "python" ] || [ -f "$PROJECT_DIR/scripts/run-pytest-in-venv.sh" ]; then
      printf 'scripts/run-pytest-in-venv.sh\n'
    fi
  } > "$manifest"
}

# Ensure scripts are executable and write toolkit metadata.
if [ "$DRY_RUN" = false ]; then
  if [ -d "$PROJECT_DIR/scripts" ]; then
    chmod +x "$PROJECT_DIR/scripts/"*.sh 2>/dev/null || true
  fi
  echo "$CURRENT_SHA" > "$PROJECT_DIR/.toolkit-version"
  write_toolkit_manifest
fi

echo ""
echo "==> Summary: $ADDED added, $UPDATED updated, $UNCHANGED unchanged"

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

if [ "$DRY_RUN" = false ]; then
  echo ""
  echo "==> Committing toolkit update..."
  git -C "$PROJECT_DIR" add -A -- principles scripts .toolkit-manifest
  git -C "$PROJECT_DIR" add -f -- .toolkit-version

  if git -C "$PROJECT_DIR" diff --cached --quiet; then
    echo "    No file changes to commit."
  else
    git -C "$PROJECT_DIR" commit --no-verify -m "chore: update toolkit to ${CURRENT_LABEL}" >/dev/null
    COMMIT_CREATED=true
    echo "    Committed: chore: update toolkit to ${CURRENT_LABEL}"
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

if [ "$DRY_RUN" = false ]; then
  echo ""
  echo "==> Done. Review the update branch:"
  echo "    branch: $UPDATE_BRANCH"
  echo "    git diff ${ORIGINAL_BRANCH}...HEAD"
  echo "    bash scripts/open-pr.sh"
else
  echo ""
  echo "==> Dry run complete. Apply with: toolkit update"
fi
