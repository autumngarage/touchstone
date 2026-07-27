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
# shellcheck source=../lib/install-hooks.sh
source "$TOUCHSTONE_ROOT/lib/install-hooks.sh"
# shellcheck source=../lib/touchstone-block.sh
source "$TOUCHSTONE_ROOT/lib/touchstone-block.sh"
# shellcheck source=../lib/install-skills.sh
source "$TOUCHSTONE_ROOT/lib/install-skills.sh"
# shellcheck source=../lib/sync-discipline.sh
source "$TOUCHSTONE_ROOT/lib/sync-discipline.sh"
PROJECT_DIR="$(pwd)"
DRY_RUN=false
CHECK_ONLY=false
REQUESTED_BRANCH=""
SHIP=false
IN_PLACE=false

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

echo "==> Updating project: $PROJECT_DIR"
echo "    Touchstone: $OLD_SHA -> $CURRENT_SHA"

# Detect both legacy shapes and an unpinned 2.0 Conductor block so update can
# surface the explicit migration path. Review configs are project-owned, so
# detection must never turn into an automatic rewrite.
# Prefer the canonical config when both compatibility names exist.
REVIEW_CONFIG_TOML=""
if [ -f "$PROJECT_DIR/.touchstone-review.toml" ]; then
  REVIEW_CONFIG_TOML="$PROJECT_DIR/.touchstone-review.toml"
elif [ -f "$PROJECT_DIR/.codex-review.toml" ]; then
  REVIEW_CONFIG_TOML="$PROJECT_DIR/.codex-review.toml"
