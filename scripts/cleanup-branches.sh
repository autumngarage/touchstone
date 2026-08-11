#!/usr/bin/env bash
#
# scripts/cleanup-branches.sh — safe branch hygiene tool.
#
# Usage:
#   bash scripts/cleanup-branches.sh                        # dry-run (default)
#   bash scripts/cleanup-branches.sh --execute              # actually delete
#   bash scripts/cleanup-branches.sh --remote-too --execute  # also delete remote branches
#
# Safety guarantees:
#   - Default mode is DRY RUN.
#   - The current branch is never deleted.
#   - The default branch (main/master) is never deleted.
#   - Ancestor-merged local branches use `git branch -d` (refuses unmerged work).
#   - Squash-merged local branches use `git branch -D` — only after tree
#     equivalence confirms the current default-branch tree has the branch's
#     content for every file it touched (handles `gh pr merge --squash`,
#     rebase-merges, and cherry-picks; rejects add-then-revert).
#   - Remote branches only deleted in --remote-too mode, only if no open PR and
#     fully merged or squash-merged.
#   - Worktree-checked-out branches are skipped.
#
set -euo pipefail

DRY_RUN=1
REMOTE_TOO=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute | -x)
      DRY_RUN=0
      shift
      ;;
    --remote-too)
      REMOTE_TOO=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      # Print the header comment block (skip shebang + leading `#`), stopping
      # at the first non-comment line. Derived instead of hardcoded so future
      # header edits don't silently truncate the help output.
      awk 'NR>2 && !/^#/ { exit } NR>2 { sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: 'gh' is not installed." >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Resolve default branch dynamically.
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo "==> Fetching from origin and pruning stale tracking refs ..."
git fetch --prune origin

PROTECTED_BRANCHES=("$DEFAULT_BRANCH" main master HEAD)

is_protected() {
  local b="$1"
  for p in "${PROTECTED_BRANCHES[@]}"; do
    [ "$b" = "$p" ] && return 0
  done
  return 1
}

# Branches checked out by worktrees — skip these.
WORKTREE_BRANCHES="$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/", "", $2); print $2}')"

is_worktree_branch() {
  local b="$1"
  [ -z "$WORKTREE_BRANCHES" ] && return 1
  while IFS= read -r wb; do
    [ -z "$wb" ] && continue
    [ "$b" = "$wb" ] && return 0
  done <<<"$WORKTREE_BRANCHES"
  return 1
}

# Locate scripts/merge-pr.sh's squash-map. The map records each squash-merge
# at the moment it happens, capturing branch tip + squash commit. Reading is
# best-effort and offline: any I/O error or unparseable line is treated as
# "no record" so a corrupt map never causes a false-positive deletion. The
# tree-equivalence path (is_fully_applied) is the safety net beneath this.
SQUASH_MAP_PATH="$(git rev-parse --git-path touchstone/squash-map.jsonl 2>/dev/null || echo "")"

# Returns 0 if a record in the squash-map names $branch AND its recorded
# branch_oid matches the branch's current tip. The OID equality is the
# load-bearing invariant: it ensures we only treat a branch as "the same
# code that merged" — if commits landed on the local branch after the
# squash, the OIDs differ and we fall through to is_fully_applied (which
# will correctly tell us those new commits are not yet on $upstream).
#
# Any failure to read the map returns 1 (no record); errors are surfaced
# to stderr but never fatal — same fail-soft contract as the rest of the
# cleanup classifier.
is_recorded_squash() {
  local branch="$1"
  local branch_oid="$2"

  [ -n "$SQUASH_MAP_PATH" ] || return 1
  [ -f "$SQUASH_MAP_PATH" ] || return 1
  [ -r "$SQUASH_MAP_PATH" ] || {
    echo "WARNING: squash-map exists but is not readable: $SQUASH_MAP_PATH" >&2
    return 1
  }

  # Grep for "branch":"<exact name>" — the JSONL writer in merge-pr.sh
  # refuses to write fields containing quote/backslash, so a literal-string
  # match is sufficient and avoids pulling in a JSON parser. Filter to
  # records that also carry the matching branch_oid; if any match, classify
  # as recorded squash.
  local line
  while IFS= read -r line; do
    case "$line" in
      *"\"branch\":\"$branch\""*"\"branch_oid\":\"$branch_oid\""*)
        return 0
        ;;
      *"\"branch_oid\":\"$branch_oid\""*"\"branch\":\"$branch\""*)
        return 0
        ;;
    esac
  done <"$SQUASH_MAP_PATH" 2>/dev/null
  return 1
}

