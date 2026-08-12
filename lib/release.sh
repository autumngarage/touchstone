#!/usr/bin/env bash
#
# lib/release.sh — automate the Touchstone release cycle.
#
# Bumps VERSION on a release branch, ships the bump through the PR merge
# gate (scripts/open-pr.sh --auto-merge), then tags the squash-merged main
# commit and creates the GitHub release. The version bump reaches main only
# through the PR boundary — required checks plus exact-head review — never
# through a direct push (issue #729): branch protection with enforce_admins
# rejects direct pushes for every identity, the release identity included.
#
# The Homebrew tap formula is bumped asynchronously by
# .github/workflows/release.yml (which calls the shared homebrew-bump
# reusable workflow in autumngarage/autumn-garage) — no local tap clone.
#
set -euo pipefail

source "${TOUCHSTONE_ROOT}/lib/colors.sh"

TOUCHSTONE_ROOT="${TOUCHSTONE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

TOUCHSTONE_RELEASE_REPO="autumngarage/touchstone"

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

# One derivation for the branch name so ship and finalize agree on it.
touchstone_release_branch_name() {
  printf 'release/v%s\n' "$1"
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
  current="$(tr -d '[:space:]' <"$TOUCHSTONE_ROOT/VERSION")"
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
  # merged version bump without the GitHub Release object that drives
  # release workflows.
  touchstone_release_preflight_github_release_auth || return 1

  local release_branch
  release_branch="$(touchstone_release_branch_name "$new_version")"

  # A leftover branch means a previous attempt stopped mid-flight. Refuse to
  # guess which phase it reached; name the resume commands instead.
  if git -C "$TOUCHSTONE_ROOT" show-ref --verify --quiet "refs/heads/${release_branch}"; then
    tk_fail "Release branch ${release_branch} already exists from an unfinished attempt."
    echo "  Resume shipping it:  git checkout ${release_branch} && bash scripts/open-pr.sh --auto-merge" >&2
    echo "  After the PR merges: bin/touchstone release --finalize v${new_version}" >&2
    echo "  Or discard it:       git branch -D ${release_branch}" >&2
    return 1
  fi

  # Bump VERSION and touchstone's own dogfood stamp on a release branch —
  # never on main (--no-verify commit: release is a meta-action, not user
  # code; the PR boundary below is the real gate).
  git -C "$TOUCHSTONE_ROOT" checkout -q -b "$release_branch"
  echo "$new_version" >"$TOUCHSTONE_ROOT/VERSION"
  if [ -f "$TOUCHSTONE_ROOT/.touchstone-version" ]; then
    echo "$new_version" >"$TOUCHSTONE_ROOT/.touchstone-version"
  fi
  git -C "$TOUCHSTONE_ROOT" add VERSION
  if [ -f "$TOUCHSTONE_ROOT/.touchstone-version" ]; then
    git -C "$TOUCHSTONE_ROOT" add .touchstone-version
  fi
  git -C "$TOUCHSTONE_ROOT" commit --no-verify -m "v${new_version}"
  tk_ok "Bumped VERSION to $new_version on ${release_branch}"

  # Ship through the same PR boundary as every other change: open-pr.sh
  # pushes the branch, opens the PR, requests exact-head review, and merges
  # once required checks pass. On any stall, fail closed — no tag, no
  # release — and name the resume commands.
  if ! (cd "$TOUCHSTONE_ROOT" && bash scripts/open-pr.sh --auto-merge); then
    tk_fail "Release PR for v${new_version} did not merge; no tag or release was created."
    echo "  Fix what open-pr.sh reported above, then rerun from ${release_branch}:" >&2
    echo "      bash scripts/open-pr.sh --auto-merge" >&2
    echo "  If the review-round budget stalls this mechanical VERSION-only bump:" >&2
    echo "      bash scripts/open-pr.sh --auto-merge --round-budget-override \"mechanical VERSION-only release bump\"" >&2
    echo "  After the PR merges, finish the release:" >&2
    echo "      bin/touchstone release --finalize v${new_version}" >&2
    return 1
  fi
  tk_ok "Release PR merged"

  touchstone_release_finalize "v${new_version}"
}

