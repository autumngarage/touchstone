#!/usr/bin/env bash
# scripts/touchstone-pr.sh — narrow, versioned PR delivery operations.

set -euo pipefail

OUTPUT_SCHEMA="touchstone.pr/v1"
READ_ATTEMPTS="${TOUCHSTONE_READ_ATTEMPTS:-3}"
RETRY_DELAY="${TOUCHSTONE_RETRY_DELAY:-2}"
# A review-gate run takes a minute or two; waiting for one before re-running
# it has its own budget, separate from transport retries.
GATE_ATTEMPTS="${TOUCHSTONE_GATE_ATTEMPTS:-60}"
GATE_RETRY_DELAY="${TOUCHSTONE_GATE_RETRY_DELAY:-5}"
REQUEST_ATTEMPTS="${TOUCHSTONE_REQUEST_ATTEMPTS:-15}"
JSON_MODE=false
PROJECT_ARG=""
TITLE=""
BODY_FILE=""
BASE_REF=""
EXPECTED_HEAD=""
EXPECTED_BRANCH=""
OPERATION="${1:-}"
PR_NUMBER=""
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
case "$REQUEST_ATTEMPTS" in '' | *[!0-9]* | 0)
  echo "ERROR: TOUCHSTONE_REQUEST_ATTEMPTS must be a positive integer" >&2
  exit 2
  ;;
esac

usage() {
  cat >&2 <<'EOF'
Usage:
  touchstone pr open --title TITLE --body-file FILE [--base BRANCH]
                     [--expect-branch BRANCH] [--project DIR] [--json]
  touchstone pr status PR [--project DIR] [--json]
  touchstone pr merge PR --head SHA [--project DIR] [--json]
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

# Every project Git read goes through here. #920 sanitized the resolver, but
# each later read still followed ambient GIT_DIR/GIT_WORK_TREE, so with those
# exported -- as hooks and some CIs do -- `--project A` reported B's branch
# and B's head one line after the resolver had ruled B out.
project_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git -C "$PROJECT_ROOT" "$@"
}

read_repository() {
  (
    unset GH_REPO GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    cd "$PROJECT_ROOT"
    gh repo view --json nameWithOwner,url,defaultBranchRef \
      --jq '[.nameWithOwner,.url,.defaultBranchRef.name] | @tsv'
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
  status | merge)
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
    --expect-branch)
      require_option_value "$@"
      EXPECTED_BRANCH="$2"
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
    [ -z "$EXPECTED_HEAD" ] \
      || fail_input "open received an option for another operation" "Use only --title, --body-file, --base, and --expect-branch."
    ;;
  status)
    [ -z "$TITLE$BODY_FILE$BASE_REF$EXPECTED_HEAD$EXPECTED_BRANCH" ] \
      || fail_input "$OPERATION does not accept mutation options" "Pass only PR, --project, and --json."
    ;;
  merge)
    [ -z "$TITLE$BODY_FILE$BASE_REF$EXPECTED_BRANCH" ] \
      || fail_input "merge received an option for another operation" "Use only --head."
    ;;
esac

# Resolve --project to the repository root, matching the implicit path and
# `touchstone adopt`. Canonicalizing the passed directory alone made
# `--project sub` and `cd sub` select different roots for the same command.
#
# Deliberately inline rather than shared: the organization-required workflow
# fetches this file alone from raw.githubusercontent.com into RUNNER_TEMP and
# runs it there, so a `source` of anything under scripts/lib/ would break the
# required check in every consumer. tests/test-project-root.sh asserts the four
# entrypoints agree, which is the contract that actually matters.
#
# A non-repository directory keeps its own path here and is refused by the
# existing work-tree check below, preserving this command's error schema.
if [ -n "$PROJECT_ARG" ]; then
  PROJECT_ROOT="$(cd "$PROJECT_ARG" 2>/dev/null && pwd -P)" \
    || fail_input "project directory does not exist: $PROJECT_ARG" "Pass an existing Git repository with --project."
else
  # Sanitized like every other project read: this lookup chooses PROJECT_ROOT
  # itself, so ambient GIT_DIR/GIT_WORK_TREE here selects the whole repository
  # the command then operates on -- and --expect-branch would match, because
  # it would be comparing against that same ambient repository's branch.
  PROJECT_ROOT="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git rev-parse --show-toplevel 2>/dev/null)" \
    || fail_input "not inside a Git repository" "Run from a repository or pass --project DIR."