# Returns 0 if every file the branch changed relative to the merge-base has
# the branch's content on $upstream right now. This uniformly detects
# squash-merges, rebase-merges, and cherry-picks (without caring how the
# change got there) and correctly rejects the add-then-revert case — where
# a patch-id lookup in upstream's history would false-positive on the add
# commit even though the current upstream tree no longer has the change.
is_fully_applied() {
  local upstream="$1"
  local branch="$2"
  local base
  base="$(git merge-base "$upstream" "$branch" 2>/dev/null)" || return 1
  [ -z "$base" ] && return 1

  # --no-renames disables git's rename heuristic, which would otherwise
  # collapse "delete old, add new" into a single destination-path entry and
  # hide the deletion from the tree check. -z makes the list NUL-delimited,
  # safe for paths containing spaces, quotes, or newlines.
  local file
  while IFS= read -r -d '' file; do
    [ -z "$file" ] && continue
    git diff --quiet "$upstream" "$branch" -- "$file" 2>/dev/null || return 1
  done < <(git diff --name-only --no-renames -z "$base" "$branch" 2>/dev/null)

  return 0
}

DEFAULT_REF="origin/$DEFAULT_BRANCH"

echo ""
echo "==> LOCAL branches"

LOCAL_BRANCHES="$(git for-each-ref --format='%(refname:short)' refs/heads/)"
MERGED_LOCAL=()
SQUASH_MERGED_LOCAL=()
UNMERGED_LOCAL=()

while IFS= read -r branch; do
  [ -z "$branch" ] && continue
  is_protected "$branch" || [ "$branch" = "$CURRENT_BRANCH" ] || is_worktree_branch "$branch" && continue
  branch_oid="$(git rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null || echo "")"
  if git merge-base --is-ancestor "$branch" "$DEFAULT_REF" 2>/dev/null; then
    MERGED_LOCAL+=("$branch")
  elif [ -n "$branch_oid" ] && is_recorded_squash "$branch" "$branch_oid"; then
    SQUASH_MERGED_LOCAL+=("$branch")
  elif is_fully_applied "$DEFAULT_REF" "$branch"; then
    SQUASH_MERGED_LOCAL+=("$branch")
  else
    UNMERGED_LOCAL+=("$branch")
  fi
done <<<"$LOCAL_BRANCHES"

if [ "${#MERGED_LOCAL[@]}" -gt 0 ]; then
  echo ""
  echo "  Fully merged into $DEFAULT_BRANCH (safe to delete locally):"
  for b in "${MERGED_LOCAL[@]}"; do
    echo "    - $b"
  done
fi

if [ "${#SQUASH_MERGED_LOCAL[@]}" -gt 0 ]; then
  echo ""
  echo "  Squash-merged into $DEFAULT_BRANCH (patches applied; safe to force-delete):"
  for b in "${SQUASH_MERGED_LOCAL[@]}"; do
    echo "    - $b"
  done
fi

if [ "${#UNMERGED_LOCAL[@]}" -gt 0 ]; then
  echo ""
  echo "  Has unique commits not on $DEFAULT_BRANCH (will NOT auto-delete):"
  for b in "${UNMERGED_LOCAL[@]}"; do
    AHEAD="$(git rev-list --count "$DEFAULT_REF..$b" 2>/dev/null || echo "?")"
    echo "    - $b ($AHEAD commits ahead)"
  done
  echo ""
  echo "  These need a human decision. Either:"
  echo "    (a) merge the work via PR and rerun cleanup, or"
  echo "    (b) git branch -D <name> manually if the work is abandoned"
fi

if [ "${#MERGED_LOCAL[@]}" -eq 0 ] && [ "${#SQUASH_MERGED_LOCAL[@]}" -eq 0 ] && [ "${#UNMERGED_LOCAL[@]}" -eq 0 ]; then
  echo "  (nothing to clean up)"
fi

# REMOTE branches.
# Enumeration cap for the open-PR scan. Deliberately a cap we can DETECT hitting
# rather than a page size we silently truncate at.
OPEN_PR_SCAN_LIMIT="${TOUCHSTONE_OPEN_PR_SCAN_LIMIT:-200}"
REMOTE_DELETABLE=()
# The OID each deletable branch was CLASSIFIED at, index-aligned with
# REMOTE_DELETABLE. Deletion is leased on this, not on whatever the branch
# points at later — only this commit was proven merged (PR #715 review).
REMOTE_DELETABLE_OIDS=()
REMOTE_HAS_PR=()
REMOTE_UNIQUE_NO_PR=()

