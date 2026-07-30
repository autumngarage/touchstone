#!/usr/bin/env bash
#
# lib/install-skills.sh — install Touchstone-bundled user-scoped Claude Code
# skills from the Touchstone source `skills/` directory into the caller's
# `~/.claude/skills/`.
#
# Why this exists:
#   The user-scoped skill bundle (engineering principles, git workflow,
#   Cortex protocol, audit-weak-points, agent-swarms,
#   memory-audit) is touchstone-owned guidance that should be available to
#   Claude Code in every project, not duplicated into each project's
#   `.claude/skills/`. This helper writes them to `~/.claude/skills/` so a
#   single source of truth reaches every project the user opens.
#
#   Project-scoped skills (anything under `<project>/.claude/skills/` that
#   is NOT under `~/.claude/skills/`) remain project-owned and untouched.
#
# Public surface:
#   touchstone_install_skills <touchstone_root> [user_skills_dir]
#       Install all skills under <touchstone_root>/skills/* into
#       <user_skills_dir> (defaults to "$HOME/.claude/skills"). Each skill
#       is copied as a directory; existing skills with the same name are
#       overwritten only when content differs (a .bak copy is left when a
#       conflict is overwritten so the user can recover hand-edits).
#
#   touchstone_uninstall_legacy_project_skills <project_dir>
#       Migration helper: remove `<project_dir>/.claude/skills/touchstone-*`
#       and `<project_dir>/.claude/skills/memory-audit/` left over from the
#       previous project-scoped install. The project's other skills are
#       left intact.
#
# Exit codes:
#   0 — all requested operations succeeded (no-op counts as success)
#   1 — source dir missing, target dir not writable, or copy failed

# Shared symlink-safe write guard. Source defensively so this lib works
# standalone; a no-op when the caller already sourced it.
if ! command -v touchstone_ensure_safe_dest >/dev/null 2>&1; then
  # shellcheck source=safe-write.sh
  source "$(dirname "${BASH_SOURCE[0]}")/safe-write.sh"
fi

# Skills considered touchstone-owned for the legacy-skill cleanup. Listed
# explicitly rather than by glob so a hand-added skill that happens to
# start with "touchstone-" (project's own) is not deleted.
_TOUCHSTONE_BUNDLED_SKILL_NAMES=(
  touchstone-git-workflow
  touchstone-pre-impl
  touchstone-agent-swarms
  touchstone-audit-weak-points
  cortex-protocol
  memory-audit
)

touchstone_install_skills() {
  local touchstone_root="$1"
  local user_skills_dir="${2:-$HOME/.claude/skills}"

  if [ -z "$touchstone_root" ]; then
    echo "ERROR: touchstone_install_skills requires touchstone_root" >&2
    return 1
  fi

  local source_dir="$touchstone_root/skills"
  if [ ! -d "$source_dir" ]; then
    # No bundle to install — not an error, just nothing to do.
    return 0
  fi

  if ! mkdir -p "$user_skills_dir" 2>/dev/null; then
    echo "ERROR: cannot create $user_skills_dir" >&2
    return 1
  fi

  local installed=0 updated=0 unchanged=0 backed_up=0
  local skill_dir name target

  for skill_dir in "$source_dir"/*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "$skill_dir")"
    target="$user_skills_dir/$name"

    # Never write through a symlink at the skill target (cp -R would follow it
    # and escape ~/.claude/skills). Replaces a final-component symlink; skips on
    # a symlinked ancestor.
    touchstone_ensure_safe_dest "$target" "$user_skills_dir" false || continue

    if [ ! -d "$target" ]; then
      cp -R "$skill_dir" "$target"
      installed=$((installed + 1))
      continue
    fi

    # Existing skill at target: compare content. Use diff -rq to detect any
    # difference (file content, file presence). If identical, skip.
    if diff -rq "$skill_dir" "$target" >/dev/null 2>&1; then
      unchanged=$((unchanged + 1))
      continue
    fi

    # Different. Back up the user's existing copy and overwrite.
    local backup="$user_skills_dir/${name}.bak"
    rm -rf "$backup"
    mv "$target" "$backup"
    cp -R "$skill_dir" "$target"
    updated=$((updated + 1))
    backed_up=$((backed_up + 1))
  done

  # Caller can read the summary via stdout if they want it.
  printf 'touchstone-skills: installed=%d updated=%d unchanged=%d backed_up=%d target=%s\n' \
    "$installed" "$updated" "$unchanged" "$backed_up" "$user_skills_dir"
  return 0
}

touchstone_uninstall_legacy_project_skills() {
  local project_dir="$1"

  if [ -z "$project_dir" ]; then
    echo "ERROR: touchstone_uninstall_legacy_project_skills requires project_dir" >&2
    return 1
  fi

  local project_skills="$project_dir/.claude/skills"
  if [ ! -d "$project_skills" ]; then
    return 0
  fi

  local removed=0 name target
  for name in "${_TOUCHSTONE_BUNDLED_SKILL_NAMES[@]}"; do
    target="$project_skills/$name"
    if [ -d "$target" ]; then
      rm -rf "$target"
      removed=$((removed + 1))
    fi
  done

  if [ "$removed" -gt 0 ]; then
    printf 'touchstone-skills: legacy project-scoped skills removed=%d (now installed user-scope)\n' "$removed"
  fi

  # Clean up `.claude/skills/` if it was emptied by the removal — keeps the
  # project tree tidy. Leave alone if the user has their own project-scoped
  # skills there.
  rmdir "$project_skills" 2>/dev/null || true

  return 0
}
