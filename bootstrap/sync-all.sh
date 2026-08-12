#!/usr/bin/env bash
#
# bootstrap/sync-all.sh — update all registered projects to the latest touchstone.
#
# Usage:
#   touchstone update-all              # update all projects
#   touchstone update-all --dry-run    # show what would change
#   touchstone update-all --ship       # ship project updates through PRs
#   touchstone update-all --pull-first # git pull touchstone before updating projects
#
# Reads project paths from ~/.touchstone-projects (one path per line, populated
# by new-project.sh). Runs update-project.sh in each one.
#
# For fully automated updates, add to cron:
#   crontab -e
#   0 9 * * 1  touchstone update-all --pull-first
#
# Exit codes (tri-state, #731): 0 = every project succeeded (with --ship:
# every shipped PR MERGED) or was skipped; 20 = no hard failures but at
# least one --ship PR is armed and NOT merged; 1 = at least one project
# failed. The summary line counts the three states separately.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE_SCRIPT="$TOUCHSTONE_ROOT/bootstrap/update-project.sh"
PROJECTS_FILE="$HOME/.touchstone-projects"
DRY_RUN=""
SHIP=""
PULL_FIRST=false
CHECK_ONLY=false
ORIGINAL_ARGS=("$@")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run | -n)
      DRY_RUN="--dry-run"
      shift
      ;;
    --pull-first)
      PULL_FIRST=true
      shift
      ;;
    --ship)
      SHIP="--ship"
      shift
      ;;
    --check)
      CHECK_ONLY=true
      shift
      ;;
    -h | --help)
      sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$PROJECTS_FILE" ]; then
  echo "No projects registered. Bootstrap a project first:"
  echo "  $TOUCHSTONE_ROOT/bootstrap/new-project.sh <project-dir>"
  exit 0
fi

