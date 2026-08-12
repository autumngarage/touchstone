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
#   7. Returns the checkout to the branch the caller started on (#772): a
#      branch-creating update never leaves the worktree parked on its
#      chore/touchstone-* branch, so an unattended sweep cannot strand the
#      next actor's commits there.
#
# Exit codes (tri-state ship reporting, #731):
#   0   update applied — and, with --ship, the PR is MERGED (positive
#       evidence: open-pr.sh --auto-merge exits 0 iff GitHub reports MERGED,
#       regression-locked by tests/test-open-pr-exit-contract.sh)
#   20  --ship armed a PR that is NOT merged: the update PR exists and is
#       open (review pending, merge-gate refusal, or the diff-scope guard
#       below refused auto-merge), so a human or later run must finish it
#   1+  stuck: the update or the ship failed with no open-PR evidence
#
# Diff-scope guard (#772 problem 2, the arpeggio#35 signal): before --ship
# auto-merges, the committed diff against the fork point must touch ONLY
# paths inside the touchstone sync write set. Any extra path refuses the
# AUTO-merge — the PR is still opened for human review.
#
set -euo pipefail

# Documented exit for "PR armed but not merged" (see header). Consumed by
# bootstrap/sync-all.sh's fan-out tally and lib/auto-update.sh's auto-ship
# reporting; keep the value in sync with both.
TOUCHSTONE_UPDATE_ARMED_EXIT=20

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
# shellcheck source=../lib/sync-content.sh
source "$TOUCHSTONE_ROOT/lib/sync-content.sh"
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

# Content-currency probe and managed-file enumerations live in
# lib/sync-content.sh (#731): the SAME read-only verdict backs this script's
# --check / early exit, auto-sync's should-sync decision, sync-all --check,
# and `touchstone status`. The wrappers below bind this run's PROJECT_DIR /
# TOUCHSTONE_ROOT / PROJECT_TYPE so the writer-side call sites (copy pass,
# manifest writer, template adder) consume the exact enumeration the probe
# compares against — writer and probe can never disagree about what
# "managed" means.
managed_file_pairs() {
  touchstone_content_managed_file_pairs "$PROJECT_DIR" "$TOUCHSTONE_ROOT" "$PROJECT_TYPE"
}

touchstone_manifest_entries() {
  touchstone_content_manifest_entries "$PROJECT_DIR" "$TOUCHSTONE_ROOT" "$PROJECT_TYPE"
}

project_template_slot_occupied() {
  touchstone_content_template_slot_occupied "$1"
}

managed_content_is_current() {
  touchstone_content_is_current "$PROJECT_DIR" "$TOUCHSTONE_ROOT"
}

# User-scoped skills and git hooks live OUTSIDE the project tree, so no
# content probe says anything about them. BOTH early exits must reconcile
# them or a deleted hook stays silently unrepaired behind "up to date" —
# and the identity-equal exit is the NORMAL released state, i.e. the most
# common path of all (PR #787 review, round 3). --check stays read-only.
reconcile_external_state() {
  local rc=0
  [ "$CHECK_ONLY" != true ] || return 0
  [ "$DRY_RUN" = false ] || return 0
  # STRICTLY outside the working tree: the user-scoped skills bundle
  # (~/.claude/skills) and the effective git hooks. Project-scoped legacy
  # skill retirement deletes TRACKED files under <project>/.claude/skills,
  # so it stays in the normal branch-and-commit path where the clean-tree
  # check, rollback snapshot, and update commit protect it — an early exit
  # runs before require_clean_git_repo and would rm -rf a user's modified
  # files with no recovery path (PR #787 review, override round P1).
  if [ -d "$TOUCHSTONE_ROOT/skills" ]; then
    touchstone_install_skills "$TOUCHSTONE_ROOT" || rc=1
  fi
  touchstone_install_hooks "$PROJECT_DIR" || rc=1
  # Status is propagated, not swallowed: the ambient auto-sync wrapper reports
  # a failed repair only if it can see one, and an ungated project must not
  # look like a successful no-op (PR #787 review, override round).
  return "$rc"
}

if [ "$OLD_SHA" = "$CURRENT_SHA" ]; then
  echo "==> Already up to date."
  reconcile_external_state || exit 1
  exit 0
fi

if managed_content_is_current; then
  echo "==> Already up to date."
  echo "    Stamp identity differs ($OLD_SHA vs $CURRENT_SHA), but every managed file matches; nothing to update."
  reconcile_external_state || exit 1
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

