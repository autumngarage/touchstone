#!/usr/bin/env bash
#
# bootstrap/update-project.sh — update touchstone-owned files in a project.
#
# Usage:
#   ~/Repos/touchstone/bootstrap/update-project.sh
#   ~/Repos/touchstone/bootstrap/update-project.sh --in-place # commit on current branch
#   ~/Repos/touchstone/bootstrap/update-project.sh --dry-run   # show what would change
#   ~/Repos/touchstone/bootstrap/update-project.sh --check     # report whether update is needed
#
# What this does:
#   1. Reads .touchstone-version from the project to know what touchstone is installed
#   2. Creates a chore/touchstone-* branch from a clean worktree, unless
#      --in-place/--no-branch is passed
#   3. Updates touchstone-owned files without .bak backups; git is the backup
#   4. Updates .touchstone-version and .touchstone-manifest
#   5. Commits the update so it is reviewable and reversible as one unit
#   6. Leaves project-owned files untouched and prints a review hint
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/safe-write.sh
source "$TOUCHSTONE_ROOT/lib/safe-write.sh"
# shellcheck source=lib/sed-inplace.sh
source "$TOUCHSTONE_ROOT/lib/sed-inplace.sh"
# shellcheck source=../lib/install-hooks.sh
source "$TOUCHSTONE_ROOT/lib/install-hooks.sh"
# shellcheck source=../lib/touchstone-block.sh
source "$TOUCHSTONE_ROOT/lib/touchstone-block.sh"
# shellcheck source=../lib/install-skills.sh
source "$TOUCHSTONE_ROOT/lib/install-skills.sh"
# shellcheck source=../lib/sync-discipline.sh
source "$TOUCHSTONE_ROOT/lib/sync-discipline.sh"
# shellcheck source=../lib/sha256.sh
source "$TOUCHSTONE_ROOT/lib/sha256.sh"
PROJECT_DIR="$(pwd)"
DRY_RUN=false
CHECK_ONLY=false
REQUESTED_BRANCH=""
SHIP=false
IN_PLACE=false
RETIRED_MANAGED_PATHS=()

usage() {
  echo "Usage: $0 [--dry-run|-n] [--check] [--branch <name>] [--in-place|--no-branch] [--ship]"
  echo "Env: TOUCHSTONE_FORCE_OVERLAP=1 proceeds even when dirty paths overlap planned writes (explicit update only; ignored by background auto-sync)."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run | -n)
      DRY_RUN=true
      shift
      ;;
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --ship)
      SHIP=true
      shift
      ;;
    --no-ship)
      SHIP=false
      shift
      ;;
    --in-place | --no-branch)
      IN_PLACE=true
      shift
      ;;
    --branch)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --branch requires a value" >&2
        exit 1
      }
      REQUESTED_BRANCH="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$IN_PLACE" = true ] && [ -n "$REQUESTED_BRANCH" ]; then
  echo "ERROR: --branch cannot be combined with --in-place/--no-branch." >&2
  exit 1
fi

# Verify we're in a project with .touchstone-version.
if [ ! -f "$PROJECT_DIR/.touchstone-version" ]; then
  if [ -f "$PROJECT_DIR/.toolkit-version" ]; then
    echo "ERROR: Legacy .toolkit-version found in $PROJECT_DIR" >&2
    echo "       This project was bootstrapped before the toolkit -> touchstone rename." >&2
    echo "       Run: touchstone migrate-from-toolkit" >&2
    echo "       Then re-run: touchstone update" >&2
    exit 1
  fi
  echo "ERROR: No .touchstone-version file found in $PROJECT_DIR" >&2
  echo "       This project hasn't been bootstrapped with Touchstone." >&2
  echo "       Run: $(dirname "$0")/new-project.sh $PROJECT_DIR" >&2
  exit 1
fi

OLD_SHA="$(cat "$PROJECT_DIR/.touchstone-version" | tr -d '[:space:]')"
CURRENT_VERSION="$(cat "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"

# Use git SHA if this is a git clone, otherwise use VERSION (brew install).
if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
  CURRENT_SHA="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
  CURRENT_SHORT="$(git -C "$TOUCHSTONE_ROOT" rev-parse --short HEAD)"
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

# Project type steers per-profile managed files. Read early: the staleness
# probe and the copy pass below both depend on it.
PROJECT_TYPE="generic"
if [ -f "$PROJECT_DIR/.touchstone-config" ]; then
  PROJECT_TYPE="$(grep '^project_type=' "$PROJECT_DIR/.touchstone-config" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
  PROJECT_TYPE="${PROJECT_TYPE:-generic}"
fi

echo "==> Updating project: $PROJECT_DIR"
echo "    Touchstone: $OLD_SHA -> $CURRENT_SHA"

retired_review_shim_manifest_entries() {
  local manifest="$PROJECT_DIR/.touchstone-manifest"
  local manifest_entry
  local has_primary_shim=false
  local has_compat_shim=false

  [ -f "$manifest" ] || return 0
  while IFS= read -r manifest_entry || [ -n "$manifest_entry" ]; do
    manifest_entry="${manifest_entry%$'\r'}"
    case "$manifest_entry" in
      scripts/conductor-review.sh) has_primary_shim=true ;;
      scripts/codex-review.sh) has_compat_shim=true ;;
    esac
  done <"$manifest"
  [ "$has_primary_shim" = true ] && printf 'scripts/conductor-review.sh\n'
  [ "$has_compat_shim" = true ] && printf 'scripts/codex-review.sh\n'
  return 0
}

RETIRED_REVIEW_SHIM_ENTRIES="$(retired_review_shim_manifest_entries)"
if [ -n "$RETIRED_REVIEW_SHIM_ENTRIES" ]; then
  if [ "$DRY_RUN" = true ]; then
    echo "WARNING: Retired local review shims require a project-owned migration before Touchstone can update." >&2
  else
    echo "ERROR: Retired local review shims require a project-owned migration before Touchstone can update." >&2
  fi
  printf '%s\n' "$RETIRED_REVIEW_SHIM_ENTRIES" | sed 's/^/         - /' >&2
  echo "       Remove their project-owned hooks, delete these files, and remove the same entries" >&2
  echo "       from .touchstone-manifest. Commit the migration together." >&2
  echo "       Then rerun: touchstone update" >&2
  if [ "$DRY_RUN" != true ]; then
    exit 1
  fi
