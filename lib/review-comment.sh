#!/usr/bin/env bash
#
# lib/review-comment.sh — shared PR comment helpers for review events.
#
# Public interface:
#   format_clean_review_comment <review-summary-json>
#   post_pr_review_comment <pr-number> <comment-string>
#   read_latest_review_event <jsonl-path>
#
set -euo pipefail

review_comment_json_field() {
  local json="$1"
  local key="$2"
  printf '%s\n' "$json" | sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1
}

review_comment_json_number() {
  local json="$1"
  local key="$2"
  printf '%s\n' "$json" | sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1
}

review_comment_clean_value() {
  local value="$1"
  value="$(printf '%s' "${value:-unknown}" | tr '\r\n\t' '   ')"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || value="unknown"
  printf '%s' "$value"
}

format_clean_review_comment() {
  local json="$1"
  local reviewer provider model peer iterations mode findings

  reviewer="$(review_comment_clean_value "$(review_comment_json_field "$json" reviewer)")"
  provider="$(review_comment_clean_value "$(review_comment_json_field "$json" provider)")"
  model="$(review_comment_clean_value "$(review_comment_json_field "$json" model)")"
  peer="$(review_comment_clean_value "$(review_comment_json_field "$json" peer_provider)")"
  iterations="$(review_comment_clean_value "$(review_comment_json_number "$json" iterations)")"
  mode="$(review_comment_clean_value "$(review_comment_json_field "$json" mode)")"
  findings="$(review_comment_clean_value "$(review_comment_json_number "$json" findings)")"

  printf '%s review clean - provider: %s, model: %s, peer: %s, iterations: %s, mode: %s, findings: %s' \
    "$reviewer" "$provider" "$model" "$peer" "$iterations" "$mode" "$findings"
}

post_pr_review_comment() {
  local pr_number="$1"
  local comment="$2"

  gh pr comment "$pr_number" --body "$comment"
}

read_latest_review_event() {
  local log_path="$1"
  [ -f "$log_path" ] || return 1
  tail -n 1 "$log_path"
}
