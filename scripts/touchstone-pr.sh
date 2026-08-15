#!/usr/bin/env bash
# scripts/touchstone-pr.sh — narrow, versioned PR delivery operations.

set -euo pipefail

OUTPUT_SCHEMA="touchstone.pr/v1"
READ_ATTEMPTS="${TOUCHSTONE_READ_ATTEMPTS:-3}"
RETRY_DELAY="${TOUCHSTONE_RETRY_DELAY:-2}"
JSON_MODE=false
PROJECT_ARG=""
TITLE=""
BODY_FILE=""
BASE_REF=""
COMMENT_ID=""
FIX_COMMIT=""
EXPECTED_HEAD=""
OPERATION="${1:-}"
PR_NUMBER=""
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CAPTURE_STDERR_TEMP=""

cleanup() {
  [ -z "$CAPTURE_STDERR_TEMP" ] || rm -f -- "$CAPTURE_STDERR_TEMP"
}
trap cleanup EXIT

case "$READ_ATTEMPTS" in '' | *[!0-9]* | 0)
  echo "ERROR: TOUCHSTONE_READ_ATTEMPTS must be a positive integer" >&2
  exit 2
  ;;
esac
case "$RETRY_DELAY" in '' | *[!0-9]*)
  echo "ERROR: TOUCHSTONE_RETRY_DELAY must be a non-negative integer" >&2
  exit 2
  ;;
esac

usage() {
  cat >&2 <<'EOF'
Usage:
  touchstone pr open --title TITLE --body-file FILE [--base BRANCH] [--project DIR] [--json]
  touchstone pr status PR [--project DIR] [--json]
  touchstone pr findings PR [--project DIR] [--json]
  touchstone pr respond PR --comment-id ID --body-file FILE [--fix-commit SHA] [--project DIR] [--json]
  touchstone pr merge PR [--head SHA] [--project DIR] [--json]
EOF
  exit 2
}

json_string() {
  printf '"'
  printf '%s' "$1" | awk 'BEGIN { ORS="" }
    {
      if (NR > 1) printf "\\n"
      for (position = 1; position <= length($0); position++) {
        character = substr($0, position, 1)
        if (character == "\\") printf "\\\\"
        else if (character == "\"") printf "\\\""
        else if (character == sprintf("%c", 8)) printf "\\b"
        else if (character == sprintf("%c", 9)) printf "\\t"
        else if (character == sprintf("%c", 12)) printf "\\f"
        else if (character == sprintf("%c", 13)) printf "\\r"
        else {
          control = 0
          for (code = 1; code < 32; code++) {
            if (character == sprintf("%c", code)) { control = code; break }
          }
          if (control) printf "\\u%04x", control
          else printf "%s", character
        }
      }
    }'
  printf '"'
}

emit_error() {
  local reason="$1" remedy="$2"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":' "$OUTPUT_SCHEMA"
    json_string "$OPERATION"
    printf ',"status":"failed","reason":'
    json_string "$reason"
    printf ',"remedy":'
    json_string "$remedy"
    printf '}\n'
  else
    printf 'ERROR: %s\n' "$reason" >&2
    [ -z "$remedy" ] || printf '       %s\n' "$remedy" >&2
  fi
}

fail_input() {
  emit_error "$1" "$2"
  exit 2
}
fail_operation() {
  emit_error "$1" "$2"
  exit 1
}

clean_diagnostic() {
  local cleaned
  cleaned="$(printf '%s\n' "$1" | awk 'BEGIN { ORS="" }
    {
      for (code = 1; code < 32; code++) {
        control = sprintf("%c", code)
        gsub(control, " ")
      }
      if (NR > 1) printf " | "; printf "%s", $0
    }')"
  printf '%.2000s' "$cleaned"
}