REMOTE_SKIPPED=0

if [ "$REMOTE_TOO" -eq 1 ]; then
  echo ""
  echo "==> REMOTE branches (--remote-too)"

  REMOTE_BRANCHES="$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | sed 's@^origin/@@' | grep -v '^HEAD$' || true)"

  # Fail closed: an errored `gh pr list` is indistinguishable from "no open
  # PRs" if we swallow the error, and would mark every remote branch as
  # deletable. Without a confirmed open-PR set we cannot safely classify.
  GH_PR_ERR=""
  # Collect BOTH the head and the base of every open PR. A merged parent branch
  # that is still serving as another PR's base has no open PR of its own, so a
  # head-only scan classified it as deletable and deleting it closed the
  # dependents -- the exact loss merge-pr.sh now avoids by never deleting
  # (issue #713, PR #715 review).
  # --limit is a hard cap, not a page size: at exactly the cap we cannot know
  # whether more open PRs exist, and a branch that is the base of an omitted PR
  # would look unreferenced and be deleted, closing that PR (PR #715 review).
  # Count PRs, not ref lines, because each PR contributes two lines.
  OPEN_PR_COUNT="$(gh pr list --state open --limit "$OPEN_PR_SCAN_LIMIT" --json number --jq 'length' 2>/dev/null || echo "")"
  if [ -n "$OPEN_PR_COUNT" ] && [ "$OPEN_PR_COUNT" -ge "$OPEN_PR_SCAN_LIMIT" ]; then
    REMOTE_SKIPPED=1
    echo ""
    echo "  ERROR: $OPEN_PR_COUNT open PRs reached the $OPEN_PR_SCAN_LIMIT scan cap — skipping remote cleanup." >&2
    echo "    Cannot prove a branch is unreferenced from a truncated list, and deleting" >&2
    echo "    the base of an omitted PR would close it. Raise TOUCHSTONE_OPEN_PR_SCAN_LIMIT" >&2
    echo "    above the open-PR count and rerun." >&2
  elif ! OPEN_PR_BRANCHES="$(gh pr list --state open --limit "$OPEN_PR_SCAN_LIMIT" --json headRefName,baseRefName --jq '.[] | .headRefName, .baseRefName' 2>&1)"; then
    GH_PR_ERR="$OPEN_PR_BRANCHES"
    REMOTE_SKIPPED=1
    echo ""
    echo "  ERROR: 'gh pr list' failed — skipping remote cleanup to avoid unsafe deletion." >&2
    echo "    $GH_PR_ERR" >&2
  fi
fi