# The single remote whose metadata may name the default branch: 'origin'
# when it exists, else the ONLY remote. A repo tracking a differently named
# remote (e.g. 'upstream') HAS authoritative metadata, so treating "no
# origin" as "remoteless" and guessing from local branch names could bless
# the checked-out branch and fork its commits into the update PR; several
# remotes with none named origin is ambiguous and fails closed
# (PR #780 review, round 3 P1).
authoritative_remote() {
  local remotes
  remotes="$(git -C "$PROJECT_DIR" remote 2>/dev/null || true)"
  [ -n "$remotes" ] || return 1
  if grep -qxF "origin" <<<"$remotes"; then
    printf 'origin\n'
    return 0
  fi
  if [ "$(printf '%s\n' "$remotes" | grep -c .)" -eq 1 ]; then
    printf '%s\n' "$remotes"
    return 0
  fi
  return 1
}

# gh's positional <repository> accepts HOST/OWNER/REPO — but handing it the
# raw git remote URL makes gh treat an SSH host ALIAS (git@github-work:o/r)
# as the API hostname and query https://github-work/..., so the live lookup
# always fails and the authority silently degrades to the cached ref
# (PR #780 review, round 3 P1). Parse the remote ourselves and canonicalize
# ssh hosts through `ssh -G`, whose effective `hostname` is the host ssh
# would actually connect to; http(s)/git hosts are already canonical.
# Unparseable remotes (local paths, exotic schemes) return nonzero: no gh
# query, cached-ref fallback.
remote_repo_selector() {
  local url="$1"
  local rest host path is_ssh=false resolved

  case "$url" in
    ssh://*)
      is_ssh=true
      rest="${url#ssh://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      [ "$host" != "$rest" ] || return 1
      host="${host%%:*}"
      ;;
    http://* | https://* | git://*)
      rest="${url#*://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      [ "$host" != "$rest" ] || return 1
      host="${host%%:*}"
      ;;
    *://* | /* | ./* | ../*)
      return 1
      ;;
    *:*)
      # scp-like [user@]host:owner/repo — a '/' before the ':' is a local
      # path, not a host.
      is_ssh=true
      rest="${url#*@}"
      host="${rest%%:*}"
      path="${rest#*:}"
      case "$host" in */* | "") return 1 ;; esac
      ;;
    *)
      return 1
      ;;
  esac

  path="${path#/}"
  path="${path%/}"
  path="${path%.git}"
  [ -n "$host" ] && [ -n "$path" ] || return 1
  case "$path" in
    */*) ;;
    *) return 1 ;;
  esac

  if [ "$is_ssh" = true ] && command -v ssh >/dev/null 2>&1; then
    resolved="$(ssh -G "$host" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }' || true)"
    [ -n "$resolved" ] && host="$resolved"
  fi

  printf '%s/%s\n' "$host" "$path"
}

