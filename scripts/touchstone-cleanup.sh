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
#   local-publication a local tip not established in its same-name origin branch
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

# --- branches whose pull request is finished ------------------------------------
# A ref is "finished" only when a pull request from THIS repository with
# that head name is merged or closed AND its head SHA is the ref's current
# SHA. Name alone is not enough: a reused branch name, or a fork's PR with
# the same name, would otherwise recommend deleting live work. The query is
# one complete repository inventory, reused for local/remote refs and stack
# bases. GitHub's native pagination costs one read per history page, not per
# ref; there is no "recent N pull requests" window or persistent cache.
if [ "$GH_OK" = true ]; then
  REPO_FULL="${REPO_ROW%%	*}"
  # shellcheck disable=SC2016 # GraphQL variables are interpreted by GitHub.
  if ! PR_PAGES="$(gh api graphql --paginate --slurp \
    -f owner="${REPO_FULL%%/*}" -f name="${REPO_FULL#*/}" -f query='
      query($owner: String!, $name: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          nameWithOwner
          pullRequests(first: 100, after: $endCursor, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) {
            nodes { headRefName number state headRefOid headRepository { nameWithOwner } baseRefName }
            pageInfo { hasNextPage endCursor }
          }
        }
      }' 2>/dev/null)" \
    || ! PR_ROWS="$(printf '%s' "$PR_PAGES" | jq -r --arg repo "$REPO_FULL" '
      def valid_pr:
        has("headRepository")
        and (.headRefName | type == "string")
        and (.number | type == "number" and . > 0 and floor == .)
        and (.state == "OPEN" or .state == "CLOSED" or .state == "MERGED")
        and (.headRefOid | type == "string" and test("^[0-9a-f]{40}\\z"))
        and (.baseRefName | type == "string")
        and (.headRepository == null or (.headRepository.nameWithOwner | type == "string"));
      if type == "array" and length > 0
        and all(.[];
          (.errors == null or .errors == [])
          and .data.repository.nameWithOwner == $repo
          and (.data.repository.pullRequests.nodes | type == "array" and all(.[]; valid_pr))
          and (.data.repository.pullRequests.pageInfo.hasNextPage | type == "boolean")
          and (.data.repository.pullRequests.pageInfo.endCursor | . == null or type == "string"))
        and all(.[0:-1][];
          .data.repository.pullRequests.pageInfo.hasNextPage == true
          and (.data.repository.pullRequests.pageInfo.endCursor | type == "string" and length > 0))
        and .[-1].data.repository.pullRequests.pageInfo.hasNextPage == false
      then .[].data.repository.pullRequests.nodes[]
        | [.headRefName, .number, .state, .headRefOid, (.headRepository.nameWithOwner // ""), .baseRefName] | @tsv
      else error("incomplete pull-request inventory") end
    ' 2>/dev/null)"; then
    GH_OK=false
    finding "github" "pull-request inventory incomplete for $REPO_FULL" "branch findings are withheld; retry after GitHub access or quota recovers and every history page can be read"
  fi
fi
if [ "$GH_OK" = true ]; then
  finished_for() {
    # $1 branch name, $2 current sha -> prints "#N merged|closed" or nothing
    # Any OPEN pull request from THIS repository on this head means the
    # branch is in flight; a fork's open PR with the same name is not ours.
    # Consume the rows before deciding: an early-exit pipeline can SIGPIPE
    # its producer once the shared history exceeds the pipe buffer.
    awk -F'\t' -v branch="$1" -v sha="$2" -v repo="$REPO_FULL" '
      $1 == branch && $5 == repo {
        if ($3 == "OPEN") open = 1
        else if (!finished && ($3 == "MERGED" || $3 == "CLOSED") && $4 == sha)
          finished = "#" $2 " " tolower($3)
      }
      END { if (open) exit 1; if (finished) print finished }
    ' <<<"$PR_ROWS"
  }
  # A branch that is still the BASE of an open pull request is a stack's
  # parent: deleting it closes the child PR, which cannot be reopened
  # (principles/git-workflow.md, stacked PRs). Read once.
  # The complete inventory includes fork/null-head PRs: their bases protect
  # parents even though they cannot establish same-repository head evidence.
  bases_open_pr() {
    awk -F'\t' -v b="$1" '
      $3 == "OPEN" && $6 == b && !child { child = "#" $2 }
      END { if (child) print child }
    ' <<<"$PR_ROWS"
  }
  # Share one live origin inventory; stale tracking refs cannot establish
  # publication or justify a remote deletion recommendation.
  REMOTE_OK=true
  if ! REMOTE_HEADS="$(git ls-remote --quiet --heads origin 2>/dev/null)"; then
    finding "github" "could not list origin's branches (origin unreachable?)" "local-publication and remote-branch findings are withheld; retry with network access"
    REMOTE_OK=false
    REMOTE_HEADS=""
  fi
  SHALLOW="$(git rev-parse --is-shallow-repository 2>/dev/null)" || SHALLOW=unknown
  publication_gap() {
    local branch="$1" tip="$2" remote relation
    remote="$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }' <<<"$REMOTE_HEADS")"
    if [ -z "$remote" ]; then
      printf '%s' "origin has no branch named $branch"
    elif [ "$tip" != "$remote" ]; then
      # Probe raw commit ancestry without graph overlays or promisor fetches.
      if ! GIT_GRAFT_FILE=/dev/null git --no-lazy-fetch --no-replace-objects cat-file -e "$remote^{commit}" >/dev/null 2>&1; then
        printf '%s' "publication to live origin/$branch at ${remote:0:8} is unverified (read-only commit probe unavailable)"
      elif GIT_GRAFT_FILE=/dev/null git --no-lazy-fetch --no-replace-objects merge-base --is-ancestor "$tip" "$remote" >/dev/null 2>&1; then
        return 0
      else
        relation=$?
        if [ "$relation" -eq 1 ] && [ "$SHALLOW" = false ]; then
          printf '%s' "not contained in live origin/$branch at ${remote:0:8}"
        else
          printf '%s' "publication to live origin/$branch at ${remote:0:8} is unverified (incomplete history or ancestry probe failed)"
        fi
      fi
    fi
  }
  while IFS=$'\t' read -r branch sha; do
    [ -n "$branch" ] || continue
    pr="$(finished_for "$branch" "$sha")" || pr=""
    # Exact merged-head evidence survives squash merges and remote deletion.
    # All other publication observations precede lifecycle/default exclusions.
    if [ "$REMOTE_OK" = true ] && [[ "$pr" != *merged ]]; then
      gap="$(publication_gap "$branch" "$sha")"
      if [ -n "$gap" ]; then
        finding "local-publication" "$branch at ${sha:0:8}: $gap" "preserve this branch; reconcile its intended publication destination with its owner before publishing or explicitly recording abandonment"
      fi
    fi
    [ "$branch" != "$DEFAULT_BRANCH" ] && [ -n "$pr" ] || continue
    case "$pr" in
      *merged) finding "local-branch" "$branch ($pr)" "git branch -D $(q "$branch") after confirming the merged head (principles/git-workflow.md, 'Periodic branch hygiene')" ;;
      *) finding "local-branch" "$branch ($pr)" "its PR was closed without merging: delete the branch if the work is abandoned, or reopen a PR for it" ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)	%(objectname)' refs/heads/)
  while IFS=$'\t' read -r sha ref; do
    branch="${ref#refs/heads/}"
    [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ] || continue
    pr="$(finished_for "$branch" "$sha")" || continue
    [ -n "$pr" ] || continue
    child="$(bases_open_pr "$branch")"
    if [ -n "$child" ]; then
      finding "remote-branch" "origin/$branch ($pr) still bases open PR $child" "do not delete: retarget $child to $(q "$DEFAULT_BRANCH") (gh pr edit ${child#\#} --base $(q "$DEFAULT_BRANCH")) and rebase it first"
      continue
    fi
    case "$pr" in
      *merged) finding "remote-branch" "origin/$branch ($pr)" "git push origin --force-with-lease=$(q "$branch"):$sha :$(q "$branch") (deletes only while the branch is still at that SHA)" ;;
      *) finding "remote-branch" "origin/$branch ($pr)" "its PR was closed without merging: git push origin --force-with-lease=$(q "$branch"):$sha :$(q "$branch") if the work is abandoned" ;;
    esac
  done < <(printf '%s\n' "$REMOTE_HEADS" | awk 'NF == 2 { print $1 "\t" $2 }')
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
    echo "clean: on $DEFAULT_BRANCH at origin, no worktrees, no publication gaps or finished branches, nothing untracked"
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
