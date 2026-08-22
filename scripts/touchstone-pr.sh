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
UNGUARDED=false
OPERATION="${1:-}"
# The tool's own tree: the checked-in policy there says which repository and
# revision the pinned gates must come from for enforcement to count.
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CANONICAL_POLICY="$TOOL_ROOT/policy/github/touchstone-main.json"
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
  touchstone pr merge PR --head SHA [--unguarded] [--project DIR] [--json]
  touchstone policy status [--base BRANCH] [--project DIR] [--json]
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
  # The scratch file keeps stderr out of the parsed stream (PR #883 found
  # successful reads turning into corrupt data when the two were merged).
  # Where no temporary directory is writable -- a read-only sandbox, where
  # fresh agents run `policy status` and `pr status` -- the read still
  # happens: stdout alone is captured and parsed, and stderr passes through
  # to the terminal instead of being quoted back. The property that matters
  # (diagnostics never enter the data) holds either way.
  if CAPTURE_STDERR_TEMP="$(mktemp "${TMPDIR:-/tmp}/touchstone-pr-read.XXXXXX" 2>/dev/null)"; then
    set +e
    output="$("$@" 2>"$CAPTURE_STDERR_TEMP")"
    status=$?
    set -e
    diagnostic="$(cat "$CAPTURE_STDERR_TEMP")"
    rm -f -- "$CAPTURE_STDERR_TEMP"
    CAPTURE_STDERR_TEMP=""
  else
    CAPTURE_STDERR_TEMP=""
    set +e
    output="$("$@")"
    status=$?
    set -e
    diagnostic="(diagnostics were printed above; no writable temporary directory under ${TMPDIR:-/tmp} to capture them)"
  fi
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
  open | policy-status) shift ;;
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
    --unguarded)
      UNGUARDED=true
      shift
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
      || fail_input "merge received an option for another operation" "Use only --head and --unguarded."
    ;;
  policy-status)
    [ -z "$TITLE$BODY_FILE$EXPECTED_HEAD$EXPECTED_BRANCH" ] && [ "$UNGUARDED" = false ] \
      || fail_input "policy status accepts only --base" "Pass only --base, --project, and --json."
    ;;