if [ "$REMOTE_TOO" -eq 1 ] && [ "$REMOTE_SKIPPED" -eq 0 ]; then

  # True when the branch is either the head OR the base of an open PR.
  has_open_pr() {
    local b="$1"
    [ -z "$OPEN_PR_BRANCHES" ] && return 1
    while IFS= read -r pr_branch; do
      [ -z "$pr_branch" ] && continue
      [ "$b" = "$pr_branch" ] && return 0
    done <<<"$OPEN_PR_BRANCHES"
    return 1
  }

  while IFS= read -r remote_branch; do
    [ -z "$remote_branch" ] && continue
    is_protected "$remote_branch" && continue
    if has_open_pr "$remote_branch"; then
      REMOTE_HAS_PR+=("$remote_branch")
      continue
    fi
    remote_oid="$(git rev-parse --verify --quiet "refs/remotes/origin/$remote_branch" 2>/dev/null || echo "")"
    if git merge-base --is-ancestor "origin/$remote_branch" "$DEFAULT_REF" 2>/dev/null; then
      REMOTE_DELETABLE+=("$remote_branch")
      REMOTE_DELETABLE_OIDS+=("$remote_oid")
    elif [ -n "$remote_oid" ] && is_recorded_squash "$remote_branch" "$remote_oid"; then
      REMOTE_DELETABLE+=("$remote_branch")
      REMOTE_DELETABLE_OIDS+=("$remote_oid")
    elif is_fully_applied "$DEFAULT_REF" "origin/$remote_branch"; then
      REMOTE_DELETABLE+=("$remote_branch")
      REMOTE_DELETABLE_OIDS+=("$remote_oid")
    else
      REMOTE_UNIQUE_NO_PR+=("$remote_branch")
    fi
  done <<<"$REMOTE_BRANCHES"

  if [ "${#REMOTE_DELETABLE[@]}" -gt 0 ]; then
    echo ""
    echo "  Fully merged or squash-merged + no open PR (safe to delete remotely):"
    for b in "${REMOTE_DELETABLE[@]}"; do
      echo "    - origin/$b"
    done
  fi

  if [ "${#REMOTE_HAS_PR[@]}" -gt 0 ]; then
    echo ""
    echo "  Has an open PR (will NOT delete):"
    for b in "${REMOTE_HAS_PR[@]}"; do
      echo "    - origin/$b"
    done
  fi

  if [ "${#REMOTE_UNIQUE_NO_PR[@]}" -gt 0 ]; then
    echo ""
    echo "  Unique commits but no open PR (will NOT auto-delete):"
    for b in "${REMOTE_UNIQUE_NO_PR[@]}"; do
      AHEAD="$(git rev-list --count "$DEFAULT_REF..origin/$b" 2>/dev/null || echo "?")"
      echo "    - origin/$b ($AHEAD commits ahead)"
    done
    echo ""
    echo "  These need a human decision: open a PR, or git push origin --delete <name>"
  fi

  if [ "${#REMOTE_DELETABLE[@]}" -eq 0 ] && [ "${#REMOTE_UNIQUE_NO_PR[@]}" -eq 0 ]; then
    echo "  (no remote-only cleanup candidates)"
  fi
fi

# DRY-RUN guard.
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "==> Dry run. Pass --execute to actually delete the branches listed above."
  exit 0
fi

# EXECUTE.
echo ""
echo "==> Executing deletions ..."

if [ "${#MERGED_LOCAL[@]}" -gt 0 ]; then
  for b in "${MERGED_LOCAL[@]}"; do
    if git branch -d "$b" 2>&1; then
      echo "    deleted local: $b"
    else
      echo "    SKIPPED local (git refused — likely has unmerged commits): $b" >&2
    fi
  done
fi

if [ "${#SQUASH_MERGED_LOCAL[@]}" -gt 0 ]; then
  # -d refuses these because squash-merge commits aren't ancestors; is_fully_applied
  # already confirmed tree equivalence against the current default branch, so -D
  # here won't lose work that isn't reachable another way.
  for b in "${SQUASH_MERGED_LOCAL[@]}"; do
    if git branch -D "$b" 2>&1; then
      echo "    force-deleted local (squash-merged): $b"
    else
      echo "    SKIPPED local (force-delete failed): $b" >&2
    fi
  done
fi

