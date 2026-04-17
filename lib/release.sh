#!/usr/bin/env bash
#
# lib/release.sh — automate the Touchstone release cycle.
#
# Bumps VERSION, commits, tags, pushes main, creates GitHub release, computes SHA,
# clones the homebrew tap to a temp dir, updates the formula, pushes, cleans up.
#
set -euo pipefail

source "${TOUCHSTONE_ROOT}/lib/colors.sh"

TOUCHSTONE_ROOT="${TOUCHSTONE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TOUCHSTONE_RELEASE_TAP_TMP=""

cleanup_tap_tmp() {
  if [ -n "${TOUCHSTONE_RELEASE_TAP_TMP:-}" ]; then
    rm -rf "$TOUCHSTONE_RELEASE_TAP_TMP"
    TOUCHSTONE_RELEASE_TAP_TMP=""
  fi
}

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

  # Create GitHub release.
  gh release create "v${new_version}" \
    --repo autumngarage/touchstone \
    --title "v${new_version}" \
    --generate-notes
  tk_ok "GitHub release created"

  # Compute SHA256 of the release tarball.
  local tarball_url="https://github.com/autumngarage/touchstone/archive/refs/tags/v${new_version}.tar.gz"
  local sha256
  sha256="$(curl -fsSL "$tarball_url" | shasum -a 256 | awk '{print $1}')"
  tk_ok "SHA256: ${sha256}"

  # Update homebrew formula — clone tap to temp dir, update, push, clean up.
  local tap_tmp
  TOUCHSTONE_RELEASE_TAP_TMP="$(mktemp -d -t touchstone-tap.XXXXXX)"
  tap_tmp="$TOUCHSTONE_RELEASE_TAP_TMP"
  trap cleanup_tap_tmp EXIT

  tk_dim "Cloning tap repo..."
  if gh repo clone autumngarage/homebrew-touchstone "$tap_tmp" -- --depth=1 2>/dev/null; then
    local formula="$tap_tmp/Formula/touchstone.rb"
    if [ -f "$formula" ]; then
      sed -i '' "s|url \"https://github.com/autumngarage/touchstone/archive/refs/tags/v[^\"]*\.tar\.gz\"|url \"${tarball_url}\"|" "$formula"
      sed -i '' "s|sha256 \"[a-f0-9]*\"|sha256 \"${sha256}\"|" "$formula"

      git -C "$tap_tmp" add Formula/touchstone.rb
      git -C "$tap_tmp" commit -m "Bump formula to v${new_version}"
      git -C "$tap_tmp" push
      tk_ok "Homebrew formula updated and pushed"
    else
      tk_warn "Formula not found — update manually"
      tk_dim "  URL: $tarball_url"
      tk_dim "  SHA: $sha256"
    fi
  else
    tk_warn "Could not clone tap repo — update formula manually"
    tk_dim "  URL: $tarball_url"
    tk_dim "  SHA: $sha256"
  fi

  echo ""
  tk_ok "Released v${new_version}"
  tk_dim "Users can upgrade with: brew update && brew upgrade touchstone"
  echo ""

  cleanup_tap_tmp
  trap - EXIT
}