esac
[ "$UNGUARDED" = false ] || [ "$OPERATION" = merge ] \
  || fail_input "--unguarded applies to merge only" "Remove --unguarded."

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
BODY_APPLIED=""
emit_open_result() {
  local state="$1" number="$2" url="$3" head="$4" request="$5" branch="$6"
  # On a reused PR, "body" says whether the title/body given now were applied
  # (updated) or already matched (unchanged); a created PR carries the body by
  # construction. Added field: compatible within touchstone.pr/v1.
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"open","status":"%s","pullRequest":%s,"url":' "$OUTPUT_SCHEMA" "$state" "$number"
    json_string "$url"
    printf ',"branch":'
    json_string "$branch"
    printf ',"head":'
    json_string "$head"
    printf ',"reviewRequest":'
    json_string "$request"
    if [ -n "$BODY_APPLIED" ]; then
      printf ',"body":'
      json_string "$BODY_APPLIED"
    fi
    printf '}\n'
  else
    printf 'PR #%s: %s\n  url: %s\n  branch: %s\n  head: %s\n  review request: %s\n' \
      "$number" "$state" "$url" "$branch" "$head" "$request"
    [ -z "$BODY_APPLIED" ] || printf '  body: %s\n' "$BODY_APPLIED"
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

# Whether GitHub Actions can run in this repository at all. A required
# workflow that cannot run reports nothing -- not queued, not failed, absent
# -- and a ruleset that requires it then blocks every merge while looking,
# from the rules alone, fully enforced (AUT-467). Disabled Actions is the
# largest enforcement gap there is, so every assessment reads this first.
actions_enabled() {
  # Reading this setting needs repository administration (read) on the
  # token; a token that cannot read it cannot verify enforcement, and an
  # unverifiable gate is reported as such rather than assumed present.
  read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/actions/permissions" --jq '.enabled' \
    || fail_operation "could not read whether Actions are enabled for $REPO (needs repository administration read on the token): $READ_OUTPUT" "Use a credential that can read repos/$REPO/actions/permissions, or retry after GitHub recovers."
  [ "$READ_OUTPUT" = true ]
}
# The remedy flips only the enabled flag: the repository's configured
# allow-list of actions is its own decision and is left as it was.
actions_disabled_remedy() {
  printf 'enable them: gh api --hostname %s -X PUT repos/%s/actions/permissions -F enabled=true' "$REPO_HOST" "$REPO"
}

# What GitHub enforces on a branch, read once from its effective rules. The
# policy's gates are three pinned required workflows plus the merge queue;
# the native rules that refuse direct delivery complete the set. "applied"
# means all of them; anything less is named, so no agent has to read rulesets
# by hand to learn whether a merge would be gated.
ENFORCEMENT_STATUS=""
ENFORCEMENT_MISSING=""
ENFORCEMENT_POLICY_FILE=""
ENFORCEMENT_EXPECTS_QUEUE=true
read_enforcement() {
  local base_ref="$1" encoded expected
  encoded="$(uri_encode "$base_ref")"
  # The expected pins travel with the tool: a workflow at the right path but
  # from another repository, another ref, or a stale revision is not the
  # canonical gate and is reported as missing with the reason. The policy
  # consulted is the repository's own where the tool ships one (a private
  # consumer derived --no-queue legitimately has no queue), else the
  # canonical one; each gate must have exactly one pin there, or the read
  # fails rather than silently expecting nothing.
  local policy_file="$CANONICAL_POLICY" expect_queue candidate
  candidate="$TOOL_ROOT/policy/github/consumers/${REPO##*/}.json"
  # The shipped consumer policy applies only to the repository it names in
  # full (organization and name); a fork with the same basename gets the
  # canonical expectations, not another repository's.
  if [ "$REPO" != "autumngarage/touchstone" ] && [ -f "$candidate" ] \
    && [ "$(jq -r '"\(.organization)/\(.repository)"' "$candidate")" = "$REPO" ]; then
    policy_file="$candidate"
  fi
  [ -f "$policy_file" ] \
    || fail_operation "the tool's policy file is missing: $policy_file" "Reinstall touchstone."
  expected="$(jq -c '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[] | {path, repository_id, ref, sha}]' "$policy_file")" \
    || fail_operation "could not read the expected workflow pins from $policy_file" "Reinstall touchstone."
  local gate_path
  for gate_path in .github/workflows/validate.yml .github/workflows/review-gate.yml .github/workflows/delivery-evidence.yml; do
    [ "$(printf '%s' "$expected" | jq --arg p "$gate_path" '[.[] | select(.path == $p)] | length')" = 1 ] \
      || fail_operation "$policy_file does not pin exactly one $gate_path" "Reinstall touchstone; the policy file is corrupt or incomplete."
  done
  expect_queue="$(jq -r 'if .managedRepositoryRuleset == null then "false" else "true" end' "$policy_file")"
  ENFORCEMENT_POLICY_FILE="$policy_file"
  ENFORCEMENT_EXPECTS_QUEUE="$expect_queue"
  # Pull requests land through auto-merge in both policy shapes (the queue
  # admits through it; without a queue `merge` arms it), so a repository with
  # it disabled is not fully enforced either.
  read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO" --jq '.allow_auto_merge' \
    || fail_operation "could not read the repository's auto-merge setting: $READ_OUTPUT" "Retry after GitHub recovers."
  local auto_merge_missing=""
  [ "$READ_OUTPUT" = true ] || auto_merge_missing="auto-merge setting"
  # Every page: the endpoint pages at 30 rules and `--paginate` emits one
  # array per page, merged here before evaluation.
  read_with_retry gh api --paginate --hostname "$REPO_HOST" "repos/$REPO/rules/branches/$encoded?per_page=100" \
    || fail_operation "could not read the effective rules for $base_ref: $READ_OUTPUT" "Retry after GitHub recovers."
  ENFORCEMENT_MISSING="$(printf '%s' "$READ_OUTPUT" | jq -s 'add // []' | jq -r --argjson expected "$expected" --argjson expect_queue "$expect_queue" '
      ([.[] | select(.type == "workflows") | .parameters.workflows[]?]) as $w
      | def gate($name; $path):
          ($expected[] | select(.path == $path)) as $e
          | if ($w | map(select(.path == $path)) | length) == 0 then "\($name) workflow"
            elif any($w[]; .path == $path and .repository_id == $e.repository_id and .ref == $e.ref and (.sha | ascii_downcase) == ($e.sha | ascii_downcase)) then empty
            else "\($name) workflow (present but not pinned at the policy revision)" end;
      [
        gate("validate"; ".github/workflows/validate.yml"),
        gate("review-gate"; ".github/workflows/review-gate.yml"),
        gate("delivery-evidence"; ".github/workflows/delivery-evidence.yml"),
        (if (any(.[]; .type == "merge_queue") or ($expect_queue | not)) then empty else "merge queue" end),
        (if any(.[]; .type == "pull_request" and (.parameters.required_review_thread_resolution // false) == true) then empty else "pull-request rule (with thread resolution)" end),
        (if any(.[]; .type == "non_fast_forward") then empty else "force-push protection" end),
        (if any(.[]; .type == "deletion") then empty else "deletion protection" end)
      ] | unique | join(",")')" \
    || fail_operation "could not evaluate the effective rules for $base_ref" "Retry after GitHub recovers."
  if [ -n "$auto_merge_missing" ]; then
    ENFORCEMENT_MISSING="${ENFORCEMENT_MISSING:+$ENFORCEMENT_MISSING,}$auto_merge_missing"
  fi
  # Disabled Actions void every required workflow at once, however the rules
  # read: the gap is named first and the status is "none" regardless of what
  # else is present, because nothing listed can run.
  if ! actions_enabled; then
    ENFORCEMENT_MISSING="repository Actions (disabled: no required workflow can run; $(actions_disabled_remedy))${ENFORCEMENT_MISSING:+,$ENFORCEMENT_MISSING}"
    ENFORCEMENT_STATUS=none
    return 0
  fi
  # Everything expected missing is "none": seven items with a queue, six
  # without, plus the auto-merge setting. Counted, not string-compared: jq
  # sorts the names and a name may carry a reason.
  local missing_count expected_count=8
  [ "$expect_queue" = true ] || expected_count=7
  missing_count="$(printf '%s' "$ENFORCEMENT_MISSING" | awk -F',' 'NF { print NF } !NF { print 0 }')"
  if [ -z "$ENFORCEMENT_MISSING" ]; then
    ENFORCEMENT_STATUS=applied
  elif [ "$missing_count" -ge "$expected_count" ]; then
    ENFORCEMENT_STATUS=none
  else
    ENFORCEMENT_STATUS=partial
  fi
}

# The remedy names a file that exists: the canonical policy for Touchstone
# itself, the checked-in consumer policy where one is shipped, otherwise the
# derivation step that creates one for review.
enforcement_remedy() {
  local name="${REPO##*/}"
  if [ "$REPO" = "autumngarage/touchstone" ]; then
    printf 'scripts/github-policy.sh apply policy/github/touchstone-main.json (in the Touchstone checkout), then close/reopen open PRs'
  elif [ -f "$TOOL_ROOT/policy/github/consumers/$name.json" ] \
    && [ "$(jq -r '"\(.organization)/\(.repository)"' "$TOOL_ROOT/policy/github/consumers/$name.json")" = "$REPO" ]; then
    printf 'scripts/github-policy.sh apply policy/github/consumers/%s.json (in the Touchstone checkout), then close/reopen open PRs' "$name"
  elif [ "${REPO%%/*}" = "$(jq -r .organization "$CANONICAL_POLICY")" ]; then
    printf 'derive a consumer policy first: scripts/derive-consumer-policy.sh %s > policy/github/consumers/%s.json, review and merge it, then scripts/github-policy.sh apply it and close/reopen open PRs' "$name" "$name"
  else
    printf 'this tool ships policy for the %s organization only; %s needs its own policy file modelled on policy/github/touchstone-main.json before scripts/github-policy.sh apply' "$(jq -r .organization "$CANONICAL_POLICY")" "$REPO"
  fi
}

enforcement_json() {
  printf '{"status":"%s","missing":[' "$ENFORCEMENT_STATUS"
  local first=true item
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ "$first" = true ] || printf ','
    first=false
    json_string "$item"
  done <<<"$(printf '%s' "$ENFORCEMENT_MISSING" | tr ',' '\n')"
  printf ']}'
}

enforcement_text() {
  if [ -z "$ENFORCEMENT_MISSING" ]; then
    printf 'applied'
  else
    printf '%s (missing: %s)' "$ENFORCEMENT_STATUS" "$(printf '%s' "$ENFORCEMENT_MISSING" | sed 's/,/, /g')"
  fi
}

policy_status() {
  local base_ref="${BASE_REF:-$DEFAULT_REF}"
  read_enforcement "$base_ref"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"policy-status","repository":' "$OUTPUT_SCHEMA"
    json_string "$REPO"
    printf ',"baseRef":'
    json_string "$base_ref"
    printf ',"policy":'
    json_string "${ENFORCEMENT_POLICY_FILE#"$TOOL_ROOT"/}"
    printf ',"enforcement":'
    enforcement_json
    printf '}\n'
  else
    printf 'repository: %s\n  base: %s\n  policy: %s\n  enforcement: %s\n' "$REPO" "$base_ref" "${ENFORCEMENT_POLICY_FILE#"$TOOL_ROOT"/}" "$(enforcement_text)"
    [ -z "$ENFORCEMENT_MISSING" ] || printf '  remedy: %s\n' "$(enforcement_remedy)"
  fi
}

wait_for_new_attempt() {
  local run_id="$1" prior="$2" attempt=1 seen
  while :; do
    read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/actions/runs/$run_id" --jq '.run_attempt' \
      || fail_operation "could not read review-gate run $run_id: $READ_OUTPUT" "Retry after GitHub recovers."
    seen="$READ_OUTPUT"
    case "$seen$prior" in *[!0-9]* | "") fail_operation "review-gate run $run_id reported a non-numeric attempt ('$seen' after '$prior')" "Inspect the run in the Actions tab." ;; esac
    [ "$seen" -le "$prior" ] || return 0
    [ "$attempt" -lt "$GATE_ATTEMPTS" ] \
      || fail_operation "review-gate run $run_id did not start its new attempt within $((GATE_ATTEMPTS * GATE_RETRY_DELAY))s" "Check the Actions tab, then retry."
    attempt=$((attempt + 1))
    sleep "$GATE_RETRY_DELAY"
  done
}

rerun_review_gate() {
  local number="$1" head="$2" attempt=1 run_id status prior_attempt local_workflow_ids
  # A required workflow runs under a workflow id the repository does not list
  # among its own; a repository-local workflow that happens to share the name
  # is listed. Only the unlisted one is the pinned gate.
  # One id per line across pages, folded into a JSON array with awk.
  read_with_retry gh api --hostname "$REPO_HOST" --paginate "repos/$REPO/actions/workflows?per_page=100" \
    --jq '.workflows[].id' \
    || fail_operation "could not list the repository's workflows: $READ_OUTPUT" "Retry after GitHub recovers."
  local_workflow_ids="$(printf '%s\n' "$READ_OUTPUT" | awk 'BEGIN { printf "[" } NF { if (n++) printf ","; printf "%s", $1 } END { printf "]" }')"
  while :; do
    # Scoped to this pull request: two open PRs can share a head SHA, and
    # re-running the other one's gate would prove nothing about this request.
    read_with_retry gh api --hostname "$REPO_HOST" \
      "repos/$REPO/actions/runs?head_sha=$head&per_page=100" \
      --jq "[.workflow_runs[] | select(.name == \"review-gate\" and (.event == \"pull_request\" or .event == \"merge_group\") and any(.pull_requests[]?; .number == $number) and ((.workflow_id as \$w | $local_workflow_ids | index(\$w)) == null))] | sort_by(.id) | last | \"\(.id // \"\") \(.status // \"\")\"" \
      || fail_operation "could not inspect review-gate runs for $head: $READ_OUTPUT" "Retry after GitHub recovers."
    read -r run_id status <<<"$READ_OUTPUT"
    if [ -n "$run_id" ] && [ "$status" = completed ]; then
      # A re-run keeps the run id and increments run_attempt. GitHub can keep
      # exposing the superseded attempt's verdict for a moment after the POST;
      # wait until the new attempt is visible so nothing downstream reads the
      # old one as current. This waits for visibility, never for a verdict.
      read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/actions/runs/$run_id" --jq '.run_attempt' \
        || fail_operation "could not read review-gate run $run_id: $READ_OUTPUT" "Retry after GitHub recovers."
      prior_attempt="$READ_OUTPUT"
      gh api --hostname "$REPO_HOST" -X POST "repos/$REPO/actions/runs/$run_id/rerun" >/dev/null 2>&1 \
        || fail_operation "could not re-run review-gate run $run_id" "Re-run it from the Actions tab, then retry."
      REVIEW_GATE_RUN_ID="$run_id"
      wait_for_new_attempt "$run_id" "$prior_attempt"
      return 0
    fi
    if [ "$attempt" -ge "$GATE_ATTEMPTS" ]; then
      # No run at all is a different failure from a slow one: when Actions
      # are disabled, waiting cannot produce a run, and the remedy is the
      # setting, not patience.
      if [ -z "$run_id" ] && ! actions_enabled; then
        fail_operation "no review-gate run can exist for $head: repository Actions are disabled for $REPO" "$(actions_disabled_remedy | sed 's/^enable them: /Enable them: /'), then re-run this command."
      fi
      fail_operation "review-gate run for $head did not reach a re-runnable state within $((GATE_ATTEMPTS * GATE_RETRY_DELAY))s (last: ${run_id:-none} ${status:-absent})" "Wait for the gate run to finish, then re-run this command."
    fi
    [ "$JSON_MODE" = true ] || printf 'Review gate run %s; retrying in %ss.\n' "${status:-not yet present}" "$GATE_RETRY_DELAY" >&2
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
    || fail_input "PR #$number moved (head $live_head on $live_base) while the review gate was re-run" "Re-review the live head, then retry."
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
  local comment_id live_comment
  if review_gate_required "$base_ref"; then
    rerun_review_gate "$number" "$head"
    verify_live_coordinates "$number" "$head" "$base_ref" "$base_sha"
    [ "$JSON_MODE" = true ] || printf 'Review gate re-run requested for run %s.\n' "$REVIEW_GATE_RUN_ID" >&2
    return 0
  fi
  comment_id="${request_url##*issuecomment-}"
  case "$comment_id" in '' | *[!0-9]*) fail_operation "review request URL has no stable comment ID: $request_url" "Inspect the surviving request comment." ;; esac
  # No pinned review gate on this base: nothing server-side binds the request,
  # so the most this command can prove is that the request comment survived
  # as a valid driver request and that the coordinates it was posted for are
  # still live. Exact-head review stays mandatory driver procedure here; the
  # missing gate is a rollout gap the driver reports, not permission.
  read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/issues/comments/$comment_id" \
    --jq 'select(((.author_association // "") == "OWNER" or (.author_association // "") == "MEMBER" or (.author_association // "") == "COLLABORATOR") and ((.body // "") | test("^[[:space:]]*@codex[[:space:]]+review([[:space:]]|$)"; "i"))) | .id' \
    || fail_operation "could not re-read review request comment $comment_id: $READ_OUTPUT" "Inspect GitHub before retrying."
  live_comment="$READ_OUTPUT"
  [ "$live_comment" = "$comment_id" ] \
    || fail_operation "review request comment $comment_id is no longer a valid driver request" "Post a fresh exact-head review request."
  verify_live_coordinates "$number" "$head" "$base_ref" "$base_sha"
  # Stderr in both modes: JSON stdout stays data, and the gap must be visible.
  printf 'No pinned review gate protects %s here; the request is posted but nothing binds it server-side. Track the policy gap.\n' "$base_ref" >&2
  return 0
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
  # Checked before anything is pushed or posted: with Actions disabled the
  # request would be accepted and then bind to a gate run that can never
  # exist, and the later timeout would read as a dispatch delay.
  actions_enabled \
    || fail_input "repository Actions are disabled for $REPO, so no required workflow can run and nothing would gate this pull request" \
      "$(actions_disabled_remedy | sed 's/^enable them: /Enable them: /'), then retry."

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
  # Only after the head and base checks above: a PR that would be refused for
  # drift is not edited first. Idempotent means "converges on the arguments
  # given", not "no-ops": on a
  # reused PR the title and body passed now are applied when they differ from
  # what GitHub holds, and the result says so. Silently keeping the old body
  # let a PR opened before the evidence sections were written fail the
  # required delivery-evidence gate with no signal from the one command the
  # driver is told to use (AUT-437).
  if [ "$state" = existing ]; then
    BODY_APPLIED=unchanged
    read_with_retry gh pr view "$number" --repo "$REPO_SPEC" --json title,body --jq '[.title, .body] | @json' \
      || fail_operation "could not read the existing pull request's title and body: $READ_OUTPUT" "Retry after GitHub recovers."
    live_title="$(printf '%s' "$READ_OUTPUT" | jq -r '.[0]')"
    live_body="$(printf '%s' "$READ_OUTPUT" | jq -r '.[1]')"
    wanted_body="$(cat "$BODY_FILE")"
    edit_args=()
    [ "$live_title" = "$TITLE" ] || edit_args+=(--title "$TITLE")
    [ "$live_body" = "$wanted_body" ] || edit_args+=(--body-file "$BODY_FILE")
    if [ "${#edit_args[@]}" -gt 0 ]; then
      edit_output="$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE && cd "$PROJECT_ROOT" && gh pr edit "$number" --repo "$REPO_SPEC" "${edit_args[@]}" 2>&1)" \
        || fail_operation "could not apply the given title/body to PR #$number: $edit_output" "Inspect the PR on GitHub before retrying."
      read_with_retry gh pr view "$number" --repo "$REPO_SPEC" --json body --jq '.body' \
        || fail_operation "PR edit could not be reconciled: $READ_OUTPUT" "Inspect GitHub before retrying."
      [ "$READ_OUTPUT" = "$wanted_body" ] \
        || fail_operation "PR #$number body differs from --body-file after the edit" "Inspect GitHub before retrying."
      BODY_APPLIED=updated
    fi
  fi
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
  # Read before the first byte of output: a failed read must produce one
  # error document, not a truncated status followed by another object.
  read_enforcement "$base"
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
    printf ',"draft":%s,"enforcement":' "$draft"
    enforcement_json
    printf '}\n'
  else
    printf 'PR #%s: %s\n  url: %s\n  head: %s\n  base: %s at %s\n  merge state: %s\n  draft: %s\n  enforcement on %s: %s\n' \
      "$number" "$state" "$url" "$head" "$base" "$base_sha" "$merge_state" "$draft" "$base" "$(enforcement_text)"
  fi
}

merge_pr() {
  local number state url head base base_sha merge_state draft merge_output merge_status=0
  local merge_diagnostic final_state final_row final_head auto_merge queue_state unguarded_marker prior_records record_author merge_auto
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
    # A required workflow cannot see a review that lands after the request.
    # Ask it to evaluate what is on the PR now, then ask GitHub to merge:
    # auto-merge arms while the run is pending and the queue admits the PR
    # when it is green. The verdict is GitHub's; this only requests it.
    # The guarded path is taken only when enforcement is fully applied --
    # the gate present at the policy's repository, ref, and revision, with
    # the queue and native rules beside it. A same-path workflow from
    # elsewhere or a stale pin is not the gate.
    read_enforcement "$base"
    if [ "$ENFORCEMENT_STATUS" = applied ]; then
      rerun_review_gate "$number" "$head"
      # Requesting the re-run can wait for an in-progress run; the head and
      # the base *ref* must still be what the evaluation covers. The base tip
      # may advance -- the gate binds by ancestry.
      verify_live_head_and_base_ref "$number" "$head" "$base"
      [ "$JSON_MODE" = true ] || printf 'Review gate re-run requested for run %s; GitHub merges when it passes.\n' "$REVIEW_GATE_RUN_ID" >&2
    else
      # Enforcement is not fully applied on this base: merging here would not
      # be gated the way the policy intends. Missing enforcement is a tracked
      # gap, not permission -- refuse unless the caller says so explicitly,
      # and then leave the fact on the PR.
      [ "$UNGUARDED" = true ] \
        || fail_input "enforcement on $base of $REPO is $(enforcement_text); GitHub would not gate this merge as the policy intends" \
          "$(enforcement_remedy); or pass --unguarded to merge anyway and record the gap on the PR."
      # Record the observed fact, once per head: what is missing, and that an
      # unguarded merge of this exact head was requested. Whether the merge
      # lands is GitHub's verdict, read below, not claimed here. A rerun
      # reuses the existing marker instead of posting again.
      unguarded_marker="<!-- touchstone:unguarded-merge head=$head -->"
      # Only a record this identity wrote counts; anyone can type the marker.
      read_with_retry gh api --hostname "$REPO_HOST" user --jq '.login' \
        || fail_operation "could not read the authenticated login: $READ_OUTPUT" "Retry after GitHub recovers."
      record_author="$READ_OUTPUT"
      read_with_retry gh api --paginate --hostname "$REPO_HOST" "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" \
        --jq "[.[] | select((.user.login // \"\") == \"$record_author\" and ((.body // \"\") | contains(\"$unguarded_marker\")))] | length" \
        || fail_operation "could not inspect PR #$PR_NUMBER comments for a prior unguarded-merge record: $READ_OUTPUT" "Inspect GitHub before retrying."
      # One count per page: sum them, so a PR past 100 comments cannot turn
      # "0\n0" into a skipped record.
      prior_records="$(printf '%s\n' "$READ_OUTPUT" | awk '{ total += $1 } END { print total + 0 }')"
      if [ "$prior_records" = 0 ]; then
        gh pr comment "$PR_NUMBER" --repo "$REPO_SPEC" --body "$unguarded_marker
Unguarded merge requested for head \`$head\` by \`touchstone pr merge --unguarded\`: enforcement on \`$base\` is $(enforcement_text), so GitHub's requirements for this merge differ from the policy by exactly what is listed (other checks or reviews may still have run). Apply the consumer policy to close the gap." >/dev/null \
          || fail_operation "could not record the unguarded merge request on PR #$PR_NUMBER" "Inspect GitHub before retrying."
      fi
      # The base inspected and recorded must be the base merged into.
      verify_live_head_and_base_ref "$number" "$head" "$base"
      printf 'WARNING: requesting merge of PR #%s without a pinned review gate on %s (recorded on the PR).\n' "$PR_NUMBER" "$base" >&2
    fi
    # Without a merge queue there is nothing to enter: GitHub refuses a plain
    # merge while required checks are still running, so arm auto-merge and
    # let it land when they pass (the state `auto-merge-enabled` below).
    merge_auto=()
    [ "$ENFORCEMENT_EXPECTS_QUEUE" = true ] || merge_auto=(--auto)
    merge_output="$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE && cd "$PROJECT_ROOT" && gh pr merge "$PR_NUMBER" --repo "$REPO_SPEC" --squash ${merge_auto[@]+"${merge_auto[@]}"} \
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
  policy-status) policy_status ;;
esac