if [ "$REMOTE_TOO" -eq 1 ] && [ "${#REMOTE_DELETABLE[@]}" -gt 0 ]; then
  # No repository slug is needed any more. Deletion goes through
  # `git push --force-with-lease`, which is the only spelling that carries an
  # expected-OID precondition; the REST endpoint it replaced had none, which is
  # why it is gone rather than kept as a fallback.
  for _rd_i in "${!REMOTE_DELETABLE[@]}"; do
    b="${REMOTE_DELETABLE[$_rd_i]}"
    classified_oid="${REMOTE_DELETABLE_OIDS[$_rd_i]}"
    # Classification happened from one snapshot taken earlier; a stacked PR
    # opened since would still be in REMOTE_DELETABLE and deleting its base
    # closes it (PR #715 review). Re-ask immediately before the destructive
    # call. GitHub offers no compare-and-delete for refs, so this narrows the
    # window rather than eliminating it — which is why it fails closed on any
    # inspection error instead of assuming "probably none".
    if ! dependents="$(gh pr list --state open --base "$b" --limit "$OPEN_PR_SCAN_LIMIT" --json number --jq '[.[].number] | join(", ")' 2>&1)"; then
      echo "    SKIPPED remote (could not re-check dependents): origin/$b — $dependents" >&2
      continue
    fi
    # A branch is referenced by an open PR in two ways, and only one of them is
    # a --base match. If a PR was opened WITH $b as its head since the snapshot,
    # a --base query reports nothing and we would delete the source branch of an
    # active PR, closing it. `gh pr list` documents --head separately for exactly
    # this reason, so both references have to be re-checked (PR #715 review).
    if ! own_pr="$(gh pr list --state open --head "$b" --limit "$OPEN_PR_SCAN_LIMIT" --json number --jq '[.[].number] | join(", ")' 2>&1)"; then
      echo "    SKIPPED remote (could not re-check its own open PRs): origin/$b — $own_pr" >&2
      continue
    fi
    if [ -n "$dependents" ]; then
      echo "    SKIPPED remote (PR(s) $dependents opened against it since the scan): origin/$b"
      continue
    fi
    if [ -n "$own_pr" ]; then
      echo "    SKIPPED remote (PR(s) $own_pr opened FROM it since the scan): origin/$b"
      continue
    fi
    # Lease on the OID this branch was CLASSIFIED at, not on whatever it points
    # at now. Only that commit was proven merged, squash-merged, or fully
    # applied; commits pushed since have been proven nothing. Capturing the
    # current tip and leasing on THAT would delete unreviewed work by design,
    # and would print a restore command naming an object this checkout does not
    # even have. Leasing on the classified OID makes an advance abort instead
    # (PR #715 review).
    if [ -z "$classified_oid" ]; then
      echo "    SKIPPED remote (no classified OID, so deletion could not be leased): origin/$b" >&2
      continue
    fi

    # Recovery is printed BEFORE the destructive request. If the server
    # processes the delete but the response is lost, an after-the-fact print
    # never runs and the record dies with the connection.
    echo "    deleting remote: origin/$b (classified at ${classified_oid:0:12})"
    printf '      restore with: git push origin %s:refs/heads/%s\n' \
      "$classified_oid" "$(printf '%q' "$b")"

    push_err=""
    if push_err="$(git push --force-with-lease="refs/heads/$b:$classified_oid" \
      origin ":refs/heads/$b" 2>&1)"; then
      echo "    deleted remote: origin/$b"
    else
      # The lease failed. Distinguish "the branch moved" from "we could not
      # look". `git ls-remote --exit-code` returns 2 specifically for no
      # matching ref; any other nonzero is an inspection failure, and calling
      # that "absent" would report a live branch as deleted.
      #
      # ONE request answers both "does the ref exist?" and "where does it
      # point?". An earlier shape asked twice — existence first, OID second —
      # and a transient failure on the second lookup produced an empty OID
      # that the comparison below misread as "still at its classified OID": a
      # definite answer manufactured from an inspection failure (PR #715
      # review). Stderr stays attached so a failed lookup shows git's own
      # diagnostic instead of discarding it.
      ls_rc=0
      ls_out="$(git ls-remote --exit-code origin "refs/heads/$b")" || ls_rc=$?
      case "$ls_rc" in
        0)
          # The ref exists, but existence alone says nothing about WHICH
          # commit it points at — a permission failure, ruleset, or pre-push
          # hook rejects the push while the branch sits exactly where it was.
          # Compare the OIDs rather than inferring an advance, and keep the
          # push's own message, which is the only thing that explains a
          # rejection (PR #715 review).
          current_oid="$(printf '%s\n' "$ls_out" | awk 'NR==1{print $1}')"
          if [ -z "$current_oid" ]; then
            # Exit 0 with output we cannot parse is still an inspection
            # failure. Never collapse "could not tell" into a definite answer.
            echo "    UNKNOWN remote result (ref reported present but its OID could not be read): origin/$b" >&2
            echo "      re-run to re-resolve; the restore command above still applies if it was removed" >&2
          elif [ "$current_oid" != "$classified_oid" ]; then
            echo "    SKIPPED remote (advanced to ${current_oid:0:12}, past its classified OID, so it is no longer proven merged): origin/$b" >&2
          else
            echo "    SKIPPED remote (delete rejected while still at its classified OID): origin/$b" >&2
            if [ -n "$push_err" ]; then
              printf '%s\n' "$push_err" | sed 's/^/      /' >&2
            fi
          fi
          ;;
        2)
          echo "    deleted remote: origin/$b (confirmed absent; the delete landed despite an unclear response)"
          ;;
        *)
          echo "    UNKNOWN remote result (delete rejected and the ref could not be inspected, rc=$ls_rc): origin/$b" >&2
          echo "      re-run to re-resolve; the restore command above still applies if it was removed" >&2
          ;;
      esac
    fi
  done
fi

echo ""
echo "==> Done. Run without --execute next time to dry-run."