fi
# env -u: an exported GIT_DIR/GIT_WORK_TREE would resolve the ambient
# repository instead of the named one, so --project A could select B.
# The validation contract promises ambient variables cannot select
# another project; enforce that at the resolver.
PROJECT_ROOT="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PROJECT_ROOT")"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
[ -z "$BODY_FILE" ] || BODY_FILE="$(absolute_input_file "$BODY_FILE")"

project_git rev-parse --git-dir >/dev/null 2>&1 \
  || fail_input "project is not a Git repository" "Initialize the project before using PR commands."

# Bind the caller's intent to the resolved branch, the way merge binds --head.
# Without it, open acts on whatever branch the invoking directory happens to
# have checked out -- a different branch per worktree, which is how two pull
# requests were opened for the wrong branch. The check is purely local, so it
# runs before GitHub is consulted: a mismatch costs no network call and no
# partial work.
if [ -n "$EXPECTED_BRANCH" ]; then
  CURRENT_BRANCH="$(project_git branch --show-current)" \
    || fail_operation "could not read the current branch" "Repair the local Git checkout."
  [ "$EXPECTED_BRANCH" = "$CURRENT_BRANCH" ] \
    || fail_input "expected branch $EXPECTED_BRANCH but $PROJECT_ROOT has '${CURRENT_BRANCH:-a detached HEAD}' checked out" \
      "Run from the intended worktree, or point --project at it."
fi
command -v gh >/dev/null 2>&1 \
  || fail_operation "GitHub CLI is unavailable" "Install and authenticate gh."
read_with_retry read_repository \
  || fail_operation "could not resolve the canonical base repository: $READ_OUTPUT" "Verify origin and GitHub access."
