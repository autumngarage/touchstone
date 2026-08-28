#!/usr/bin/env bash
#
# scripts/respond-review.sh — answer a PR review finding as one audited step.
#
# The merge gate requires every actionable review thread to be resolved or
# explicitly answered. Doing that by hand takes a REST reply, a GraphQL
# thread lookup, a GraphQL resolve mutation, and a verification read — four
# calls drivers were hand-rolling per finding (issue #652). This script owns
# the whole exchange and fails loudly at every step.
#
# Usage:
#   touchstone pr answer <pr-number> --comment-id <id> --body-file <file> [--fix-commit <sha>]
#   touchstone pr answer <pr-number> --all-resolved-check
#   (installed name; from a source checkout: bash scripts/respond-review.sh …)
#
# Modes:
#   --comment-id + --body-file   Reply to the review comment (body read from
#                                the file, avoiding shell-quoting hazards),
#                                then resolve its thread and verify the
#                                resolution stuck. --fix-commit appends a
#                                "Fixed in <sha>." line to the reply.
#   --all-resolved-check         Exit 0 when no unresolved review threads
#                                remain on the PR; otherwise list them and
#                                exit 1. Use before re-running the merge gate.
#
# Transient GraphQL failures (gateway HTML instead of JSON, rate blips) are
# retried up to 3 times with a short delay before failing closed.
#
set -euo pipefail

GRAPHQL_ATTEMPTS=3
GRAPHQL_RETRY_DELAY="${TOUCHSTONE_GRAPHQL_RETRY_DELAY:-2}"
# Behavior-v1 gates must finish before they can be refreshed. Behavior v2
# gates own the evidence wait; the answer client returns immediately when the
# exact run is already active instead of polling the poller.
GATE_ATTEMPTS="${TOUCHSTONE_GATE_ATTEMPTS:-60}"
GATE_RETRY_DELAY="${TOUCHSTONE_GATE_RETRY_DELAY:-5}"
GATE_V2_REVIEW_REUSE_SECONDS=3600
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

PR_NUMBER="${1:-}"
case "$PR_NUMBER" in
  "" | *[!0-9]*) usage ;;
esac
shift

COMMENT_ID=""
BODY_FILE=""
FIX_COMMIT=""
ALL_RESOLVED_CHECK=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --comment-id)
      shift
      COMMENT_ID="${1:-}"
      ;;
    --body-file)
      shift
      BODY_FILE="${1:-}"
      ;;
    --fix-commit)
      shift
      FIX_COMMIT="${1:-}"
      ;;
    --all-resolved-check)
      ALL_RESOLVED_CHECK=true
      ;;
    *)
      usage
      ;;
  esac
  shift || true
done

REPO_WITH_OWNER="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
  || fail "could not resolve the GitHub repository (gh repo view failed)."
REPO_OWNER="${REPO_WITH_OWNER%%/*}"
REPO_NAME="${REPO_WITH_OWNER##*/}"
[ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ] \
  || fail "could not parse owner/name from '$REPO_WITH_OWNER'."

# Every parsed GitHub response comes through here. A successful gh call may
# still write debug or warning diagnostics to stderr; merging the streams
# turned those lines into an author login or a reply id (AUT-294). On success
# only stdout is returned; on failure both streams form the error detail.
gh_read() {
  local stderr_file output status=0
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/respond-review.XXXXXXXX")" \
    || {
      echo "could not create a file for gh diagnostics"
      return 1
    }
  output="$(gh "$@" 2>"$stderr_file")" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$output"
  else
    cat "$stderr_file"
    [ -z "$output" ] || printf '%s\n' "$output"
  fi
  rm -f -- "$stderr_file"
  return "$status"
}

# Runs a GraphQL query with bounded retries; transient gateway responses
# (HTML instead of JSON) surface as gh errors and are retried before the
# script fails closed.
graphql_with_retry() {
  local attempt=1 output status
  while :; do
    status=0
    output="$(gh_read api graphql "$@")" || status=$?
    if [ "$status" -eq 0 ]; then
      printf '%s\n' "$output"
      return 0
    fi
    if [ "$attempt" -ge "$GRAPHQL_ATTEMPTS" ]; then
      echo "ERROR: GraphQL call failed after $GRAPHQL_ATTEMPTS attempt(s):" >&2
      printf '%s\n' "$output" | sed 's/^/       /' >&2
      return "$status"
    fi
    echo "==> GraphQL attempt $attempt failed; retrying in ${GRAPHQL_RETRY_DELAY}s ..." >&2
    attempt=$((attempt + 1))
    sleep "$GRAPHQL_RETRY_DELAY"
  done
}