resolve_default_branch() {
  local default_branch="" remote="" remote_url="" selector=""

  remote="$(authoritative_remote)" || remote=""

  # The LIVE remote answer outranks the cached symbolic ref: after a
  # default-branch rename, refs/remotes/<remote>/HEAD keeps pointing at the
  # former default until someone runs git remote set-head, and trusting the
  # cache would authorize an update from the renamed-away branch
  # (PR #780 review, round 2 P1). The cache is the fallback for offline/gh-
  # less runs — best local knowledge, with the refusal below still guarding
  # any checkout that does not match it.
  if [ -n "$remote" ] && command -v gh >/dev/null 2>&1; then
    remote_url="$(git -C "$PROJECT_DIR" remote get-url "$remote" 2>/dev/null || true)"
    # Pinned via an explicit positional selector: an argument-less gh repo
    # view honors the GH_REPO environment override, which could point the
    # default-branch authority at an arbitrary repository whose default
    # matches the local feature branch (PR #780 review, override round P1).
    if [ -n "$remote_url" ] && selector="$(remote_repo_selector "$remote_url")"; then
      default_branch="$(gh repo view "$selector" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
    fi
  fi
  if [ -z "$default_branch" ] && [ -n "$remote" ]; then
    default_branch="$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)"
    default_branch="${default_branch#"$remote"/}"
  fi
  # init.defaultBranch is deliberately NOT consulted: it names the preferred
  # branch for NEWLY initialized repos, not this repo's default — a feature
  # branch bearing that name would be accepted and the fork would carry its
  # commits, recreating the exact #772 contamination (PR #780 review, P1).
  # Without authoritative remote metadata, only a repo with NO remotes AT
  # ALL gets a local heuristic, and only when it is unambiguous.
  if [ -z "$default_branch" ] \
    && [ -z "$(git -C "$PROJECT_DIR" remote 2>/dev/null || true)" ]; then
    local has_main=false has_master=false
    git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main && has_main=true
    git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/master && has_master=true
    if [ "$has_main" = true ] && [ "$has_master" = false ]; then
      default_branch="main"
    elif [ "$has_master" = true ] && [ "$has_main" = false ]; then
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
  local default_branch auth_remote="" remote_ref=""
  default_branch="$(resolve_default_branch)"
  auth_remote="$(authoritative_remote)" || auth_remote=""

  if [ -z "$default_branch" ]; then
    echo "ERROR: could not resolve the default branch for $PROJECT_DIR; refusing to branch from HEAD." >&2
    if [ -n "$auth_remote" ]; then
      echo "       Fix: git remote set-head $auth_remote --auto" >&2
    elif [ -n "$(git -C "$PROJECT_DIR" remote 2>/dev/null || true)" ]; then
      echo "       Several remotes and none named 'origin': touchstone cannot pick the authority." >&2
      echo "       Fix: git remote rename <primary-remote> origin" >&2
    else
      echo "       No remote and no unambiguous local main/master branch." >&2
    fi
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

  # Name equality is not history equality: a local default branch carrying
  # unpushed commits (an accidental commit on main, divergence after a
  # remote force-push) would fork those commits into the update PR despite
  # the name check above (PR #780 review, round 3 P1). Refresh only the
  # remote-tracking ref — the cached copy may be stale, and the user's local
  # branch is never touched (same pattern as open-pr.sh's review-policy
  # fetch) — then require HEAD to introduce nothing beyond it.
  if [ -n "$auth_remote" ]; then
    remote_ref="refs/remotes/$auth_remote/$default_branch"
    # A failed fetch fails CLOSED even when a cached tracking ref exists:
    # the cache can predate a remote force-push, and trusting it would
    # carry commits the authoritative branch no longer has
    # (PR #780 review). The ancestor check below only means anything
    # against a ref refreshed THIS run.
    if ! git -C "$PROJECT_DIR" fetch --quiet --no-tags "$auth_remote" \
      "+refs/heads/$default_branch:$remote_ref" >/dev/null 2>&1 \
      || ! git -C "$PROJECT_DIR" rev-parse --verify --quiet "$remote_ref^{commit}" >/dev/null; then
      echo "ERROR: cannot verify local '$default_branch' against $auth_remote; refusing to branch from HEAD." >&2
      echo "       The fetch failed and no $remote_ref exists locally, so unpushed local commits" >&2
      echo "       could ride into the update PR undetected." >&2
      echo "       Fix: git fetch $auth_remote $default_branch" >&2
      echo "       Then rerun: touchstone update" >&2
      echo "       To update the current branch in place instead: touchstone update --in-place" >&2
      touchstone_sync_log_skip "$PROJECT_DIR" "$OLD_SHA" "$CURRENT_SHA" "default-branch-unverifiable" "" "touchstone update"
      exit 1
    fi
    if ! git -C "$PROJECT_DIR" merge-base --is-ancestor HEAD "$remote_ref" 2>/dev/null; then
      echo "ERROR: local '$default_branch' has commits that $auth_remote/$default_branch does not; refusing to branch from HEAD." >&2
      echo "       A chore/touchstone-* branch forked here would carry those commits into the update PR." >&2
      echo "       Fix: git push $auth_remote $default_branch   (if they are meant to ship)" >&2
      echo "       Or move them aside: git branch <slug> && git reset --hard $auth_remote/$default_branch" >&2
      echo "       Then rerun: touchstone update" >&2
      echo "       To update the current branch in place instead: touchstone update --in-place" >&2
      touchstone_sync_log_skip "$PROJECT_DIR" "$OLD_SHA" "$CURRENT_SHA" "default-branch-ahead-of-remote" "" "touchstone update"
      exit 1
    fi
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
# Project-owned paths this run legitimately wrote: template slots it
# CREATED (a slot that already existed does not qualify) and steering files
# whose managed block it refreshed and staged. Both are absent from the
# manifest, so the scope guard needs them named explicitly (PR #787 review).
SCOPE_CREATED_SLOTS=()

add_project_template_if_missing() {
  local src="$1" dst="$2"
  local rel_path
  rel_path="$(relative_project_path "$dst")"

  if project_template_slot_occupied "$dst"; then
    # Hand-edited, already-shipped, or deliberately symlinked — leave alone.
    # update_file handles touchstone-owned files; this helper exists
    # precisely so project-owned additions skip when present, even if the
    # on-disk content differs. Checked BEFORE ensure_safe_dest: that guard
    # REPLACES a final-component symlink, which would rip out a
    # project-owned symlinked config the probe correctly reports as present
    # (PR #780 review, round 3 P2).
    return 0
  fi

  SCOPE_CREATED_SLOTS+=("$rel_path")
  if ! ensure_safe_dest "$dst"; then
    SKIPPED_UNSAFE=$((SKIPPED_UNSAFE + 1))
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
# Whether each steering file was otherwise clean BEFORE this run touched it.
# The scope exemption for a refreshed steering file may only apply when the
# update is the sole author of its diff: with TOUCHSTONE_FORCE_OVERLAP=1 a
# file can carry staged project-owned edits, and exempting the whole path
# would let those ride into an auto-merged touchstone commit
# (PR #787 review). Computed here because the refresh itself dirties them.
steering_file_was_clean() {
  local rel="$1"
  [ -e "$PROJECT_DIR/$rel" ] || return 0
  git -C "$PROJECT_DIR" ls-files --error-unmatch "$rel" >/dev/null 2>&1 || return 1
  git -C "$PROJECT_DIR" diff --quiet -- "$rel" 2>/dev/null || return 1
  git -C "$PROJECT_DIR" diff --cached --quiet -- "$rel" 2>/dev/null || return 1
}
AGENTS_WAS_CLEAN=false
GEMINI_WAS_CLEAN=false
steering_file_was_clean "AGENTS.md" && AGENTS_WAS_CLEAN=true
steering_file_was_clean "GEMINI.md" && GEMINI_WAS_CLEAN=true

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
  touchstone_manifest_entries >"$manifest"
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
      # A managed-block refresh of an existing steering file is exactly what
      # this update is for. It is project-owned so it is absent from the
      # manifest, and without recording it the scope guard reported a normal
      # refresh as foreign content and refused every auto-merge (round 2).
      # But exempt it ONLY when the file was otherwise clean before this run:
      # under TOUCHSTONE_FORCE_OVERLAP=1 it can carry staged project-owned
      # edits, and a whole-path exemption would auto-merge those under the
      # touchstone commit (round 5). Not exempting is the safe direction --
      # the guard then opens the PR for human review instead.
      local was_clean=false
      case "$rel" in
        AGENTS.md) was_clean="$AGENTS_WAS_CLEAN" ;;
        GEMINI.md) was_clean="$GEMINI_WAS_CLEAN" ;;
      esac
      if [ "$was_clean" = true ]; then
        SCOPE_CREATED_SLOTS+=("$rel")
      else
        echo "    NOTE: $rel carried pre-existing changes; not exempting it from the"
        echo "          diff-scope guard, so this update will open a PR for review."
      fi
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