IFS="$(printf '\t')" read -r REPO REPO_URL DEFAULT_REF <<<"$READ_OUTPUT"
case "$REPO" in */*) ;; *) fail_operation "GitHub returned an invalid repository identity" "Expected owner/name, got '$REPO'." ;; esac
case "$REPO_URL" in
  http://* | https://*)
    REPO_HOST="${REPO_URL#*://}"
    REPO_HOST="${REPO_HOST%%/*}"
    ;;
  *) fail_operation "GitHub returned an invalid repository URL" "Expected an HTTP(S) repository URL, got '$REPO_URL'." ;;
esac
REPO_SPEC="$REPO_HOST/$REPO"
gh auth status --hostname "$REPO_HOST" >/dev/null 2>&1 \
  || fail_operation "GitHub authentication failed for $REPO_HOST" "Run 'gh auth login --hostname $REPO_HOST' and retry."

# The branch is reported, not just used: the operator's only check against
# acting on the wrong worktree used to be inferring it from the PR URL.
emit_open_result() {
  local state="$1" number="$2" url="$3" head="$4" request="$5" branch="$6"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"open","status":"%s","pullRequest":%s,"url":' "$OUTPUT_SCHEMA" "$state" "$number"
    json_string "$url"
    printf ',"branch":'
    json_string "$branch"
    printf ',"head":'
    json_string "$head"
    printf ',"reviewRequest":'
    json_string "$request"
    printf '}\n'
  else
    printf 'PR #%s: %s\n  url: %s\n  branch: %s\n  head: %s\n  review request: %s\n' \
      "$number" "$state" "$url" "$branch" "$head" "$request"
  fi
}

# Where the repository requires the pinned review-gate workflow, a new
# request or answer is evidence the gate has not seen: required workflows run
# only on pull-request and merge-queue events, so the driver asks GitHub to
# re-run the gate's run for this head. The driver can request an evaluation;
# it cannot set the result. Detection reads the effective ruleset, not the
# run list, so a run that has not appeared yet is never mistaken for the
# absence of the gate. A run still in progress is waited for, then re-run:
# it may have read the evidence before the request landed.
REVIEW_GATE_RUN_ID=""
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

review_gate_required() {
  local base_ref="$1" encoded
  encoded="$(uri_encode "$base_ref")"
  read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/rules/branches/$encoded" \
    --jq '[.[] | select(.type == "workflows") | .parameters.workflows[]?.path] | any(. == ".github/workflows/review-gate.yml")' \
    || fail_operation "could not read the effective rules for $base_ref: $READ_OUTPUT" "Retry after GitHub recovers."
  [ "$READ_OUTPUT" = true ]
}

rerun_review_gate() {
  local number="$1" head="$2" attempt=1 run_id status
  while :; do
    # Scoped to this pull request: two open PRs can share a head SHA, and
    # re-running the other one's gate would prove nothing about this request.
    read_with_retry gh api --hostname "$REPO_HOST" \
      "repos/$REPO/actions/runs?head_sha=$head&per_page=100" \
      --jq "[.workflow_runs[] | select(.name == \"review-gate\" and (.event == \"pull_request\" or .event == \"merge_group\") and any(.pull_requests[]?; .number == $number))] | sort_by(.id) | last | \"\(.id // \"\") \(.status // \"\")\"" \
      || fail_operation "could not inspect review-gate runs for $head: $READ_OUTPUT" "Retry after GitHub recovers."
    read -r run_id status <<<"$READ_OUTPUT"
    if [ -n "$run_id" ] && [ "$status" = completed ]; then
      # A re-run keeps the run id and increments run_attempt; record the
      # attempt being superseded so a stale read cannot pass off the old
      # verdict as the new one.
      read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/actions/runs/$run_id" --jq '.run_attempt' \
        || fail_operation "could not read review-gate run $run_id: $READ_OUTPUT" "Retry after GitHub recovers."
      REVIEW_GATE_PRIOR_ATTEMPT="$READ_OUTPUT"
      gh api --hostname "$REPO_HOST" -X POST "repos/$REPO/actions/runs/$run_id/rerun" >/dev/null 2>&1 \
        || fail_operation "could not re-run review-gate run $run_id" "Re-run it from the Actions tab, then retry."
      REVIEW_GATE_RUN_ID="$run_id"
      return 0
    fi
    [ "$attempt" -lt "$GATE_ATTEMPTS" ] \
      || fail_operation "review-gate run for $head did not reach a re-runnable state within $((GATE_ATTEMPTS * GATE_RETRY_DELAY))s (last: ${run_id:-none} ${status:-absent})" "Wait for the gate run to finish, then re-run this command."
    [ "$JSON_MODE" = true ] || printf 'Review gate run %s; retrying in %ss.\n' "${status:-not yet present}" "$GATE_RETRY_DELAY" >&2
    attempt=$((attempt + 1))
    sleep "$GATE_RETRY_DELAY"
  done
}

# Re-run the pinned gate on current evidence and wait for its verdict. A
# required workflow cannot see a review that lands after the request, so
# merge asks for one evaluation of what is on the PR now before enqueueing.
refresh_review_gate_before_merge() {
  local number="$1" head="$2" attempt=1 run_id status conclusion
  rerun_review_gate "$number" "$head"
  run_id="$REVIEW_GATE_RUN_ID"
  while :; do
    read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/actions/runs/$run_id" \
      --jq '"\(.status) \(.conclusion // "") \(.run_attempt)"' \
      || fail_operation "could not read review-gate run $run_id: $READ_OUTPUT" "Retry after GitHub recovers."
    read -r status conclusion attempt_seen <<<"$READ_OUTPUT"
    # Only the attempt after the re-run counts; a stale read still shows the
    # superseded attempt as completed.
    if [ "$status" = completed ] && [ "${attempt_seen:-0}" -gt "${REVIEW_GATE_PRIOR_ATTEMPT:-0}" ]; then
      [ "$conclusion" = success ] \
        || fail_operation "review-gate run $run_id concluded $conclusion on current evidence" "Answer the open findings or request a fresh review, then retry."
      [ "$JSON_MODE" = true ] || printf 'Review gate run %s passed on current evidence.\n' "$run_id" >&2
      return 0
    fi
    [ "$attempt" -lt "$GATE_ATTEMPTS" ] \
      || fail_operation "review-gate run $run_id did not complete within $((GATE_ATTEMPTS * GATE_RETRY_DELAY))s" "Wait for it in the Actions tab, then retry."
    [ "$JSON_MODE" = true ] || printf 'Review gate run %s %s; retrying in %ss.\n' "$run_id" "$status" "$GATE_RETRY_DELAY" >&2
    attempt=$((attempt + 1))
    sleep "$GATE_RETRY_DELAY"
  done
}

verify_live_head_and_base_ref() {
  local number="$1" head="$2" base_ref="$3" live_head live_base
  read_with_retry gh pr view "$number" --repo "$REPO_SPEC" --json headRefOid,baseRefName \
    --jq '[.headRefOid,.baseRefName] | @tsv' \
    || fail_operation "could not re-read PR coordinates: $READ_OUTPUT" "Inspect GitHub before retrying."
  IFS="$(printf '\t')" read -r live_head live_base <<<"$READ_OUTPUT"
  [ "$live_head" = "$head" ] && [ "$live_base" = "$base_ref" ] \
    || fail_input "PR #$number moved (head $live_head on $live_base) while the review gate re-ran" "Re-review the live head, then retry."
}

verify_live_coordinates() {
  local number="$1" head="$2" base_ref="$3" base_sha="$4" live_row live_head live_base live_base_sha
  read_with_retry gh pr view "$number" --repo "$REPO_SPEC" \
    --json headRefOid,baseRefName,baseRefOid \
    --jq '[.headRefOid,.baseRefName,.baseRefOid] | @tsv' \
    || fail_operation "could not re-read review coordinates: $READ_OUTPUT" "Inspect GitHub before retrying."
  live_row="$READ_OUTPUT"
  IFS="$(printf '\t')" read -r live_head live_base live_base_sha <<<"$live_row"
  [ "$live_head" = "$head" ] && [ "$live_base" = "$base_ref" ] && [ "$live_base_sha" = "$base_sha" ] \
    || fail_input "PR coordinates moved before the review request was bound" "Push or integrate the live head/base, then request review once for that binding."
}

wait_for_request_binding() {
  local number="$1" head="$2" base_ref="$3" base_sha="$4" request_url="$5"
  local comment_id base_ref_hash description attempt=1 live_comment live_row live_head live_base live_base_sha marker
  if review_gate_required "$base_ref"; then
    rerun_review_gate "$number" "$head"
    verify_live_coordinates "$number" "$head" "$base_ref" "$base_sha"
    [ "$JSON_MODE" = true ] || printf 'Review gate re-run requested for run %s.\n' "$REVIEW_GATE_RUN_ID" >&2
    return 0
  fi
  comment_id="${request_url##*issuecomment-}"
  case "$comment_id" in '' | *[!0-9]*) fail_operation "review request URL has no stable comment ID: $request_url" "Inspect the surviving request comment." ;; esac
  base_ref_hash="$(printf '%s' "$base_ref" | git hash-object --stdin)" \
    || fail_operation "could not hash the review base ref" "Repair the local Git installation."
  description="v1 p=$number r=$base_ref_hash b=$base_sha c=$comment_id"
  while :; do
    read_with_retry gh api --paginate --hostname "$REPO_HOST" \
      "repos/$REPO/commits/$head/statuses?per_page=100" \
      --jq ".[] | select(.context == \"touchstone/review-request-v1\" and .state == \"success\" and (.creator.login // \"\") == \"github-actions[bot]\" and .description == \"$description\") | .id" \
      || fail_operation "could not inspect the review-request binding: $READ_OUTPUT" "Retry after GitHub recovers."
    marker="$READ_OUTPUT"
    if [ -n "$marker" ]; then
      read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/issues/comments/$comment_id" \
        --jq 'select(((.author_association // "") == "OWNER" or (.author_association // "") == "MEMBER" or (.author_association // "") == "COLLABORATOR") and ((.body // "") | test("^[[:space:]]*@codex[[:space:]]+review([[:space:]]|$)"; "i"))) | .id' \
        || fail_operation "could not re-read review request comment $comment_id: $READ_OUTPUT" "Inspect GitHub before retrying."
      live_comment="$READ_OUTPUT"
      [ "$live_comment" = "$comment_id" ] \
        || fail_operation "review request comment $comment_id is no longer a valid driver request" "Post a fresh exact-head review request."
      read_with_retry gh pr view "$number" --repo "$REPO_SPEC" \
        --json headRefOid,baseRefName,baseRefOid \
        --jq '[.headRefOid,.baseRefName,.baseRefOid] | @tsv' \
        || fail_operation "could not re-read review coordinates: $READ_OUTPUT" "Inspect GitHub before retrying."
      live_row="$READ_OUTPUT"
      IFS="$(printf '\t')" read -r live_head live_base live_base_sha <<<"$live_row"
      [ "$live_head" = "$head" ] && [ "$live_base" = "$base_ref" ] && [ "$live_base_sha" = "$base_sha" ] \
        || fail_input "PR coordinates moved before the review request was bound" "Push or integrate the live head/base, then request review once for that binding."
      return 0
    fi
    [ "$attempt" -lt "$REQUEST_ATTEMPTS" ] \
      || fail_operation "review request comment $comment_id has no matching server binding" "Inspect the review-binding workflow before retrying."
    [ "$JSON_MODE" = true ] || printf 'Review binding pending; retrying in %ss.\n' "$RETRY_DELAY" >&2
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY"
  done
}

open_pr() {
  local branch local_head remote_line remote_head rows count number url pr_head pr_base pr_base_sha create_output create_status=0
  local request_marker request_head_marker comment_rows existing_request moved_request request_body request_url request_rows state request_author
  [ -n "$TITLE" ] || fail_input "open requires --title" "Pass the PR title explicitly."
  [ -f "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
    || fail_input "open requires a non-empty --body-file" "Put the reviewed PR description in that file."
  branch="$(project_git branch --show-current)" \
    || fail_operation "could not read the current branch" "Repair the local Git checkout."
  [ -n "$branch" ] || fail_input "detached HEAD cannot open a PR" "Create or switch to a feature branch."
  # Re-checked here, not only up front: the repository and authentication
  # reads sit between the two, and a worktree that changed branches in that
  # window would otherwise pass the early check and be mutated anyway --
  # exactly the wrong-branch pull request this option exists to prevent.
  [ -z "$EXPECTED_BRANCH" ] || [ "$EXPECTED_BRANCH" = "$branch" ] \
    || fail_input "expected branch $EXPECTED_BRANCH but $PROJECT_ROOT now has '$branch' checked out" \
      "The checkout changed while the command was running; retry from a settled worktree."
  local_head="$(project_git rev-parse HEAD)"
  remote_line="$(project_git ls-remote --heads origin "refs/heads/$branch" 2>/dev/null)" \
    || fail_operation "could not read origin/$branch" "Push the branch and verify remote access."
  remote_head="${remote_line%%[[:space:]]*}"
  [ -n "$remote_head" ] || fail_input "origin/$branch does not exist" "Run 'git push -u origin HEAD' first."
  [ "$local_head" = "$remote_head" ] || fail_input "local and remote heads differ" "Push the current head, then retry."
  [ -n "$DEFAULT_REF" ] || fail_operation "GitHub returned no default branch" "Set the repository's default branch before opening a pull request."
  [ "$branch" != "$DEFAULT_REF" ] \
    || fail_input "cannot open a pull request from the default branch '$branch'" \
      "Create and push a feature branch first."
  if [ -z "$BASE_REF" ]; then
    BASE_REF="$DEFAULT_REF"
  fi

  read_with_retry gh pr list --repo "$REPO_SPEC" --state open --head "$branch" --limit 100 \
    --json number,url,headRefOid,baseRefName,baseRefOid \
    --jq '.[] | [.number,.url,.headRefOid,.baseRefName,.baseRefOid] | @tsv' \
    || fail_operation "could not inspect existing pull requests: $READ_OUTPUT" "Retry after GitHub recovers."
  rows="$READ_OUTPUT"
  count="$(printf '%s\n' "$rows" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -le 1 ] || fail_operation "multiple open pull requests use branch '$branch'" "Close or retarget duplicates."
  if [ "$count" -eq 0 ]; then
    create_output="$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE && cd "$PROJECT_ROOT" && gh pr create --repo "$REPO_SPEC" --head "$branch" --base "$BASE_REF" \
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
  read_with_retry gh api user --hostname "$REPO_HOST" --jq '.login' \
    || fail_operation "could not resolve the authenticated user: $READ_OUTPUT" "Verify authentication for $REPO_HOST."
  request_author="$READ_OUTPUT"
  [ -n "$request_author" ] \
    || fail_operation "GitHub returned no authenticated login" "Re-authenticate to $REPO_HOST."
  read_with_retry gh api --paginate --hostname "$REPO_HOST" "repos/$REPO/issues/$number/comments" \
    --jq '.[] | [.html_url, (.user.login // ""), (.body // "")] | @tsv' \
    || fail_operation "could not inspect prior review requests: $READ_OUTPUT" "Retry without posting a duplicate."
  comment_rows="$READ_OUTPUT"
  existing_request="$(printf '%s\n' "$comment_rows" | awk -F '\t' -v marker="$request_marker" -v author="$request_author" \
    '$2 == author && index($3, "@codex review") && index($3, marker) { print $1 }')"
  if [ -n "$existing_request" ]; then
    request_url="$(printf '%s\n' "$existing_request" | sed -n '1p')"
    wait_for_request_binding "$number" "$local_head" "$pr_base" "$pr_base_sha" "$request_url"
    emit_open_result "$state" "$number" "$url" "$local_head" "existing:$request_url" "$branch"
    return 0
  fi
  moved_request="$(printf '%s\n' "$comment_rows" | awk -F '\t' -v marker="$request_head_marker" -v author="$request_author" \
    '$2 == author && index($3, "@codex review") && index($3, marker) { print $1 }')"
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
    --jq '.[] | [.html_url, (.user.login // ""), (.body // "")] | @tsv' \
    || fail_operation "review request returned $request_url but its surviving state could not be read: $READ_OUTPUT" \
      "Inspect comments before retrying."
  request_rows="$READ_OUTPUT"
  printf '%s\n' "$request_rows" | awk -F '\t' -v url="$request_url" -v marker="$request_marker" -v author="$request_author" \
    '$1 == url && $2 == author && index($3, "@codex review") && index($3, marker) { found=1 } END { exit !found }' \
    || fail_operation "review request returned $request_url but was not verified" \
      "Inspect comments before retrying; a rerun will reuse a surviving exact-binding request."
  wait_for_request_binding "$number" "$local_head" "$pr_base" "$pr_base_sha" "$request_url"
  emit_open_result "$state" "$number" "$url" "$local_head" "posted:$request_url" "$branch"
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

merge_pr() {
  local number state url head base base_sha merge_state draft merge_output merge_status=0
  local merge_diagnostic final_state final_row final_head auto_merge queue_state
  [ -n "$EXPECTED_HEAD" ] \
    || fail_input "merge requires --head SHA" "Pass the exact reviewed head from GitHub."
  read_pr_row
  IFS="$(printf '\t')" read -r number state url head base base_sha merge_state draft <<<"$PR_ROW"
  [ "$EXPECTED_HEAD" = "$head" ] \
    || fail_input "expected head $EXPECTED_HEAD but PR #$PR_NUMBER is at $head" "Re-review the live head."
  if [ "$state" = MERGED ]; then
    final_state=already-merged
  else
    [ "$state" = OPEN ] || fail_input "PR #$PR_NUMBER is $state" "Only an open or merged PR is supported."
    if review_gate_required "$base"; then
      refresh_review_gate_before_merge "$number" "$head"
      # The wait can be minutes. The head and the base *ref* must still be
      # live; the base *tip* may advance underneath -- the gate binds by
      # ancestry and the queue validates the merged result.
      verify_live_head_and_base_ref "$number" "$head" "$base"
    fi
    merge_output="$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE && cd "$PROJECT_ROOT" && gh pr merge "$PR_NUMBER" --repo "$REPO_SPEC" --squash \
      --match-head-commit "$EXPECTED_HEAD" 2>&1)" || merge_status=$?
    merge_diagnostic="$(clean_diagnostic "$merge_output")"
    read_with_retry gh api graphql --hostname "$REPO_HOST" \
      -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F pr="$PR_NUMBER" \
      -f query='query($owner: String!, $name: String!, $pr: Int!) { repository(owner:$owner,name:$name) { pullRequest(number:$pr) { state url headRefOid autoMergeRequest { enabledAt } mergeQueueEntry { state } } } }' \
      --jq '[.data.repository.pullRequest.state,.data.repository.pullRequest.url,.data.repository.pullRequest.headRefOid,(.data.repository.pullRequest.autoMergeRequest != null),(.data.repository.pullRequest.mergeQueueEntry.state // "")] | @tsv' \
      || fail_operation "merge returned $merge_status (${merge_diagnostic:-no diagnostic}) and final state could not be read: $READ_OUTPUT" "Inspect GitHub."
    final_row="$READ_OUTPUT"
    IFS="$(printf '\t')" read -r state _ final_head auto_merge queue_state <<<"$final_row"
    [ "$final_head" = "$EXPECTED_HEAD" ] \
      || fail_operation "PR #$PR_NUMBER moved to $final_head during merge reconciliation" "Inspect and review the live head."
    if [ "$state" = MERGED ]; then
      final_state=merged
    elif [ "$state" = OPEN ] && [ -n "$queue_state" ]; then
      final_state=queued
    elif [ "$state" = OPEN ] && [ "$auto_merge" = true ]; then
      final_state=auto-merge-enabled
    else
      fail_operation "GitHub did not accept merge for PR #$PR_NUMBER: $merge_diagnostic" "The repository ruleset remains authoritative."
    fi
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
  merge) merge_pr ;;
esac