# All thread scans paginate: a PR can carry more than one page of review
# threads, and a fixed-size query would silently ignore later pages —
# --all-resolved-check would pass with unresolved threads remaining.
# Repository identity travels as GraphQL VARIABLES, never textual
# substitution: a repository name containing a placeholder-like token
# (e.g. PRNUM-tools) must not be rewritten by a later replacement pass.
THREADS_QUERY='query($endCursor: String, $owner: String!, $name: String!, $pr: Int!) { repository(owner:$owner, name:$name) { pullRequest(number:$pr) { reviewThreads(first:100, after:$endCursor) { nodes { id isResolved comments(first:1) { nodes { databaseId path } } } pageInfo { hasNextPage endCursor } } } } }'

list_unresolved_threads() {
  graphql_with_retry --paginate \
    -f owner="$REPO_OWNER" -f name="$REPO_NAME" -F pr="$PR_NUMBER" \
    -f query="$THREADS_QUERY" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | [.id, (.comments.nodes[0].databaseId | tostring), (.comments.nodes[0].path // "-")] | @tsv'
}

if [ "$ALL_RESOLVED_CHECK" = true ]; then
  UNRESOLVED="$(list_unresolved_threads)" || exit 1
  if [ -z "$UNRESOLVED" ]; then
    echo "==> All review threads on PR #$PR_NUMBER are resolved."
    exit 0
  fi
  echo "ERROR: PR #$PR_NUMBER has unresolved review thread(s):" >&2
  printf '%s\n' "$UNRESOLVED" | while IFS=$'\t' read -r _tid cid path; do
    echo "       comment $cid ($path)" >&2
  done
  echo "       Answer each with: touchstone pr answer $PR_NUMBER --comment-id <id> --body-file <file>" >&2
  exit 1
fi

[ -n "$COMMENT_ID" ] || usage
case "$COMMENT_ID" in *[!0-9]*) fail "--comment-id must be numeric, got: $COMMENT_ID" ;; esac
[ -n "$BODY_FILE" ] || usage
[ -f "$BODY_FILE" ] || fail "--body-file not found: $BODY_FILE"
[ -s "$BODY_FILE" ] || fail "--body-file is empty: $BODY_FILE"

# The head this answer binds to is captured BEFORE any mutation. Read after
# the reply, a push landing mid-run would bind the merge hint and the gate
# re-run to a commit the answer never addressed.
PR_ROW="$(gh_read pr view "$PR_NUMBER" --json headRefOid,baseRefName --jq '[.headRefOid,.baseRefName] | @tsv')" \
  || fail "could not read the PR coordinates: $PR_ROW"
IFS="$(printf '\t')" read -r HEAD_SHA BASE_REF <<<"$PR_ROW"
[ -n "$HEAD_SHA" ] && [ -n "$BASE_REF" ] || fail "PR $PR_NUMBER has no readable head and base."

# A fix reference is review evidence, not caller-supplied prose. Resolve it
# through GitHub, then prove the resulting commit is the captured PR head or
# one of its ancestors before publishing the canonical SHA. The compare API
# reports `ahead` when HEAD_SHA descends from the named fix and `identical`
# when the fix is the head itself; every other relationship is off-head.
if [ -n "$FIX_COMMIT" ]; then
  CANONICAL_FIX="$(gh_read api "repos/$REPO_OWNER/$REPO_NAME/commits/$FIX_COMMIT" --jq '.sha')" \
    || fail "--fix-commit '$FIX_COMMIT' does not resolve to a commit in $REPO_WITH_OWNER: $CANONICAL_FIX"
  [ -n "$CANONICAL_FIX" ] \
    || fail "--fix-commit '$FIX_COMMIT' resolved without a canonical commit SHA."
  FIX_RELATION="$(gh_read api "repos/$REPO_OWNER/$REPO_NAME/compare/$CANONICAL_FIX...$HEAD_SHA" --jq '.status')" \
    || fail "could not prove --fix-commit $CANONICAL_FIX is reachable from PR #$PR_NUMBER head $HEAD_SHA: $FIX_RELATION"
  case "$FIX_RELATION" in
    ahead | identical) ;;
    *) fail "--fix-commit $CANONICAL_FIX is not reachable from PR #$PR_NUMBER head $HEAD_SHA (relationship: ${FIX_RELATION:-<empty>})." ;;
  esac
  FIX_COMMIT="$CANONICAL_FIX"