capture_command() {
  local output diagnostic status=0
  CAPTURE_STDERR_TEMP="$(mktemp "${TMPDIR:-/tmp}/touchstone-pr-read.XXXXXX")" || {
    CAPTURE_OUTPUT=""
    CAPTURE_ERROR="could not create a temporary file for command diagnostics"
    return 1
  }
  set +e
  output="$("$@" 2>"$CAPTURE_STDERR_TEMP")"
  status=$?
  set -e
  diagnostic="$(cat "$CAPTURE_STDERR_TEMP")"
  rm -f -- "$CAPTURE_STDERR_TEMP"
  CAPTURE_STDERR_TEMP=""
  CAPTURE_OUTPUT="$output"
  CAPTURE_ERROR=""
  if [ "$status" -ne 0 ]; then
    [ -z "$output" ] || diagnostic="${diagnostic}${diagnostic:+
}${output}"
    CAPTURE_ERROR="$(clean_diagnostic "$diagnostic")"
  fi
  return "$status"
}

read_with_retry() {
  local attempt=1 status
  while :; do
    status=0
    capture_command "$@" || status=$?
    if [ "$status" -eq 0 ]; then
      READ_OUTPUT="$CAPTURE_OUTPUT"
      return 0
    fi
    if [ "$attempt" -ge "$READ_ATTEMPTS" ]; then
      READ_OUTPUT="$CAPTURE_ERROR"
      return "$status"
    fi
    if [ "$JSON_MODE" = false ]; then
      printf 'Read attempt %s failed; retrying in %ss.\n' "$attempt" "$RETRY_DELAY" >&2
    fi
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY"
  done
}

read_repository() {
  (
    unset GH_REPO
    cd "$PROJECT_ROOT"
    gh repo view --json nameWithOwner,url --jq '[.nameWithOwner,.url] | @tsv'
  )
}

absolute_input_file() {
  local path="$1" directory
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *)
      directory="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || {
        printf '%s\n' "$path"
        return 0
      }
      printf '%s/%s\n' "$directory" "$(basename "$path")"
      ;;
  esac
}

require_option_value() {
  local option="${1:-}" value="${2:-}"
  [ "$#" -ge 2 ] || fail_input "missing value for $option" "Pass a non-empty value after $option."
  case "$value" in '' | --*) fail_input "missing value for $option" "Pass a non-empty value after $option." ;; esac
}

case "$OPERATION" in
  status | findings | respond | merge)
    [ "$#" -ge 2 ] || usage
    PR_NUMBER="$2"
    case "$PR_NUMBER" in "" | *[!0-9]*) usage ;; esac
    shift 2
    ;;
  open) shift ;;
  *) usage ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON_MODE=true
      shift
      ;;
    --project)
      require_option_value "$@"
      PROJECT_ARG="$2"
      shift 2
      ;;
    --title)
      require_option_value "$@"
      TITLE="$2"
      shift 2
      ;;
    --body-file)
      require_option_value "$@"
      BODY_FILE="$2"
      shift 2
      ;;
    --base)
      require_option_value "$@"
      BASE_REF="$2"
      shift 2
      ;;
    --comment-id)
      require_option_value "$@"
      COMMENT_ID="$2"
      shift 2
      ;;
    --fix-commit)
      require_option_value "$@"
      FIX_COMMIT="$2"
      shift 2
      ;;
    --head)
      require_option_value "$@"
      EXPECTED_HEAD="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *) fail_input "unknown argument '$1'" "Run 'touchstone pr $OPERATION --help' for the supported interface." ;;
  esac
done

case "$OPERATION" in
  open)
    [ -z "$COMMENT_ID$FIX_COMMIT$EXPECTED_HEAD" ] \
      || fail_input "open received an option for another operation" "Use only --title, --body-file, and --base."
    ;;
  status | findings)
    [ -z "$TITLE$BODY_FILE$BASE_REF$COMMENT_ID$FIX_COMMIT$EXPECTED_HEAD" ] \
      || fail_input "$OPERATION does not accept mutation options" "Pass only PR, --project, and --json."
    ;;
  respond)
    [ -z "$TITLE$BASE_REF$EXPECTED_HEAD" ] \
      || fail_input "respond received an option for another operation" "Use only --comment-id, --body-file, and --fix-commit."
    ;;
  merge)
    [ -z "$TITLE$BODY_FILE$BASE_REF$COMMENT_ID$FIX_COMMIT" ] \
      || fail_input "merge received an option for another operation" "Use only --head."
    ;;
