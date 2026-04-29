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
# shellcheck source=../lib/install-hooks.sh
source "$TOUCHSTONE_ROOT/lib/install-hooks.sh"
# shellcheck source=../lib/agents-principles-block.sh
source "$TOUCHSTONE_ROOT/lib/agents-principles-block.sh"
PROJECT_DIR="$(pwd)"
DRY_RUN=false
CHECK_ONLY=false
REQUESTED_BRANCH=""
SHIP=false
IN_PLACE=false

usage() {
  echo "Usage: $0 [--dry-run|-n] [--check] [--branch <name>] [--in-place|--no-branch] [--ship]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --ship) SHIP=true; shift ;;
    --no-ship) SHIP=false; shift ;;
    --in-place|--no-branch) IN_PLACE=true; shift ;;
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

if [ "$OLD_SHA" = "$CURRENT_SHA" ]; then
  echo "==> Already up to date."
  exit 0
fi

if [ "$CHECK_ONLY" = true ]; then
  echo "==> Needs sync."
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
    : > "$ROLLBACK_TMP_DIR/.touchstone-manifest.nonfile"
  else
    : > "$ROLLBACK_TMP_DIR/.touchstone-manifest.missing"
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

  if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "ERROR: Working tree is dirty. touchstone update needs a clean git boundary." >&2
    echo "       Commit, stash, or revert local changes, then run touchstone update." >&2
    echo "       Preview safely with: touchstone update --dry-run" >&2
    exit 1
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

# Read project type (default: generic for backward compatibility).
PROJECT_TYPE="generic"
if [ -f "$PROJECT_DIR/.touchstone-config" ]; then
  PROJECT_TYPE="$(grep '^project_type=' "$PROJECT_DIR/.touchstone-config" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
  PROJECT_TYPE="${PROJECT_TYPE:-generic}"
fi

# Scripts
update_file "$TOUCHSTONE_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
update_file "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" "$PROJECT_DIR/scripts/branch-guard.sh"
update_file "$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh" "$PROJECT_DIR/scripts/emergency-disclosure.sh"
update_file "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_DIR/scripts/touchstone-run.sh"
update_file "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
update_file "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
update_file "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
update_file "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" "$PROJECT_DIR/scripts/spawn-worktree.sh"
update_file "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" "$PROJECT_DIR/scripts/cleanup-worktrees.sh"

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

# Touchstone-shipped skills (touchstone-owned, prefixed with `touchstone-`
# to keep them distinguishable from project-owned skills under .claude/skills/).
# Each file inside a touchstone-* skill is overwritten on update; project-
# owned skills (any name without the `touchstone-` prefix) are untouched.
if [ -d "$TOUCHSTONE_ROOT/.claude/skills" ]; then
  for skill_dir in "$TOUCHSTONE_ROOT/.claude/skills/"touchstone-*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    project_skill_dir="$PROJECT_DIR/.claude/skills/$skill_name"
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$project_skill_dir"
    fi
    for f in "$skill_dir"*; do
      [ -f "$f" ] || continue
      update_file "$f" "$project_skill_dir/$(basename "$f")"
    done
  done
fi