fi

REPLY_BODY="$(cat "$BODY_FILE")"
if [ -n "$FIX_COMMIT" ]; then
  REPLY_BODY="$REPLY_BODY

Fixed in $FIX_COMMIT."
fi

# Idempotency marker: reruns after a partial failure (reply posted, resolve
# failed) must not post a duplicate reply. The marker is invisible in
# rendered Markdown and detectable on the next run.
REPLY_MARKER="<!-- touchstone:respond-review comment=$COMMENT_ID -->"
REPLY_BODY="$REPLY_BODY

$REPLY_MARKER"

# The marker only proves idempotency for OUR OWN prior run. Selecting replies
# by in_reply_to_id alone let any participant's comment carrying the (trivially
# predictable) marker satisfy the check — the script would then skip posting
# the driver's actual answer and resolve the thread anyway, so a finding could
# be marked answered without the answer ever being written, and
# --all-resolved-check would call the PR clean (#722). Authorship is therefore
# part of the predicate: the reply must be ours.
REPLY_AUTHOR="$(gh_read api user --jq '.login')" \
  || fail "could not resolve the authenticated user for reply idempotency: $REPLY_AUTHOR"
[ -n "$REPLY_AUTHOR" ] || fail "GitHub returned no authenticated login; refusing to trust the idempotency marker."
EXISTING_REPLY="$(gh_read api --paginate \
  "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" \
  --jq ".[] | select(.in_reply_to_id == $COMMENT_ID) | select((.user.login // \"\") == \"$REPLY_AUTHOR\") | .body")" \
  || fail "could not inspect existing replies for comment $COMMENT_ID: $EXISTING_REPLY"
if printf '%s' "$EXISTING_REPLY" | grep -qF "$REPLY_MARKER"; then
  echo "==> Reply for comment $COMMENT_ID already posted (marker found); skipping the reply step."
  echo "    matched our own reply as @$REPLY_AUTHOR."
else
  echo "==> Replying to review comment $COMMENT_ID on PR #$PR_NUMBER ..."
  REPLY_ID="$(gh_read api "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" \
    -f body="$REPLY_BODY" --jq '.id')" \
    || fail "could not post the reply: $REPLY_ID"
  echo "    reply id: $REPLY_ID"
fi

echo "==> Resolving the thread for comment $COMMENT_ID ..."
THREAD_ID="$(graphql_with_retry --paginate \
  -f owner="$REPO_OWNER" -f name="$REPO_NAME" -F pr="$PR_NUMBER" \
  -f query="$THREADS_QUERY" \
  --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.nodes[0].databaseId == $COMMENT_ID) | .id")" \
  || fail "could not look up the review thread for comment $COMMENT_ID."
[ -n "$THREAD_ID" ] || fail "no review thread found whose first comment is $COMMENT_ID."

RESOLVED="$(graphql_with_retry \
  -f query="mutation { resolveReviewThread(input:{threadId:\"$THREAD_ID\"}) { thread { isResolved } } }" \
  --jq '.data.resolveReviewThread.thread.isResolved')" \
  || fail "resolveReviewThread failed for thread $THREAD_ID."
[ "$RESOLVED" = "true" ] || fail "thread $THREAD_ID did not report isResolved=true (got: ${RESOLVED:-<empty>})."

# Verify with a fresh read — the mutation response alone has lied before.
VERIFY="$(graphql_with_retry \
  -f query="query { node(id:\"$THREAD_ID\") { ... on PullRequestReviewThread { isResolved } } }" \
  --jq '.data.node.isResolved')" \
  || fail "could not verify thread resolution for $THREAD_ID."
[ "$VERIFY" = "true" ] || fail "thread $THREAD_ID is still unresolved after the mutation."

# Answered findings satisfy the gate on an unchanged head (issue #751) — the
# next step after resolving every thread is the MERGE GATE, never another
# review request of the same head (PR #755 review, round 8).
# An answer is evidence the pinned review-gate has not seen. Where the base
# branch requires that workflow, ask GitHub to re-run its run for this head;
# a behavior-v1 run still in progress is waited for first, because it may have
# read the evidence before this answer. A behavior-v2 run owns that wait and
# will observe the answer on its next poll. Where the repository still runs the
# status-publishing review-gate, its own event handlers pick the answer up.
# The head must not have moved since capture: the hint below and the gate
# re-run are bound to the head this answer addressed, never a later push.
LIVE_HEAD="$(gh_read pr view "$PR_NUMBER" --json headRefOid --jq .headRefOid)" \
  || fail "could not re-read the PR head after answering: $LIVE_HEAD"
[ "$LIVE_HEAD" = "$HEAD_SHA" ] \
  || fail "PR head moved from $HEAD_SHA to $LIVE_HEAD while answering; the reply and resolution stand, but request review for the new head before merging."
# Ask the shared PR observer which behavior GitHub's effective, exact pinned
# workflow implements. Local policy bytes alone are rollout intent and cannot
# authorize the behavior-v2 early return.
GATE_BEHAVIOR_VERSION=1
BOUND_GATE_RUN_ID=""
if PR_STATUS="$(bash "$TOOL_ROOT/scripts/touchstone-pr.sh" status "$PR_NUMBER" --json)"; then
  GATE_BEHAVIOR_VERSION="$(printf '%s' "$PR_STATUS" | jq -er '.reviewGateBehaviorContractVersion // 1')" \
    || fail "effective review-gate status reported an invalid behavior contract."
  if [ "$GATE_BEHAVIOR_VERSION" = 2 ]; then
    BOUND_GATE_RUN_ID="$(printf '%s' "$PR_STATUS" | jq -r \
      '.reviewGateCheck | select(.present == true and ((.unbound // false) | not)) | .workflowRunId // empty')"
    if [ -z "$BOUND_GATE_RUN_ID" ]; then
      echo "WARNING: behavior v2 has no verified policy-bound review-gate run; conservatively refreshing through the behavior-v1 path." >&2
    fi
  fi
else
  echo "WARNING: could not verify behavior v2; conservatively refreshing the gate through the behavior-v1 path." >&2
fi
# Percent-encode one path segment with the base tool surface only: a branch
# name may carry "/" or other bytes the rules endpoint cannot take raw.
uri_encode() {
  local input="$1" i char out="" LC_ALL=C
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [A-Za-z0-9._~-]) out+="$char" ;;
      *) out+="$(printf '%%%02X' "'$char")" ;;
    esac
  done
  printf '%s' "$out"
}
BASE_REF_ENCODED="$(uri_encode "$BASE_REF")"
GATE_REQUIRED="$(gh_read api "repos/$REPO_OWNER/$REPO_NAME/rules/branches/$BASE_REF_ENCODED" \
  --jq '[.[] | select(.type == "workflows") | .parameters.workflows[]?.path] | any(. == ".github/workflows/review-gate.yml")')" \
  || fail "could not read the effective rules for $BASE_REF: $GATE_REQUIRED"
if [ "$GATE_REQUIRED" = true ]; then
  # The pinned gate runs under a workflow id the repository does not list; a
  # local workflow sharing the name is listed and is not the gate.
  LOCAL_WORKFLOW_IDS="$(gh_read api --paginate "repos/$REPO_OWNER/$REPO_NAME/actions/workflows?per_page=100" --jq '.workflows[].id' | awk 'BEGIN { printf "[" } NF { if (n++) printf ","; printf "%s", $1 } END { printf "]" }')" \
    || fail "could not list the repository's workflows: $LOCAL_WORKFLOW_IDS"
  attempt=1
  while :; do
    GATE_PAGES="$(gh_read api "repos/$REPO_OWNER/$REPO_NAME/actions/runs?head_sha=$HEAD_SHA&per_page=100" --paginate)" \
      || fail "could not inspect review-gate runs: $GATE_PAGES"
    GATE_ROW="$(printf '%s\n' "$GATE_PAGES" | jq -ser \
      --argjson number "$PR_NUMBER" --argjson local_ids "$LOCAL_WORKFLOW_IDS" '
        [.[].workflow_runs[]? | select(.name == "review-gate" and any(.pull_requests[]?; .number == $number) and ((.workflow_id as $w | $local_ids | index($w)) == null))]
        | if length == 0 then ""
          elif any(.[]; (.id | type) != "number" or (.run_attempt | type) != "number"
            or (.run_started_at | type) != "string" or .run_started_at == ""
            or (.status | type) != "string") then
            error("workflow run is missing its id, attempt, status, or execution timestamp")
          else (map(.run_started_at) | max) as $latest_start
            | [.[] | select(.run_started_at == $latest_start)] as $latest_runs
            | if ($latest_runs | length) > 1 then
                error("multiple workflow runs share the newest execution timestamp")
              else $latest_runs[0] | "\(.id) \(.status) \(.run_started_at)"
              end
          end')" \
      || fail "GitHub returned malformed or ambiguous review-gate run data"
    read -r GATE_RUN GATE_STATUS GATE_STARTED_AT <<<"$GATE_ROW"
    if [ -n "$GATE_RUN" ] && [ "$GATE_BEHAVIOR_VERSION" = 2 ] && [ "$GATE_RUN" = "$BOUND_GATE_RUN_ID" ]; then
      case "$GATE_STATUS" in
        queued | requested | waiting | pending)
          echo "==> Review gate run $GATE_RUN is already evaluating this head; returning control while it waits for review evidence."
          break
          ;;
        in_progress)
          GATE_STARTED_EPOCH="$(jq -ner --arg started "$GATE_STARTED_AT" '$started | fromdateiso8601')" 2>/dev/null || GATE_STARTED_EPOCH=""
          GATE_NOW="$(date -u +%s)"
          case "$GATE_STARTED_EPOCH$GATE_NOW" in
            '' | *[!0-9]*) ;;
            *)
              if [ "$GATE_NOW" -ge "$GATE_STARTED_EPOCH" ] \
                && [ "$GATE_NOW" -lt "$((GATE_STARTED_EPOCH + GATE_V2_REVIEW_REUSE_SECONDS))" ]; then
                echo "==> Review gate run $GATE_RUN is already evaluating this head; returning control while it waits for review evidence."
                break
              fi
              ;;
          esac
          ;;
        completed) ;;
        *) fail "review-gate run $GATE_RUN reported unsupported active status '${GATE_STATUS:-empty}'; inspect it in the Actions tab." ;;
      esac
    fi
    if [ -n "$GATE_RUN" ] && [ "$GATE_STATUS" = completed ]; then
      gh api -X POST "repos/$REPO_OWNER/$REPO_NAME/actions/runs/$GATE_RUN/rerun" >/dev/null \
        || fail "could not re-run review-gate run $GATE_RUN; re-run it from the Actions tab."
      echo "==> Review gate re-run requested (run $GATE_RUN)."
      break
    fi
    [ "$attempt" -lt "$GATE_ATTEMPTS" ] \
      || fail "review-gate run for $HEAD_SHA did not reach a re-runnable state within $((GATE_ATTEMPTS * GATE_RETRY_DELAY))s (last: ${GATE_RUN:-none} ${GATE_STATUS:-absent}); wait for it, then re-run this command."
    echo "==> Review gate run ${GATE_STATUS:-not yet present}; retrying in ${GATE_RETRY_DELAY}s ..." >&2
    attempt=$((attempt + 1))
    sleep "$GATE_RETRY_DELAY"
  done
fi

echo "==> Replied and resolved. When every thread is answered, prove it and merge:"
echo "    touchstone pr answer $PR_NUMBER --all-resolved-check"
# The captured head, never a live read: a merge hint that resolves the head
# at run time accepts a commit pushed after this answer, unreviewed.
echo "    touchstone pr merge $PR_NUMBER --head $HEAD_SHA   # or: gh pr merge $PR_NUMBER --squash --match-head-commit $HEAD_SHA"
echo "    gh pr view $PR_NUMBER --json state,mergedAt   # the merge exit code lies in both directions"
echo "    (Pushed new commits instead? The head moved — request one review for the new head.)"