fi

# Single source of truth for touchstone-owned file copies: src<TAB>dst lines
# consumed by both the copy pass and the content-staleness probe, so the two
# can never disagree about what "managed" means.
managed_file_pairs() {
  local f

  # Principles
  if [ -d "$TOUCHSTONE_ROOT/principles" ]; then
    for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
      printf '%s\t%s\n' "$f" "$PROJECT_DIR/principles/$(basename "$f")"
    done
  fi

  # TOUCHSTONE.md — canonical lean-router steering doc, imported by CLAUDE.md
  # (@TOUCHSTONE.md) and inlined into AGENTS.md/GEMINI.md by touchstone_block_apply.
  if [ -f "$TOUCHSTONE_ROOT/TOUCHSTONE.md" ]; then
    printf '%s\t%s\n' "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "$PROJECT_DIR/TOUCHSTONE.md"
  fi

  # Required deterministic backstop for the issue-claim workflow. General CI
  # validate.yml remains opt-in and project-owned; this workflow is part of the
  # documented Touchstone delivery contract.
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/templates/ci/issue-claim-check.yml" "$PROJECT_DIR/.github/workflows/issue-claim-check.yml"

  # Scripts
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" "$PROJECT_DIR/scripts/branch-guard.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh" "$PROJECT_DIR/scripts/emergency-disclosure.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_DIR/scripts/touchstone-run.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/claim-issue.sh" "$PROJECT_DIR/scripts/claim-issue.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/respond-review.sh" "$PROJECT_DIR/scripts/respond-review.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$PROJECT_DIR/scripts/issue-claim-check.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" "$PROJECT_DIR/scripts/spawn-worktree.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" "$PROJECT_DIR/scripts/cleanup-worktrees.sh"

  # Libraries used by touchstone-owned scripts.
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/lib/toml.sh" "$PROJECT_DIR/lib/toml.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/lib/events.sh" "$PROJECT_DIR/lib/events.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/lib/codex-auth.sh" "$PROJECT_DIR/lib/codex-auth.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/lib/script-sync-guard.sh" "$PROJECT_DIR/lib/script-sync-guard.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/lib/sha256.sh" "$PROJECT_DIR/lib/sha256.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/lib/preflight.sh" "$PROJECT_DIR/lib/preflight.sh"
  printf '%s\t%s\n' "$TOUCHSTONE_ROOT/lib/preflight-scope.sh" "$PROJECT_DIR/lib/preflight-scope.sh"

  if [ "$PROJECT_TYPE" = "python" ] || [ -f "$PROJECT_DIR/scripts/run-pytest-in-venv.sh" ]; then
    printf '%s\t%s\n' "$TOUCHSTONE_ROOT/scripts/run-pytest-in-venv.sh" "$PROJECT_DIR/scripts/run-pytest-in-venv.sh"
  fi
}