esac

if [ -n "$PROJECT_ARG" ]; then
  PROJECT_ROOT="$(cd "$PROJECT_ARG" 2>/dev/null && pwd -P)" \
    || fail_input "project directory does not exist: $PROJECT_ARG" "Pass an existing Git repository with --project."
else
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || fail_input "not inside a Git repository" "Run from a repository or pass --project DIR."
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
fi
[ -z "$BODY_FILE" ] || BODY_FILE="$(absolute_input_file "$BODY_FILE")"

git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || fail_input "project is not a Git repository" "Initialize the project before using PR commands."
command -v gh >/dev/null 2>&1 \
  || fail_operation "GitHub CLI is unavailable" "Install and authenticate gh."
gh auth status >/dev/null 2>&1 \
  || fail_operation "GitHub authentication failed" "Run 'gh auth login' and retry."
read_with_retry read_repository \
  || fail_operation "could not resolve the canonical base repository: $READ_OUTPUT" "Verify origin and GitHub access."
IFS="$(printf '\t')" read -r REPO REPO_URL <<<"$READ_OUTPUT"
case "$REPO" in */*) ;; *) fail_operation "GitHub returned an invalid repository identity" "Expected owner/name, got '$REPO'." ;; esac
case "$REPO_URL" in
  http://* | https://*)
    REPO_HOST="${REPO_URL#*://}"
    REPO_HOST="${REPO_HOST%%/*}"
    ;;
  *) fail_operation "GitHub returned an invalid repository URL" "Expected an HTTP(S) repository URL, got '$REPO_URL'." ;;
esac
REPO_SPEC="$REPO_HOST/$REPO"

emit_open_result() {
  local state="$1" number="$2" url="$3" head="$4" request="$5"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"open","status":"%s","pullRequest":%s,"url":' "$OUTPUT_SCHEMA" "$state" "$number"
    json_string "$url"
    printf ',"head":'
    json_string "$head"
    printf ',"reviewRequest":'
    json_string "$request"
    printf '}\n'
  else
    printf 'PR #%s: %s\n  url: %s\n  head: %s\n  review request: %s\n' \
      "$number" "$state" "$url" "$head" "$request"
  fi
}

open_pr() {
  local branch local_head remote_line remote_head rows count number url pr_head pr_base pr_base_sha create_output create_status=0
  local request_marker request_head_marker comment_rows existing_request moved_request request_body request_url request_rows state
  [ -n "$TITLE" ] || fail_input "open requires --title" "Pass the PR title explicitly."
  [ -f "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
    || fail_input "open requires a non-empty --body-file" "Put the reviewed PR description in that file."
  branch="$(git -C "$PROJECT_ROOT" branch --show-current)" \
    || fail_operation "could not read the current branch" "Repair the local Git checkout."
  [ -n "$branch" ] || fail_input "detached HEAD cannot open a PR" "Create or switch to a feature branch."
  local_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  remote_line="$(git -C "$PROJECT_ROOT" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null)" \
    || fail_operation "could not read origin/$branch" "Push the branch and verify remote access."
  remote_head="${remote_line%%[[:space:]]*}"
  [ -n "$remote_head" ] || fail_input "origin/$branch does not exist" "Run 'git push -u origin HEAD' first."
  [ "$local_head" = "$remote_head" ] || fail_input "local and remote heads differ" "Push the current head, then retry."
  if [ -z "$BASE_REF" ]; then
    BASE_REF="$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    BASE_REF="${BASE_REF#origin/}"
  fi
  [ -n "$BASE_REF" ] || fail_input "default base branch is unknown" "Pass --base BRANCH or set origin/HEAD."
  [ "$branch" != "$BASE_REF" ] \
    || fail_input "cannot open a pull request from the default branch '$branch'" \
      "Create and push a feature branch first."

  read_with_retry gh pr list --repo "$REPO_SPEC" --state open --head "$branch" --limit 100 \
    --json number,url,headRefOid,baseRefName,baseRefOid \
    --jq '.[] | [.number,.url,.headRefOid,.baseRefName,.baseRefOid] | @tsv' \
    || fail_operation "could not inspect existing pull requests: $READ_OUTPUT" "Retry after GitHub recovers."
  rows="$READ_OUTPUT"
  count="$(printf '%s\n' "$rows" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -le 1 ] || fail_operation "multiple open pull requests use branch '$branch'" "Close or retarget duplicates."
  if [ "$count" -eq 0 ]; then
    create_output="$(cd "$PROJECT_ROOT" && gh pr create --repo "$REPO_SPEC" --head "$branch" --base "$BASE_REF" \
      --title "$TITLE" --body-file "$BODY_FILE" 2>&1)" || create_status=$?
    read_with_retry gh pr list --repo "$REPO_SPEC" --state open --head "$branch" --limit 100 \
      --json number,url,headRefOid,baseRefName,baseRefOid \
      --jq '.[] | [.number,.url,.headRefOid,.baseRefName,.baseRefOid] | @tsv' \
      || fail_operation "PR creation could not be reconciled: $READ_OUTPUT" "Inspect GitHub before retrying."
    rows="$READ_OUTPUT"
    count="$(printf '%s\n' "$rows" | awk 'NF { count++ } END { print count + 0 }')"
    [ "$count" -eq 1 ] \
      || fail_operation "PR creation was not verified (exit $create_status): $create_output" "Inspect GitHub before retrying."
    state=opened
  else
    state=existing
  fi
  IFS="$(printf '\t')" read -r number url pr_head pr_base pr_base_sha <<<"$rows"
  [ "$pr_head" = "$local_head" ] \
    || fail_input "PR head $pr_head does not match local/remote head $local_head" "Refresh the PR branch before review."
  [ "$pr_base" = "$BASE_REF" ] \
    || fail_input "PR base $pr_base does not match requested base $BASE_REF" "Pass the live base or retarget the PR explicitly."
  [ -n "$pr_base_sha" ] \
    || fail_operation "GitHub returned no base SHA for PR #$number" "Retry after GitHub returns the complete PR binding."
  request_marker="<!-- touchstone:pr-open head=$local_head base=$pr_base base_sha=$pr_base_sha -->"
  request_head_marker="<!-- touchstone:pr-open head=$local_head "
  read_with_retry gh api --paginate --hostname "$REPO_HOST" "repos/$REPO/issues/$number/comments" \
    --jq '.[] | [.html_url, (.body // "")] | @tsv' \
    || fail_operation "could not inspect prior review requests: $READ_OUTPUT" "Retry without posting a duplicate."
  comment_rows="$READ_OUTPUT"
  existing_request="$(printf '%s\n' "$comment_rows" | awk -F '\t' -v marker="$request_marker" \
    'index($2, marker) { print $1 }')"
  if [ -n "$existing_request" ]; then
    request_url="$(printf '%s\n' "$existing_request" | sed -n '1p')"
    emit_open_result "$state" "$number" "$url" "$local_head" "existing:$request_url"
    return 0
  fi
  moved_request="$(printf '%s\n' "$comment_rows" | awk -F '\t' -v marker="$request_head_marker" \
    'index($2, marker) { print $1 }')"
  [ -z "$moved_request" ] \
    || fail_input "this head already has a review request for different base coordinates" \
      "Wait for that request to finish, then integrate or use the documented raw recovery path."
  request_body="@codex review

$request_marker"
  if capture_command gh pr comment "$number" --repo "$REPO_SPEC" --body "$request_body"; then
    request_url="$CAPTURE_OUTPUT"
  else
    fail_operation "could not post the review request: $CAPTURE_ERROR" "Inspect comments before retrying."
  fi
  read_with_retry gh api --paginate --hostname "$REPO_HOST" "repos/$REPO/issues/$number/comments" \
    --jq '.[] | [.html_url, (.body // "")] | @tsv' \
    || fail_operation "review request returned $request_url but its surviving state could not be read: $READ_OUTPUT" \
      "Inspect comments before retrying."
  request_rows="$READ_OUTPUT"
  printf '%s\n' "$request_rows" | awk -F '\t' -v url="$request_url" -v marker="$request_marker" \
    '$1 == url && index($2, marker) { found=1 } END { exit !found }' \
    || fail_operation "review request returned $request_url but was not verified" \
      "Inspect comments before retrying; a rerun will reuse a surviving exact-binding request."
  emit_open_result "$state" "$number" "$url" "$local_head" "posted:$request_url"
}

read_pr_row() {
  read_with_retry gh pr view "$PR_NUMBER" --repo "$REPO_SPEC" \
    --json number,state,url,headRefOid,baseRefName,baseRefOid,mergeStateStatus,isDraft \
    --jq '[.number,.state,.url,.headRefOid,.baseRefName,.baseRefOid,.mergeStateStatus,.isDraft] | @tsv' \
    || fail_operation "could not read PR #$PR_NUMBER: $READ_OUTPUT" "Verify the PR and GitHub access."
  PR_ROW="$READ_OUTPUT"
}

status_pr() {
  local number state url head base base_sha merge_state draft
  read_pr_row
  IFS="$(printf '\t')" read -r number state url head base base_sha merge_state draft <<<"$PR_ROW"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"status","status":"observed","pullRequest":%s,"state":' "$OUTPUT_SCHEMA" "$number"
    json_string "$state"
    printf ',"url":'
    json_string "$url"
    printf ',"head":'
    json_string "$head"
    printf ',"baseRef":'
    json_string "$base"
    printf ',"baseSha":'
    json_string "$base_sha"
    printf ',"mergeState":'
    json_string "$merge_state"
    printf ',"draft":%s}\n' "$draft"
  else
    printf 'PR #%s: %s\n  url: %s\n  head: %s\n  base: %s at %s\n  merge state: %s\n  draft: %s\n' \
      "$number" "$state" "$url" "$head" "$base" "$base_sha" "$merge_state" "$draft"
  fi
}

findings_pr() {
  local query threads reviews
  # shellcheck disable=SC2016 # GraphQL variable references are intentionally literal.
  query='query($endCursor: String, $owner: String!, $name: String!, $pr: Int!) { repository(owner:$owner,name:$name) { pullRequest(number:$pr) { reviewThreads(first:100,after:$endCursor) { nodes { id isResolved comments(first:1) { nodes { databaseId path body url } } } pageInfo { hasNextPage endCursor } } } } }'
  read_with_retry gh api graphql --hostname "$REPO_HOST" --paginate --slurp \
    -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F pr="$PR_NUMBER" -f query="$query" \
    --jq '[.[] | .data.repository.pullRequest.reviewThreads.nodes[] | {threadId:.id,resolved:.isResolved,commentId:.comments.nodes[0].databaseId,path:(.comments.nodes[0].path // null),body:.comments.nodes[0].body,url:.comments.nodes[0].url}]' \
    || fail_operation "could not read paginated review threads: $READ_OUTPUT" "Retry after GitHub recovers."
  threads="$READ_OUTPUT"
  read_with_retry gh api --paginate --hostname "$REPO_HOST" --slurp "repos/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" \
    --jq '[.[][] | select((.body // "") != "") | {reviewId:.id,state:.state,body:.body,url:.html_url,commit:.commit_id}]' \
    || fail_operation "could not read paginated review bodies: $READ_OUTPUT" "Retry after GitHub recovers."
  reviews="$READ_OUTPUT"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"findings","status":"observed","pullRequest":%s,"threads":%s,"reviews":%s}\n' \
      "$OUTPUT_SCHEMA" "$PR_NUMBER" "$threads" "$reviews"
  else
    printf 'PR #%s findings\n' "$PR_NUMBER"
    read_with_retry gh api graphql --hostname "$REPO_HOST" --paginate --slurp \
      -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F pr="$PR_NUMBER" -f query="$query" \
      --jq '.[] | .data.repository.pullRequest.reviewThreads.nodes[] | "  thread \(.comments.nodes[0].databaseId) [resolved=\(.isResolved)] \(.comments.nodes[0].path // \"-\")\n    \(.comments.nodes[0].body)\n    \(.comments.nodes[0].url)"' \
      || fail_operation "could not render review threads: $READ_OUTPUT" "Retry after GitHub recovers."
    [ -z "$READ_OUTPUT" ] || printf '%s\n' "$READ_OUTPUT"
    read_with_retry gh api --paginate --hostname "$REPO_HOST" --slurp "repos/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" \
      --jq '.[][] | select((.body // "") != "") | "  review \(.id) [\(.state)] at \(.commit_id)\n    \(.body)\n    \(.html_url)"' \
      || fail_operation "could not render review bodies: $READ_OUTPUT" "Retry after GitHub recovers."
    [ -z "$READ_OUTPUT" ] || printf '%s\n' "$READ_OUTPUT"
  fi
}

respond_pr() {
  local output status=0
  local -a args
  [ -n "$COMMENT_ID" ] || fail_input "respond requires --comment-id" "Pass the root review comment ID."
  [ -f "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
    || fail_input "respond requires a non-empty --body-file" "Write the reply to a file."
  case "$COMMENT_ID" in *[!0-9]*) fail_input "comment ID must be numeric" "Pass a database ID." ;; esac
  args=("$PR_NUMBER" --comment-id "$COMMENT_ID" --body-file "$BODY_FILE")
  if [ -n "$FIX_COMMIT" ]; then args+=(--fix-commit "$FIX_COMMIT"); fi
  output="$(cd "$PROJECT_ROOT" && bash "$SCRIPT_ROOT/scripts/respond-review.sh" "${args[@]}" 2>&1)" || status=$?
  if [ "$status" -ne 0 ]; then
    emit_error "$output" "Inspect the review thread before retrying."
    exit "$status"
  fi
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"respond","status":"verified","pullRequest":%s,"commentId":%s,"detail":' \
      "$OUTPUT_SCHEMA" "$PR_NUMBER" "$COMMENT_ID"
    json_string "$output"
    printf '}\n'
  else
    printf '%s\n' "$output"
  fi
}

merge_pr() {
  local number state url head base base_sha merge_state draft merge_output merge_status=0
  local final_row
  read_pr_row
  IFS="$(printf '\t')" read -r number state url head base base_sha merge_state draft <<<"$PR_ROW"
  if [ -n "$EXPECTED_HEAD" ] && [ "$EXPECTED_HEAD" != "$head" ]; then
    fail_input "expected head $EXPECTED_HEAD but PR #$PR_NUMBER is at $head" "Re-review the live head."
  fi
  EXPECTED_HEAD="$head"
  if [ "$state" = MERGED ]; then
    final_state=already-merged
  else
    [ "$state" = OPEN ] || fail_input "PR #$PR_NUMBER is $state" "Only an open or merged PR is supported."
    merge_output="$(cd "$PROJECT_ROOT" && gh pr merge "$PR_NUMBER" --repo "$REPO_SPEC" --squash \
      --match-head-commit "$EXPECTED_HEAD" 2>&1)" || merge_status=$?
    read_with_retry gh pr view "$PR_NUMBER" --repo "$REPO_SPEC" --json state,url --jq '[.state,.url] | @tsv' \
      || fail_operation "merge returned $merge_status and final state could not be read: $READ_OUTPUT" "Inspect GitHub."
    final_row="$READ_OUTPUT"
    IFS="$(printf '\t')" read -r state _ <<<"$final_row"
    [ "$state" = MERGED ] \
      || fail_operation "GitHub did not merge PR #$PR_NUMBER: $merge_output" "The repository ruleset remains authoritative."
    final_state=merged
  fi
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"merge","status":"%s","pullRequest":%s,"head":' \
      "$OUTPUT_SCHEMA" "$final_state" "$PR_NUMBER"
    json_string "$EXPECTED_HEAD"
    printf '}\n'
  else
    printf 'PR #%s: %s at %s\n' "$PR_NUMBER" "$final_state" "$EXPECTED_HEAD"
  fi
}

case "$OPERATION" in
  open) open_pr ;;
  status) status_pr ;;
  findings) findings_pr ;;
  respond) respond_pr ;;
  merge) merge_pr ;;
esac
