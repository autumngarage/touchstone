#!/usr/bin/env bash
# scripts/touchstone-pr.sh — narrow, versioned PR delivery operations.

set -euo pipefail

OUTPUT_SCHEMA="touchstone.pr/v1"
READ_ATTEMPTS="${TOUCHSTONE_READ_ATTEMPTS:-3}"
RETRY_DELAY="${TOUCHSTONE_RETRY_DELAY:-2}"
# One initial PR-head read plus ten default 2-second waits covers the observed
# post-push lag without turning a real mismatch into success.
PR_HEAD_ATTEMPTS=11
# A required-workflow run takes a minute or two; waiting for one before
# re-running it has its own budget, separate from transport retries.
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
BODY_SNAPSHOT_TEMP=""

cleanup() {
  [ -z "$CAPTURE_STDERR_TEMP" ] || rm -f -- "$CAPTURE_STDERR_TEMP"
  [ -z "$BODY_SNAPSHOT_TEMP" ] || rm -f -- "$BODY_SNAPSHOT_TEMP"
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

read_open_pr_rows_for_head() {
  local branch="$1" expected_head="$2" attempt=1 rows count observed_head
  while :; do
    read_with_retry gh pr list --repo "$REPO_SPEC" --state open --head "$branch" --limit 100 \
      --json number,url,headRefOid,baseRefName,baseRefOid \
      --jq '.[] | [.number,.url,.headRefOid,.baseRefName,.baseRefOid] | @tsv' \
      || return $?
    rows="$READ_OUTPUT"
    count="$(printf '%s\n' "$rows" | awk 'NF { count++ } END { print count + 0 }')"
    if [ "$count" -ne 1 ]; then
      READ_OUTPUT="$rows"
      return 0
    fi
    IFS="$(printf '\t')" read -r _ _ observed_head _ _ <<<"$rows"
    if [ "$observed_head" = "$expected_head" ] || [ "$attempt" -ge "$PR_HEAD_ATTEMPTS" ]; then
      READ_OUTPUT="$rows"
      return 0
    fi
    if [ "$JSON_MODE" = false ]; then
      printf 'PR head read does not yet match the pushed head; retrying in %ss.\n' "$RETRY_DELAY" >&2
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

# Policy provenance belongs to the Touchstone checkout, never to ambient Git
# state inherited from a hook or CI runner. Keep these reads isolated for the
# same reason project_git isolates reads of the consumer repository.
tool_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git -C "$TOOL_ROOT" "$@"
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

snapshot_body_file() {
  [ -n "$BODY_FILE" ] || return 0
  [ -r "$BODY_FILE" ] && [ ! -d "$BODY_FILE" ] \
    || fail_input "open requires a readable --body-file" "Put the reviewed PR description in that file."
  BODY_SNAPSHOT_TEMP="$(mktemp "${TMPDIR:-/tmp}/touchstone-pr-body.XXXXXX" 2>/dev/null)" \
    || fail_operation "could not create a temporary PR-body snapshot" "Make ${TMPDIR:-/tmp} writable, then retry."
  cat 2>/dev/null <"$BODY_FILE" >"$BODY_SNAPSHOT_TEMP" \
    || fail_input "open could not read --body-file" "Pass a readable file or stream containing the reviewed PR description."
  [ -s "$BODY_SNAPSHOT_TEMP" ] \
    || fail_input "open requires a non-empty --body-file" "Put the reviewed PR description in that file."
  BODY_FILE="$BODY_SNAPSHOT_TEMP"
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
[ "$OPERATION" != open ] || snapshot_body_file

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

REQUIRED_WORKFLOW_LOCAL_IDS="[]"
required_workflow_declared() {
  local base_ref="$1" workflow_path="$2" encoded pages declared expected workflow_pages
  REQUIRED_WORKFLOW_LOCAL_IDS="[]"
  expected="$(enforcement_policy_jq -c --arg path "$workflow_path" \
    '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]? | select(.path == $path) | {repository_id, ref}] | if length == 1 then .[0] else null end')" \
    || fail_operation "could not read the declared source for $workflow_path" "Reinstall touchstone; the policy file is corrupt or incomplete."
  [ "$expected" != null ] || return 1
  encoded="$(uri_encode "$base_ref")"
  read_with_retry gh api --hostname "$REPO_HOST" --paginate "repos/$REPO/rules/branches/$encoded" \
    || fail_operation "could not read the effective rules for $base_ref: $READ_OUTPUT" "Retry after GitHub recovers."
  pages="$READ_OUTPUT"
  declared="$(printf '%s\n' "$pages" | jq -sr --arg path "$workflow_path" --argjson expected "$expected" \
    'add // [] | [.[] | select(.type == "workflows") | .parameters.workflows[]?] | any(.path == $path and .repository_id == $expected.repository_id and .ref == $expected.ref)')" \
    || fail_operation "GitHub returned malformed effective rules for $base_ref" "Retry after GitHub returns complete rule pages."
  case "$declared" in true | false) ;; *) fail_operation "GitHub returned an invalid workflow declaration result for $base_ref" "Retry after GitHub returns complete rule pages." ;; esac
  [ "$declared" = true ] || return 1
  # Organization-required runs receive a target-repository workflow_id, not
  # the source repository's workflow_id. Enumerate the target's workflows so
  # repository-local look-alikes can be excluded when selecting the run.
  read_with_retry gh api --hostname "$REPO_HOST" --paginate "repos/$REPO/actions/workflows?per_page=100" \
    || fail_operation "could not list repository-local workflows in $REPO: $READ_OUTPUT" "Retry after GitHub recovers."
  workflow_pages="$READ_OUTPUT"
  REQUIRED_WORKFLOW_LOCAL_IDS="$(printf '%s\n' "$workflow_pages" | jq -sec '[.[].workflows[]?.id] | unique')" \
    || fail_operation "GitHub returned malformed workflow pages for $REPO" "Retry after GitHub returns complete workflow pages."
  return 0
}

review_gate_required() {
  required_workflow_declared "$1" ".github/workflows/review-gate.yml"
}

delivery_evidence_required() {
  required_workflow_declared "$1" ".github/workflows/delivery-evidence.yml"
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

# Whether the revision GitHub actually pins is at least the revision this
# tool knows. The tool's policy file travels with the release; the ruleset is
# applied from a checkout that moves ahead of it, so comparing the two SHAs
# for equality reported every repository pinned at a *newer* workflow
# revision as unpinned and failed every merge closed (AUT-559). The tool's
# revision is a floor, not an identity: the pinned revision must descend from
# it, and it must also be published on the branch the policy pins, read from
# the source repository itself rather than trusted as a bare SHA. Anything
# that cannot be resolved is "unverified" and still fails closed.
PIN_LINEAGE_VERDICT=""
PIN_LINEAGE_REASON=""
resolve_pin_lineage() {
  local repository_id="$1" ref="$2" expected_sha="$3" actual_shas="$4"
  local source_repo branch head_sha sha status
  local unverified=false unverified_reason=""
  local -a candidates=()
  PIN_LINEAGE_VERDICT=off-lineage
  PIN_LINEAGE_REASON=""
  case "$ref" in
    refs/heads/*) branch="${ref#refs/heads/}" ;;
    *)
      PIN_LINEAGE_VERDICT=unverified
      PIN_LINEAGE_REASON="the policy pins the non-branch ref $ref"
      return 0
      ;;
  esac
  # The pin carries a repository id, so the source repository is resolved by
  # the id GitHub enforces -- never by a name the policy file writes down.
  if ! read_with_retry gh api --hostname "$REPO_HOST" "repositories/$repository_id" --jq '.full_name'; then
    PIN_LINEAGE_VERDICT=unverified
    PIN_LINEAGE_REASON="workflow source repository $repository_id could not be read"
    return 0
  fi
  source_repo="$READ_OUTPUT"
  case "$source_repo" in */*) ;;
  *)
    PIN_LINEAGE_VERDICT=unverified
    PIN_LINEAGE_REASON="workflow source repository $repository_id has no readable name"
    return 0
    ;;
  esac
  # The ceiling. A branch with a slash is routed by GitHub unencoded; the
  # same read `scripts/github-policy.sh` makes when it applies a policy.
  if ! read_with_retry gh api --hostname "$REPO_HOST" "repos/$source_repo/commits/$branch" --jq '.sha'; then
    PIN_LINEAGE_VERDICT=unverified
    PIN_LINEAGE_REASON="the head of $ref in $source_repo could not be read"
    return 0
  fi
  head_sha="$READ_OUTPUT"
  read -r -a candidates <<<"$actual_shas"
  for sha in "${candidates[@]}"; do
    [ -n "$sha" ] || continue
    if ! read_with_retry gh api --hostname "$REPO_HOST" "repos/$source_repo/compare/$expected_sha...$sha" --jq '.status'; then
      unverified=true
      unverified_reason="$sha could not be compared with the policy revision in $source_repo"
      continue
    fi
    # "ahead" is GitHub's word for: the pinned revision descends from the
    # tool's. "behind" and "diverged" are the genuine gaps this guard exists
    # for and stay closed.
    status="$READ_OUTPUT"
    case "$status" in ahead | identical) ;; *) continue ;; esac
    if [ "$sha" != "$head_sha" ]; then
      if ! read_with_retry gh api --hostname "$REPO_HOST" "repos/$source_repo/compare/$sha...$head_sha" --jq '.status'; then
        unverified=true
        unverified_reason="$sha could not be located on $ref in $source_repo"
        continue
      fi
      case "$READ_OUTPUT" in ahead | identical) ;; *) continue ;; esac
    fi
    PIN_LINEAGE_VERDICT=at-or-ahead
    PIN_LINEAGE_REASON=""
    return 0
  done
  if [ "$unverified" = true ]; then
    PIN_LINEAGE_VERDICT=unverified
    PIN_LINEAGE_REASON="$unverified_reason"
  fi
  return 0
}