# Would touchstone_block_apply change this steering file? Runs the exact
# writer against a throwaway copy so probe and writer can never diverge.
# Fail closed: anything the writer would refuse (orphaned sentinel, symlink)
# reads as stale so the real update surfaces the error loudly.
steering_block_is_current() {
  local target="$1" tmp status=0

  [ -e "$target" ] || return 0
  [ -L "$target" ] && return 1
  [ -f "$target" ] || return 1

  tmp="$(mktemp -t touchstone-block-probe.XXXXXX)"
  cp "$target" "$tmp"
  touchstone_block_apply "$tmp" "$TOUCHSTONE_ROOT" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# #773: .touchstone-version is derived state. A source-checkout sync stamps a
# git SHA while a brew install compares its release semver, so the identities
# can disagree over a byte-identical tree — and the stale-guard then blocks
# every PR while `touchstone update` reports nothing to update. Staleness is
# decided by the content the update would actually write, never by the stamp
# alone. Fail closed: any missing, differing, or unrefreshable managed
# artifact keeps the tree stale.
managed_content_is_current() {
  local src dst skill_name

  # The manifest must be a rewritable regular file; let the real update
  # surface anything else as a loud failure.
  [ -f "$PROJECT_DIR/.touchstone-manifest" ] || return 1
  [ -r "$PROJECT_DIR/.touchstone-manifest" ] || return 1

  # A retirement the update would still apply is a pending change.
  local manifest_entries
  manifest_entries="$(tr -d '\r' <"$PROJECT_DIR/.touchstone-manifest" 2>/dev/null)" || return 1
  if grep -qxF "lib/review-comment.sh" <<<"$manifest_entries" \
    && [ -e "$PROJECT_DIR/lib/review-comment.sh" ]; then
    return 1
  fi

  while IFS=$'\t' read -r src dst; do
    [ -f "$dst" ] || return 1
    cmp -s "$src" "$dst" || return 1
    case "$dst" in
      "$PROJECT_DIR"/scripts/*.sh)
        # The update chmods managed scripts; a missing execute bit is a change.
        [ -x "$dst" ] || return 1
        ;;
    esac
  done < <(managed_file_pairs)

  if [ -f "$TOUCHSTONE_ROOT/templates/claude-settings.json" ]; then
    cmp -s "$TOUCHSTONE_ROOT/templates/claude-settings.json" "$PROJECT_DIR/.claude/settings.json" || return 1
  fi

  # Project-owned templates the update would ADD when missing (their content
  # is never compared: present means project-owned, hands off).
  if [ -f "$TOUCHSTONE_ROOT/templates/.markdownlint.json" ] \
    && [ ! -f "$PROJECT_DIR/.markdownlint.json" ]; then
    return 1
  fi
  if [ "$PROJECT_TYPE" = "swift" ] \
    && [ -f "$TOUCHSTONE_ROOT/templates/swift/.swiftlint.yml" ] \
    && [ ! -f "$PROJECT_DIR/.swiftlint.yml" ]; then
    return 1
  fi
  if [ -f "$TOUCHSTONE_ROOT/templates/GEMINI.md" ] \
    && [ ! -f "$PROJECT_DIR/GEMINI.md" ]; then
    return 1
  fi

  # Legacy project-scoped skill copies the update would remove.
  if [ -d "$TOUCHSTONE_ROOT/skills" ] && [ -d "$PROJECT_DIR/.claude/skills" ]; then
    for skill_name in "${_TOUCHSTONE_BUNDLED_SKILL_NAMES[@]}"; do
      if [ -d "$PROJECT_DIR/.claude/skills/$skill_name" ]; then
        return 1
      fi
    done
  fi

  steering_block_is_current "$PROJECT_DIR/AGENTS.md" || return 1
  steering_block_is_current "$PROJECT_DIR/GEMINI.md" || return 1

  return 0
}

if [ "$OLD_SHA" = "$CURRENT_SHA" ]; then
  echo "==> Already up to date."
  exit 0
fi

if managed_content_is_current; then
  echo "==> Already up to date."
  echo "    Stamp identity differs ($OLD_SHA vs $CURRENT_SHA), but every managed file matches; nothing to update."
  exit 0
fi

if [ "$CHECK_ONLY" = true ]; then
  echo "==> Needs update."
  echo "    Run: touchstone update"
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

resolve_default_branch() {
  local default_branch=""

  default_branch="$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's#^origin/##' || true)"
  if [ -z "$default_branch" ] \
    && command -v gh >/dev/null 2>&1 \
    && git -C "$PROJECT_DIR" remote get-url origin >/dev/null 2>&1; then
    default_branch="$(cd "$PROJECT_DIR" && gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  fi
  if [ -z "$default_branch" ]; then
    local configured
    configured="$(git -C "$PROJECT_DIR" config --get init.defaultBranch 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$configured" ] && git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$configured"; then
      default_branch="$configured"
    elif git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main; then
      default_branch="main"
    elif git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/master; then
      default_branch="master"
    fi
  fi

  printf '%s\n' "$default_branch"
}

# #772: a chore/touchstone-* update branch forks from HEAD, so on any checkout
# that is not the default branch the fork carries that branch's commits into
# the update PR (arpeggio#35 auto-merged a feature branch's four commits under
# a version-bump title; convoy#234 was closed for the same carry-in). Require
# the default branch and refuse otherwise — never switch the user's worktree.
require_default_branch_checkout() {
  local default_branch
  default_branch="$(resolve_default_branch)"

  if [ -z "$default_branch" ]; then
    echo "ERROR: could not resolve the default branch for $PROJECT_DIR; refusing to branch from HEAD." >&2
    echo "       Fix: git remote set-head origin --auto" >&2
    echo "       Then rerun: touchstone update" >&2
    echo "       To update the current branch in place instead: touchstone update --in-place" >&2
    touchstone_sync_log_skip "$PROJECT_DIR" "$OLD_SHA" "$CURRENT_SHA" "no-default-branch" "" "touchstone update"
    exit 1
  fi

  if [ "$ORIGINAL_BRANCH" != "$default_branch" ]; then
    echo "ERROR: refusing to create an update branch from '$ORIGINAL_BRANCH' (default branch: $default_branch)." >&2
    echo "       A chore/touchstone-* branch forked here would carry this branch's commits into the update PR." >&2
    echo "       Fix: git checkout $default_branch && git pull --rebase" >&2
    echo "       Then rerun: touchstone update" >&2
    echo "       To update the current branch in place instead: touchstone update --in-place" >&2
    touchstone_sync_log_skip "$PROJECT_DIR" "$OLD_SHA" "$CURRENT_SHA" "off-default-branch" "" "touchstone update"
    exit 1
  fi
}

relative_project_path() {
  local path="$1"
  printf '%s' "${path#"$PROJECT_DIR"/}"
}

# Thin wrapper over the shared symlink-safe write guard (lib/safe-write.sh),
# bound to this run's PROJECT_DIR / DRY_RUN. See touchstone_ensure_safe_dest for
# the full rationale. Call BEFORE any mkdir/cp/redirect into the project.
ensure_safe_dest() {
  local dry=false
  [ "$DRY_RUN" = true ] && dry=true
  touchstone_ensure_safe_dest "$1" "$PROJECT_DIR" "$dry"
}

ADDED_PATHS=()
COMMIT_CREATED=false
ORIGINAL_BRANCH=""
ORIGINAL_HEAD=""
UPDATE_BRANCH=""
ROLLBACK_TMP_DIR=""
ROLLBACK_STARTED=false
ROLLBACK_PATHS=()
ROLLBACK_EXISTING_PATHS_FILE=""
ROLLBACK_STAGED_PATCH=""

snapshot_update_boundary() {
  local rel target backup

  ROLLBACK_TMP_DIR="$(mktemp -d -t touchstone-update-rollback.XXXXXX)"
  ROLLBACK_EXISTING_PATHS_FILE="$ROLLBACK_TMP_DIR/existing-paths"
  ROLLBACK_STAGED_PATCH="$ROLLBACK_TMP_DIR/staged.patch"
  : >"$ROLLBACK_EXISTING_PATHS_FILE"

  while IFS= read -r rel; do
    rel="${rel%/}"
    [ -n "$rel" ] || continue
    case "$rel" in
      /* | .. | ../* | */../* | */..)
        echo "ERROR: Refusing unsafe rollback path: $rel" >&2
        return 1
        ;;
    esac
    ROLLBACK_PATHS+=("$rel")
    target="$PROJECT_DIR/$rel"
    if [ -e "$target" ] || [ -L "$target" ]; then
      backup="$ROLLBACK_TMP_DIR/tree/$rel"
      mkdir -p "$(dirname "$backup")"
      cp -pR "$target" "$backup"
      printf '%s\n' "$rel" >>"$ROLLBACK_EXISTING_PATHS_FILE"
    fi
  done < <(touchstone_sync_planned_write_paths "$PROJECT_DIR" "$TOUCHSTONE_ROOT")

  if [ "${#ROLLBACK_PATHS[@]}" -gt 0 ]; then
    git -C "$PROJECT_DIR" diff --cached --binary HEAD -- "${ROLLBACK_PATHS[@]}" \
      >"$ROLLBACK_STAGED_PATCH"
  fi
}