# The command that ships the update branch. The checkout is left on that
# branch (returning it is deferred — see the checkout-restoration issue), so
# open-pr.sh operates on it directly.
# Positive GitHub evidence for the update branch's PR state, shared by both
# ship paths so identical real states never classify differently.
current_update_pr_state() {
  local pr_json pr_state pr_head pr_base local_head
  command -v gh >/dev/null 2>&1 || return 0
  pr_json="$(cd "$PROJECT_DIR" && gh pr view "$UPDATE_BRANCH" --json state,headRefOid,baseRefName 2>/dev/null || true)"
  pr_state="$(printf '%s\n' "$pr_json" | sed -nE 's/.*"state"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
  pr_head="$(printf '%s\n' "$pr_json" | sed -nE 's/.*"headRefOid"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
  pr_base="$(printf '%s\n' "$pr_json" | sed -nE 's/.*"baseRefName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
  [ -n "$pr_state" ] || return 0
  # An existing PR on this branch may target a stacked or otherwise
  # non-default base. Accepting it as evidence for THIS update would point
  # the suggested retry at that PR and merge the update into the wrong
  # branch (PR #787 review, override round).
  if [ -n "$pr_base" ] && [ -n "${ORIGINAL_BRANCH:-}" ] && [ "$pr_base" != "$ORIGINAL_BRANCH" ]; then
    return 0
  fi
  # The update-branch name is deterministic, so another clone or an earlier
  # run can leave an OPEN PR pointing at a DIFFERENT head. Claiming this
  # update is armed on that evidence reports someone else's PR as ours
  # (PR #787 review, round 3). Positive evidence means same branch AND same
  # head; anything else is not evidence about this update.
  local_head="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$pr_head" ] && [ -n "$local_head" ] && [ "$pr_head" != "$local_head" ]; then
    return 0
  fi
  printf '%s\n' "$pr_state"
}

