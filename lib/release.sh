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

touchstone_release_preflight_github_release_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    tk_fail "GitHub CLI is required to create the release. Install gh and try again."
    return 1
  fi

  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    tk_fail "GitHub CLI is not authenticated. Run: gh auth login"
    return 1
  fi
}

touchstone_release_preflight_remote_main() {
  local local_head remote_head

  tk_info "Refreshing origin/main and release tags"
  if ! git -C "$TOUCHSTONE_ROOT" fetch --prune --tags origin \
    "+refs/heads/main:refs/remotes/origin/main"; then
    tk_fail "Could not refresh origin/main and tags. Release state was not mutated."
    return 1
  fi

  local_head="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
  remote_head="$(git -C "$TOUCHSTONE_ROOT" rev-parse --verify refs/remotes/origin/main 2>/dev/null || true)"
  if [ -z "$remote_head" ]; then
    tk_fail "origin/main does not resolve after fetch. Release state was not mutated."
    return 1
  fi
  if [ "$local_head" != "$remote_head" ]; then
    tk_fail "Local main is not the exact origin/main revision."
    tk_dim "  local:  $local_head"
    tk_dim "  remote: $remote_head"
    tk_dim "  Fix: update local main, verify the diff, and rerun the release."
    return 1
  fi
}

touchstone_release_preflight_tag_absent() {
  local release_tag="$1"
  local remote_tag_status=0

  if git -C "$TOUCHSTONE_ROOT" show-ref --verify --quiet "refs/tags/$release_tag"; then
    tk_fail "Release tag already exists locally: $release_tag"
    return 1
  fi

  git -C "$TOUCHSTONE_ROOT" ls-remote --exit-code --tags origin \
    "refs/tags/$release_tag" >/dev/null 2>&1 || remote_tag_status=$?
  case "$remote_tag_status" in
    0)
      tk_fail "Release tag already exists on origin: $release_tag"
      return 1
      ;;
    2) return 0 ;;
    *)
      tk_fail "Could not verify whether $release_tag exists on origin (git exit $remote_tag_status)."
      return "$remote_tag_status"
      ;;
  esac
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
  IFS='.' read -r major minor patch <<<"$current"
  case "$bump_type" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch) patch=$((patch + 1)) ;;
    *)
      tk_fail "Unknown bump type: $bump_type (use --major, --minor, or --patch)"
      return 1
      ;;
  esac
  local new_version="${major}.${minor}.${patch}"
  tk_info "New version: v${new_version}"

  # Fail before mutating the repo; otherwise a local auth problem can leave a
  # pushed tag without the GitHub Release object that drives release workflows.
  touchstone_release_preflight_github_release_auth || return 1

  # Refresh the publication boundary immediately before mutation. A stale
  # local main or pre-existing tag must fail before VERSION, commits, or tags
  # change. A later race is rejected by the atomic push below.
  touchstone_release_preflight_remote_main || return 1
  local release_tag="v${new_version}"
  touchstone_release_preflight_tag_absent "$release_tag" || return 1
  local release_base_head
  release_base_head="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"

  # Bump VERSION file and touchstone's own dogfood stamp.
  echo "$new_version" >"$TOUCHSTONE_ROOT/VERSION"
  if [ -f "$TOUCHSTONE_ROOT/.touchstone-version" ]; then
    echo "$new_version" >"$TOUCHSTONE_ROOT/.touchstone-version"
  fi
  tk_ok "Bumped VERSION to $new_version"

  # Commit, tag, push (--no-verify: release is a meta-action, not user code).
  git -C "$TOUCHSTONE_ROOT" add VERSION
  if [ -f "$TOUCHSTONE_ROOT/.touchstone-version" ]; then
    git -C "$TOUCHSTONE_ROOT" add .touchstone-version
  fi
  git -C "$TOUCHSTONE_ROOT" commit --no-verify -m "v${new_version}"
  git -C "$TOUCHSTONE_ROOT" tag "$release_tag"

  local push_status=0
  git -C "$TOUCHSTONE_ROOT" push --atomic --no-verify origin \
    "HEAD:refs/heads/main" \
    "refs/tags/$release_tag:refs/tags/$release_tag" || push_status=$?
  if [ "$push_status" -ne 0 ]; then
    tk_fail "Atomic publication failed; branch and tag were not intentionally published separately."
    tk_dim "  Local release commit and $release_tag remain for diagnosis."
    tk_dim "  Retry after resolving remote state: git push --atomic --no-verify origin HEAD:refs/heads/main refs/tags/$release_tag:refs/tags/$release_tag"
    tk_dim "  Abort the local release: git tag -d $release_tag && git reset --hard $release_base_head"
    return "$push_status"
  fi
  tk_ok "Committed, tagged, atomically pushed main and $release_tag"

  # Create GitHub release. The release.published event triggers
  # .github/workflows/release.yml, which calls the shared homebrew-bump
  # reusable workflow in autumngarage/autumn-garage — the tap formula's
  # `url` + `sha256` get rewritten and committed to the tap's `main`
  # automatically (no local clone, no manual SHA computation).
  local github_release_status=0
  gh release create "$release_tag" \
    --repo autumngarage/touchstone \
    --title "$release_tag" \
    --generate-notes \
    --verify-tag || github_release_status=$?
  if [ "$github_release_status" -ne 0 ]; then
    tk_fail "Git refs were published, but the GitHub Release was not created."
    tk_dim "  Published commit: $(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
    tk_dim "  Published tag: $release_tag"
    tk_dim "  Resume idempotently: gh release view $release_tag --repo autumngarage/touchstone >/dev/null 2>&1 || gh release create $release_tag --repo autumngarage/touchstone --title $release_tag --generate-notes --verify-tag"
    return "$github_release_status"
  fi
  tk_ok "GitHub release created"

  echo ""
  tk_ok "Released v${new_version}"
  tk_dim "Tap formula bump is in flight via .github/workflows/release.yml"
  tk_dim "  watch: gh run list --workflow=release.yml --repo autumngarage/touchstone"
  tk_dim "Users can upgrade with: brew update && brew upgrade touchstone (after the workflow completes, ~30s)"
  echo ""
}
