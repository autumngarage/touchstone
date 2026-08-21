#!/usr/bin/env bash
#
# scripts/touchstone-cleanup.sh — report what a session left behind.
#
# Usage:
#   bash scripts/touchstone-cleanup.sh check [--project DIR] [--json]
#
# Read-only. It never deletes anything: cleanup is the driver's step 9, and
# a tool that removed branches or worktrees on its own would be adjudicating
# what is finished. What it does is make the mess legible, so "I cleaned up"
# is a verified state rather than a claim. Exit 0 with nothing to report,
# exit 1 with the list, exit 2 on invalid input; a failed GitHub read is
# reported as a finding of its own, never silently treated as clean.
#
# Findings, in the order the driver should resolve them:
#   checkout      the working tree is not on the default branch at origin's
#                 tip (detached HEAD, a feature branch, or behind/ahead)
#   worktree      a linked worktree other than the main checkout exists
#   local-branch  a local branch whose pull request is merged or closed
#   remote-branch a remote branch whose pull request is merged or closed
#   untracked     untracked files in the working tree (build and test
#                 residue such as __pycache__; a dirty tree also refuses the
#                 next ship)
#   dirty         tracked files with uncommitted changes
#
# Tracker items are not inspected here: the GitHub tracker closes them from
# the PR body's closing reference, and the Linear adapter has no transport
# (AUT-410). Step 9 still names them.
set -euo pipefail

ACTION="${1:-}"
shift || true
PROJECT_DIR=""
JSON=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --project requires a non-empty directory" >&2
        exit 2
      }
      PROJECT_DIR="$2"
      shift 2
      ;;
    --json)
      JSON=true
      shift
      ;;
    *)
      echo "usage: touchstone cleanup check [--project DIR] [--json]" >&2
      exit 2
      ;;
  esac
done
[ "$ACTION" = check ] || {
  echo "usage: touchstone cleanup check [--project DIR] [--json]" >&2
  exit 2
}

if [ -n "$PROJECT_DIR" ]; then
  cd "$PROJECT_DIR" 2>/dev/null || {
    echo "ERROR: --project directory is not accessible: $PROJECT_DIR" >&2
    exit 2
  }
  unset GH_REPO GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ERROR: not inside a git working tree" >&2
  exit 2
}

FINDINGS=()
FINDING_COUNT=0
finding() {
  # kind<TAB>subject<TAB>remedy
  FINDINGS+=("$1	$2	$3")
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# --- default branch and repository identity (one GitHub read) ---------------
REPO_ROW=""
DEFAULT_BRANCH=""
GH_OK=true
if REPO_ROW="$(gh repo view --json nameWithOwner,defaultBranchRef --jq '[.nameWithOwner,.defaultBranchRef.name] | @tsv' 2>/dev/null)"; then
  DEFAULT_BRANCH="${REPO_ROW#*	}"
fi
if [ -z "$DEFAULT_BRANCH" ]; then
  GH_OK=false
  # Fall back to the local notion so the checkout and worktree findings
  # still work offline; branch findings need GitHub and say so below.
  DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
  finding "github" "repository read failed" "branch findings below are incomplete; run with gh authenticated"
fi

# --- checkout ----------------------------------------------------------------
CURRENT="$(git branch --show-current 2>/dev/null || true)"
if [ -z "$CURRENT" ]; then
  finding "checkout" "detached HEAD at $(git rev-parse --short HEAD)" "git checkout $DEFAULT_BRANCH && git pull --rebase"
elif [ "$CURRENT" != "$DEFAULT_BRANCH" ]; then
  finding "checkout" "on branch $CURRENT" "git checkout $DEFAULT_BRANCH && git pull --rebase (after its PR is merged)"
else
  git fetch --quiet origin "$DEFAULT_BRANCH" 2>/dev/null || true
  if git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null; then
    LOCAL_HEAD="$(git rev-parse HEAD)"
    REMOTE_HEAD="$(git rev-parse "origin/$DEFAULT_BRANCH")"
    if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
      finding "checkout" "$DEFAULT_BRANCH is at ${LOCAL_HEAD:0:8}, origin at ${REMOTE_HEAD:0:8}" "git pull --rebase"
    fi
  fi
fi

# --- dirty and untracked -------------------------------------------------------
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    '?? '*) finding "untracked" "${line#?? }" "remove it, or add it to .gitignore if every checkout produces it" ;;
    *) finding "dirty" "${line:3}" "commit, stash, or discard it" ;;
  esac
