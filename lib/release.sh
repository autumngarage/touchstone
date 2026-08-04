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

  tk_info "Refreshing origin/main"
  if ! git -C "$TOUCHSTONE_ROOT" fetch --prune --no-tags origin \
    "+refs/heads/main:refs/remotes/origin/main"; then
    tk_fail "Could not refresh origin/main. Release state was not mutated."
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

touchstone_release_remote_ref_oid() {
  local ref_name="$1"
  local remote_output remote_oid="" remote_status=0

  remote_output="$(git -C "$TOUCHSTONE_ROOT" ls-remote --exit-code origin "$ref_name")" \
    || remote_status=$?
  case "$remote_status" in
    0)
      remote_oid="$(printf '%s\n' "$remote_output" | awk 'NR == 1 { print $1 }')"
      if [[ ! "$remote_oid" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
        tk_fail "Remote ref $ref_name returned an invalid object ID." >&2
        return 1
      fi
      printf '%s\n' "$remote_oid"
      ;;
    2) printf '\n' ;;
    *)
      tk_fail "Could not inspect remote ref $ref_name (git exit $remote_status)." >&2
      return "$remote_status"
      ;;
  esac
}

touchstone_release_command() {
  local arg

  printf 'bash '
  printf '%q' "$TOUCHSTONE_ROOT/scripts/release.sh"
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
}

touchstone_release_restore_command() {
  local release_tag="$1"
  local backup_ref="$2"

  printf 'git -C %q reset --hard %q && git -C %q tag %q %q' \
    "$TOUCHSTONE_ROOT" "$backup_ref" "$TOUCHSTONE_ROOT" "$release_tag" "$backup_ref"
}

touchstone_release_github_release_state() {
  local release_tag="$1"
  local state="" view_status=0

  state="$(gh release view "$release_tag" \
    --repo autumngarage/touchstone \
    --json isDraft,isPrerelease,publishedAt \
    --jq 'if .isDraft and .isPrerelease then "draft-prerelease" elif .isPrerelease then "published-prerelease" elif .isDraft then "draft" elif .publishedAt != null then "published" else "unknown" end')" \
    || view_status=$?
  [ "$view_status" -eq 0 ] || return "$view_status"
  case "$state" in
    published | draft | draft-prerelease | published-prerelease | unknown) printf '%s\n' "$state" ;;
    *)
      tk_fail "GitHub returned an invalid release state for $release_tag." >&2
      return 1
      ;;
  esac
}

touchstone_release_ensure_github_release() {
  local release_tag="$1"
  local state="" state_status=0 create_status=0 edit_status=0

  state="$(touchstone_release_github_release_state "$release_tag")" || state_status=$?
  if [ "$state_status" -eq 0 ]; then
    case "$state" in
      published)
        tk_ok "GitHub release already published"
        return 0
        ;;
      draft)
        gh release edit "$release_tag" \
          --repo autumngarage/touchstone \
          --draft=false || edit_status=$?
        if [ "$edit_status" -eq 0 ]; then
          tk_ok "Published existing draft GitHub release"
          return 0
        fi
        tk_fail "Could not publish the existing draft GitHub Release for $release_tag."
        return "$edit_status"
        ;;
      draft-prerelease)
        gh release edit "$release_tag" \
          --repo autumngarage/touchstone \
          --prerelease=false \
          --draft=false || edit_status=$?
        if [ "$edit_status" -eq 0 ]; then
          tk_ok "Published existing draft as a non-prerelease GitHub release"
          return 0
        fi
        tk_fail "Could not publish the prerelease draft safely for $release_tag."
        return "$edit_status"
        ;;
      published-prerelease)
        tk_fail "GitHub Release $release_tag is already published as a prerelease."
        tk_dim "  Clear the prerelease flag, then manually dispatch release.yml for $release_tag."
        return 1
        ;;
      unknown)
        tk_fail "GitHub Release $release_tag exists but is neither draft nor published."
        return 1
        ;;
    esac
  fi

  gh release create "$release_tag" \
    --repo autumngarage/touchstone \
    --title "$release_tag" \
    --generate-notes \
    --verify-tag || create_status=$?
  if [ "$create_status" -eq 0 ]; then
    tk_ok "GitHub release created"
    return 0
  fi

  # A failed response can still follow a committed server-side mutation.
  # Reconcile observed state before declaring recovery incomplete.
  state=""
  state_status=0
  state="$(touchstone_release_github_release_state "$release_tag")" || state_status=$?
  if [ "$state_status" -eq 0 ] && [ "$state" = "published" ]; then
    tk_warn "GitHub release creation returned an error, but the release is published."
    return 0
  fi
  if [ "$state_status" -eq 0 ] && [ "$state" = "draft" ]; then
    edit_status=0
    gh release edit "$release_tag" \
      --repo autumngarage/touchstone \
      --draft=false || edit_status=$?
    if [ "$edit_status" -eq 0 ]; then
      tk_ok "Published draft left by the failed GitHub release request"
      return 0
    fi
  fi
  if [ "$state_status" -eq 0 ] && [ "$state" = "draft-prerelease" ]; then
    edit_status=0
    gh release edit "$release_tag" \
      --repo autumngarage/touchstone \
      --prerelease=false \
      --draft=false || edit_status=$?
    if [ "$edit_status" -eq 0 ]; then
      tk_ok "Published prerelease draft left by the failed request as a normal release"
      return 0
    fi
  fi
  if [ "$state_status" -eq 0 ] && [ "$state" = "published-prerelease" ]; then
    tk_fail "GitHub created $release_tag as a prerelease; automatic tap publication did not run."
    tk_dim "  Clear the prerelease flag, then manually dispatch release.yml for $release_tag."
  fi

  return "$create_status"
}