restore_update_boundary() {
  local rel target backup existed=false

  [ -n "$ROLLBACK_TMP_DIR" ] || return 0
  if [ "${#ROLLBACK_PATHS[@]}" -gt 0 ]; then
    git -C "$PROJECT_DIR" reset -q HEAD -- "${ROLLBACK_PATHS[@]}" >/dev/null 2>&1 || true
  fi

  for rel in ${ROLLBACK_PATHS[@]+"${ROLLBACK_PATHS[@]}"}; do
    target="$PROJECT_DIR/$rel"
    backup="$ROLLBACK_TMP_DIR/tree/$rel"
    existed=false
    if grep -qxF "$rel" "$ROLLBACK_EXISTING_PATHS_FILE" 2>/dev/null; then
      existed=true
    fi
    rm -rf "$target"
    if [ "$existed" = true ]; then
      mkdir -p "$(dirname "$target")"
      cp -pR "$backup" "$target"
    fi
  done

  if [ -s "$ROLLBACK_STAGED_PATCH" ]; then
    if ! git -C "$PROJECT_DIR" apply --cached "$ROLLBACK_STAGED_PATCH"; then
      echo "ERROR: Could not restore the pre-update staged state." >&2
      echo "       Recovery snapshot retained at: $ROLLBACK_TMP_DIR" >&2
      return 1
    fi
  fi
}

rollback_failed_update() {
  local rc=$?

  if [ "$rc" -eq 0 ] || [ "$COMMIT_CREATED" = true ]; then
    if [ -n "$ROLLBACK_TMP_DIR" ]; then
      rm -rf "$ROLLBACK_TMP_DIR"
    fi
    return
  fi

  if [ "$ROLLBACK_STARTED" != true ]; then
    if [ -n "$ROLLBACK_TMP_DIR" ]; then
      rm -rf "$ROLLBACK_TMP_DIR"
    fi
    return
  fi

  echo "" >&2
  if [ "$IN_PLACE" = true ]; then
    echo "==> Update failed; rolling back in-place changes on $ORIGINAL_BRANCH" >&2
  else
    echo "==> Update failed; rolling back $UPDATE_BRANCH" >&2
  fi
  if ! restore_update_boundary; then
    return
  fi

  local rel
  for rel in ${ADDED_PATHS[@]+"${ADDED_PATHS[@]}"}; do
    rm -f "$PROJECT_DIR/$rel" 2>/dev/null || true
  done

  if [ "$IN_PLACE" != true ] && [ -n "$ORIGINAL_BRANCH" ]; then
    git -C "$PROJECT_DIR" checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
  fi
  if [ "$IN_PLACE" != true ] && [ -n "$UPDATE_BRANCH" ]; then
    git -C "$PROJECT_DIR" branch -D "$UPDATE_BRANCH" >/dev/null 2>&1 || true
  fi
  if [ -n "$ROLLBACK_TMP_DIR" ]; then
    rm -rf "$ROLLBACK_TMP_DIR"
  fi
}
trap rollback_failed_update EXIT

require_clean_git_repo() {
  if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: touchstone update requires a git repository." >&2
    echo "       Git is the backup and review boundary for touchstone updates." >&2
    exit 1
  fi

  if ! git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "ERROR: touchstone update requires at least one existing commit." >&2
    echo "       Commit the initial project state first, then run touchstone update." >&2
    exit 1
  fi

  ORIGINAL_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  ORIGINAL_HEAD="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  if [ "$ORIGINAL_BRANCH" = "HEAD" ]; then
    echo "ERROR: touchstone update cannot run from a detached HEAD." >&2
    echo "       Check out a branch first, then run touchstone update." >&2
    exit 1
  fi

  local dirty_paths overlap_paths
  dirty_paths="$(touchstone_sync_dirty_paths "$PROJECT_DIR")"
  overlap_paths="$(touchstone_sync_dirty_overlap_paths "$PROJECT_DIR" "$TOUCHSTONE_ROOT")"

  if [ -n "$overlap_paths" ] && [ "${TOUCHSTONE_FORCE_OVERLAP:-}" != "1" ]; then
    echo "ERROR: Working tree is dirty. touchstone update needs a clean git boundary." >&2
    echo "       Dirty paths overlap planned touchstone writes:" >&2
    printf '%s\n' "$overlap_paths" | sed 's/^/         - /' >&2
    echo "       Commit, stash, or revert local changes, then run touchstone update." >&2
    echo "       Preview safely with: touchstone update --dry-run" >&2
    touchstone_sync_log_skip "$PROJECT_DIR" "$OLD_SHA" "$CURRENT_SHA" "dirty-overlap" "$overlap_paths" "touchstone update"
    exit 1
  fi

  if [ -n "$overlap_paths" ]; then
    echo "WARNING: TOUCHSTONE_FORCE_OVERLAP=1 set; proceeding despite dirty paths that overlap planned touchstone writes:" >&2
    printf '%s\n' "$overlap_paths" | sed 's/^/         - /' >&2
  elif [ -n "$dirty_paths" ]; then
    printf '==> Proceeding with sync past unrelated dirty paths: '
    printf '%s\n' "$dirty_paths" | touchstone_sync_format_path_list
  fi
}

if [ "$DRY_RUN" = false ]; then
  require_clean_git_repo

  if [ "$IN_PLACE" = true ]; then
    UPDATE_BRANCH="$ORIGINAL_BRANCH"
    snapshot_update_boundary
    ROLLBACK_STARTED=true
    echo "==> Applying update on current branch: $UPDATE_BRANCH"
  else
    require_default_branch_checkout

    if [ -n "$REQUESTED_BRANCH" ]; then
      UPDATE_BRANCH="$REQUESTED_BRANCH"
      if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$UPDATE_BRANCH"; then
        echo "ERROR: Branch already exists: $UPDATE_BRANCH" >&2
        exit 1
      fi
    else
      UPDATE_BRANCH="$(unique_branch_name "chore/touchstone-$(sanitize_branch_component "$CURRENT_LABEL")")"
    fi
    snapshot_update_boundary
    echo "==> Creating update branch: $UPDATE_BRANCH"
    ROLLBACK_STARTED=true
    git -C "$PROJECT_DIR" checkout -b "$UPDATE_BRANCH" >/dev/null
  fi
