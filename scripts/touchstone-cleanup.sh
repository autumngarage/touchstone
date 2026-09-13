#!/usr/bin/env bash
#
# scripts/touchstone-cleanup.sh — report repository cleanup residue.
#
# Usage:
#   bash scripts/touchstone-cleanup.sh check [--project DIR] [--json]
#
# Read-only. It never deletes anything: cleanup is the driver's step 9, and
# a tool that removed branches or worktrees on its own would be adjudicating
# what is finished. What it does is make repository residue legible without
# claiming which session owns it. Exit 0 with nothing to report,
# exit 1 with the list, exit 2 on invalid input; a failed GitHub read is
# reported as a finding of its own, never silently treated as clean.
#
# Findings, in the order the driver should resolve them:
#   checkout      the working tree is not on the default branch at origin's
#                 tip (detached HEAD, a feature branch, or behind/ahead)
#   worktree      a linked worktree other than the main checkout exists
#   local-branch  a local branch whose pull request (from this repository,
#                 at the branch's current SHA) is merged or closed
#   remote-branch the same for a branch on origin
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
      case "$2" in
        /*) PROJECT_DIR="$2" ;;
        *) PROJECT_DIR="$PWD/$2" ;; # absolute before cd: never resolved through CDPATH
      esac
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
  cd -- "$PROJECT_DIR" 2>/dev/null || {
    echo "ERROR: --project directory is not accessible: $PROJECT_DIR" >&2
    exit 2
  }
  unset GH_REPO GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ERROR: not inside a git working tree" >&2
  exit 2
}

# Names and paths that appear inside an executable remedy are shell-quoted:
# a branch Git accepts (`feat;rm -rf x`) must not become a command a driver
# pastes. printf %q is what bash itself uses to re-enter a word.
q() { printf '%q' "$1"; }

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
  finding "checkout" "detached HEAD at $(git rev-parse --short HEAD)" "git checkout $(q "$DEFAULT_BRANCH") && git pull --rebase"
elif [ "$CURRENT" != "$DEFAULT_BRANCH" ]; then
  finding "checkout" "on branch $CURRENT" "git checkout $(q "$DEFAULT_BRANCH") && git pull --rebase (after its PR is merged)"
else
  # Read origin's tip without fetching: a fetch writes FETCH_HEAD and may move
  # the remote-tracking ref, and a swallowed fetch failure would let a stale
  # cached ref claim "at origin". ls-remote reads and writes nothing.
  if REMOTE_HEAD="$(git ls-remote --quiet --heads origin "refs/heads/$DEFAULT_BRANCH" 2>/dev/null | awk '{ print $1; exit }')" \
    && [ -n "$REMOTE_HEAD" ]; then
    LOCAL_HEAD="$(git rev-parse HEAD)"
    if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
      finding "checkout" "$DEFAULT_BRANCH is at ${LOCAL_HEAD:0:8}, origin at ${REMOTE_HEAD:0:8}" "git pull --rebase"
    fi
  else
    finding "checkout" "could not read origin/$DEFAULT_BRANCH (origin unreachable?)" "retry with network access; the checkout's position against origin is unverified"
  fi
fi

# --- dirty and untracked -------------------------------------------------------
if STATUS_LINES="$(git status --porcelain --untracked-files=all 2>&1)"; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '?? '*) finding "untracked" "${line#?? }" "remove it, or add it to .gitignore if every checkout produces it" ;;
      *) finding "dirty" "${line:3}" "commit, stash, or discard it" ;;
    esac
  done <<<"$STATUS_LINES"
else
  finding "dirty" "git status failed: $(printf '%s' "$STATUS_LINES" | head -1)" "repair the working tree; dirty and untracked files are unverified"
fi

# --- worktrees -------------------------------------------------------------------
# Porcelain records are NUL-separated with -z, so a path with spaces stays
# one path; the first record is the main checkout.
# A worktree whose directory was removed by hand (porcelain marks it
# "prunable") still owns its branch; it is reported with the prune remedy
# instead of crashing on a path that is not there.
MAIN_WORKTREE=""
WT_PATH=""
WT_BRANCH=""
WT_PRUNABLE=false
WORKER_DONE="confirm the worker is terminal, then confirm its final report reached the parent or its cancellation was acknowledged"
PRUNABLE_DONE="confirm every prunable worker is terminal, then confirm each final report or cancellation was acknowledged"
emit_worktree() {
  [ -n "$WT_PATH" ] && [ "$WT_PATH" != "$MAIN_WORKTREE" ] || return 0
  if [ "$WT_PRUNABLE" = true ]; then
    finding "worktree" "$WT_PATH [${WT_BRANCH:-(detached)}] directory missing" "$PRUNABLE_DONE; then git worktree prune (the directory is gone; Git still records it)"
  else
    finding "worktree" "$WT_PATH [${WT_BRANCH:-(detached)}]" "$WORKER_DONE; then git worktree remove $(q "$WT_PATH")"
  fi
}
while IFS= read -r -d '' record; do
  case "$record" in
    "worktree "*)
      emit_worktree
      WT_PATH="${record#worktree }"
      WT_BRANCH=""
      WT_PRUNABLE=false
      [ -n "$MAIN_WORKTREE" ] || MAIN_WORKTREE="$WT_PATH"
      ;;
    "branch "*) WT_BRANCH="${record#branch refs/heads/}" ;;
    prunable*) WT_PRUNABLE=true ;;
  esac
done < <(git worktree list --porcelain -z)
emit_worktree

# --- branch inventory ---------------------------------------------------------
# One fully paginated GraphQL inventory, shared by both ref loops. A failed
# page invalidates the whole inventory; never classify from partial results.
if [ "$GH_OK" = true ]; then
  REPO_FULL="${REPO_ROW%%	*}"
  PR_ROWS=""
  if ! PR_ROWS="$(gh api graphql --paginate \
    -F owner="${REPO_FULL%%/*}" -F name="${REPO_FULL#*/}" \
    -f query='query($owner:String!,$name:String!,$endCursor:String) {
      repository(owner:$owner,name:$name) {
        pullRequests(first:100,after:$endCursor) {
          nodes { number state headRefName headRefOid baseRefName headRepository { nameWithOwner } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' --jq '.data.repository.pullRequests.nodes[] |
      [.headRefName, .number, .state, .headRefOid,
       (.headRepository.nameWithOwner // ""), .baseRefName] | @tsv' 2>&1)"; then
    finding github "pull-request read failed: $PR_ROWS" "branch findings are withheld; retry with gh authenticated"
    GH_OK=false
  fi
fi
if [ "$GH_OK" = true ]; then
  REMOTE_OK=true
  if ! REMOTE_HEADS="$(git ls-remote --quiet --heads origin 2>&1)"; then
    finding github "could not list origin's branches: $REMOTE_HEADS" "remote and local-only classifications are withheld; retry with network access"
    REMOTE_HEADS=""
    REMOTE_OK=false
  fi
  # The live default SHA, not a possibly stale local main, is the ancestry
  # boundary. Missing objects stay unverified: this read-only check never fetches.
  DEFAULT_SHA="$(awk -v ref="refs/heads/$DEFAULT_BRANCH" '$2 == ref { print $1 }' <<<"$REMOTE_HEADS")"
  finished_for() {
    awk -F'\t' -v b="$1" -v sha="$2" -v repo="$REPO_FULL" \
      '$1 == b && $5 == repo && ($3 == "MERGED" || $3 == "CLOSED") && $4 == sha {
        print "#" $2 " " tolower($3); exit
      }' <<<"$PR_ROWS"
  }
  open_head() {
    awk -F'\t' -v b="$1" -v repo="$REPO_FULL" \
      '$1 == b && $3 == "OPEN" && $5 == repo { found = 1 } END { exit !found }' <<<"$PR_ROWS"
  }
  bases_open_pr() {
    awk -F'\t' -v b="$1" '$3 == "OPEN" && $6 == b { print "#" $2; exit }' <<<"$PR_ROWS"
  }
  checked_out() {
    awk -v b="branch refs/heads/$1" '$0 == b { found = 1 } END { exit !found }' <<<"$WORKTREE_ROWS"
  }
  unknown_branch() {
    local location="$1" branch="$2" sha="$3" subject kind date remote_sha ahead
    subject="$branch"
    [ "$location" = local ] || subject="origin/$branch"
    if ! date="$(git show -s --format=%cI "$sha" -- 2>/dev/null)"; then
      finding unverified-branch "$subject ($sha; object unavailable)" "inspect this ref in its owning checkout; delivery and age are unverified"
      return
    fi
    subject="$subject (last commit $date)"
    # Zero unique commits is proof; matching filenames or even matching trees
    # cannot prove the branch's changes were delivered by another route.
    if [ -n "$DEFAULT_SHA" ] && ahead="$(git rev-list --count "$DEFAULT_SHA..$sha" -- 2>/dev/null)" && [ "$ahead" = 0 ]; then
      finding "$location-branch" "$subject (no unique commits against origin/$DEFAULT_BRANCH)" "confirm the owner has finished with this branch, then remove the ref at $sha"
      return
    fi
    kind=unshipped-branch
    remote_sha="$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }' <<<"$REMOTE_HEADS")"
    if [ "$location" = local ] && [ "$REMOTE_OK" = true ] && [ -z "$remote_sha" ]; then
      kind=local-only-work
      finding "$kind" "$subject" "coordinate with the owner: git push -u origin $(q "$branch"), open a PR, or record the decision to abandon this work"
    else
      finding "$kind" "$subject" "reconcile with the owner: open a PR or record the decision to abandon this work; no delivery proof exists for this head"
    fi
  }
  inspect_branch() {
    local location="$1" branch="$2" sha="$3" pr child
    [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ] || return 0
    open_head "$branch" && return 0
    child="$(bases_open_pr "$branch")"
    pr="$(finished_for "$branch" "$sha")"
    if [ -n "$child" ]; then
      finding "$location-branch" "$([ "$location" = local ] || printf 'origin/')$branch ($pr) still bases open PR $child" "do not delete: retarget $child to $(q "$DEFAULT_BRANCH") and rebase it first"
      return
    fi
    # A checked-out no-PR branch is observable active work, not abandonment.
    if checked_out "$branch"; then return; fi
    if [ -z "$pr" ]; then
      unknown_branch "$location" "$branch" "$sha"
      return
    fi
    if [ "$location" = local ]; then
      case "$pr" in
        *merged) finding local-branch "$branch ($pr)" "git branch -D $(q "$branch") after confirming the merged head (principles/git-workflow.md, 'Periodic branch hygiene')" ;;
        *) finding local-branch "$branch ($pr)" "its PR was closed without merging: delete the branch if the work is abandoned, or reopen a PR for it" ;;
      esac
    else
      case "$pr" in
        *merged) finding remote-branch "origin/$branch ($pr)" "git push origin --force-with-lease=$(q "$branch"):$sha :$(q "$branch") (deletes only while the branch is still at that SHA)" ;;
        *) finding remote-branch "origin/$branch ($pr)" "its PR was closed without merging: git push origin --force-with-lease=$(q "$branch"):$sha :$(q "$branch") if the work is abandoned" ;;
      esac
    fi
  }
  WORKTREE_ROWS="$(git worktree list --porcelain)"
  while IFS=$'\t' read -r branch sha; do
    inspect_branch local "$branch" "$sha"
  done < <(git for-each-ref --format='%(refname:short)	%(objectname)' refs/heads/)
  while IFS=$'\t' read -r sha ref; do
    [ -n "$ref" ] || continue
    inspect_branch remote "${ref#refs/heads/}" "$sha"
  done <<<"$REMOTE_HEADS"
fi

# --- report -----------------------------------------------------------------------
if [ "$JSON" = true ]; then
  printf '{"schema":"touchstone.cleanup/v1","defaultBranch":%s,"findings":[' "$(printf '%s' "$DEFAULT_BRANCH" | jq -Rs .)"
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
    echo "$FINDING_COUNT repository cleanup finding(s):"
    echo "Resolve only findings this session owns; leave active sibling work untouched and route stale residue."
    for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
      IFS=$'\t' read -r kind subject remedy <<<"$f"
      printf '  %-14s %s\n      -> %s\n' "$kind" "$subject" "$remedy"
    done
  fi
fi
[ "$FINDING_COUNT" -eq 0 ]