# Tag the squash-merged main commit and publish the GitHub release.
#
# Separate entry point (`bin/touchstone release --finalize vX.Y.Z`) so a
# release whose PR stalled and merged later can finish without re-bumping.
# Idempotent: a rerun after a partial failure (tag pushed, release missing)
# skips the steps that already completed.
touchstone_release_finalize() {
  local raw_version="${1:-}"
  local new_version="${raw_version#v}"
  if ! printf '%s' "$new_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    tk_fail "Invalid version '${raw_version}' (expected X.Y.Z or vX.Y.Z)."
    return 1
  fi
  local release_branch tag
  release_branch="$(touchstone_release_branch_name "$new_version")"
  tag="v${new_version}"

  touchstone_release_preflight_github_release_auth || return 1

  git -C "$TOUCHSTONE_ROOT" fetch -q origin main

  # Squash-merge rewrites the commit: the merged main commit is NOT the
  # branch head. Resolve it from the PR record, never from the local branch.
  local merge_record merge_state merge_sha
  if ! merge_record="$(gh pr view "$release_branch" --repo "$TOUCHSTONE_RELEASE_REPO" \
    --json state,mergeCommit --jq '.state + " " + (.mergeCommit.oid // "")')"; then
    tk_fail "Could not resolve the release PR for ${release_branch}."
    echo "  Ship it first: git checkout ${release_branch} && bash scripts/open-pr.sh --auto-merge" >&2
    echo "  Then rerun:    bin/touchstone release --finalize ${tag}" >&2
    return 1
  fi
  merge_state="${merge_record%% *}"
  merge_sha="${merge_record#* }"
  if [ "$merge_state" != "MERGED" ] || [ -z "$merge_sha" ]; then
    tk_fail "Release PR for ${release_branch} is not merged (state: ${merge_state:-unknown})."
    echo "  Merge it first: git checkout ${release_branch} && bash scripts/open-pr.sh --auto-merge" >&2
    echo "  Then rerun:     bin/touchstone release --finalize ${tag}" >&2
    return 1
  fi

  # Invariant: the tag target is a commit on origin/main.
  if ! git -C "$TOUCHSTONE_ROOT" merge-base --is-ancestor "$merge_sha" origin/main; then
    tk_fail "Merged commit ${merge_sha} is not on origin/main."
    echo "  Refresh and rerun: git fetch origin && bin/touchstone release --finalize ${tag}" >&2
    return 1
  fi
  # Invariant: the merged commit carries exactly this version bump.
  local merged_version
  merged_version="$(git -C "$TOUCHSTONE_ROOT" show "${merge_sha}:VERSION" | tr -d '[:space:]')"
  if [ "$merged_version" != "$new_version" ]; then
    tk_fail "VERSION at merged commit ${merge_sha} is ${merged_version}, expected ${new_version}."
    echo "  The squash merge did not land this bump. Inspect the PR for ${release_branch}: gh pr view ${release_branch}" >&2
    return 1
  fi

  # Tag the merged main commit and push the tag (--no-verify: the tag push
  # is the release meta-action; the version bump itself already merged
  # through the PR boundary).
  if git -C "$TOUCHSTONE_ROOT" rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    local existing_target
    existing_target="$(git -C "$TOUCHSTONE_ROOT" rev-parse "refs/tags/${tag}^{commit}")"
    if [ "$existing_target" != "$merge_sha" ]; then
      tk_fail "Tag ${tag} already exists at ${existing_target}, not the merged commit ${merge_sha}."
      echo "  Retarget it deliberately: git tag -d ${tag} && bin/touchstone release --finalize ${tag}" >&2
      return 1
    fi
    tk_ok "Tag ${tag} already points at the merged commit"
  else
    git -C "$TOUCHSTONE_ROOT" tag "$tag" "$merge_sha"
  fi
  git -C "$TOUCHSTONE_ROOT" push --no-verify origin "$tag"
  tk_ok "Tagged merged commit ${merge_sha} as ${tag} and pushed the tag"

  # Create the GitHub release. The release.published event triggers
  # .github/workflows/release.yml, which calls the shared homebrew-bump
  # reusable workflow in autumngarage/autumn-garage — the tap formula's
  # `url` + `sha256` get rewritten and committed to the tap's `main`
  # automatically (no local clone, no manual SHA computation).
  # Mere existence of a release object is not success: a draft never emits
  # release.published, so the tap bump would silently not run — publish it.
  local release_is_draft
  if release_is_draft="$(gh release view "$tag" --repo "$TOUCHSTONE_RELEASE_REPO" \
    --json isDraft --jq '.isDraft' 2>/dev/null)"; then
    if [ "$release_is_draft" = "true" ]; then
      gh release edit "$tag" --repo "$TOUCHSTONE_RELEASE_REPO" --draft=false
      tk_ok "Published existing draft GitHub release ${tag}"
    else
      tk_ok "GitHub release ${tag} already exists"
    fi
  else
    gh release create "$tag" \
      --repo "$TOUCHSTONE_RELEASE_REPO" \
      --title "$tag" \
      --generate-notes
    tk_ok "GitHub release created"
  fi

  # Leave the operator on an up-to-date main when this working copy can own
  # it. main may be checked out in another worktree (e.g. --finalize run
  # from a release worktree); the tag and release are already published, so
  # local cleanup must never fail the release — fall back to detaching at
  # the released commit and say what was skipped.
  if git -C "$TOUCHSTONE_ROOT" checkout -q main 2>/dev/null; then
    # Best-effort: the tag and GitHub release are already published, so a
    # failed sync here (dirty worktree, transient fetch error) must not
    # turn a completed release into a nonzero exit (PR #784 review).
    if ! git -C "$TOUCHSTONE_ROOT" pull --rebase -q origin main 2>/dev/null; then
      tk_dim "local main could not be fast-forwarded (dirty worktree or fetch failure)"
      tk_dim "  Sync it manually: git checkout main && git pull --rebase origin main"
    fi
  elif git -C "$TOUCHSTONE_ROOT" checkout -q --detach "$merge_sha" 2>/dev/null; then
    tk_dim "main is checked out in another worktree; left this one detached at ${tag}"
    tk_dim "  Sync it where it lives: git checkout main && git pull --rebase origin main"
  else
    tk_dim "Could not switch this worktree off ${release_branch}; sync main manually."
  fi
  # The local release branch is merged; the remote one is retained by
  # merge-pr.sh for stacked-PR safety and cleaned up by cleanup-branches.sh.
  if git -C "$TOUCHSTONE_ROOT" show-ref --verify --quiet "refs/heads/${release_branch}"; then
    git -C "$TOUCHSTONE_ROOT" branch -q -D "$release_branch" 2>/dev/null \
      || tk_dim "Local branch ${release_branch} is still checked out in another worktree; delete it there."
  fi

  echo ""
  tk_ok "Released v${new_version}"
  tk_dim "Tap formula bump is in flight via .github/workflows/release.yml"
  tk_dim "  watch: gh run list --workflow=release.yml --repo autumngarage/touchstone"
  tk_dim "Users can upgrade with: brew update && brew upgrade touchstone (after the workflow completes, ~30s)"
  echo ""
}