PROJECTS=()
while IFS= read -r project_dir || [ -n "$project_dir" ]; do
  [ -z "$project_dir" ] && continue
  [[ "$project_dir" == \#* ]] && continue
  PROJECTS+=("$project_dir")
done <"$PROJECTS_FILE"

# Optionally update the Touchstone itself first.
if [ "$PULL_FIRST" = true ]; then
  if [ "${TOUCHSTONE_UPDATE_ALL_REEXECED:-}" = "1" ]; then
    echo "==> Touchstone was refreshed before re-exec."
  else
    echo "==> Pulling latest touchstone ..."
    if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
      git -C "$TOUCHSTONE_ROOT" pull --rebase
    elif command -v brew >/dev/null 2>&1 && brew list touchstone >/dev/null 2>&1; then
      brew update
      if ! brew upgrade touchstone; then
        echo "WARNING: brew upgrade touchstone failed; continuing with current install." >&2
      fi
    else
      echo "WARNING: cannot update Touchstone first; install is neither a git checkout nor a Homebrew package." >&2
    fi
    echo ""

    reexec_path=""
    if [ -d "$TOUCHSTONE_ROOT/.git" ] && [ -x "$TOUCHSTONE_ROOT/bin/touchstone" ]; then
      reexec_path="$TOUCHSTONE_ROOT/bin/touchstone"
    else
      reexec_path="$(command -v touchstone 2>/dev/null || true)"
    fi
    if [ -n "$reexec_path" ] && [ -x "$reexec_path" ]; then
      TOUCHSTONE_UPDATE_ALL_REEXECED=1 exec "$reexec_path" update-all ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
    fi
  fi
fi

# Check-only mode: report which projects need update, then exit.
if [ "$CHECK_ONLY" = true ]; then
  # The verdict is the SHARED content predicate (#731) — the same one behind
  # `touchstone update --check`, auto-sync, and `touchstone status` — so the
  # fleet listing can never disagree with the per-project check. Raw stamp
  # identity survives only as display detail. Sourced lazily: only --check
  # needs the probe, and minimal fixtures exercise the fan-out path without
  # a lib/ directory.
  SYNC_CONTENT_LIB="$TOUCHSTONE_ROOT/lib/sync-content.sh"
  if [ ! -f "$SYNC_CONTENT_LIB" ]; then
    echo "ERROR: $SYNC_CONTENT_LIB is missing; cannot compute the shared content verdict." >&2
    echo "       Restore it with a full touchstone install (brew reinstall touchstone," >&2
    echo "       or git -C <touchstone-checkout> checkout lib/sync-content.sh)." >&2
    exit 1
  fi
  # shellcheck source=../lib/sync-content.sh
  source "$SYNC_CONTENT_LIB"
  CURRENT_ID="$(touchstone_content_installed_id "$TOUCHSTONE_ROOT")"
  BEHIND=0
  TOTAL=0
  for project_dir in ${PROJECTS[@]+"${PROJECTS[@]}"}; do
    TOTAL=$((TOTAL + 1))
    if [ ! -d "$project_dir" ]; then
      echo "  ? $(basename "$project_dir") — directory not found"
      continue
    fi
    proj_id="$(cat "$project_dir/.touchstone-version" 2>/dev/null | tr -d '[:space:]' || echo "none")"
    if [ "$proj_id" = "$CURRENT_ID" ]; then
      echo "  ✓ $(basename "$project_dir") — up to date"
    elif touchstone_content_is_current "$project_dir" "$TOUCHSTONE_ROOT" 2>/dev/null; then
      echo "  ✓ $(basename "$project_dir") — up to date (content matches; stamp $proj_id differs from $CURRENT_ID)"
    else
      echo "  ! $(basename "$project_dir") — needs update"
      BEHIND=$((BEHIND + 1))
    fi
  done
  echo ""
  if [ "$BEHIND" -eq 0 ]; then
    echo "All $TOTAL projects are up to date."
  else
    echo "$BEHIND/$TOTAL projects need update. Run: touchstone update-all"
  fi
  exit 0
fi

# Tri-state fan-out tally (#731). update-project.sh's documented ship
# contract: exit 0 = update applied and (with --ship) the PR is MERGED;
# exit 20 = the PR is armed but NOT merged (review pending, merge-gate or
# diff-scope refusal); anything else = stuck. "Succeeded" must never absorb
# an armed-but-unmerged PR — these tallies feed automation, not a banner.
UPDATE_ARMED_EXIT=20

TOTAL=0
SUCCESS=0
ARMED=0
SKIPPED=0
FAILED=0

for project_dir in ${PROJECTS[@]+"${PROJECTS[@]}"}; do
  TOTAL=$((TOTAL + 1))

  if [ ! -d "$project_dir" ]; then
    echo "==> SKIPPED (directory not found): $project_dir"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo ""
  echo "================================================================"
  echo "==> Updating: $project_dir"
  echo "================================================================"

  update_args=()
  [ -z "$DRY_RUN" ] || update_args+=("$DRY_RUN")
  [ -z "$SHIP" ] || update_args+=("$SHIP")
  project_rc=0
  (cd "$project_dir" && bash "$UPDATE_SCRIPT" ${update_args[@]+"${update_args[@]}"} </dev/null) || project_rc=$?
  if [ "$project_rc" -eq 0 ]; then
    SUCCESS=$((SUCCESS + 1))
  elif [ -n "$SHIP" ] && [ "$project_rc" -eq "$UPDATE_ARMED_EXIT" ]; then
    echo "==> ARMED (PR open, not merged): $project_dir"
    ARMED=$((ARMED + 1))
  else
    echo "==> FAILED: $project_dir"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "================================================================"
echo "==> Update-all complete: $SUCCESS/$TOTAL succeeded, $ARMED armed (PR open, not merged), $SKIPPED skipped, $FAILED failed"
echo "================================================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
# Armed is not success: propagate the tri-state so automated callers see
# that at least one PR still needs a merge (same code update-project uses).
if [ "$ARMED" -gt 0 ]; then
  exit "$UPDATE_ARMED_EXIT"
fi