# Per-profile project-owned templates (e.g. swift's .swiftlint.yml). These are
# NOT touchstone-owned: add when missing, never overwrite a hand-edited copy.
# They stay out of .touchstone-manifest so future `touchstone update` runs do
# not clobber project-owned customization.
PROJECT_OWNED_ADDED_PATHS=()
add_profile_project_template_if_missing() {
  local src="$1" dst="$2"
  local rel_path
  rel_path="$(relative_project_path "$dst")"

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

if [ "$PROJECT_TYPE" = "swift" ] && [ -f "$TOUCHSTONE_ROOT/templates/swift/.swiftlint.yml" ]; then
  add_profile_project_template_if_missing \
    "$TOUCHSTONE_ROOT/templates/swift/.swiftlint.yml" \
    "$PROJECT_DIR/.swiftlint.yml"
fi

if [ -f "$TOUCHSTONE_ROOT/templates/GEMINI.md" ]; then
  gemini_md_was_present=false
  [ -f "$PROJECT_DIR/GEMINI.md" ] && gemini_md_was_present=true
  add_profile_project_template_if_missing \
    "$TOUCHSTONE_ROOT/templates/GEMINI.md" \
    "$PROJECT_DIR/GEMINI.md"
  if [ "$DRY_RUN" = false ] && [ "$gemini_md_was_present" = false ] && [ -f "$PROJECT_DIR/GEMINI.md" ]; then
    escaped_project_name="$(printf '%s' "$(basename "$PROJECT_DIR")" | sed 's/[\\/&]/\\&/g')"
    sed -i '' "s/{{PROJECT_NAME}}/$escaped_project_name/g" "$PROJECT_DIR/GEMINI.md" 2>/dev/null || true
  fi
fi

# Refresh the touchstone-managed shared-principles block inside AGENTS.md.
# AGENTS.md itself is project-owned, but the sentinel-delimited block is
# touchstone-owned so non-Claude reviewers (Codex/Gemini) get the engineering
# principles that CLAUDE.md gets for free via @-imports.
AGENTS_PRINCIPLES_TOUCHED=false
if [ "$DRY_RUN" = false ] && [ -f "$PROJECT_DIR/AGENTS.md" ]; then
  agents_md_before_sha="$(shasum -a 256 "$PROJECT_DIR/AGENTS.md" | awk '{print $1}')"
  agents_principles_block_apply "$PROJECT_DIR/AGENTS.md" || true
  agents_md_after_sha="$(shasum -a 256 "$PROJECT_DIR/AGENTS.md" | awk '{print $1}')"
  if [ "$agents_md_before_sha" != "$agents_md_after_sha" ]; then
    AGENTS_PRINCIPLES_TOUCHED=true
    echo "    refreshed (project-owned, managed block): AGENTS.md"
  fi
fi

write_touchstone_manifest() {
  local manifest="$PROJECT_DIR/.touchstone-manifest"
  {
    printf '# Managed by touchstone. These paths may be updated by `touchstone update`.\n'
    printf '.touchstone-manifest\n'
    printf '.touchstone-version\n'
    if [ -d "$TOUCHSTONE_ROOT/principles" ]; then
      for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
        printf 'principles/%s\n' "$(basename "$f")"
      done
    fi
    printf 'scripts/codex-review.sh\n'
    printf 'scripts/branch-guard.sh\n'
    printf 'scripts/emergency-disclosure.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    printf 'scripts/spawn-worktree.sh\n'
    printf 'scripts/cleanup-worktrees.sh\n'
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
  } > "$manifest"
}

# Ensure scripts are executable and write touchstone metadata.
if [ "$DRY_RUN" = false ]; then
  if [ -d "$PROJECT_DIR/scripts" ]; then
    chmod +x "$PROJECT_DIR/scripts/"*.sh 2>/dev/null || true
  fi
  echo "$CURRENT_SHA" > "$PROJECT_DIR/.touchstone-version"
  write_touchstone_manifest
fi

echo ""
echo "==> Summary: $ADDED added, $UPDATED updated, $UNCHANGED unchanged"

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
  git -C "$PROJECT_DIR" add -A -- principles scripts .touchstone-manifest
  git -C "$PROJECT_DIR" add -f -- .touchstone-version
  if [ -f "$PROJECT_DIR/.claude/settings.json" ]; then
    git -C "$PROJECT_DIR" add -f -- .claude/settings.json
  fi
  if [ -d "$PROJECT_DIR/.claude/skills" ]; then
    git -C "$PROJECT_DIR" add -f -- .claude/skills
  fi
  # Stage any per-profile project-owned templates added on this run (e.g.
  # swift's .swiftlint.yml). These are project-owned, but the addition only
  # makes sense bundled into the same review commit as the rest of the
  # update — leaving them unstaged would make `touchstone update --ship`
  # ship an incomplete change.
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
echo "      diff $TOUCHSTONE_ROOT/hooks/codex-review.config.example.toml ./.codex-review.toml"

if [ "$DRY_RUN" = false ]; then
  if [ "$SHIP" = true ] && [ "${COMMIT_CREATED:-false}" = true ]; then
    if [ ! -x "$PROJECT_DIR/scripts/open-pr.sh" ]; then
      echo ""
      echo "==> --ship requested but scripts/open-pr.sh is missing or not executable."
      echo "    branch: $UPDATE_BRANCH (left for manual ship)"
    else
      echo ""
      echo "==> Shipping update via scripts/open-pr.sh --auto-merge..."
      if ! (cd "$PROJECT_DIR" && bash scripts/open-pr.sh --auto-merge); then
        echo ""
        echo "==> Ship failed (see errors above). The update commit is preserved on:"
        echo "    branch: $UPDATE_BRANCH"
        echo "    Re-ship when ready:  cd $PROJECT_DIR && bash scripts/open-pr.sh --auto-merge"
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
