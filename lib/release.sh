#!/usr/bin/env bash
#
# lib/release.sh — automate the toolkit release cycle.
#
# Bumps VERSION, tags, creates GitHub release, computes SHA,
# updates the homebrew-toolkit formula, and pushes everything.
#
set -euo pipefail

source "${TOOLKIT_ROOT}/lib/colors.sh"

TOOLKIT_ROOT="${TOOLKIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TAP_DIR="$HOME/Repos/homebrew-toolkit"

toolkit_release() {
  local bump_type="${1:-minor}"

  # Must be on main with clean working tree.
  local branch
  branch="$(git -C "$TOOLKIT_ROOT" rev-parse --abbrev-ref HEAD)"
  if [ "$branch" != "main" ]; then
    tk_fail "Must be on main branch (currently on $branch)"
    return 1
  fi
  if [ -n "$(git -C "$TOOLKIT_ROOT" status --porcelain)" ]; then
    tk_fail "Working tree is dirty. Commit or stash changes first."
    return 1
  fi

  # Current version.
  local current
  current="$(cat "$TOOLKIT_ROOT/VERSION" | tr -d '[:space:]')"
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

  # Bump VERSION file.
  echo "$new_version" > "$TOOLKIT_ROOT/VERSION"
  tk_ok "Bumped VERSION to $new_version"

  # Commit, tag, push.
  git -C "$TOOLKIT_ROOT" add VERSION
  git -C "$TOOLKIT_ROOT" commit -m "v${new_version}"
  git -C "$TOOLKIT_ROOT" tag "v${new_version}"
  git -C "$TOOLKIT_ROOT" push --tags
  tk_ok "Committed, tagged, pushed v${new_version}"

  # Create GitHub release.
  gh release create "v${new_version}" \
    --repo henrymodisett/toolkit \
    --title "v${new_version}" \
    --generate-notes
  tk_ok "GitHub release created"

  # Compute SHA256 of the release tarball.
  local tarball_url="https://github.com/henrymodisett/toolkit/archive/refs/tags/v${new_version}.tar.gz"
  local sha256
  sha256="$(curl -fsSL "$tarball_url" | shasum -a 256 | awk '{print $1}')"
  tk_ok "SHA256: ${sha256}"

  # Update homebrew formula.
  if [ -d "$TAP_DIR" ]; then
    local formula="$TAP_DIR/Formula/toolkit.rb"
    if [ -f "$formula" ]; then
      # Update URL and SHA in the formula.
      sed -i '' "s|url \"https://github.com/henrymodisett/toolkit/archive/refs/tags/v[^\"]*\.tar\.gz\"|url \"${tarball_url}\"|" "$formula"
      sed -i '' "s|sha256 \"[a-f0-9]*\"|sha256 \"${sha256}\"|" "$formula"

      git -C "$TAP_DIR" add Formula/toolkit.rb
      git -C "$TAP_DIR" commit -m "Bump formula to v${new_version}"
      git -C "$TAP_DIR" push
      tk_ok "Homebrew formula updated and pushed"
    else
      tk_warn "Formula not found at $formula — update manually"
    fi
  else
    tk_warn "Tap repo not found at $TAP_DIR — update formula manually"
    tk_dim "  URL: $tarball_url"
    tk_dim "  SHA: $sha256"
  fi

  echo ""
  tk_ok "Released v${new_version}"
  tk_dim "Users can upgrade with: brew update && brew upgrade toolkit"
  echo ""
}
