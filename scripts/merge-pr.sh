#!/usr/bin/env bash
#
# scripts/merge-pr.sh — squash-merge a PR and clean up.
#
# Usage:
#   bash scripts/merge-pr.sh <pr-number>
#
# What this does:
#   1. Verifies the PR is open and mergeable.
#   2. Squash-merges and deletes the remote branch.
#   3. Checks out the default branch and pulls the updated state.
#
# Exit codes:
#   0 — merged cleanly
#   1 — merge failed (PR not mergeable, conflicts, etc.)
#   2 — usage / environment error
#
set -euo pipefail

PR_NUMBER="${1:-}"

if [ -z "$PR_NUMBER" ] || ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Usage: bash scripts/merge-pr.sh <pr-number>" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: 'gh' is not installed." >&2
  exit 2
fi

# Resolve the default branch.
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)"

# 1. Sanity check the PR exists and is open.
PR_STATE="$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>/dev/null || echo "")"
if [ "$PR_STATE" != "OPEN" ]; then
  echo "ERROR: PR #$PR_NUMBER is not open (state: $PR_STATE)." >&2
  exit 1
fi

# 2. Check mergeability with retries (GitHub's status can lag after a push).
echo "==> Checking merge state for PR #$PR_NUMBER ..."
STATE=""
MERGEABLE=""
for attempt in 1 2 3 4 5; do
  MERGE_STATE="$(gh pr view "$PR_NUMBER" --json mergeStateStatus,mergeable --template '{{.mergeStateStatus}} {{.mergeable}}' 2>/dev/null || echo '')"
  STATE="${MERGE_STATE%% *}"
  MERGEABLE="${MERGE_STATE#* }"
  [ -n "$STATE" ] || STATE="UNKNOWN"
  [ -n "$MERGEABLE" ] || MERGEABLE="UNKNOWN"
  echo "    attempt $attempt: mergeStateStatus=$STATE mergeable=$MERGEABLE"
  if [ "$STATE" = "CLEAN" ] && [ "$MERGEABLE" = "MERGEABLE" ]; then
    break
  fi
  if [ "$STATE" = "DIRTY" ] || [ "$STATE" = "BEHIND" ]; then
    echo "ERROR: PR #$PR_NUMBER is $STATE — has conflicts or is out of date with base." >&2
    echo "       Rebase or resolve conflicts on the PR branch before merging." >&2
    exit 1
  fi
  sleep 3
done

if [ "$STATE" != "CLEAN" ] || [ "$MERGEABLE" != "MERGEABLE" ]; then
  echo "ERROR: PR #$PR_NUMBER is not cleanly mergeable (state=$STATE mergeable=$MERGEABLE)." >&2
  echo "       Inspect manually: gh pr view $PR_NUMBER --web" >&2
  exit 1
fi

# 3. Squash-merge and delete the branch.
echo "==> Squash-merging PR #$PR_NUMBER ..."
gh pr merge "$PR_NUMBER" --squash --delete-branch

# 4. Sync local default branch.
echo "==> Merged. Updating local $DEFAULT_BRANCH ..."
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
  git checkout "$DEFAULT_BRANCH"
fi
git pull --rebase
echo "==> Done."