manual_ship_command() {
  printf 'bash scripts/open-pr.sh --auto-merge'
}

# #772 problem 2 (arpeggio#35): a touchstone update PR touches a KNOWN write
# set. Before auto-merging, list every committed path between the fork point
# and HEAD that falls outside that set — the planned sync writes plus the
# project-owned templates the update adds only into empty slots
# (.markdownlint.json / .swiftlint.yml, which leave the planned set once
# they exist). Any survivor means foreign content rode into the update
# commit (e.g. a pre-staged file the unrelated-dirty allowance let through),
# and auto-merging it would land unreviewed changes under a chore title.
update_commit_scope_violations() {
  local scope_tmp path planned allowed
  scope_tmp="$(mktemp -t touchstone-update-scope.XXXXXX)"
  # The allowlist is what this run actually writes: every entry of the
  # manifest it just regenerated (exact files — the planned-write set used
  # to carry directory-wide entries like `principles/`, which admitted any
  # staged descendant) plus the project-owned template slots this run
  # created (an unconditional lint-file exemption absorbed a pre-staged edit
  # to an EXISTING .markdownlint.json). PR #787 review.
  {
    if [ -f "$PROJECT_DIR/.touchstone-manifest" ]; then
      tr -d '\r' <"$PROJECT_DIR/.touchstone-manifest"
    fi
    printf '%s\n' "${SCOPE_CREATED_SLOTS[@]:-}"
    # A retirement deletes a tracked managed file and drops it from the
    # regenerated manifest, so the manifest alone cannot vouch for it — the
    # legitimate deletion would read as foreign content and refuse every
    # auto-merge (PR #787 review, round 3). Today's cortex-pr-merged-hook
    # and lib/review-comment.sh retirements hit this on real syncs.
    printf '%s\n' "${RETIRED_MANAGED_PATHS[@]:-}"
  } >"$scope_tmp"
  # --no-renames: rename detection folds "foreign.txt -> scripts/claim-issue.sh"
  # into the destination path alone, hiding the foreign source from the guard
  # (PR #787 review, round 3 — demonstrated with R100 in --name-status).
  git -C "$PROJECT_DIR" diff --no-renames --name-only "$ORIGINAL_HEAD" HEAD \
    | while IFS= read -r path; do
      [ -n "$path" ] || continue
      allowed=false
      while IFS= read -r planned; do
        [ -n "$planned" ] || continue
        case "$planned" in \#*) continue ;; esac
        if [ "$path" = "$planned" ]; then
          allowed=true
          break
        fi
      done <"$scope_tmp"
      [ "$allowed" = true ] || printf '%s\n' "$path"
    done
  rm -f "$scope_tmp"
}

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
      echo "    Ship after repair:  cd $PROJECT_DIR && $(manual_ship_command)" >&2
      exit 1
    fi
    if [ ! -x "$PROJECT_DIR/scripts/open-pr.sh" ]; then
      echo ""
      echo "==> --ship requested but scripts/open-pr.sh is missing or not executable."
      echo "    branch: $UPDATE_BRANCH (left for manual ship)"
      exit 1
    fi

    SCOPE_VIOLATIONS="$(update_commit_scope_violations)"
    if [ -n "$SCOPE_VIOLATIONS" ]; then
      echo ""
      echo "==> Refusing to AUTO-merge: the update commit touches paths outside the touchstone sync write set:" >&2
      printf '%s\n' "$SCOPE_VIOLATIONS" | sed 's/^/      - /' >&2
      echo "    A touchstone update PR may only touch managed paths; auto-merging anything else would land" >&2
      echo "    unreviewed changes under a chore title (#772, arpeggio#35)." >&2
      echo "==> Opening the update PR for human review WITHOUT auto-merge..."
      SCOPE_SHIP_RC=0
      (cd "$PROJECT_DIR" && bash scripts/open-pr.sh) || SCOPE_SHIP_RC=$?
      if [ "$SCOPE_SHIP_RC" -eq 0 ] || [ "$(current_update_pr_state)" = "OPEN" ]; then
        # A nonzero exit AFTER the PR was created (e.g. the review request
        # failed) is still an armed PR. Classifying by positive GitHub
        # evidence keeps the guard path and the normal path agreeing on the
        # same real state (PR #787 review).
        echo "==> Ship result: armed — the PR exists for human review and is NOT merged." >&2
        echo "    After reviewing the extra paths, merge with:" >&2
        echo "      cd $PROJECT_DIR && $(manual_ship_command)" >&2
        exit "$TOUCHSTONE_UPDATE_ARMED_EXIT"
      fi
      echo "==> Ship result: stuck — the PR could not be opened either (see errors above)." >&2
      echo "    branch: $UPDATE_BRANCH" >&2
      echo "    Review the extra paths, then ship manually:  cd $PROJECT_DIR && $(manual_ship_command)" >&2
      exit 1
    fi

    echo ""
    echo "==> Shipping update via scripts/open-pr.sh --auto-merge..."
    SHIP_RC=0
    (cd "$PROJECT_DIR" && bash scripts/open-pr.sh --auto-merge) || SHIP_RC=$?
    if [ "$SHIP_RC" -eq 0 ]; then
      # Positive merge evidence: open-pr.sh --auto-merge exits 0 iff GitHub
      # reports the PR MERGED (its header exit contract; regression-locked by
      # tests/test-open-pr-exit-contract.sh cases 1 and 3). Anything nonzero
      # is classified below instead of being lumped into one failure bucket.
      echo ""
      echo "==> Ship result: merged."
      exit 0
    fi

    # Tri-state classification of the nonzero exit (#731): the PR may exist
    # and simply not be merged yet (review pending, merge-gate refusal, a
    # post-creation error) — that is ARMED, not stuck, and conflating the
    # two made 'sync failed' reporting dishonest. Positive evidence only:
    # query GitHub for the update branch's PR state.
    # Same head-binding rule as the scope path: a deterministic branch name
    # can carry another clone's PR (PR #787 review, round 3).
    SHIP_PR_STATE="$(current_update_pr_state)"
    SHIP_PR_URL=""
    if [ -n "$SHIP_PR_STATE" ] && command -v gh >/dev/null 2>&1; then
      SHIP_PR_URL="$(cd "$PROJECT_DIR" && gh pr view "$UPDATE_BRANCH" --json url 2>/dev/null || true \
        | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
    fi
    if [ "$SHIP_PR_STATE" = "MERGED" ]; then
      # The merge itself landed; open-pr.sh failed on a follow-up step.
      echo ""
      echo "==> Ship result: merged (open-pr.sh exited $SHIP_RC on a post-merge step; see errors above)."
      [ -z "$SHIP_PR_URL" ] || echo "    PR: $SHIP_PR_URL"
      exit 0
    fi
    if [ "$SHIP_PR_STATE" = "OPEN" ]; then
      echo "" >&2
      echo "==> Ship result: armed — the update PR exists but is NOT merged (review pending," >&2
      echo "    merge-gate refusal, or an error after PR creation; see output above)." >&2
      [ -z "$SHIP_PR_URL" ] || echo "    PR: $SHIP_PR_URL" >&2
      echo "    Finish the merge:  cd $PROJECT_DIR && $(manual_ship_command)" >&2
      exit "$TOUCHSTONE_UPDATE_ARMED_EXIT"
    fi
    echo ""
    echo "==> Ship failed (see errors above). No open PR found for the update branch."
    echo "==> Ship result: stuck. The update commit is preserved on:"
    echo "    branch: $UPDATE_BRANCH"
    echo "    Re-ship when ready:  cd $PROJECT_DIR && $(manual_ship_command)"
    exit 1
  else
    echo ""
    if [ "$IN_PLACE" = true ]; then
      echo "==> Done. Review the update commit on the current branch:"
      echo "    branch: $UPDATE_BRANCH"
      echo "    git diff ${ORIGINAL_HEAD:-$ORIGINAL_BRANCH}...HEAD"
      echo "    bash scripts/open-pr.sh --auto-merge"
    else
      echo "==> Done. Review the update branch:"
      echo "    branch: $UPDATE_BRANCH"
      echo "    git diff ${ORIGINAL_HEAD:-$ORIGINAL_BRANCH}...$UPDATE_BRANCH"
      echo "    $(manual_ship_command)"
    fi
  fi
else
  echo ""
  echo "==> Dry run complete. Apply with: touchstone update"
fi