fi

# Show changes between versions.
echo ""
echo "==> Changes in touchstone since last update:"
if git -C "$TOUCHSTONE_ROOT" log --oneline "$OLD_SHA..$CURRENT_SHA" 2>/dev/null; then
  echo ""
elif command -v gh >/dev/null 2>&1; then
  gh release list --repo autumngarage/touchstone --limit 15 2>/dev/null | head -10 || true
  echo ""
else
  echo "    (couldn't compute changes — old SHA may have been garbage collected)"
  echo "    Run: touchstone changelog"
  echo ""
fi

# --------------------------------------------------------------------------
# Touchstone-owned files
# --------------------------------------------------------------------------

ADDED=0
UPDATED=0
UNCHANGED=0
SKIPPED_UNSAFE=0

update_file() {
  local src="$1"
  local dst="$2"
  local dst_dir rel_path
  dst_dir="$(dirname "$dst")"
  rel_path="$(relative_project_path "$dst")"

  # Guard against symlink traversal (final component AND ancestor dirs) before
  # any mkdir/cp below. See ensure_safe_dest.
  if ! ensure_safe_dest "$dst"; then
    SKIPPED_UNSAFE=$((SKIPPED_UNSAFE + 1))
    return
  fi

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

# Retired-but-not-removed: list stale worker files so the owner can delete
# them deliberately. Never mutates the project.
report_retired_worker_files() {
  local rel found=false
  for rel in scripts/worker.sh lib/worker-ship-job.sh lib/worker-review-fix.sh lib/worker-state.sh; do
    if [ -e "$PROJECT_DIR/$rel" ]; then
      if [ "$found" = false ]; then
        echo "    ! the worker engine was retired in 2.13.0; these files are no longer managed:"
        found=true
      fi
      echo "      - $rel"
    fi
  done
  if [ "$found" = true ]; then
    echo "      Ship with: bash scripts/open-pr.sh --auto-merge"
    echo "      Delete them when you are ready; Touchstone will not touch them."
  fi
}

remove_retired_managed_file() {
  local rel_path="$1"
  local manifest="$PROJECT_DIR/.touchstone-manifest"
  local target="$PROJECT_DIR/$rel_path"

  [ -f "$manifest" ] || return 0
  # CRLF tolerance: a manifest checked out with core.autocrlf carries \r,
  # which a plain fixed-string match would never equal. Read into a variable
  # rather than piping: grep -q exits at the first match, tr takes SIGPIPE,
  # and pipefail would turn a successful MATCH into a nonzero pipeline.
  local manifest_entries=""
  manifest_entries="$(tr -d '\r' <"$manifest")" || return 0
  grep -qxF "$rel_path" <<<"$manifest_entries" || return 0
  [ -e "$target" ] || return 0
  if ! ensure_safe_dest "$target" || [ ! -f "$target" ]; then
    echo "    ! refusing to remove unsafe retired path: $target" >&2
    SKIPPED_UNSAFE=$((SKIPPED_UNSAFE + 1))
    return 0
  fi
  if ! git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$rel_path" >/dev/null 2>&1; then
    echo "    ! leaving untracked retired file in place: $target" >&2
    echo "      Touchstone will stop managing it; remove it manually after preserving any local changes." >&2
    return 0
  fi
  # Never destroy local work: a retired file carrying uncommitted edits is
  # left in place with an explicit notice. Retirement removes Touchstone's
  # managed copy, it does not discard a project's modifications.
  # Worktree OR index: a staged customization must neither be deleted nor
  # swept into Touchstone's own update commit.
  if ! git -C "$PROJECT_DIR" diff --quiet -- "$rel_path" 2>/dev/null \
    || ! git -C "$PROJECT_DIR" diff --cached --quiet -- "$rel_path" 2>/dev/null; then
    echo "    ! leaving locally modified retired file in place: $target" >&2
    echo "      It has uncommitted changes (worktree or index); Touchstone no longer manages it." >&2
    echo "      Commit or discard them, then delete the file when you are ready." >&2
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "    - would remove retired managed file: $target"
  else
    RETIRED_MANAGED_PATHS+=("$rel_path")
    rm -f "$target"
    echo "    - removed retired managed file: $target"
  fi
  UPDATED=$((UPDATED + 1))
}

echo "==> Updating touchstone-owned files:"

remove_retired_managed_file "lib/review-comment.sh"
# Journal hook retired with the Cortex pause (issue #730): merge-pr.sh no
# longer invokes it, so a leftover copy would be dead code that still pushes
# HEAD:main on a manual run.
remove_retired_managed_file "scripts/cortex-pr-merged-hook.sh"
# Worker engine retired in 2.13.0 (issue #694). Touchstone stops managing
# these files and NOTIFIES; it does not delete them. Automatic deletion of a
# project's tracked files has to reason about dirty worktrees, staged edits,
# staged renames and deletions, and rollback snapshots — convenience
# automation with an unbounded edge-case surface, which is exactly what this
# release removes. One notice, the project owner decides.
report_retired_worker_files

if [ -d "$TOUCHSTONE_ROOT/principles" ] && [ "$DRY_RUN" = false ]; then
  mkdir -p "$PROJECT_DIR/principles"
fi

# The copy pass consumes the same managed_file_pairs enumeration the
# content-staleness probe compares against, so they cannot drift apart.
while IFS=$'\t' read -r pair_src pair_dst; do
  update_file "$pair_src" "$pair_dst"
done < <(managed_file_pairs)

# Claude Code settings — wires the branch-guard and emergency-disclosure
# PreToolUse hooks. The settings file is touchstone-owned (overwritten on
# update); user-specific overrides belong in .claude/settings.local.json,
# which Claude Code merges on top of this file. update_settings_file backs
# up the previous contents before overwriting so an accidental hand-edit
# can be recovered (Phase 2 of audits/2026-04-24-guidance-effectiveness-plan.md).
update_settings_file() {
  local src="$1" dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"

  if ! ensure_safe_dest "$dst"; then
    SKIPPED_UNSAFE=$((SKIPPED_UNSAFE + 1))
    return
  fi

  if [ ! -f "$dst" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "    + would add: $dst"
    else
      mkdir -p "$dst_dir"
      cp "$src" "$dst"
      ADDED_PATHS+=("$(relative_project_path "$dst")")
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
    echo "      put project-specific overrides in $(dirname "$dst")/settings.local.json"
  fi
  UPDATED=$((UPDATED + 1))
}
update_settings_file "$TOUCHSTONE_ROOT/templates/claude-settings.json" "$PROJECT_DIR/.claude/settings.json"

# Touchstone-shipped skills are installed user-scope at ~/.claude/skills/
# rather than mirrored into each project's .claude/skills/. This keeps a
# single source of truth across all projects the user opens. The migration
# below removes any leftover project-scoped touchstone-* skill directories
# from the previous project-scoped install pattern.
if [ -d "$TOUCHSTONE_ROOT/skills" ] && [ "$DRY_RUN" = false ]; then
  touchstone_install_skills "$TOUCHSTONE_ROOT" || true
  touchstone_uninstall_legacy_project_skills "$PROJECT_DIR" || true
fi

# Project-owned templates, including shared formatting config and profile
# additions such as Swift's .swiftlint.yml. Add them when missing, but never
# overwrite a hand-edited copy. They stay out of .touchstone-manifest so future
# updates do not clobber project-owned customization.
PROJECT_OWNED_ADDED_PATHS=()
add_project_template_if_missing() {
  local src="$1" dst="$2"
  local rel_path
  rel_path="$(relative_project_path "$dst")"

  if ! ensure_safe_dest "$dst"; then
    SKIPPED_UNSAFE=$((SKIPPED_UNSAFE + 1))
    return 0
  fi

  if [ -f "$dst" ]; then
    # Hand-edited or already-shipped — leave alone. update_file handles
    # touchstone-owned files; this helper exists precisely so project-owned
    # additions skip when present, even if the on-disk content differs.
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "    + would add (project-owned): $dst"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  ADDED_PATHS+=("$rel_path")
  PROJECT_OWNED_ADDED_PATHS+=("$rel_path")
  echo "    + added (project-owned): $dst"
}

if [ -f "$TOUCHSTONE_ROOT/templates/.markdownlint.json" ]; then
  add_project_template_if_missing \
    "$TOUCHSTONE_ROOT/templates/.markdownlint.json" \
    "$PROJECT_DIR/.markdownlint.json"
fi

if [ "$PROJECT_TYPE" = "swift" ] && [ -f "$TOUCHSTONE_ROOT/templates/swift/.swiftlint.yml" ]; then
  add_project_template_if_missing \
    "$TOUCHSTONE_ROOT/templates/swift/.swiftlint.yml" \
    "$PROJECT_DIR/.swiftlint.yml"
fi

if [ -f "$TOUCHSTONE_ROOT/templates/GEMINI.md" ]; then
  gemini_md_was_present=false
  [ -f "$PROJECT_DIR/GEMINI.md" ] && gemini_md_was_present=true
  add_project_template_if_missing \
    "$TOUCHSTONE_ROOT/templates/GEMINI.md" \
    "$PROJECT_DIR/GEMINI.md"
  if [ "$DRY_RUN" = false ] && [ "$gemini_md_was_present" = false ] && [ -f "$PROJECT_DIR/GEMINI.md" ]; then
    escaped_project_name="$(printf '%s' "$(basename "$PROJECT_DIR")" | sed 's/[\\/&]/\\&/g')"
    touchstone_sed_inplace "s/{{PROJECT_NAME}}/$escaped_project_name/g" "$PROJECT_DIR/GEMINI.md"
  fi
fi

# Refresh the touchstone-managed shared-principles block inside AGENTS.md.
# AGENTS.md itself is project-owned, but the sentinel-delimited block is
# touchstone-owned so non-Claude reviewers (Codex/Gemini) get the steering
# content that CLAUDE.md gets for free via @-imports.
AGENTS_PRINCIPLES_TOUCHED=false
GEMINI_PRINCIPLES_TOUCHED=false

# A block-apply failure (orphaned sentinel, symlinked target, missing render
# source) must FAIL the update. Swallowing it with `|| true` committed the
# new .touchstone-version anyway, so automated sync treated the project as
# current and never retried while the agent stayed on a stale or malformed
# contract (PR #703 review). Exiting here lands inside the rollback boundary:
# nothing is committed and the version is not advanced.
fail_block_apply() {
  local target_name="$1"
  echo "ERROR: could not refresh the touchstone-managed steering block in $target_name." >&2
  echo "       The usual cause is an orphaned sentinel: one '<!-- touchstone:steering:start/end -->'" >&2
  echo "       marker without its pair (see the exact reason above)." >&2
  echo "       Repair $target_name, then rerun touchstone update. Continuing would advance" >&2
  echo "       .touchstone-version while this file stays on the old contract, and automated" >&2
  echo "       sync would never retry." >&2
  exit 1
}

if [ "$DRY_RUN" = false ] && [ -f "$PROJECT_DIR/AGENTS.md" ]; then
  agents_md_before_sha="$(touchstone_sha256_file "$PROJECT_DIR/AGENTS.md")"
  touchstone_block_apply "$PROJECT_DIR/AGENTS.md" "$TOUCHSTONE_ROOT" || fail_block_apply "AGENTS.md"
  agents_md_after_sha="$(touchstone_sha256_file "$PROJECT_DIR/AGENTS.md")"
  if [ "$agents_md_before_sha" != "$agents_md_after_sha" ]; then
    AGENTS_PRINCIPLES_TOUCHED=true
    echo "    refreshed (project-owned, managed block): AGENTS.md"
  fi
fi
# GEMINI.md carries the same managed block and was never refreshed here, so a
# contract change reached Codex but not Gemini (PR #703 review). Its own
# conditional: a project can ship GEMINI.md without AGENTS.md, and update
# never backfills a missing AGENTS.md, so nesting this under that check would
# strand Gemini-only projects on the old contract permanently.
if [ "$DRY_RUN" = false ] && [ -f "$PROJECT_DIR/GEMINI.md" ]; then
  gemini_md_before_sha="$(touchstone_sha256_file "$PROJECT_DIR/GEMINI.md")"
  touchstone_block_apply "$PROJECT_DIR/GEMINI.md" "$TOUCHSTONE_ROOT" || fail_block_apply "GEMINI.md"
  gemini_md_after_sha="$(touchstone_sha256_file "$PROJECT_DIR/GEMINI.md")"
  if [ "$gemini_md_before_sha" != "$gemini_md_after_sha" ]; then
    GEMINI_PRINCIPLES_TOUCHED=true
    echo "    refreshed (project-owned, managed block): GEMINI.md"
  fi
fi

write_touchstone_manifest() {
  local manifest="$PROJECT_DIR/.touchstone-manifest"
  ensure_safe_dest "$manifest" || true
  {
    printf '# Managed by touchstone. These paths may be updated by `touchstone update`.\n'
    printf '.touchstone-manifest\n'
    printf '.touchstone-version\n'
    printf 'TOUCHSTONE.md\n'
    printf '.github/workflows/issue-claim-check.yml\n'
    if [ -d "$TOUCHSTONE_ROOT/principles" ]; then
      for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
        printf 'principles/%s\n' "$(basename "$f")"
      done
    fi
    printf 'scripts/branch-guard.sh\n'
    printf 'scripts/emergency-disclosure.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/claim-issue.sh\n'
    printf 'scripts/respond-review.sh\n'
    printf 'scripts/issue-claim-check.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    printf 'scripts/spawn-worktree.sh\n'
    printf 'scripts/cleanup-worktrees.sh\n'
    printf 'lib/toml.sh\n'
    printf 'lib/events.sh\n'
    printf 'lib/codex-auth.sh\n'
    printf 'lib/script-sync-guard.sh\n'
    printf 'lib/sha256.sh\n'
    printf 'lib/preflight.sh\n'
    printf 'lib/preflight-scope.sh\n'
    if [ "$PROJECT_TYPE" = "python" ] || [ -f "$PROJECT_DIR/scripts/run-pytest-in-venv.sh" ]; then
      printf 'scripts/run-pytest-in-venv.sh\n'
    fi
    printf '.claude/settings.json\n'
    if [ -d "$TOUCHSTONE_ROOT/.claude/skills" ]; then
      for skill_dir in "$TOUCHSTONE_ROOT/.claude/skills/"touchstone-*/; do
        [ -d "$skill_dir" ] || continue
        skill_name="$(basename "$skill_dir")"
        for f in "$skill_dir"*; do
          [ -f "$f" ] || continue
          printf '.claude/skills/%s/%s\n' "$skill_name" "$(basename "$f")"
        done
      done
    fi
  } >"$manifest"
}

stage_touchstone_manifest_paths() {
  local manifest="$PROJECT_DIR/.touchstone-manifest"
  local rel_path

  if [ ! -f "$manifest" ]; then
    echo "ERROR: expected .touchstone-manifest before staging update" >&2
    return 1
  fi

  while IFS= read -r rel_path; do
    case "$rel_path" in
      "" | \#*) continue ;;
    esac
    if [ -e "$PROJECT_DIR/$rel_path" ] || [ -L "$PROJECT_DIR/$rel_path" ]; then
      git -C "$PROJECT_DIR" add -f -- "$rel_path"
    fi
  done <"$manifest"
}

# Ensure scripts are executable and write touchstone metadata.
if [ "$DRY_RUN" = false ]; then
  while IFS= read -r managed_path; do
    case "$managed_path" in
      scripts/*.sh)
        if [ -f "$PROJECT_DIR/$managed_path" ] && [ ! -L "$PROJECT_DIR/$managed_path" ]; then
          chmod +x "$PROJECT_DIR/$managed_path" 2>/dev/null || true
        fi
        ;;
    esac
  done < <(touchstone_sync_planned_write_paths "$PROJECT_DIR" "$TOUCHSTONE_ROOT")
  ensure_safe_dest "$PROJECT_DIR/.touchstone-version" || true
  echo "$CURRENT_SHA" >"$PROJECT_DIR/.touchstone-version"
  write_touchstone_manifest
fi

echo ""
echo "==> Summary: $ADDED added, $UPDATED updated, $UNCHANGED unchanged"
if [ "$SKIPPED_UNSAFE" -gt 0 ]; then
  echo "==> WARNING: $SKIPPED_UNSAFE managed path(s) skipped — destination traverses a symlink (see warnings above)." >&2
fi
echo "==> Workflow scripts: project-local copies from Touchstone-managed files"
echo "    Prototype shim runner available for evaluation: touchstone run-script <script>"

# Reinstall pre-commit hook shims so a drifted or empty .git/hooks/ gets repaired.
# The helper is idempotent; it skips silently when there's nothing to do.
if [ "$DRY_RUN" = false ] && [ -f "$PROJECT_DIR/.pre-commit-config.yaml" ]; then
  HOOKS_PRESENT_STATUS=0
  touchstone_project_hooks_present "$PROJECT_DIR" || HOOKS_PRESENT_STATUS=$?
  if [ "$HOOKS_PRESENT_STATUS" -eq 1 ]; then
    echo ""
    touchstone_install_hooks "$PROJECT_DIR" || true
  elif [ "$HOOKS_PRESENT_STATUS" -eq 2 ]; then
    echo "==> WARNING: could not resolve Git hook paths; hooks were not changed." >&2
  fi
  # Presence is not readiness: files that exist but are inert, typed for the
  # wrong slot, or bound to another config leave the repo ungated. Surface it
  # on every update; --ship additionally refuses below.
  if ! touchstone_project_hooks_ready "$PROJECT_DIR"; then
    echo "==> WARNING: effective pre-commit/pre-push hooks are not ready (missing, inert, wrong-typed, or bound to another config)." >&2
    echo "    Diagnose with: touchstone doctor --project" >&2
  fi
fi

# setup.sh is project-owned after bootstrap, so existing projects keep the
# legacy copy that unsets core.hooksPath — the template fix never reaches
# them through updates. Warn (never rewrite a project-owned file silently).
if [ -f "$PROJECT_DIR/setup.sh" ] \
  && grep -q 'unset-all core\.hooksPath' "$PROJECT_DIR/setup.sh"; then
  echo "==> WARNING: setup.sh contains the legacy core.hooksPath reset; running it deletes a configured hook boundary." >&2
  echo "    Re-sync your project-owned setup.sh hook section from templates/setup.sh." >&2
fi

if [ "$DRY_RUN" = false ]; then
  echo ""
  echo "==> Committing touchstone update..."
  stage_touchstone_manifest_paths
  if [ "${#RETIRED_MANAGED_PATHS[@]}" -gt 0 ]; then
    git -C "$PROJECT_DIR" add -u -- "${RETIRED_MANAGED_PATHS[@]}"
  fi
  if [ -f "$PROJECT_DIR/.claude/settings.json" ]; then
    git -C "$PROJECT_DIR" add -f -- .claude/settings.json
  fi
  if [ -d "$PROJECT_DIR/.claude/skills" ]; then
    git -C "$PROJECT_DIR" add -f -- .claude/skills
  fi
  # Stage project-owned templates added on this run (e.g. .markdownlint.json
  # or Swift's .swiftlint.yml). Their addition only makes sense bundled into
  # the same review commit as the rest of the update.
  if [ "${#PROJECT_OWNED_ADDED_PATHS[@]}" -gt 0 ]; then
    git -C "$PROJECT_DIR" add -f -- "${PROJECT_OWNED_ADDED_PATHS[@]}"
  fi
  # The shared-principles block inside AGENTS.md is touchstone-managed even
  # though the file is project-owned. Stage it so a refresh ships in this
  # update commit rather than dangling as an unstaged diff.
  #
  # Only when the file is already tracked (files this run created were staged
  # via PROJECT_OWNED_ADDED_PATHS above, so they are tracked by now). A
  # pre-existing gitignored file is invisible to the clean-worktree check, and
  # `git add -f` on it published deliberately-ignored private local steering
  # content into the update commit (PR #703 review). The on-disk block still
  # refreshes; the file just stays untracked, as its owner chose.
  stage_refreshed_steering_file() {
    local rel="$1"
    if git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      git -C "$PROJECT_DIR" add -f -- "$rel"
    else
      echo "    NOTE: $rel is untracked (gitignored?); refreshed managed block left unstaged, not published."
    fi
  }
  if [ "$AGENTS_PRINCIPLES_TOUCHED" = true ] && [ -f "$PROJECT_DIR/AGENTS.md" ]; then
    stage_refreshed_steering_file AGENTS.md
  fi
  # Same for GEMINI.md — refreshing the block without staging it committed the
  # version bump while leaving the new contract dangling as an unstaged diff
  # (PR #703 review).
  if [ "$GEMINI_PRINCIPLES_TOUCHED" = true ] && [ -f "$PROJECT_DIR/GEMINI.md" ]; then
    stage_refreshed_steering_file GEMINI.md
  fi

  if git -C "$PROJECT_DIR" diff --cached --quiet; then
    echo "    No file changes to commit."
  else
    git -C "$PROJECT_DIR" commit --no-verify -m "chore: update touchstone to ${CURRENT_LABEL}" >/dev/null
    COMMIT_CREATED=true
    echo "    Committed: chore: update touchstone to ${CURRENT_LABEL}"
  fi
fi

# Hint about project-owned files.
echo ""
echo "==> Project-owned files (not auto-updated):"
echo "    Consider reviewing these against the latest touchstone templates:"
echo "      touchstone diff"
echo "      diff $TOUCHSTONE_ROOT/templates/CLAUDE.md ./CLAUDE.md"
echo "      diff $TOUCHSTONE_ROOT/templates/AGENTS.md ./AGENTS.md"
echo "      diff $TOUCHSTONE_ROOT/templates/GEMINI.md ./GEMINI.md"
echo "      diff $TOUCHSTONE_ROOT/templates/pre-commit-config.yaml ./.pre-commit-config.yaml"
echo "      diff $TOUCHSTONE_ROOT/templates/touchstone-review.toml ./.touchstone-review.toml"

if [ "$DRY_RUN" = false ]; then
  if [ "$SHIP" = true ] && [ "${COMMIT_CREATED:-false}" = true ]; then
    # Shipping pushes through git, and the deterministic validation this
    # update preserves lives in the effective pre-push hook. If readiness
    # cannot be established — hooks missing, inert, wrong-typed, bound to a
    # different config, or an unrepairable configured hook path — refuse the
    # ship rather than push an ungated update.
    if ! touchstone_project_hooks_ready "$PROJECT_DIR"; then
      echo ""
      echo "==> --ship refused: effective pre-commit/pre-push hooks are not ready." >&2
      echo "    The push would bypass deterministic pre-push validation." >&2
      echo "    Diagnose with: touchstone doctor --project" >&2
      echo "    branch: $UPDATE_BRANCH (left for manual ship after repair)" >&2
      exit 1
    fi
    if [ ! -x "$PROJECT_DIR/scripts/open-pr.sh" ]; then
      echo ""
      echo "==> --ship requested but scripts/open-pr.sh is missing or not executable."
      echo "    branch: $UPDATE_BRANCH (left for manual ship)"
      exit 1
    else
      echo ""
      echo "==> Shipping update via scripts/open-pr.sh --auto-merge..."
      if ! (cd "$PROJECT_DIR" && bash scripts/open-pr.sh --auto-merge); then
        echo ""
        echo "==> Ship failed (see errors above). The update commit is preserved on:"
        echo "    branch: $UPDATE_BRANCH"
        echo "    Re-ship when ready:  cd $PROJECT_DIR && bash scripts/open-pr.sh --auto-merge"
        exit 1
      fi
    fi
  else
    echo ""
    if [ "$IN_PLACE" = true ]; then
      echo "==> Done. Review the update commit on the current branch:"
    else
      echo "==> Done. Review the update branch:"
    fi
    echo "    branch: $UPDATE_BRANCH"
    echo "    git diff ${ORIGINAL_HEAD:-$ORIGINAL_BRANCH}...HEAD"
    echo "    bash scripts/open-pr.sh --auto-merge"
  fi
else
  echo ""
  echo "==> Dry run complete. Apply with: touchstone update"
fi
