#!/usr/bin/env bash
#
# lib/release.sh — automate the Touchstone release cycle.
#
# Bumps VERSION, commits, tags, pushes main, creates the GitHub release.
# The Homebrew tap formula is bumped asynchronously by
# .github/workflows/release.yml (which calls the shared homebrew-bump
# reusable workflow in autumngarage/autumn-garage) — no local tap clone.
#
set -euo pipefail

source "${TOUCHSTONE_ROOT}/lib/colors.sh"

TOUCHSTONE_ROOT="${TOUCHSTONE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

touchstone_release() {
  local bump_type="${1:-minor}"

  # Must be on main with clean working tree.
  local branch
  branch="$(git -C "$TOUCHSTONE_ROOT" rev-parse --abbrev-ref HEAD)"
  if [ "$branch" != "main" ]; then
    tk_fail "Must be on main branch (currently on $branch)"
    return 1
  fi
  if [ -n "$(git -C "$TOUCHSTONE_ROOT" status --porcelain)" ]; then
    tk_fail "Working tree is dirty. Commit or stash changes first."
    return 1
  fi

  # Current version.
  local current
  current="$(cat "$TOUCHSTONE_ROOT/VERSION" | tr -d '[:space:]')"
  tk_info "Current version: v${current}"

  # Compute new version.
  local major minor patch
  IFS='.' read -r major minor patch <<< "$current"
  case "$bump_type" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) tk_fail "Unknown bump type: $bump_type (use --major, --minor, or --patch)"; return 1 ;;
  esac
  local new_version="${major}.${minor}.${patch}"
  tk_info "New version: v${new_version}"

  # Bump VERSION file and touchstone's own dogfood stamp.
  echo "$new_version" > "$TOUCHSTONE_ROOT/VERSION"
  if [ -f "$TOUCHSTONE_ROOT/.touchstone-version" ]; then
    echo "$new_version" > "$TOUCHSTONE_ROOT/.touchstone-version"
  fi
  tk_ok "Bumped VERSION to $new_version"

  # Commit, tag, push (--no-verify: release is a meta-action, not user code).
  git -C "$TOUCHSTONE_ROOT" add VERSION
  if [ -f "$TOUCHSTONE_ROOT/.touchstone-version" ]; then
    git -C "$TOUCHSTONE_ROOT" add .touchstone-version
  fi
  git -C "$TOUCHSTONE_ROOT" commit --no-verify -m "v${new_version}"
  git -C "$TOUCHSTONE_ROOT" tag "v${new_version}"
  git -C "$TOUCHSTONE_ROOT" push --no-verify origin main "v${new_version}"
  tk_ok "Committed, tagged, pushed main and v${new_version}"

  # Create GitHub release. The release.published event triggers
  # .github/workflows/release.yml, which calls the shared homebrew-bump
  # reusable workflow in autumngarage/autumn-garage — the tap formula's
  # `url` + `sha256` get rewritten and committed to the tap's `main`
  # automatically (no local clone, no manual SHA computation).
  gh release create "v${new_version}" \
    --repo autumngarage/touchstone \
    --title "v${new_version}" \
    --generate-notes
  tk_ok "GitHub release created"

  echo ""
  tk_ok "Released v${new_version}"
  tk_dim "Tap formula bump is in flight via .github/workflows/release.yml"
  tk_dim "  watch: gh run list --workflow=release.yml --repo autumngarage/touchstone"
  tk_dim "Users can upgrade with: brew update && brew upgrade touchstone (after the workflow completes, ~30s)"
  echo ""
}
