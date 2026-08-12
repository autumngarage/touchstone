#!/usr/bin/env bash
#
# scripts/claim-issue.sh — deterministically claim an issue before dispatch.
#
# Usage:
#   bash scripts/claim-issue.sh <issue-ref> [<dispatch-comment>]
#
# The tracker is declared per project in .touchstone-review.toml ([issues]);
# undeclared means GitHub. Only the GitHub adapter can perform the claim, so
# other trackers print the protocol the agent must carry out by hand.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_TRACKER_LIB="$SCRIPT_DIR/../lib/issue-tracker.sh"

usage() {
  echo "Usage: bash scripts/claim-issue.sh <issue-ref> [<dispatch-comment>]" >&2
}

log() {
  echo "==> $*" >&2
}

if [ ! -f "$ISSUE_TRACKER_LIB" ]; then
  echo "ERROR: issue-tracker library not found at $ISSUE_TRACKER_LIB." >&2
  echo "       Run: touchstone update" >&2
  exit 2
fi
# shellcheck source=../lib/issue-tracker.sh
source "$ISSUE_TRACKER_LIB"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

# Project root first, working directory second: the script ships next to the
# policy it must obey, and cwd may be anywhere under it.
if ! issue_tracker_load "$SCRIPT_DIR/.." "$PWD"; then
  exit 2
fi

if ! ISSUE_REF="$(issue_tracker_normalize_ref "$1")"; then
  echo "ERROR: '$1' is not a $ISSUE_TRACKER issue reference; expected $(issue_tracker_ref_hint)." >&2
  usage
  exit 2
fi
ISSUE_NUMBER="$ISSUE_REF"

DISPATCH_COMMENT="${2-}"
COMMENT_PROVIDED=0
if [ "$#" -eq 2 ]; then
  COMMENT_PROVIDED=1
fi

if ! issue_tracker_has_claim_transport; then
  CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
  if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH="(detached-head)"
  fi
  echo "MANUAL CLAIM REQUIRED: Touchstone has no $ISSUE_TRACKER claim transport; do these three steps in $ISSUE_TRACKER before editing:" >&2
  echo "  1. Assign $ISSUE_REF to yourself." >&2
  echo "  2. Comment on $ISSUE_REF: \"Dispatched: branch \`$CURRENT_BRANCH\`, agent \`${TOUCHSTONE_AGENT_LABEL:-$(whoami)}\`.\"" >&2
  echo "  3. Reference it from the PR body as: $(issue_tracker_closing_ref "$ISSUE_REF")" >&2
  echo "     Touchstone verifies none of these three steps for you." >&2
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required." >&2
  exit 2
fi

log "Checking gh authentication ..."
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 2
fi

if ! GH_LOGIN="$(gh api user --jq '.login' 2>/dev/null)" || [ -z "$GH_LOGIN" ]; then
  echo "ERROR: failed to resolve GitHub login via gh api user." >&2
  exit 2
fi

log "Inspecting issue #$ISSUE_NUMBER ..."
if ! ISSUE_STATE="$(gh issue view "$ISSUE_NUMBER" --json state --jq '.state' 2>/dev/null)"; then
  echo "ERROR: issue #$ISSUE_NUMBER not found." >&2
  exit 2
fi

if [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo "ERROR: can't claim closed issue (#$ISSUE_NUMBER)." >&2
  exit 1
fi

if ! PRE_ASSIGNEES="$(gh issue view "$ISSUE_NUMBER" --json assignees --jq '.assignees | map(.login) | join("\n")' 2>/dev/null)"; then
  echo "ERROR: failed to read assignees for issue #$ISSUE_NUMBER." >&2
  exit 2
fi

OTHER_ASSIGNEE=""
ASSIGNEE_COUNT=0
ME_ONLY=0
if [ -n "$PRE_ASSIGNEES" ]; then
  while IFS= read -r assignee; do
    [ -n "$assignee" ] || continue
    ASSIGNEE_COUNT=$((ASSIGNEE_COUNT + 1))
    if [ "$assignee" != "$GH_LOGIN" ]; then
      OTHER_ASSIGNEE="$assignee"
      break
    fi
  done <<<"$PRE_ASSIGNEES"

  if [ -n "$OTHER_ASSIGNEE" ]; then
    echo "ERROR: already claimed by @$OTHER_ASSIGNEE." >&2
    exit 1
  fi

  if [ "$ASSIGNEE_COUNT" -eq 1 ]; then
    ME_ONLY=1
  fi
fi

post_dispatch_comment() {
  local body="$1"
  log "Posting dispatch comment to issue #$ISSUE_NUMBER ..."
  gh issue comment "$ISSUE_NUMBER" --body "$body" >/dev/null
}

if [ "$ME_ONLY" -eq 1 ]; then
  log "Issue #$ISSUE_NUMBER is already assigned to @$GH_LOGIN (idempotent)."
  if [ "$COMMENT_PROVIDED" -eq 1 ] && [ -n "$DISPATCH_COMMENT" ]; then
    post_dispatch_comment "$DISPATCH_COMMENT"
  fi
  exit 0
fi

log "Claiming issue #$ISSUE_NUMBER as @$GH_LOGIN ..."
gh issue edit "$ISSUE_NUMBER" --add-assignee @me >/dev/null

if ! POST_ASSIGNEES="$(gh issue view "$ISSUE_NUMBER" --json assignees --jq '.assignees | map(.login) | join("\n")' 2>/dev/null)"; then
  echo "ERROR: failed to re-read assignees after claiming issue #$ISSUE_NUMBER." >&2
  exit 2
fi

RACE_ASSIGNEE=""
I_AM_ASSIGNEE=0
if [ -n "$POST_ASSIGNEES" ]; then
  while IFS= read -r assignee; do
    [ -n "$assignee" ] || continue
    if [ "$assignee" = "$GH_LOGIN" ]; then
      I_AM_ASSIGNEE=1
      continue
    fi
    RACE_ASSIGNEE="$assignee"
    break
  done <<<"$POST_ASSIGNEES"
fi

if [ -n "$RACE_ASSIGNEE" ]; then
  log "Race detected; removing @me from issue #$ISSUE_NUMBER ..."
  gh issue edit "$ISSUE_NUMBER" --remove-assignee @me >/dev/null
  echo "ERROR: race detected — @$RACE_ASSIGNEE claimed concurrently, backed off." >&2
  exit 1
fi

if [ "$I_AM_ASSIGNEE" -ne 1 ]; then
  echo "ERROR: claim did not stick; @$GH_LOGIN is not assigned after claim attempt." >&2
  exit 1
fi

if [ "$COMMENT_PROVIDED" -eq 1 ]; then
  COMMENT_BODY="$DISPATCH_COMMENT"
else
  CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
  if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH="(detached-head)"
  fi
  AGENT_LABEL="${TOUCHSTONE_AGENT_LABEL:-$(whoami)}"
  COMMENT_BODY="Dispatched: branch \`$CURRENT_BRANCH\`, agent \`${AGENT_LABEL}\` claiming this issue. PR will land via \`scripts/open-pr.sh --auto-merge\`."
fi

if [ -n "$COMMENT_BODY" ]; then
  post_dispatch_comment "$COMMENT_BODY"
fi

log "Issue #$ISSUE_NUMBER claimed successfully by @$GH_LOGIN."