# The three gates normally carry one identical pin, so the source repository,
# its branch head, and the comparison are resolved once per distinct pin
# rather than once per gate.
PIN_LINEAGE_CACHE=""
pin_lineage() {
  local key="$1|$2|$3|$4" cached
  cached="$(printf '%s' "$PIN_LINEAGE_CACHE" | awk -F'\t' -v key="$key" '$1 == key { print $2 "\t" $3; exit }')"
  if [ -n "$cached" ]; then
    IFS=$'\t' read -r PIN_LINEAGE_VERDICT PIN_LINEAGE_REASON <<<"$cached"
    return 0
  fi
  resolve_pin_lineage "$@"
  PIN_LINEAGE_CACHE="$PIN_LINEAGE_CACHE$(printf '%s\t%s\t%s' "$key" "$PIN_LINEAGE_VERDICT" "$PIN_LINEAGE_REASON")
"
}

# What GitHub enforces on a branch, read once from its effective rules. A
# consumer policy requires pinned workflows; a workflow-source policy requires
# its source-contract status. The queue and native rules complete either set.
# "applied" means all of them; anything less is named, so no agent has to read
# rulesets by hand to learn whether a merge would be gated.
ENFORCEMENT_STATUS=""
ENFORCEMENT_MISSING=""
ENFORCEMENT_POLICY_FILE=""
ENFORCEMENT_POLICY_CONTENT=""
ENFORCEMENT_POLICY_BOUND=false
ENFORCEMENT_POLICY_SOURCE=""
ENFORCEMENT_POLICY_REVISION=""
ENFORCEMENT_CANDIDATE_REVISION=""
ENFORCEMENT_CANDIDATE_SOURCE=""
ENFORCEMENT_CANDIDATE_ROLE=""
ENFORCEMENT_POLICY_TYPE=""
ENFORCEMENT_EXPECTS_QUEUE=true
ENFORCEMENT_EXPECTS_REVIEW_GATE=true