done < <(git status --porcelain --untracked-files=all 2>/dev/null)

# --- worktrees -------------------------------------------------------------------
MAIN_WORKTREE="$(git worktree list --porcelain | awk 'NR == 1 && $1 == "worktree" { print $2 }')"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ "$path" != "$MAIN_WORKTREE" ] || continue
  branch="$(git -C "$path" branch --show-current 2>/dev/null || echo '(detached)')"
  finding "worktree" "$path [$branch]" "git worktree remove '$path' once its PR is merged, then git worktree prune"
done < <(git worktree list --porcelain | awk '$1 == "worktree" { print $2 }')

# --- branches whose pull request is finished ------------------------------------
if [ "$GH_OK" = true ]; then
  # One read for every non-open PR head, instead of one read per branch.
  FINISHED_HEADS="$(gh pr list --state merged --limit 200 --json headRefName,number,state --jq '.[] | [.headRefName, .number, .state] | @tsv' 2>/dev/null || true)
$(gh pr list --state closed --limit 200 --json headRefName,number,state --jq '.[] | [.headRefName, .number, .state] | @tsv' 2>/dev/null || true)"
  OPEN_HEADS="$(gh pr list --state open --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null || true)"
  finished_for() {
    # A branch with an open PR is not finished even if an older PR on the
    # same name was closed.
    printf '%s\n' "$OPEN_HEADS" | grep -qxF -- "$1" && return 1
    printf '%s\n' "$FINISHED_HEADS" | awk -F'\t' -v b="$1" '$1 == b { print "#" $2 " " tolower($3); exit }'
  }
  while IFS= read -r branch; do
    [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ] || continue
    pr="$(finished_for "$branch" || true)"
    [ -n "$pr" ] || continue
    case "$pr" in
      *merged) finding "local-branch" "$branch ($pr)" "git branch -D $branch after confirming the merged head (principles/git-workflow.md, 'Periodic branch hygiene')" ;;
      *) finding "local-branch" "$branch ($pr)" "its PR was closed without merging: delete the branch if the work is abandoned, or reopen a PR for it" ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
  while IFS= read -r branch; do
    [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ] || continue
    pr="$(finished_for "$branch" || true)"
    [ -n "$pr" ] || continue
    case "$pr" in
      *merged) finding "remote-branch" "origin/$branch ($pr)" "git push origin --delete $branch" ;;
      *) finding "remote-branch" "origin/$branch ($pr)" "its PR was closed without merging: git push origin --delete $branch if the work is abandoned" ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | sed 's|^origin/||' | grep -vx HEAD)
fi

# --- report -----------------------------------------------------------------------
if [ "$JSON" = true ]; then
  printf '{"schema":"touchstone.cleanup/v1","defaultBranch":"%s","findings":[' "$DEFAULT_BRANCH"
  first=true
  for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
    IFS=$'\t' read -r kind subject remedy <<<"$f"
    [ "$first" = true ] || printf ','
    first=false
    printf '{"kind":%s,"subject":%s,"remedy":%s}' \
      "$(printf '%s' "$kind" | jq -Rs .)" "$(printf '%s' "$subject" | jq -Rs .)" "$(printf '%s' "$remedy" | jq -Rs .)"
  done
  printf '],"clean":%s}\n' "$([ "$FINDING_COUNT" -eq 0 ] && echo true || echo false)"
else
  if [ "$FINDING_COUNT" -eq 0 ]; then
    echo "clean: on $DEFAULT_BRANCH at origin, no worktrees, no finished branches, nothing untracked"
  else
    echo "$FINDING_COUNT thing(s) left behind:"
    for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
      IFS=$'\t' read -r kind subject remedy <<<"$f"
      printf '  %-14s %s\n      -> %s\n' "$kind" "$subject" "$remedy"
    done
  fi
fi
[ "$FINDING_COUNT" -eq 0 ]
