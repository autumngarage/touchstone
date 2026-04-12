#!/usr/bin/env bash
#
# bootstrap/sync-all.sh — update all registered projects to the latest toolkit.
#
# Usage:
#   ~/Repos/toolkit/bootstrap/sync-all.sh              # update all projects
#   ~/Repos/toolkit/bootstrap/sync-all.sh --dry-run     # show what would change
#   ~/Repos/toolkit/bootstrap/sync-all.sh --pull-first  # git pull toolkit before syncing
#
# Reads project paths from ~/.toolkit-projects (one path per line, populated
# by new-project.sh). Runs update-project.sh in each one.
#
# For fully automated sync, add to cron:
#   crontab -e
#   0 9 * * 1  cd ~/Repos/toolkit && git pull && ~/Repos/toolkit/bootstrap/sync-all.sh
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE_SCRIPT="$TOOLKIT_ROOT/bootstrap/update-project.sh"
PROJECTS_FILE="$HOME/.toolkit-projects"
DRY_RUN=""
PULL_FIRST=false
CHECK_ONLY=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN="--dry-run"; shift ;;
    --pull-first) PULL_FIRST=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    -h|--help)
      sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ ! -f "$PROJECTS_FILE" ]; then
  echo "No projects registered. Bootstrap a project first:"
  echo "  $TOOLKIT_ROOT/bootstrap/new-project.sh <project-dir>"
  exit 0
fi

# Optionally update the toolkit itself first.
if [ "$PULL_FIRST" = true ]; then
  echo "==> Pulling latest toolkit ..."
  git -C "$TOOLKIT_ROOT" pull --rebase
  echo ""
fi

# Check-only mode: report which projects need sync, then exit.
if [ "$CHECK_ONLY" = true ]; then
  CURRENT_ID="$(
    if [ -d "$TOOLKIT_ROOT/.git" ]; then
      git -C "$TOOLKIT_ROOT" rev-parse HEAD
    else
      cat "$TOOLKIT_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]'
    fi
  )"
  BEHIND=0
  TOTAL=0
  while IFS= read -r project_dir; do
    [ -z "$project_dir" ] && continue
    [[ "$project_dir" == \#* ]] && continue
    TOTAL=$((TOTAL + 1))
    if [ ! -d "$project_dir" ]; then
      echo "  ? $(basename "$project_dir") — directory not found"
      continue
    fi
    proj_id="$(cat "$project_dir/.toolkit-version" 2>/dev/null | tr -d '[:space:]' || echo "none")"
    if [ "$proj_id" = "$CURRENT_ID" ]; then
      echo "  ✓ $(basename "$project_dir") — up to date"
    else
      echo "  ! $(basename "$project_dir") — needs sync"
      BEHIND=$((BEHIND + 1))
    fi
  done < "$PROJECTS_FILE"
  echo ""
  if [ "$BEHIND" -eq 0 ]; then
    echo "All $TOTAL projects are up to date."
  else
    echo "$BEHIND/$TOTAL projects need sync. Run: toolkit sync"
  fi
  exit 0
fi

TOTAL=0
SUCCESS=0
SKIPPED=0
FAILED=0

while IFS= read -r project_dir; do
  # Skip empty lines and comments.
  [ -z "$project_dir" ] && continue
  [[ "$project_dir" == \#* ]] && continue

  TOTAL=$((TOTAL + 1))

  if [ ! -d "$project_dir" ]; then
    echo "==> SKIPPED (directory not found): $project_dir"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo ""
  echo "================================================================"
  echo "==> Syncing: $project_dir"
  echo "================================================================"

  if (cd "$project_dir" && bash "$UPDATE_SCRIPT" $DRY_RUN); then
    SUCCESS=$((SUCCESS + 1))
  else
    echo "==> FAILED: $project_dir"
    FAILED=$((FAILED + 1))
  fi
done < "$PROJECTS_FILE"

echo ""
echo "================================================================"
echo "==> Sync complete: $SUCCESS/$TOTAL succeeded, $SKIPPED skipped, $FAILED failed"
echo "================================================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