select_enforcement_policy() {
  local base_ref="$1" defer_branch="${2:-false}" name="${REPO##*/}" candidate candidate_repo source_policy="" policy_branch tool_git_root dirty_inventory
  tool_git_root="$(tool_git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$tool_git_root" = "$TOOL_ROOT" ]; then
    tool_git diff --quiet HEAD -- policy/github/touchstone-main.json policy/github/consumers policy/github/workflow-sources \
      && tool_git diff --cached --quiet HEAD -- policy/github/touchstone-main.json policy/github/consumers policy/github/workflow-sources \
      || fail_operation "the policy inventory is not represented by source revision $(tool_git rev-parse HEAD)" "Commit or discard every policy inventory edit before assessing enforcement."
    dirty_inventory="$(tool_git ls-files --others --exclude-standard -- policy/github/touchstone-main.json policy/github/consumers policy/github/workflow-sources)"
    [ -z "$dirty_inventory" ] \
      || fail_operation "the policy inventory is not represented by source revision $(tool_git rev-parse HEAD)" "Commit or discard untracked policy inventory files before assessing enforcement."
  fi
  ENFORCEMENT_POLICY_FILE="$CANONICAL_POLICY"
  if [ "$REPO" = "autumngarage/touchstone" ]; then
    :
  else
    for candidate in "$TOOL_ROOT"/policy/github/workflow-sources/*.json; do
      [ -f "$candidate" ] || continue
      candidate_repo="$(jq -er '"\(.organization)/\(.repository)"' "$candidate")" \
        || fail_operation "could not read repository coordinates from $candidate" "Reinstall touchstone; the workflow-source policy inventory is corrupt."
      [ "$candidate_repo" = "$REPO" ] || continue
      [ -z "$source_policy" ] \
        || fail_operation "multiple workflow-source policies match $REPO" "Keep exactly one checked-in policy for this repository."
      source_policy="$candidate"
    done
    if [ -n "$source_policy" ]; then
      ENFORCEMENT_POLICY_FILE="$source_policy"
    else
      candidate="$TOOL_ROOT/policy/github/consumers/$name.json"
      if [ -f "$candidate" ] \
        && [ "$(jq -r '"\(.organization)/\(.repository)"' "$candidate")" = "$REPO" ]; then
        ENFORCEMENT_POLICY_FILE="$candidate"
      fi
    fi
  fi
  if [ "$defer_branch" = false ]; then
    policy_branch="$(jq -er '.branch' "$ENFORCEMENT_POLICY_FILE")" \
      || fail_operation "could not read the protected branch from $ENFORCEMENT_POLICY_FILE" "Reinstall touchstone; the policy file is corrupt or incomplete."
    [ "$policy_branch" = "$base_ref" ] \
      || fail_operation "$ENFORCEMENT_POLICY_FILE protects $policy_branch, not PR base $base_ref" "Use a checked-in policy for $REPO@$base_ref; enforcement cannot be inferred from another branch."
  fi
}

enforcement_policy_jq() {
  if [ "$ENFORCEMENT_POLICY_BOUND" = true ]; then
    printf '%s' "$ENFORCEMENT_POLICY_CONTENT" | jq "$@"
  else
    jq "$@" "$ENFORCEMENT_POLICY_FILE"
  fi
}

bind_enforcement_policy() {
  local policy_revision="${1:-}" candidate_revision="${2:-}" candidate_repo="${3:-}" pr_number="${4:-}" base_ref="${5:-}"
  local tool_git_root="" source_blob working_blob changed_rows changed_status changed_path previous_path
  ENFORCEMENT_POLICY_SOURCE="${ENFORCEMENT_POLICY_FILE#"$TOOL_ROOT"/}"
  ENFORCEMENT_POLICY_CONTENT=""
  ENFORCEMENT_POLICY_BOUND=false
  ENFORCEMENT_POLICY_REVISION=""
  ENFORCEMENT_CANDIDATE_REVISION=""
  ENFORCEMENT_CANDIDATE_SOURCE=""
  ENFORCEMENT_CANDIDATE_ROLE=""

  # A Touchstone PR is the one place where the tool tree can carry policy
  # that GitHub cannot enforce until after merge. Assess the live base against
  # the immutable policy bytes at the PR's base SHA; the candidate head is
  # separately reported as desired-after-merge when it changes those bytes.
  if [ "$REPO" = "autumngarage/touchstone" ] && [ -n "$policy_revision" ]; then
    case "$policy_revision" in *[!0-9a-fA-F]* | "")
      fail_operation "PR base policy revision is not an immutable commit SHA: $policy_revision" "Retry after GitHub returns the complete PR binding."
      ;;
    esac
    [ "${#policy_revision}" -eq 40 ] \
      || fail_operation "PR base policy revision is not a full commit SHA: $policy_revision" "Retry after GitHub returns the complete PR binding."
    ENFORCEMENT_POLICY_CONTENT="$(project_git show "$policy_revision:$ENFORCEMENT_POLICY_SOURCE" 2>/dev/null)" \
      || fail_operation "could not resolve $ENFORCEMENT_POLICY_SOURCE at PR base $policy_revision" "Fetch the PR base commit, then retry."
    ENFORCEMENT_POLICY_BOUND=true
    ENFORCEMENT_POLICY_REVISION="$(printf '%s' "$policy_revision" | tr 'A-F' 'a-f')"
    if [ -n "$candidate_revision" ]; then
      case "$candidate_revision" in *[!0-9a-fA-F]* | "")
        fail_operation "candidate policy revision is not an immutable commit SHA: $candidate_revision" "Retry after GitHub returns the complete PR binding."
        ;;
      esac
      [ "${#candidate_revision}" -eq 40 ] \
        || fail_operation "candidate policy revision is not a full commit SHA: $candidate_revision" "Retry after GitHub returns the complete PR binding."
      case "$pr_number" in *[!0-9]* | "")
        fail_operation "GitHub returned no pull request number for candidate policy $candidate_revision" "Retry after GitHub returns the complete PR binding."
        ;;
      esac
      read_with_retry gh api --paginate --hostname "$REPO_HOST" \
        "repos/$REPO/pulls/$pr_number/files?per_page=100" \
        --jq '.[] | select(.filename == "policy/github/touchstone-main.json" or .previous_filename == "policy/github/touchstone-main.json") | [.status, .filename, (.previous_filename // "-")] | @tsv' \
        || fail_operation "could not inspect the files changed by PR #$pr_number: $READ_OUTPUT" "Retry after GitHub recovers."
      changed_rows="$READ_OUTPUT"
      # The file list is live PR state, unlike the content reads below which
      # address immutable commits. Bind it back to the coordinates captured by
      # read_pr_row before interpreting it as this head's candidate intent.
      verify_live_head_and_base "$pr_number" "$candidate_revision" "$base_ref" "$policy_revision"
      if [ -n "$changed_rows" ]; then
        [ "$(printf '%s\n' "$changed_rows" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] \
          || fail_operation "PR #$pr_number reports multiple changes for $ENFORCEMENT_POLICY_SOURCE" "Inspect the pull request file list."
        IFS="$(printf '\t')" read -r changed_status changed_path previous_path <<<"$changed_rows"
        [ "$changed_status" != renamed ] || [ "$previous_path" = "$ENFORCEMENT_POLICY_SOURCE" ] \
          || fail_operation "PR #$pr_number reports an unexpected prior policy path '$previous_path'" "Inspect the pull request file list."
        ENFORCEMENT_CANDIDATE_REVISION="$(printf '%s' "$candidate_revision" | tr 'A-F' 'a-f')"
        case "$changed_status" in
          removed)
            ENFORCEMENT_CANDIDATE_SOURCE="$ENFORCEMENT_POLICY_SOURCE"
            ENFORCEMENT_CANDIDATE_ROLE="absent-after-merge"
            ;;
          modified | added | renamed)
            case "$candidate_repo" in */*) ;; *)
              fail_operation "GitHub returned no candidate repository for changed policy $candidate_revision" "Retry after GitHub returns the complete PR source."
              ;;
            esac
            ENFORCEMENT_CANDIDATE_SOURCE="$changed_path"
            ENFORCEMENT_CANDIDATE_ROLE="desired-after-merge"
            ;;
          *) fail_operation "PR #$pr_number reports unsupported policy change status '$changed_status'" "Inspect the pull request file list." ;;
        esac
      fi
      if [ "$ENFORCEMENT_CANDIDATE_ROLE" = desired-after-merge ]; then
        read_with_retry gh api --hostname "$REPO_HOST" -H "Accept: application/vnd.github.raw+json" \
          "repos/$candidate_repo/contents/$ENFORCEMENT_CANDIDATE_SOURCE?ref=$candidate_revision" \
          || fail_operation "could not resolve changed $ENFORCEMENT_CANDIDATE_SOURCE at $candidate_repo@$candidate_revision: $READ_OUTPUT" "Restore access to the PR source, then retry."
        # Candidate bytes are post-merge intent, not enforcement input. Do not
        # locally adjudicate their schema: the protected validation workflow
        # owns that verdict. Exact byte equality is enough to suppress a false
        # candidate when GitHub reports a modified file with unchanged content.
        if [ "$changed_status" = modified ] && [ "$ENFORCEMENT_POLICY_CONTENT" = "$READ_OUTPUT" ]; then
          ENFORCEMENT_CANDIDATE_REVISION=""
          ENFORCEMENT_CANDIDATE_SOURCE=""
          ENFORCEMENT_CANDIDATE_ROLE=""
        fi
      fi
    fi
    return 0
  fi

  # A source checkout is bound to the commit that contains the exact policy
  # bytes being evaluated. A modified policy has no immutable revision and is
  # refused. A packaged install is the reviewed release named by VERSION.
  tool_git_root="$(tool_git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$tool_git_root" = "$TOOL_ROOT" ]; then
    ENFORCEMENT_POLICY_REVISION="$(tool_git rev-parse HEAD 2>/dev/null)" \
      || fail_operation "could not resolve the source policy revision" "Repair the Touchstone checkout, then retry."
    source_blob="$(tool_git rev-parse "$ENFORCEMENT_POLICY_REVISION:$ENFORCEMENT_POLICY_SOURCE" 2>/dev/null)" \
      || fail_operation "could not resolve $ENFORCEMENT_POLICY_SOURCE at $ENFORCEMENT_POLICY_REVISION" "Use a commit that contains the selected policy."
    working_blob="$(tool_git hash-object "$ENFORCEMENT_POLICY_FILE")" \
      || fail_operation "could not hash $ENFORCEMENT_POLICY_SOURCE" "Use a readable policy artifact."
    [ "$source_blob" = "$working_blob" ] \
      || fail_operation "$ENFORCEMENT_POLICY_SOURCE is not represented by source revision $ENFORCEMENT_POLICY_REVISION" "Commit or discard the policy edit before assessing enforcement."
  else
    local version
    version="$(cat "$TOOL_ROOT/VERSION" 2>/dev/null)" \
      || fail_operation "could not resolve the installed policy release" "Reinstall touchstone."
    if ! printf '%s\n' "$version" | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { found=1 } END { exit !found }'; then
      fail_operation "installed VERSION does not name a release: $version" "Reinstall touchstone."
    fi
    ENFORCEMENT_POLICY_REVISION="v$version"
  fi
}

