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
#   bash scripts/respond-review.sh <pr-number> --comment-id <id> --body-file <file> [--fix-commit <sha>]
#   bash scripts/respond-review.sh <pr-number> --all-resolved-check
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
GRAPHQL_RETRY_DELAY=2

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

# Runs a GraphQL query with bounded retries; transient gateway responses
# (HTML instead of JSON) surface as gh errors and are retried before the
# script fails closed.
graphql_with_retry() {
  local attempt=1 output status
  while :; do
    status=0
    output="$(gh api graphql "$@" 2>&1)" || status=$?
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
  echo "       Answer each with: bash scripts/respond-review.sh $PR_NUMBER --comment-id <id> --body-file <file>" >&2
  exit 1
fi

[ -n "$COMMENT_ID" ] || usage
case "$COMMENT_ID" in *[!0-9]*) fail "--comment-id must be numeric, got: $COMMENT_ID" ;; esac
[ -n "$BODY_FILE" ] || usage
[ -f "$BODY_FILE" ] || fail "--body-file not found: $BODY_FILE"
[ -s "$BODY_FILE" ] || fail "--body-file is empty: $BODY_FILE"

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
REPLY_AUTHOR="$(gh api user --jq '.login' 2>&1)" \
  || fail "could not resolve the authenticated user for reply idempotency: $REPLY_AUTHOR"
[ -n "$REPLY_AUTHOR" ] || fail "GitHub returned no authenticated login; refusing to trust the idempotency marker."
EXISTING_REPLY="$(gh api --paginate \
  "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" \
  --jq ".[] | select(.in_reply_to_id == $COMMENT_ID) | select((.user.login // \"\") == \"$REPLY_AUTHOR\") | .body" 2>&1)" \
  || fail "could not inspect existing replies for comment $COMMENT_ID: $EXISTING_REPLY"
if printf '%s' "$EXISTING_REPLY" | grep -qF "$REPLY_MARKER"; then
  echo "==> Reply for comment $COMMENT_ID already posted (marker found); skipping the reply step."
  echo "    matched our own reply as @$REPLY_AUTHOR."
else
  echo "==> Replying to review comment $COMMENT_ID on PR #$PR_NUMBER ..."
  REPLY_ID="$(gh api "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" \
    -f body="$REPLY_BODY" --jq '.id' 2>&1)" \
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
echo "==> Replied and resolved. When every thread is answered, rerun the merge gate:"
echo "    bash scripts/respond-review.sh $PR_NUMBER --all-resolved-check && bash scripts/merge-pr.sh $PR_NUMBER"
echo "    (Pushed new commits instead? Then request one review for the new head: bash scripts/open-pr.sh)"