fi
NEEDS_CODEX_REVIEW_MIGRATION=false
if [ -n "$REVIEW_CONFIG_TOML" ]; then
  if grep -qE '^[[:space:]]*reviewers[[:space:]]*=[[:space:]]*\[' "$REVIEW_CONFIG_TOML" \
    || grep -qE '^\[review\.local\]' "$REVIEW_CONFIG_TOML" \
    || grep -qE '^\[review\.assist\]' "$REVIEW_CONFIG_TOML" \
    || grep -qE '^[[:space:]]*(small|large)_reviewers[[:space:]]*=[[:space:]]*\[' "$REVIEW_CONFIG_TOML" \
    || {
      grep -qE '^\[review\.conductor\]' "$REVIEW_CONFIG_TOML" \
        && ! awk '
          /^\[review\.conductor\][[:space:]]*$/ { section = "review.conductor"; next }
          /^\[/ { section = "other"; next }
          section == "review.conductor" && /^[[:space:]]*with[[:space:]]*=/ { found = 1 }
          END { exit(found ? 0 : 1) }
        ' "$REVIEW_CONFIG_TOML"
    }; then
    NEEDS_CODEX_REVIEW_MIGRATION=true
  fi
fi

print_review_config_migration_notice() {
  local config_name
  config_name="$(basename "$REVIEW_CONFIG_TOML")"
  echo ""
  echo "==> Review config migration available for $config_name."
  echo "    This project-owned file was not changed."
  echo "    A missing review.conductor.with value defaults to Codex at runtime."
  echo "    To rewrite it explicitly: touchstone migrate-review-config --file $config_name"
}

if [ "$NEEDS_CODEX_REVIEW_MIGRATION" = true ]; then
  print_review_config_migration_notice
fi

if [ "$OLD_SHA" = "$CURRENT_SHA" ]; then
  echo "==> Already up to date."
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
BRANCH_CREATED=false
COMMIT_CREATED=false
ORIGINAL_BRANCH=""
ORIGINAL_HEAD=""
UPDATE_BRANCH=""
ROLLBACK_TMP_DIR=""

snapshot_touchstone_metadata() {
  ROLLBACK_TMP_DIR="$(mktemp -d -t touchstone-update-rollback.XXXXXX)"
  cp "$PROJECT_DIR/.touchstone-version" "$ROLLBACK_TMP_DIR/.touchstone-version"
  if [ -f "$PROJECT_DIR/.touchstone-manifest" ]; then
    cp "$PROJECT_DIR/.touchstone-manifest" "$ROLLBACK_TMP_DIR/.touchstone-manifest"
  elif [ -e "$PROJECT_DIR/.touchstone-manifest" ]; then
    : >"$ROLLBACK_TMP_DIR/.touchstone-manifest.nonfile"
  else
    : >"$ROLLBACK_TMP_DIR/.touchstone-manifest.missing"
  fi
}

restore_touchstone_metadata() {
  [ -n "$ROLLBACK_TMP_DIR" ] || return

  if [ -f "$ROLLBACK_TMP_DIR/.touchstone-version" ]; then
    cp "$ROLLBACK_TMP_DIR/.touchstone-version" "$PROJECT_DIR/.touchstone-version"
  fi

  if [ -f "$ROLLBACK_TMP_DIR/.touchstone-manifest.missing" ]; then
    if [ -f "$PROJECT_DIR/.touchstone-manifest" ]; then
      rm -f "$PROJECT_DIR/.touchstone-manifest"
    fi
  elif [ -f "$ROLLBACK_TMP_DIR/.touchstone-manifest" ]; then
    cp "$ROLLBACK_TMP_DIR/.touchstone-manifest" "$PROJECT_DIR/.touchstone-manifest"
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

  if [ "$BRANCH_CREATED" != true ] && [ "$IN_PLACE" != true ]; then
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
  git -C "$PROJECT_DIR" restore --staged --worktree . >/dev/null 2>&1 || true
  restore_touchstone_metadata

  local rel
  for rel in ${ADDED_PATHS[@]+"${ADDED_PATHS[@]}"}; do
    rm -f "$PROJECT_DIR/$rel" 2>/dev/null || true
  done

  if [ "$IN_PLACE" != true ] && [ -n "$ORIGINAL_BRANCH" ]; then
    git -C "$PROJECT_DIR" checkout -f "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
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
    snapshot_touchstone_metadata
    echo "==> Applying update on current branch: $UPDATE_BRANCH"
  else
    if [ -n "$REQUESTED_BRANCH" ]; then
      UPDATE_BRANCH="$REQUESTED_BRANCH"
      if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$UPDATE_BRANCH"; then
        echo "ERROR: Branch already exists: $UPDATE_BRANCH" >&2
        exit 1
      fi
    else
      UPDATE_BRANCH="$(unique_branch_name "chore/touchstone-$(sanitize_branch_component "$CURRENT_LABEL")")"
    fi
    snapshot_touchstone_metadata
    echo "==> Creating update branch: $UPDATE_BRANCH"
    git -C "$PROJECT_DIR" checkout -b "$UPDATE_BRANCH" >/dev/null
    BRANCH_CREATED=true
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

echo "==> Updating touchstone-owned files:"

# Principles
if [ -d "$TOUCHSTONE_ROOT/principles" ]; then
  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$PROJECT_DIR/principles"
  fi
  for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
    update_file "$f" "$PROJECT_DIR/principles/$(basename "$f")"
  done
fi

# TOUCHSTONE.md — canonical lean-router steering doc, imported by CLAUDE.md
# (@TOUCHSTONE.md) and inlined into AGENTS.md/GEMINI.md by touchstone_block_apply.
if [ -f "$TOUCHSTONE_ROOT/TOUCHSTONE.md" ]; then
  update_file "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "$PROJECT_DIR/TOUCHSTONE.md"
fi

# Required deterministic backstop for the issue-claim workflow. General CI
# validate.yml remains opt-in and project-owned; this workflow is part of the
# documented Touchstone delivery contract.
update_file "$TOUCHSTONE_ROOT/templates/ci/issue-claim-check.yml" "$PROJECT_DIR/.github/workflows/issue-claim-check.yml"

# Read project type (default: generic for backward compatibility).
PROJECT_TYPE="generic"
if [ -f "$PROJECT_DIR/.touchstone-config" ]; then
  PROJECT_TYPE="$(grep '^project_type=' "$PROJECT_DIR/.touchstone-config" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
  PROJECT_TYPE="${PROJECT_TYPE:-generic}"
fi

# Scripts
update_file "$TOUCHSTONE_ROOT/hooks/conductor-review.sh" "$PROJECT_DIR/scripts/conductor-review.sh"
update_file "$TOUCHSTONE_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
update_file "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" "$PROJECT_DIR/scripts/branch-guard.sh"
update_file "$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh" "$PROJECT_DIR/scripts/emergency-disclosure.sh"
update_file "$TOUCHSTONE_ROOT/hooks/cortex-pr-merged-hook.sh" "$PROJECT_DIR/scripts/cortex-pr-merged-hook.sh"
update_file "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_DIR/scripts/touchstone-run.sh"
update_file "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
update_file "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
update_file "$TOUCHSTONE_ROOT/scripts/claim-issue.sh" "$PROJECT_DIR/scripts/claim-issue.sh"
update_file "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$PROJECT_DIR/scripts/issue-claim-check.sh"
update_file "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
update_file "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" "$PROJECT_DIR/scripts/spawn-worktree.sh"
update_file "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" "$PROJECT_DIR/scripts/cleanup-worktrees.sh"
update_file "$TOUCHSTONE_ROOT/scripts/worker.sh" "$PROJECT_DIR/scripts/worker.sh"

# Libraries used by touchstone-owned scripts.
update_file "$TOUCHSTONE_ROOT/lib/toml.sh" "$PROJECT_DIR/lib/toml.sh"
update_file "$TOUCHSTONE_ROOT/lib/events.sh" "$PROJECT_DIR/lib/events.sh"
update_file "$TOUCHSTONE_ROOT/lib/worker-ship-job.sh" "$PROJECT_DIR/lib/worker-ship-job.sh"
update_file "$TOUCHSTONE_ROOT/lib/worker-review-fix.sh" "$PROJECT_DIR/lib/worker-review-fix.sh"
update_file "$TOUCHSTONE_ROOT/lib/worker-state.sh" "$PROJECT_DIR/lib/worker-state.sh"
update_file "$TOUCHSTONE_ROOT/lib/script-sync-guard.sh" "$PROJECT_DIR/lib/script-sync-guard.sh"
update_file "$TOUCHSTONE_ROOT/lib/preflight.sh" "$PROJECT_DIR/lib/preflight.sh"
update_file "$TOUCHSTONE_ROOT/lib/preflight-scope.sh" "$PROJECT_DIR/lib/preflight-scope.sh"
update_file "$TOUCHSTONE_ROOT/lib/review-comment.sh" "$PROJECT_DIR/lib/review-comment.sh"

if [ "$PROJECT_TYPE" = "python" ] || [ -f "$PROJECT_DIR/scripts/run-pytest-in-venv.sh" ]; then
  update_file "$TOUCHSTONE_ROOT/scripts/run-pytest-in-venv.sh" "$PROJECT_DIR/scripts/run-pytest-in-venv.sh"
fi

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
    sed -i '' "s/{{PROJECT_NAME}}/$escaped_project_name/g" "$PROJECT_DIR/GEMINI.md" 2>/dev/null || true
  fi
fi

# Refresh the touchstone-managed shared-principles block inside AGENTS.md.
# AGENTS.md itself is project-owned, but the sentinel-delimited block is
# touchstone-owned so non-Claude reviewers (Codex/Gemini) get the steering
# content that CLAUDE.md gets for free via @-imports.
AGENTS_PRINCIPLES_TOUCHED=false
if [ "$DRY_RUN" = false ] && [ -f "$PROJECT_DIR/AGENTS.md" ]; then
  agents_md_before_sha="$(shasum -a 256 "$PROJECT_DIR/AGENTS.md" | awk '{print $1}')"
  touchstone_block_apply "$PROJECT_DIR/AGENTS.md" "$TOUCHSTONE_ROOT" || true
  agents_md_after_sha="$(shasum -a 256 "$PROJECT_DIR/AGENTS.md" | awk '{print $1}')"
  if [ "$agents_md_before_sha" != "$agents_md_after_sha" ]; then
    AGENTS_PRINCIPLES_TOUCHED=true
    echo "    refreshed (project-owned, managed block): AGENTS.md"
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
    printf 'scripts/conductor-review.sh\n'
    printf 'scripts/codex-review.sh\n'
    printf 'scripts/branch-guard.sh\n'
    printf 'scripts/emergency-disclosure.sh\n'
    printf 'scripts/cortex-pr-merged-hook.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/claim-issue.sh\n'
    printf 'scripts/issue-claim-check.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    printf 'scripts/spawn-worktree.sh\n'
    printf 'scripts/cleanup-worktrees.sh\n'
    printf 'scripts/worker.sh\n'
    printf 'lib/toml.sh\n'
    printf 'lib/events.sh\n'
    printf 'lib/worker-ship-job.sh\n'
    printf 'lib/worker-review-fix.sh\n'
    printf 'lib/worker-state.sh\n'
    printf 'lib/script-sync-guard.sh\n'
    printf 'lib/preflight.sh\n'
    printf 'lib/preflight-scope.sh\n'
    printf 'lib/review-comment.sh\n'
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
  if [ -d "$PROJECT_DIR/scripts" ]; then
    # -type f (find does not follow symlinks here) so we only chmod real files;
    # a glob would follow a planted symlink and flip perms on its target.
    find "$PROJECT_DIR/scripts" -maxdepth 1 -type f -name '*.sh' \
      -exec chmod +x {} + 2>/dev/null || true
  fi
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
if [ "$DRY_RUN" = false ] \
  && [ -f "$PROJECT_DIR/.pre-commit-config.yaml" ] \
  && { [ ! -f "$PROJECT_DIR/.git/hooks/pre-commit" ] || [ ! -f "$PROJECT_DIR/.git/hooks/pre-push" ]; }; then
  echo ""
  touchstone_install_hooks "$PROJECT_DIR" || true
fi

if [ "$DRY_RUN" = false ]; then
  echo ""
  echo "==> Committing touchstone update..."
  stage_touchstone_manifest_paths
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
  if [ "$AGENTS_PRINCIPLES_TOUCHED" = true ] && [ -f "$PROJECT_DIR/AGENTS.md" ]; then
    git -C "$PROJECT_DIR" add -f -- AGENTS.md
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
echo "      diff $TOUCHSTONE_ROOT/hooks/conductor-review.config.example.toml ./.touchstone-review.toml"

if [ "$DRY_RUN" = false ]; then
  if [ "$SHIP" = true ] && [ "${COMMIT_CREATED:-false}" = true ]; then
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