touchstone_release_resume() {
  local release_tag="$1"
  local expected_release_oid="$2"
  local remote_tag_oid=""

  if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    tk_fail "Invalid release tag: $release_tag (expected vMAJOR.MINOR.PATCH)"
    return 1
  fi
  if [[ ! "$expected_release_oid" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    tk_fail "Invalid expected release commit: $expected_release_oid"
    return 1
  fi

  touchstone_release_preflight_github_release_auth || return 1
  remote_tag_oid="$(touchstone_release_remote_ref_oid "refs/tags/$release_tag")" || return $?
  if [ -z "$remote_tag_oid" ]; then
    tk_fail "Remote tag does not exist: $release_tag"
    return 1
  fi
  if [ "$remote_tag_oid" != "$expected_release_oid" ]; then
    tk_fail "Remote tag $release_tag no longer identifies the intended release commit."
    tk_dim "  expected: $expected_release_oid"
    tk_dim "  observed: $remote_tag_oid"
    return 1
  fi

  local github_release_status=0
  touchstone_release_ensure_github_release "$release_tag" || github_release_status=$?
  if [ "$github_release_status" -ne 0 ]; then
    tk_fail "GitHub Release recovery is still incomplete for $release_tag."
    tk_dim "  Retry: $(touchstone_release_command --resume "$release_tag" "$expected_release_oid")"
    return "$github_release_status"
  fi
  tk_ok "Release recovery complete: $release_tag is published"
}

touchstone_release_abort_local() {
  local release_tag="$1"
  local release_base_head="$2"
  local branch local_head local_tag_oid remote_main_oid remote_tag_oid backup_ref

  if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || [[ ! "$release_base_head" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    tk_fail "Usage: touchstone release --abort-local vMAJOR.MINOR.PATCH BASE_COMMIT"
    return 1
  fi
  branch="$(git -C "$TOUCHSTONE_ROOT" branch --show-current)"
  if [ "$branch" != "main" ]; then
    tk_fail "Local release abort requires main (currently $branch)."
    return 1
  fi
  if [ -n "$(git -C "$TOUCHSTONE_ROOT" status --porcelain)" ]; then
    tk_fail "Local release abort requires a clean worktree."
    return 1
  fi
  if ! git -C "$TOUCHSTONE_ROOT" cat-file -e "$release_base_head^{commit}" 2>/dev/null; then
    tk_fail "Release base commit does not exist locally: $release_base_head"
    return 1
  fi

  local_head="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
  local_tag_oid="$(git -C "$TOUCHSTONE_ROOT" rev-parse --verify "refs/tags/$release_tag^{commit}" 2>/dev/null || true)"
  if [ -z "$local_tag_oid" ] || [ "$local_tag_oid" != "$local_head" ]; then
    tk_fail "Local tag $release_tag does not identify the current release commit."
    return 1
  fi

  remote_main_oid="$(touchstone_release_remote_ref_oid refs/heads/main)" || return $?
  remote_tag_oid="$(touchstone_release_remote_ref_oid "refs/tags/$release_tag")" || return $?
  if [ "$remote_main_oid" != "$release_base_head" ] || [ -n "$remote_tag_oid" ]; then
    tk_fail "Remote release state changed; refusing local rollback."
    tk_dim "  expected remote main: $release_base_head"
    tk_dim "  observed remote main: ${remote_main_oid:-absent}"
    tk_dim "  observed remote tag:  ${remote_tag_oid:-absent}"
    return 1
  fi

  backup_ref="refs/touchstone/release-aborts/$release_tag"
  if git -C "$TOUCHSTONE_ROOT" show-ref --verify --quiet "$backup_ref"; then
    local existing_backup
    existing_backup="$(git -C "$TOUCHSTONE_ROOT" rev-parse "$backup_ref")"
    if [ "$existing_backup" != "$local_head" ]; then
      tk_fail "Recovery ref already exists at another commit: $backup_ref"
      return 1
    fi
  else
    git -C "$TOUCHSTONE_ROOT" update-ref "$backup_ref" "$local_head"
  fi

  git -C "$TOUCHSTONE_ROOT" tag -d "$release_tag"
  git -C "$TOUCHSTONE_ROOT" reset --hard "$release_base_head"
  tk_ok "Aborted local release state after revalidating unchanged remote refs."
  tk_dim "  Recovery ref retained: $backup_ref -> $local_head"
  tk_dim "  Restore if needed: $(touchstone_release_restore_command "$release_tag" "$backup_ref")"
}

touchstone_release_validate_retry_state() {
  local release_tag="$1"
  local release_base_head="$2"
  local release_commit="$3"
  local branch local_head local_tag_oid release_parent release_subject release_version

  if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || [[ ! "$release_base_head" =~ ^[0-9a-fA-F]{40,64}$ ]] \
    || [[ ! "$release_commit" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    tk_fail "Usage: touchstone release --retry vMAJOR.MINOR.PATCH BASE_COMMIT RELEASE_COMMIT"
    return 1
  fi
  branch="$(git -C "$TOUCHSTONE_ROOT" branch --show-current)"
  if [ "$branch" != "main" ]; then
    tk_fail "Release retry requires main (currently $branch)."
    return 1
  fi
  if [ -n "$(git -C "$TOUCHSTONE_ROOT" status --porcelain)" ]; then
    tk_fail "Release retry requires a clean worktree."
    return 1
  fi
  if ! git -C "$TOUCHSTONE_ROOT" cat-file -e "$release_base_head^{commit}" 2>/dev/null \
    || ! git -C "$TOUCHSTONE_ROOT" cat-file -e "$release_commit^{commit}" 2>/dev/null; then
    tk_fail "Release retry base or release commit does not exist locally."
    return 1
  fi

  local_head="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
  local_tag_oid="$(git -C "$TOUCHSTONE_ROOT" rev-parse --verify \
    "refs/tags/$release_tag^{commit}" 2>/dev/null || true)"
  release_parent="$(git -C "$TOUCHSTONE_ROOT" rev-parse "$release_commit^" 2>/dev/null || true)"
  release_subject="$(git -C "$TOUCHSTONE_ROOT" show -s --format=%s "$release_commit")"
  release_version="$(git -C "$TOUCHSTONE_ROOT" show "$release_commit:VERSION" 2>/dev/null \
    | tr -d '[:space:]' || true)"
  if [ "$local_head" != "$release_commit" ] \
    || [ "$local_tag_oid" != "$release_commit" ] \
    || [ "$release_parent" != "$release_base_head" ] \
    || [ "$release_subject" != "$release_tag" ] \
    || [ "$release_version" != "${release_tag#v}" ]; then
    tk_fail "Local release state does not match the versioned retry contract."
    tk_dim "  expected base:    $release_base_head"
    tk_dim "  expected release: $release_commit"
    tk_dim "  observed HEAD:    $local_head"
    tk_dim "  observed tag:     ${local_tag_oid:-absent}"
    tk_dim "  observed parent:  ${release_parent:-absent}"
    tk_dim "  observed subject: ${release_subject:-absent}"
    tk_dim "  observed VERSION: ${release_version:-absent}"
    return 1
  fi
}

touchstone_release_publish_refs() {
  local release_tag="$1"
  local release_base_head="$2"
  local release_commit="$3"
  local remote_main_oid="" remote_tag_oid="" remote_state_status=0 push_status=0

  remote_main_oid="$(touchstone_release_remote_ref_oid refs/heads/main)" || remote_state_status=$?
  if [ "$remote_state_status" -eq 0 ]; then
    remote_tag_oid="$(touchstone_release_remote_ref_oid "refs/tags/$release_tag")" \
      || remote_state_status=$?
  fi
  if [ "$remote_state_status" -ne 0 ]; then
    tk_fail "Could not establish remote state before release publication."
    return "$remote_state_status"
  fi

  if [ "$remote_main_oid" = "$release_commit" ] && [ "$remote_tag_oid" = "$release_commit" ]; then
    tk_warn "Both release refs are already published at the intended commit."
    tk_dim "  Continuing with GitHub Release publication."
    return 0
  fi
  if [ "$remote_main_oid" != "$release_base_head" ] || [ -n "$remote_tag_oid" ]; then
    tk_fail "Remote release state changed before atomic publication."
    tk_dim "  expected main before release: $release_base_head"
    tk_dim "  intended release commit:    $release_commit"
    tk_dim "  observed remote main:       ${remote_main_oid:-absent}"
    tk_dim "  observed remote tag:        ${remote_tag_oid:-absent}"
    return 1
  fi

  git -C "$TOUCHSTONE_ROOT" push --atomic --no-verify \
    "--force-with-lease=refs/heads/main:$release_base_head" origin \
    "$release_commit:refs/heads/main" \
    "refs/tags/$release_tag:refs/tags/$release_tag" || push_status=$?
  if [ "$push_status" -eq 0 ]; then
    return 0
  fi

  remote_state_status=0
  remote_main_oid="$(touchstone_release_remote_ref_oid refs/heads/main)" || remote_state_status=$?
  if [ "$remote_state_status" -eq 0 ]; then
    remote_tag_oid="$(touchstone_release_remote_ref_oid "refs/tags/$release_tag")" \
      || remote_state_status=$?
  fi
  if [ "$remote_state_status" -ne 0 ]; then
    tk_fail "Atomic publication returned an error and remote state could not be reconciled."
    tk_dim "  Local release commit and $release_tag remain unchanged for diagnosis."
    return "$push_status"
  fi
  if [ "$remote_main_oid" = "$release_commit" ] && [ "$remote_tag_oid" = "$release_commit" ]; then
    tk_warn "Atomic push returned an error, but both release refs were published."
    tk_dim "  Continuing with GitHub Release creation after remote reconciliation."
    return 0
  fi
  if [ "$remote_main_oid" = "$release_base_head" ] && [ -z "$remote_tag_oid" ]; then
    tk_fail "Atomic publication failed before either release ref was published."
    tk_dim "  Local release commit and $release_tag remain for retry or verified local rollback."
    tk_dim "  Retry complete publication: $(touchstone_release_command --retry "$release_tag" "$release_base_head" "$release_commit")"
    tk_dim "  Abort after revalidating remote refs: $(touchstone_release_command --abort-local "$release_tag" "$release_base_head")"
    return "$push_status"
  fi

  tk_fail "Atomic publication returned an error and remote state changed concurrently."
  tk_dim "  expected main before release: $release_base_head"
  tk_dim "  intended release commit:    $release_commit"
  tk_dim "  observed remote main:       ${remote_main_oid:-absent}"
  tk_dim "  observed remote tag:        ${remote_tag_oid:-absent}"
  tk_dim "  Local release state was retained; inspect remote history before retry or rollback."
  return "$push_status"
}

touchstone_release_complete_publication() {
  local release_tag="$1"
  local release_base_head="$2"
  local release_commit="$3"
  local publication_status=0 github_release_status=0

  touchstone_release_publish_refs \
    "$release_tag" "$release_base_head" "$release_commit" || publication_status=$?
  [ "$publication_status" -eq 0 ] || return "$publication_status"
  tk_ok "Atomically published main and $release_tag"

  touchstone_release_ensure_github_release "$release_tag" || github_release_status=$?
  if [ "$github_release_status" -ne 0 ]; then
    tk_fail "Git refs were published, but normal GitHub Release recovery did not complete."
    tk_dim "  Published commit: $release_commit"
    tk_dim "  Published tag: $release_tag"
    tk_dim "  Resume idempotently: $(touchstone_release_command --resume "$release_tag" "$release_commit")"
    return "$github_release_status"
  fi
}

touchstone_release_retry() {
  local release_tag="$1"
  local release_base_head="$2"
  local release_commit="$3"

  touchstone_release_validate_retry_state \
    "$release_tag" "$release_base_head" "$release_commit" || return 1
  touchstone_release_preflight_github_release_auth || return 1
  touchstone_release_complete_publication \
    "$release_tag" "$release_base_head" "$release_commit" || return $?
  tk_ok "Release publication retry complete: $release_tag is published"
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
  local release_commit
  release_commit="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"

  # Atomically publish the refs and create the GitHub release. The
  # release.published event triggers
  # .github/workflows/release.yml, which calls the shared homebrew-bump
  # reusable workflow in autumngarage/autumn-garage — the tap formula's
  # `url` + `sha256` get rewritten and committed to the tap's `main`
  # automatically (no local clone, no manual SHA computation).
  touchstone_release_complete_publication \
    "$release_tag" "$release_base_head" "$release_commit" || return $?

  echo ""
  tk_ok "Released v${new_version}"
  tk_dim "Tap formula bump is in flight via .github/workflows/release.yml"
  tk_dim "  watch: gh run list --workflow=release.yml --repo autumngarage/touchstone"
  tk_dim "Users can upgrade with: brew update && brew upgrade touchstone (after the workflow completes, ~30s)"
  echo ""
}