read_enforcement() {
  local base_ref="$1" policy_revision="${2:-}" candidate_revision="${3:-}" candidate_repo="${4:-}" pr_number="${5:-}"
  local encoded expected expected_statuses expected_count policy_file policy_type policy_branch
  encoded="$(uri_encode "$base_ref")"
  # The expected pins travel with the tool: a workflow at the right path but
  # from another repository, another ref, or a stale revision is not the
  # canonical gate and is reported as missing with the reason. The policy
  # consulted is the repository's own where the tool ships one (a source
  # policy or a private consumer derived --no-queue), else the canonical one.
  # Required gates/statuses must be complete, or the read fails rather than
  # silently expecting nothing.
  local expect_queue
  if [ "$REPO" = "autumngarage/touchstone" ] && [ -n "$policy_revision" ]; then
    select_enforcement_policy "$base_ref" true
  else
    select_enforcement_policy "$base_ref"
  fi
  bind_enforcement_policy "$policy_revision" "$candidate_revision" "$candidate_repo" "$pr_number" "$base_ref"
  policy_file="$ENFORCEMENT_POLICY_FILE"
  [ "$ENFORCEMENT_POLICY_BOUND" = true ] || [ -f "$policy_file" ] \
    || fail_operation "the tool's policy file is missing: $policy_file" "Reinstall touchstone."
  policy_branch="$(enforcement_policy_jq -er '.branch')" \
    || fail_operation "could not read the protected branch from $ENFORCEMENT_POLICY_SOURCE at $ENFORCEMENT_POLICY_REVISION" "Use a complete policy artifact."
  [ "$policy_branch" = "$base_ref" ] \
    || fail_operation "$ENFORCEMENT_POLICY_SOURCE at $ENFORCEMENT_POLICY_REVISION protects $policy_branch, not PR base $base_ref" "Use a policy for $REPO@$base_ref; enforcement cannot be inferred from another branch."
  policy_type="$(enforcement_policy_jq -er '.policyType // "consumer"')" \
    || fail_operation "could not read the policy type from $policy_file" "Reinstall touchstone."
  expected_statuses="$(enforcement_policy_jq -c '[.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | {context, integration_id: (.integration_id // null)}]')" \
    || fail_operation "could not read the expected status checks from $policy_file" "Reinstall touchstone."
  case "$policy_type" in
    consumer)
      expected="$(enforcement_policy_jq -c '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[] | {path, repository_id, ref, sha}]')" \
        || fail_operation "could not read the expected workflow pins from $policy_file" "Reinstall touchstone."
      local gate_path
      for gate_path in .github/workflows/validate.yml .github/workflows/review-gate.yml .github/workflows/delivery-evidence.yml; do
        [ "$(printf '%s' "$expected" | jq --arg p "$gate_path" '[.[] | select(.path == $p)] | length')" = 1 ] \
          || fail_operation "$policy_file does not pin exactly one $gate_path" "Reinstall touchstone; the policy file is corrupt or incomplete."
      done
      ;;
    workflow-source)
      expected='[]'
      [ "$(printf '%s' "$expected_statuses" | jq 'length')" -gt 0 ] \
        || fail_operation "$policy_file declares no required status check" "Reinstall touchstone; the workflow-source policy file is corrupt or incomplete."
      ;;
    *) fail_operation "$policy_file has unsupported policy type '$policy_type'" "Reinstall touchstone." ;;
  esac
  expect_queue="$(enforcement_policy_jq -r 'if .managedRepositoryRuleset == null then "false" else "true" end')"
  ENFORCEMENT_POLICY_TYPE="$policy_type"
  ENFORCEMENT_EXPECTS_QUEUE="$expect_queue"
  ENFORCEMENT_EXPECTS_REVIEW_GATE="$(printf '%s' "$expected" | jq 'any(.path == ".github/workflows/review-gate.yml")')"
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
  # jq classifies each gate against the policy's pin and names the rules that
  # are simply absent; only a gate present at some *other* revision of the
  # same source and ref needs GitHub asked about lineage, so the rules
  # document is turned into verdicts here and resolved below.
  local gate_report
  gate_report="$(printf '%s' "$READ_OUTPUT" | jq -s 'add // []' | jq -r --argjson expected "$expected" --argjson expected_statuses "$expected_statuses" --argjson expect_queue "$expect_queue" '
      ([.[] | select(.type == "workflows") | .parameters.workflows[]?]) as $w
      | ([.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?]) as $s
      | def gate($e):
          ($w | map(select(.path == $e.path))) as $found
          | ($found | map(select(.repository_id == $e.repository_id and .ref == $e.ref))) as $same
          | ($e.path | split("/") | last | sub("[.]yml$"; "")) as $name
          | if ($found | length) == 0 then ["gate", $name, "absent", ($e.repository_id | tostring), $e.ref, ($e.sha | ascii_downcase), ""]
            elif any($same[]; ((.sha // "") | ascii_downcase) == ($e.sha | ascii_downcase)) then ["gate", $name, "pinned", "", "", "", ""]
            elif ($same | length) == 0 then ["gate", $name, "other-source", ($e.repository_id | tostring), $e.ref, ($e.sha | ascii_downcase),
                  ([$found[] | "repo=" + ((.repository_id // "") | tostring) + " ref=" + (.ref // "") + " sha=" + ((.sha // "") | ascii_downcase)] | unique | join(" "))]
            else ["gate", $name, "other-revision", ($e.repository_id | tostring), $e.ref, ($e.sha | ascii_downcase),
                  ([$same[] | (.sha // "") | ascii_downcase | select(. != "")] | unique | join(" "))] end;
      def required_status($e):
          if any($s[]; .context == $e.context and ($e.integration_id == null or (.integration_id // null) == $e.integration_id))
          then empty else ["status", $e.context] end;
      [
        ($expected[] | gate(.)),
        ($expected_statuses[] | required_status(.)),
        (if (any(.[]; .type == "merge_queue") or ($expect_queue | not)) then empty else ["rule", "merge queue"] end),
        (if any(.[]; .type == "pull_request" and (.parameters.required_review_thread_resolution // false) == true) then empty else ["rule", "pull-request rule (with thread resolution)"] end),
        (if any(.[]; .type == "non_fast_forward") then empty else ["rule", "force-push protection"] end),
        (if any(.[]; .type == "deletion") then empty else ["rule", "deletion protection"] end)
      ] | .[] | @tsv')" \
    || fail_operation "could not evaluate the effective rules for $base_ref" "Retry after GitHub recovers."
  local -a missing_names=()
  local kind name verdict pin_repository_id pin_ref pin_expected pin_actual
  while IFS=$'\t' read -r kind name verdict pin_repository_id pin_ref pin_expected pin_actual; do
    case "$kind" in
      rule)
        missing_names+=("$name")
        continue
        ;;
      status)
        missing_names+=("$name status")
        continue
        ;;
      gate) ;;
      *) continue ;;
    esac
    case "$verdict" in
      pinned) ;;
      absent) missing_names+=("$name workflow") ;;
      other-revision)
        pin_lineage "$pin_repository_id" "$pin_ref" "$pin_expected" "$pin_actual"
        case "$PIN_LINEAGE_VERDICT" in
          # A revision on the policy's own lineage, at or ahead of the one
          # the tool carries, enforces at least what the tool expects.
          at-or-ahead) ;;
          unverified)
            missing_names+=("$name workflow (present but pinned at a revision this tool could not verify: $(printf '%s' "$PIN_LINEAGE_REASON" | tr ',' ';')) [expected $pin_expected; observed ${pin_actual:-unreadable}]")
            ;;
          *) missing_names+=("$name workflow (present but not pinned at the policy revision) [expected $pin_expected; observed ${pin_actual:-unreadable}]") ;;
        esac
        ;;
      other-source)
        missing_names+=("$name workflow (present but not pinned at the policy revision) [expected repo=$pin_repository_id ref=$pin_ref sha=$pin_expected; observed ${pin_actual:-unreadable}]")
        ;;
      *) missing_names+=("$name workflow (present but not pinned at the policy revision) [expected $pin_expected; observed ${pin_actual:-unreadable}]") ;;
    esac
  done <<<"$gate_report"
  if [ -n "$auto_merge_missing" ]; then
    missing_names+=("$auto_merge_missing")
  fi
  ENFORCEMENT_MISSING=""
  if [ "${#missing_names[@]}" -gt 0 ]; then
    ENFORCEMENT_MISSING="$(printf '%s\n' "${missing_names[@]}" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//')"
  fi
  # Disabled Actions void every required workflow at once, however the rules
  # read: the gap is named first and the status is "none" regardless of what
  # else is present, because nothing listed can run.
  ENFORCEMENT_ACTIONS_DISABLED=false
  if ! actions_enabled; then
    ENFORCEMENT_ACTIONS_DISABLED=true
    ENFORCEMENT_MISSING="repository Actions (disabled: no required workflow can run; $(actions_disabled_remedy))${ENFORCEMENT_MISSING:+,$ENFORCEMENT_MISSING}"
    ENFORCEMENT_STATUS=none
    return 0
  fi
  # Everything expected missing is "none". Derive the count from the policy's
  # own gate/status declarations plus the shared native rules and auto-merge.
  expected_count=$(($(printf '%s' "$expected" | jq 'length') + $(printf '%s' "$expected_statuses" | jq 'length') + 4))
  [ "$expect_queue" = true ] && expected_count=$((expected_count + 1))
  local missing_count
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
ENFORCEMENT_ACTIONS_DISABLED=false
enforcement_remedy() {
  local name="${REPO##*/}"
  # Applying policy cannot fix a repository whose Actions are off: the
  # setting comes first, and the rules are re-assessed once it is on.
  if [ "$ENFORCEMENT_ACTIONS_DISABLED" = true ]; then
    printf '%s, then re-run this command to assess the rules' "$(actions_disabled_remedy)"
    return 0
  fi
  if [ "$REPO" = "autumngarage/touchstone" ]; then
    printf 'in a clean Touchstone checkout at %s, run scripts/github-policy.sh apply policy/github/touchstone-main.json, then close/reopen open PRs' "$ENFORCEMENT_POLICY_REVISION"
  elif [ "$ENFORCEMENT_POLICY_TYPE" = workflow-source ]; then
    printf 'in a clean Touchstone checkout at %s, run scripts/github-policy.sh apply %s, then close/reopen open PRs' "$ENFORCEMENT_POLICY_REVISION" "$ENFORCEMENT_POLICY_SOURCE"
  elif [ -f "$TOOL_ROOT/policy/github/consumers/$name.json" ] \
    && [ "$(jq -r '"\(.organization)/\(.repository)"' "$TOOL_ROOT/policy/github/consumers/$name.json")" = "$REPO" ]; then
    printf 'in a clean Touchstone checkout at %s, run scripts/github-policy.sh apply policy/github/consumers/%s.json, then close/reopen open PRs' "$ENFORCEMENT_POLICY_REVISION" "$name"
  elif [ "${REPO%%/*}" = "$(jq -r .organization "$CANONICAL_POLICY")" ]; then
    printf 'derive a consumer policy first: scripts/derive-consumer-policy.sh %s > policy/github/consumers/%s.json in a clean Touchstone checkout at %s, review and merge it, then scripts/github-policy.sh apply it and close/reopen open PRs' "$name" "$name" "$ENFORCEMENT_POLICY_REVISION"
  else
    printf 'this tool ships policy for the %s organization only; %s needs its own policy file modelled at Touchstone revision %s before scripts/github-policy.sh apply' "$(jq -r .organization "$CANONICAL_POLICY")" "$REPO" "$ENFORCEMENT_POLICY_REVISION"
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

policy_binding_json_fields() {
  printf ',"policy":{"source":'
  json_string "$ENFORCEMENT_POLICY_SOURCE"
  printf ',"revision":'
  json_string "$ENFORCEMENT_POLICY_REVISION"
  printf '}'
  if [ -n "$ENFORCEMENT_CANDIDATE_REVISION" ]; then
    printf ',"candidatePolicy":{"source":'
    json_string "$ENFORCEMENT_CANDIDATE_SOURCE"
    printf ',"revision":'
    json_string "$ENFORCEMENT_CANDIDATE_REVISION"
    printf ',"role":'
    json_string "$ENFORCEMENT_CANDIDATE_ROLE"
    printf '}'
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
    json_string "$ENFORCEMENT_POLICY_SOURCE"
    printf ',"policyRevision":'
    json_string "$ENFORCEMENT_POLICY_REVISION"
    printf ',"enforcement":'
    enforcement_json
    printf '}\n'
  else
    printf 'repository: %s\n  base: %s\n  policy: %s at %s\n  enforcement: %s\n' "$REPO" "$base_ref" "$ENFORCEMENT_POLICY_SOURCE" "$ENFORCEMENT_POLICY_REVISION" "$(enforcement_text)"
    [ -z "$ENFORCEMENT_MISSING" ] || printf '  remedy: %s\n' "$(enforcement_remedy)"
  fi
}

wait_for_new_attempt() {
  local run_id="$1" prior="$2" workflow_name="$3" attempt=1 seen
  while :; do
    read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/actions/runs/$run_id" --jq '.run_attempt' \
      || fail_operation "could not read $workflow_name run $run_id: $READ_OUTPUT" "Retry after GitHub recovers."
    seen="$READ_OUTPUT"
    case "$seen$prior" in *[!0-9]* | "") fail_operation "$workflow_name run $run_id reported a non-numeric attempt ('$seen' after '$prior')" "Inspect the run in the Actions tab." ;; esac
    [ "$seen" -le "$prior" ] || return 0
    [ "$attempt" -lt "$GATE_ATTEMPTS" ] \
      || fail_operation "$workflow_name run $run_id did not start its new attempt within $((GATE_ATTEMPTS * GATE_RETRY_DELAY))s" "Check the Actions tab, then retry."
    attempt=$((attempt + 1))
    sleep "$GATE_RETRY_DELAY"
  done
}

REQUIRED_WORKFLOW_RUN_ID=""
REQUIRED_WORKFLOW_RERAN=false
rerun_required_workflow() {
  local number="$1" head="$2" workflow_name="$3" local_workflow_ids="$4"
  local attempt=1 run_id status prior_attempt run_pages run_row workflow_ids workflow_id_count
  REQUIRED_WORKFLOW_RUN_ID=""
  REQUIRED_WORKFLOW_RERAN=false
  while :; do
    # Scoped to this pull request: two open PRs can share a head SHA, and
    # re-running the other one's gate would prove nothing about this request.
    read_with_retry gh api --hostname "$REPO_HOST" --paginate \
      "repos/$REPO/actions/runs?head_sha=$head&per_page=100" \
      || fail_operation "could not inspect $workflow_name runs for $head: $READ_OUTPUT" "Retry after GitHub recovers."
    run_pages="$READ_OUTPUT"
    workflow_ids="$(printf '%s\n' "$run_pages" | jq -sec \
      --arg workflow "$workflow_name" --argjson local_ids "$local_workflow_ids" --argjson number "$number" \
      '[.[].workflow_runs[]? | select(.name == $workflow and .workflow_id != null and (.workflow_id as $id | $local_ids | index($id)) == null and (.event == "pull_request" or .event == "merge_group") and any(.pull_requests[]?; .number == $number)) | .workflow_id] | unique')" \
      || fail_operation "GitHub returned malformed $workflow_name run pages for $head" "Retry after GitHub returns complete workflow-run pages."
    workflow_id_count="$(printf '%s' "$workflow_ids" | jq 'length')"
    [ "$workflow_id_count" -le 1 ] \
      || fail_operation "multiple external $workflow_name workflow identities ran for PR #$number at $head" "Remove the same-named required-workflow ambiguity, then retry."
    run_row="$(printf '%s\n' "$run_pages" | jq -ser \
      --arg workflow "$workflow_name" --argjson workflow_ids "$workflow_ids" --argjson number "$number" \
      '[.[].workflow_runs[]? | select(.name == $workflow and (.workflow_id as $id | $workflow_ids | index($id)) != null and (.event == "pull_request" or .event == "merge_group") and any(.pull_requests[]?; .number == $number))] | sort_by(.id) | last | "\(.id // "") \(.status // "")"')" \
      || fail_operation "GitHub returned malformed $workflow_name run pages for $head" "Retry after GitHub returns complete workflow-run pages."
    read -r run_id status <<<"$run_row"
    if [ -n "$run_id" ] && [ "$status" = completed ]; then
      REQUIRED_WORKFLOW_RUN_ID="$run_id"
      # A re-run keeps the run id and increments run_attempt. GitHub can keep
      # exposing the superseded attempt's verdict for a moment after the POST;
      # wait until the new attempt is visible so nothing downstream reads the
      # old one as current. This waits for visibility, never for a verdict.
      read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/actions/runs/$run_id" --jq '.run_attempt' \
        || fail_operation "could not read $workflow_name run $run_id: $READ_OUTPUT" "Retry after GitHub recovers."
      prior_attempt="$READ_OUTPUT"
      gh api --hostname "$REPO_HOST" -X POST "repos/$REPO/actions/runs/$run_id/rerun" >/dev/null 2>&1 \
        || fail_operation "could not re-run $workflow_name run $run_id" "Re-run it from the Actions tab, then retry."
      REQUIRED_WORKFLOW_RERAN=true
      wait_for_new_attempt "$run_id" "$prior_attempt" "$workflow_name"
      return 0
    fi
    if [ "$attempt" -ge "$GATE_ATTEMPTS" ]; then
      # No run at all is a different failure from a slow one: when Actions
      # are disabled, waiting cannot produce a run, and the remedy is the
      # setting, not patience.
      if [ -z "$run_id" ] && ! actions_enabled; then
        fail_operation "no $workflow_name run can exist for $head: repository Actions are disabled for $REPO" "$(actions_disabled_remedy | sed 's/^enable them: /Enable them: /'), then re-run this command."
      fi
      fail_operation "$workflow_name run for $head did not reach a re-runnable state within $((GATE_ATTEMPTS * GATE_RETRY_DELAY))s (last: ${run_id:-none} ${status:-absent})" "Wait for the gate run to finish, then re-run this command."
    fi
    [ "$JSON_MODE" = true ] || printf '%s run %s; retrying in %ss.\n' "$workflow_name" "${status:-not yet present}" "$GATE_RETRY_DELAY" >&2
    attempt=$((attempt + 1))
    sleep "$GATE_RETRY_DELAY"
  done
}

rerun_review_gate() {
  review_gate_required "$3" \
    || fail_operation "the applied policy no longer declares the central review gate" "Re-assess the live base policy before retrying."
  rerun_required_workflow "$1" "$2" review-gate "$REQUIRED_WORKFLOW_LOCAL_IDS"
  REVIEW_GATE_RUN_ID="$REQUIRED_WORKFLOW_RUN_ID"
}

verify_live_head_and_base() {
  local number="$1" head="$2" base_ref="$3" base_sha="$4" live_head live_base live_base_sha
  read_with_retry gh pr view "$number" --repo "$REPO_SPEC" --json headRefOid,baseRefName,baseRefOid \
    --jq '[.headRefOid,.baseRefName,.baseRefOid] | @tsv' \
    || fail_operation "could not re-read PR coordinates: $READ_OUTPUT" "Inspect GitHub before retrying."
  IFS="$(printf '\t')" read -r live_head live_base live_base_sha <<<"$READ_OUTPUT"
  [ "$live_head" = "$head" ] && [ "$live_base" = "$base_ref" ] \
    || fail_input "PR #$number moved (head $live_head on $live_base at $live_base_sha) after enforcement was assessed" "Re-run against the live head and base policy."
  [ "$ENFORCEMENT_POLICY_BOUND" = false ] || [ "$live_base_sha" = "$base_sha" ] \
    || fail_input "PR #$number base advanced from $base_sha to $live_base_sha after enforcement was assessed" "Re-run against the live base policy."
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

verify_live_body() {
  local number="$1" expected_body="$2" live_body
  read_with_retry gh pr view "$number" --repo "$REPO_SPEC" --json body --jq '.body' \
    || fail_operation "could not re-read PR body binding: $READ_OUTPUT" "Inspect GitHub before retrying."
  live_body="$READ_OUTPUT"
  [ "$live_body" = "$expected_body" ] \
    || fail_input "PR #$number body moved while delivery evidence was refreshed" "Re-run with the live title and body so evidence is bound to the surviving content."
}

wait_for_request_binding() {
  local number="$1" head="$2" base_ref="$3" base_sha="$4" request_url="$5" request_author="$6"
  local comment_id live_comment request_marker
  if review_gate_required "$base_ref"; then
    rerun_required_workflow "$number" "$head" review-gate "$REQUIRED_WORKFLOW_LOCAL_IDS"
    REVIEW_GATE_RUN_ID="$REQUIRED_WORKFLOW_RUN_ID"
    verify_live_coordinates "$number" "$head" "$base_ref" "$base_sha"
    [ "$JSON_MODE" = true ] || printf 'Review gate re-run requested for run %s.\n' "$REVIEW_GATE_RUN_ID" >&2
    return 0
  fi
  comment_id="${request_url##*issuecomment-}"
  case "$comment_id" in '' | *[!0-9]*) fail_operation "review request URL has no stable comment ID: $request_url" "Inspect the surviving request comment." ;; esac
  request_marker="<!-- touchstone:pr-open head=$head base=$base_ref base_sha=$base_sha -->"
  # No pinned review gate on this base: nothing server-side binds the request,
  # so the most this command can prove is that the request comment survived
  # as a valid driver request and that the coordinates it was posted for are
  # still live. Exact-head review stays mandatory driver procedure here;
  # whether the absent gate is intentional or a rollout gap comes from the
  # selected policy below.
  read_with_retry gh api --hostname "$REPO_HOST" "repos/$REPO/issues/comments/$comment_id" \
    || fail_operation "could not re-read review request comment $comment_id: $READ_OUTPUT" "Inspect GitHub before retrying."
  live_comment="$(printf '%s' "$READ_OUTPUT" | jq -r --arg author "$request_author" --arg marker "$request_marker" \
    'select((.user.login // "") == $author and ((.body // "") | test("^@codex review(\\r?\\n|$)"; "i") and contains($marker))) | .id')" \
    || fail_operation "could not evaluate review request comment $comment_id" "Inspect GitHub before retrying."
  [ "$live_comment" = "$comment_id" ] \
    || fail_operation "review request comment $comment_id is no longer a valid driver request" "Post a fresh exact-head review request."
  verify_live_coordinates "$number" "$head" "$base_ref" "$base_sha"
  read_enforcement "$base_ref" "$base_sha"
  # Stderr in both modes: JSON stdout stays data, and the exact-head driver
  # obligation must remain visible where the source policy intentionally has
  # no reusable review gate.
  if [ "$ENFORCEMENT_STATUS" = applied ] && [ "$ENFORCEMENT_EXPECTS_REVIEW_GATE" = false ]; then
    printf 'The applied workflow-source policy %s at %s has no pinned review gate; exact-head review remains mandatory driver procedure.\n' "$ENFORCEMENT_POLICY_SOURCE" "$ENFORCEMENT_POLICY_REVISION" >&2
  else
    printf 'No pinned review gate protects %s here; %s at %s reports the gap, and nothing binds the posted request server-side. Track it.\n' "$base_ref" "$ENFORCEMENT_POLICY_SOURCE" "$ENFORCEMENT_POLICY_REVISION" >&2
  fi
  return 0
}

open_pr() {
  local branch local_head remote_line remote_head rows count number url pr_head pr_base pr_base_sha create_output create_status=0
  local request_marker request_head_marker comment_rows existing_request moved_request request_body request_url request_rows state request_author
  [ -n "$TITLE" ] || fail_input "open requires --title" "Pass the PR title explicitly."
  [ -f "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
    || fail_input "open requires a non-empty --body-file" "Put the reviewed PR description in that file."
  wanted_body="$(cat "$BODY_FILE")"
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
  # Policy is branch-specific. Refuse an unmodelled base before creating,
  # editing, or commenting on a pull request; another branch's rules cannot
  # establish what GitHub will enforce here.
  select_enforcement_policy "$BASE_REF"
  # Checked before anything is pushed or posted: with Actions disabled the
  # request would be accepted and then bind to a gate run that can never
  # exist, and the later timeout would read as a dispatch delay.
  actions_enabled \
    || fail_input "repository Actions are disabled for $REPO, so no required workflow can run and nothing would gate this pull request" \
      "$(actions_disabled_remedy | sed 's/^enable them: /Enable them: /'), then retry."

  read_open_pr_rows_for_head "$branch" "$local_head" \
    || fail_operation "could not inspect existing pull requests: $READ_OUTPUT" "Retry after GitHub recovers."
  rows="$READ_OUTPUT"
  count="$(printf '%s\n' "$rows" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -le 1 ] || fail_operation "multiple open pull requests use branch '$branch'" "Close or retarget duplicates."
  if [ "$count" -eq 0 ]; then
    create_output="$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE && cd "$PROJECT_ROOT" && gh pr create --repo "$REPO_SPEC" --head "$branch" --base "$BASE_REF" \
      --title "$TITLE" --body-file "$BODY_FILE" 2>&1)" || create_status=$?
    read_open_pr_rows_for_head "$branch" "$local_head" \
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
  # Required-workflow identity comes from the immutable base policy, not a
  # same-path repository-local workflow or policy bytes changed by this PR.
  bind_enforcement_policy "$pr_base_sha"
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
  # Required workflows do not reliably receive a new consumer event when an
  # existing PR body is corrected. The sequencer owns body convergence, so it
  # also owns requesting a fresh delivery-evidence evaluation without
  # close/reopen side effects. Every reused PR gets a new attempt: GitHub's PR
  # timestamp includes comments and reviews, so it cannot safely distinguish a
  # body edit from ordinary feedback. Re-read the exact coordinates and body
  # after the request so the recovery cannot bind evidence to state that moved.
  if [ "$state" = existing ] && delivery_evidence_required "$pr_base"; then
    rerun_required_workflow "$number" "$local_head" delivery-evidence "$REQUIRED_WORKFLOW_LOCAL_IDS"
    verify_live_coordinates "$number" "$local_head" "$pr_base" "$pr_base_sha"
    verify_live_body "$number" "$wanted_body"
    if [ "$REQUIRED_WORKFLOW_RERAN" = true ] && [ "$JSON_MODE" = false ]; then
      printf 'Delivery evidence re-run requested for run %s.\n' "$REQUIRED_WORKFLOW_RUN_ID" >&2
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
    wait_for_request_binding "$number" "$local_head" "$pr_base" "$pr_base_sha" "$request_url" "$request_author"
    verify_live_body "$number" "$wanted_body"
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
  wait_for_request_binding "$number" "$local_head" "$pr_base" "$pr_base_sha" "$request_url" "$request_author"
  verify_live_body "$number" "$wanted_body"
  emit_open_result "$state" "$number" "$url" "$local_head" "posted:$request_url" "$branch"
}

read_pr_row() {
  read_with_retry gh pr view "$PR_NUMBER" --repo "$REPO_SPEC" \
    --json number,state,url,headRefOid,headRepository,baseRefName,baseRefOid,mergeStateStatus,isDraft \
    --jq '[.number,.state,.url,.headRefOid,(.headRepository.nameWithOwner // "-"),.baseRefName,.baseRefOid,.mergeStateStatus,.isDraft] | @tsv' \
    || fail_operation "could not read PR #$PR_NUMBER: $READ_OUTPUT" "Verify the PR and GitHub access."
  PR_ROW="$READ_OUTPUT"
}

read_auto_merge_state() {
  local number="$1" expected_head="$2" row
  read_with_retry gh api graphql --hostname "$REPO_HOST" \
    -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F number="$number" \
    -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid autoMergeRequest{enabledAt}}}}' \
    --jq '[.data.repository.pullRequest.headRefOid, (.data.repository.pullRequest.autoMergeRequest.enabledAt // "")] | @tsv' \
    || fail_operation "could not read auto-merge state for PR #$number: $READ_OUTPUT" "Retry after GitHub recovers."
  row="$READ_OUTPUT"
  IFS="$(printf '\t')" read -r AUTO_MERGE_HEAD AUTO_MERGE_ENABLED_AT <<<"$row"
  [ -n "$AUTO_MERGE_HEAD" ] \
    || fail_operation "GitHub returned no live head while reading auto-merge state for PR #$number" "Retry after GitHub recovers."
  [ "$AUTO_MERGE_HEAD" = "$expected_head" ] \
    || fail_operation "PR #$number moved from $expected_head to $AUTO_MERGE_HEAD while status was being read" "Re-run status against the live head."
  if [ -n "$AUTO_MERGE_ENABLED_AT" ]; then
    AUTO_MERGE_ARMED=true
  else
    AUTO_MERGE_ARMED=false
  fi
}

auto_merge_json() {
  printf '{"armed":%s,"enabledAt":' "$AUTO_MERGE_ARMED"
  if [ -n "$AUTO_MERGE_ENABLED_AT" ]; then json_string "$AUTO_MERGE_ENABLED_AT"; else printf 'null'; fi
  printf ',"head":'
  json_string "$AUTO_MERGE_HEAD"
  printf '}'
}

auto_merge_text() {
  if [ "$AUTO_MERGE_ARMED" = true ]; then
    printf 'armed at %s for %s' "$AUTO_MERGE_ENABLED_AT" "$AUTO_MERGE_HEAD"
  else
    printf 'not armed for %s' "$AUTO_MERGE_HEAD"
  fi
}

status_pr() {
  local number state url head head_repo base base_sha merge_state draft
  read_pr_row
  IFS="$(printf '\t')" read -r number state url head head_repo base base_sha merge_state draft <<<"$PR_ROW"
  [ "$head_repo" != - ] || head_repo=""
  # Read before the first byte of output: a failed read must produce one
  # error document, not a truncated status followed by another object.
  read_auto_merge_state "$number" "$head"
  read_enforcement "$base" "$base_sha" "$head" "$head_repo" "$number"
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
    printf ',"draft":%s,"autoMerge":' "$draft"
    auto_merge_json
    printf ',"enforcement":'
    enforcement_json
    policy_binding_json_fields
    printf '}\n'
  else
    printf 'PR #%s: %s\n  url: %s\n  head: %s\n  base: %s at %s\n  merge state: %s\n  draft: %s\n  auto-merge: %s\n  policy: %s at %s\n  enforcement on %s: %s\n' \
      "$number" "$state" "$url" "$head" "$base" "$base_sha" "$merge_state" "$draft" "$(auto_merge_text)" "$ENFORCEMENT_POLICY_SOURCE" "$ENFORCEMENT_POLICY_REVISION" "$base" "$(enforcement_text)"
    [ -z "$ENFORCEMENT_CANDIDATE_REVISION" ] \
      || printf '  candidate policy: %s at %s (%s)\n' "$ENFORCEMENT_CANDIDATE_SOURCE" "$ENFORCEMENT_CANDIDATE_REVISION" "$ENFORCEMENT_CANDIDATE_ROLE"
  fi
}

merge_pr() {
  local number state url head head_repo base base_sha merge_state draft merge_output merge_status=0
  local merge_diagnostic final_state final_row final_head auto_merge queue_state unguarded_marker prior_records record_author merge_auto
  [ -n "$EXPECTED_HEAD" ] \
    || fail_input "merge requires --head SHA" "Pass the exact reviewed head from GitHub."
  read_pr_row
  IFS="$(printf '\t')" read -r number state url head head_repo base base_sha merge_state draft <<<"$PR_ROW"
  [ "$head_repo" != - ] || head_repo=""
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
    # the gate present at the policy's repository and ref, at the policy's
    # revision or a descendant of it published there, with the queue and
    # native rules beside it. A same-path workflow from elsewhere, a pin
    # behind or off that lineage, and a lineage that cannot be resolved are
    # all not the gate.
    read_enforcement "$base" "$base_sha" "$head" "$head_repo" "$number"
    if [ "$JSON_MODE" = false ]; then
      printf 'Enforcement assessed with %s at %s.\n' "$ENFORCEMENT_POLICY_SOURCE" "$ENFORCEMENT_POLICY_REVISION" >&2
      [ -z "$ENFORCEMENT_CANDIDATE_REVISION" ] \
        || printf 'Candidate %s at %s is %s.\n' "$ENFORCEMENT_CANDIDATE_SOURCE" "$ENFORCEMENT_CANDIDATE_REVISION" "$ENFORCEMENT_CANDIDATE_ROLE" >&2
    fi
    if [ "$ENFORCEMENT_STATUS" = applied ]; then
      if [ "$ENFORCEMENT_EXPECTS_REVIEW_GATE" = true ]; then
        rerun_review_gate "$number" "$head" "$base"
        [ "$JSON_MODE" = true ] || printf 'Review gate re-run requested for run %s; GitHub merges when it passes.\n' "$REVIEW_GATE_RUN_ID" >&2
      elif [ "$JSON_MODE" != true ]; then
        printf 'Workflow-source policy applied; GitHub merges when its required source check passes.\n' >&2
      fi
      # A gate re-run may wait for an in-progress run. The source-policy path
      # has no gate to re-run, but both paths must still merge the head and
      # exact base policy whose enforcement was just inspected.
      verify_live_head_and_base "$number" "$head" "$base" "$base_sha"
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
Unguarded merge requested for head \`$head\` by \`touchstone pr merge --unguarded\`: enforcement on \`$base\` is $(enforcement_text) using \`$ENFORCEMENT_POLICY_SOURCE\` at \`$ENFORCEMENT_POLICY_REVISION\`, so GitHub's requirements for this merge differ from that policy by exactly what is listed (other checks or reviews may still have run). Apply that policy revision to close the gap." >/dev/null \
          || fail_operation "could not record the unguarded merge request on PR #$PR_NUMBER" "Inspect GitHub before retrying."
      fi
      # The base inspected and recorded must be the base merged into.
      verify_live_head_and_base "$number" "$head" "$base" "$base_sha"
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
    if [ -n "$ENFORCEMENT_POLICY_REVISION" ]; then
      policy_binding_json_fields
    fi
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
