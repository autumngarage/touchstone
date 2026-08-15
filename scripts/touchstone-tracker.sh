#!/usr/bin/env bash
#
# scripts/touchstone-tracker.sh — tracker-neutral claim/reconciliation adapter.
#
# Usage:
#   bash scripts/touchstone-tracker.sh claim <issue> [--project DIR] [--json]
#   bash scripts/touchstone-tracker.sh reconcile <issue> --disposition fixed|partial|stale \
#     [--note-file FILE] [--project DIR] [--json]

set -euo pipefail

OUTPUT_SCHEMA="touchstone.tracker/v1"
JSON_MODE=false
PROJECT_ARG=""
NOTE_FILE=""
DISPOSITION=""
OPERATION="${1:-}"
REFERENCE=""
TRACKER=""
KEY_PREFIX=""
TRACKER_SCHEMA_SEEN=false
TRACKER_TYPE_SEEN=false
TRACKER_KEYS=""
GITHUB_HOST="github.com"

usage() {
  sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' >&2
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN { ORS="" }
    {
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
      for (code = 1; code < 32; code++) {
        if (code == 9 || code == 13) continue
        control = sprintf("%c", code)
        replacement = sprintf("\\u%04x", code)
        gsub(control, replacement)
      }
      if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

emit() {
  local status="$1" reason="$2" remedy="$3" partial="${4:-false}"
  if [ "$JSON_MODE" = true ]; then
    printf '{"schema":"%s","operation":"%s","tracker":"%s","reference":"%s","status":"%s","reason":"%s","partial":%s,"remedy":"%s"}\n' \
      "$OUTPUT_SCHEMA" "$(json_escape "$OPERATION")" "$(json_escape "$TRACKER")" \
      "$(json_escape "$REFERENCE")" "$status" "$(json_escape "$reason")" \
      "$partial" "$(json_escape "$remedy")"
  else
    printf 'tracker %s: %s (%s)\n' "$OPERATION" "$status" "$reason"
    printf '  tracker: %s\n  issue: %s\n' "$TRACKER" "$REFERENCE"
    [ -z "$remedy" ] || printf '  remedy: %s\n' "$remedy"
  fi
}

fail_input() {
  emit failed "$1" "$2"
  exit 2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

file_has_content() {
  [ -f "$1" ] && grep -q '[^[:space:]]' "$1"
}

parse_string() {
  local raw
  raw="$(trim "$1")"
  case "$raw" in
    \"*\")
      raw="${raw#\"}"
      raw="${raw%\"}"
      ;;
    *) return 1 ;;
  esac
  case "$raw" in *\"* | *\\*) return 1 ;; esac
  PARSED="$raw"
}

load_tracker() {
  local config="$PROJECT_ROOT/.touchstone-tracker.toml" line key value lineno=0
  TRACKER="github"
  [ ! -L "$config" ] \
    || fail_input unsafe-config "Replace the .touchstone-tracker.toml symlink with a reviewed regular file in this repository."
  [ -e "$config" ] || return 0
  [ -f "$config" ] \
    || fail_input unsafe-config "Replace .touchstone-tracker.toml with a reviewed regular file."

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(trim "${line%%#*}")"
    [ -n "$line" ] || continue
    case "$line" in
      *=*)
        key="$(trim "${line%%=*}")"
        value="${line#*=}"
        ;;
      *) fail_input malformed-config "Use key = value syntax at .touchstone-tracker.toml:$lineno." ;;
    esac
    case " $TRACKER_KEYS " in
      *" $key "*) fail_input duplicate-tracker-key "Keep exactly one tracker $key declaration." ;;
    esac
    TRACKER_KEYS="$TRACKER_KEYS $key"
    case "$key" in
      schema)
        value="$(trim "$value")"
        [ "$value" = 1 ] || fail_input unsupported-tracker-schema "Set schema = 1 in .touchstone-tracker.toml."
        TRACKER_SCHEMA_SEEN=true
        ;;
      type)
        parse_string "$value" || fail_input malformed-config "Set type to a single-line quoted string."
        TRACKER="$PARSED"
        TRACKER_TYPE_SEEN=true
        ;;
      key_prefix)
        parse_string "$value" || fail_input malformed-config "Set key_prefix to a single-line quoted string."
        KEY_PREFIX="$PARSED"
        ;;
      *) fail_input unknown-tracker-key "Remove unsupported tracker key '$key'." ;;
    esac
  done <"$config"

  case "$TRACKER" in github | linear) ;; *) fail_input unknown-tracker "Set type to \"github\" or \"linear\"." ;; esac
  [ "$TRACKER_SCHEMA_SEEN" = true ] \
    || fail_input missing-tracker-schema "Add schema = 1 to .touchstone-tracker.toml."
  [ "$TRACKER_TYPE_SEEN" = true ] \
    || fail_input missing-tracker-type "Add type = \"github\" or type = \"linear\" to .touchstone-tracker.toml."
  if [ "$TRACKER" = linear ]; then
    printf '%s' "$KEY_PREFIX" | grep -Eq '^[A-Z][A-Z0-9]*$' \
      || fail_input invalid-key-prefix "Set key_prefix to the Linear team key, for example \"AUT\"."
  elif [ -n "$KEY_PREFIX" ]; then
    fail_input invalid-key-prefix "Remove key_prefix; it applies only to the Linear tracker."
  fi
}

validate_project_contract() {
  local output status
  set +e
  output="$(bash "$SCRIPT_ROOT/touchstone-run.sh" validate --check-contract \
    --project "$PROJECT_ROOT" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 0 ] \
    || fail_input invalid-project-contract "$output"
}

normalize_reference() {
  local raw="$REFERENCE"
  case "$TRACKER" in
    github)
      raw="${raw#\#}"
      printf '%s' "$raw" | grep -Eq '^[0-9]+$' \
        || fail_input wrong-tracker-reference "Use a GitHub issue number such as 123, or quote '#123'."
      REFERENCE="#$raw"
      ISSUE_ID="$raw"
      ;;
    linear)
      raw="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
      printf '%s' "$raw" | grep -Eq "^${KEY_PREFIX}-[0-9]+$" \
        || fail_input wrong-tracker-reference "Use a Linear issue key such as ${KEY_PREFIX}-123."
      REFERENCE="$raw"
      ISSUE_ID="$raw"
      ;;
  esac
}

set_canonical_repo_identity() {
  local identity="$1" fallback_host="$2" authority host repo
  host=""
  repo=""

  case "$identity" in
    http://* | https://*)
      authority="${identity#*://}"
      host="${authority%%/*}"
      repo="${authority#*/}"
      ;;
    ssh://*)
      authority="${identity#ssh://}"
      authority="${authority#*@}"
      host="${authority%%/*}"
      host="${host%%:*}"
      repo="${authority#*/}"
      ;;
    *@*:*)
      authority="${identity#*@}"
      host="${authority%%:*}"
      repo="${identity#*:}"
      ;;
    */*/*)
      host="${identity%%/*}"
      repo="${identity#*/}"
      ;;
    */*)
      host="$fallback_host"
      repo="$identity"
      ;;
    *) return 1 ;;
  esac

  repo="${repo%.git}"
  case "$host" in "" | */* | *@*) return 1 ;; esac
  case "$repo" in "" | /* | */ | */*/*) return 1 ;; esac
  GITHUB_HOST="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  CURRENT_REPO="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
}

resolve_repo() {
  local identity remote fallback_host="${GH_HOST:-github.com}"
  CURRENT_REPO=""

  identity="${GH_REPO:-}"
  if [ -n "$identity" ]; then
    set_canonical_repo_identity "$identity" "$fallback_host" || true
    return
  fi

  remote="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  if [ -n "$remote" ] && set_canonical_repo_identity "$remote" "$fallback_host"; then
    return
  fi

  if command -v gh >/dev/null 2>&1; then
    identity="$(cd "$PROJECT_ROOT" && gh repo view --json url --jq '.url // empty' 2>/dev/null || true)"
    [ -z "$identity" ] || set_canonical_repo_identity "$identity" "$fallback_host" || true
  fi
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

claim_github() {
  local output rc partial
  if ! command -v gh >/dev/null 2>&1; then
    emit unverifiable transport-unavailable "Install and authenticate the gh CLI."
    exit 3
  fi
  set +e
  output="$(cd "$PROJECT_ROOT" && bash "$SCRIPT_ROOT/claim-issue.sh" "$ISSUE_ID" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    partial=false
    printf '%s\n' "$output" | grep -Fx '==> touchstone-claim-state: assignment-mutated' >/dev/null && partial=true
    emit failed github-claim-failed "$output" "$partial"
    exit 1
  fi
  emit verified claimed "GitHub assignment was re-read after the claim mutation."
}

claim_linear() {
  emit unverifiable linear-transport-unavailable "Use the Linear API/MCP to assign $REFERENCE to yourself, then verify its assignee from Linear."
  exit 3
}

read_github_issue_state() {
  local status=0
  set +e
  GITHUB_STATE_ROW="$(cd "$PROJECT_ROOT" && gh issue view "$ISSUE_ID" \
    --repo "$GITHUB_HOST/$CURRENT_REPO" --json state,stateReason \
    --jq '[.state,.stateReason] | @tsv' 2>/dev/null)"
  status=$?
  set -e
  return "$status"
}

reconcile_github() {
  local note_url verified_url state state_reason verification_status
  command -v gh >/dev/null 2>&1 || {
    emit unverifiable transport-unavailable "Install and authenticate the gh CLI."
    exit 3
  }
  resolve_repo
  if [ -z "$CURRENT_REPO" ]; then
    emit failed github-repository-unresolved "Resolve the repository through GH_REPO, the origin remote, or gh before retrying."
    exit 1
  fi

  if [ "$DISPOSITION" = fixed ]; then
    if ! read_github_issue_state; then
      emit failed github-close-verification-failed "Reading $REFERENCE final state failed."
      exit 1
    fi
    IFS="$(printf '\t')" read -r state state_reason <<<"$GITHUB_STATE_ROW"
    if [ "$state" = OPEN ]; then
      emit unverifiable merge-close-pending "$REFERENCE is still open; verify again after the PR reaches the default branch."
      exit 3
    fi
    if [ "$state" != CLOSED ] || [ "$state_reason" != COMPLETED ]; then
      emit failed github-fixed-state-mismatch "$REFERENCE did not finish as a completed closure."
      exit 1
    fi
    emit verified reconciled "$REFERENCE is closed as completed in GitHub."
    return 0
  fi

  file_has_content "$NOTE_FILE" || fail_input missing-note "Provide a non-empty --note-file for a $DISPOSITION reconciliation."
  if ! note_url="$(cd "$PROJECT_ROOT" && gh issue comment "$ISSUE_ID" \
    --repo "$GITHUB_HOST/$CURRENT_REPO" --body-file "$NOTE_FILE" 2>/dev/null)" || [ -z "$note_url" ]; then
    emit failed github-comment-failed "No reconciliation comment was verified."
    exit 1
  fi
  set +e
  verified_url="$(cd "$PROJECT_ROOT" && gh api --paginate --hostname "$GITHUB_HOST" \
    "repos/$CURRENT_REPO/issues/$ISSUE_ID/comments" \
    --jq ".[] | select(.html_url == \"$note_url\") | .html_url" 2>/dev/null)"
  verification_status=$?
  set -e
  if [ "$verification_status" -ne 0 ]; then
    emit failed github-comment-verification-failed "The mutation returned $note_url, but reading the paginated issue timeline failed." true
    exit 1
  fi
  if ! grep -Fxq "$note_url" <<<"$verified_url"; then
    emit failed github-comment-unverified "The mutation returned $note_url, but the paginated issue timeline did not verify it." true
    exit 1
  fi

  if [ "$DISPOSITION" = stale ]; then
    if ! (cd "$PROJECT_ROOT" && gh issue close "$ISSUE_ID" \
      --repo "$GITHUB_HOST/$CURRENT_REPO" --reason 'not planned' >/dev/null 2>&1); then
      emit failed github-close-failed "The comment was created at $note_url, but closing $REFERENCE failed; inspect the issue before retrying only the close." true
      exit 1
    fi
  fi

  if ! read_github_issue_state; then
    emit failed github-state-verification-failed "The tracker mutation completed, but reading $REFERENCE final state failed." true
    exit 1
  fi
  IFS="$(printf '\t')" read -r state state_reason <<<"$GITHUB_STATE_ROW"
  if [ "$DISPOSITION" = partial ] && [ "$state" != OPEN ]; then
    emit failed github-open-unverified "The comment was created at $note_url, but $REFERENCE was not verified open; reopen it after inspecting the merge." true
    exit 1
  fi
  if [ "$DISPOSITION" = stale ] && { [ "$state" != CLOSED ] || [ "$state_reason" != NOT_PLANNED ]; }; then
    emit failed github-stale-state-unverified "The comment was created at $note_url, but $REFERENCE was not verified closed as not planned." true
    exit 1
  fi
  emit verified reconciled "$note_url"
}

reconcile_linear() {
  local action
  case "$DISPOSITION" in
    fixed) action="verify Linear links the merged PR to $REFERENCE and marks it complete" ;;
    partial) action="post the --note-file contents to $REFERENCE and verify the issue remains open" ;;
    stale) action="post the --note-file contents to $REFERENCE, cancel it, and verify its final state" ;;
  esac
  if [ "$DISPOSITION" != fixed ] && ! file_has_content "$NOTE_FILE"; then
    fail_input missing-note "Provide a non-empty --note-file for a $DISPOSITION reconciliation."
  fi
  emit unverifiable linear-transport-unavailable "Use the Linear API/MCP to $action."
  exit 3
}

for argument in "$@"; do
  [ "$argument" != --json ] || JSON_MODE=true
done

case "$OPERATION" in -h | --help)
  usage
  exit 0
  ;;
esac
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON_MODE=true
      shift
      ;;
    --project)
      [ "$#" -ge 2 ] || fail_input missing-option-value "Pass a directory after --project."
      case "$2" in '' | --*) fail_input missing-option-value "Pass a directory after --project." ;; esac
      PROJECT_ARG="$2"
      shift 2
      ;;
    --note-file)
      [ "$#" -ge 2 ] || fail_input missing-option-value "Pass a file after --note-file."
      case "$2" in '' | --*) fail_input missing-option-value "Pass a file after --note-file." ;; esac
      NOTE_FILE="$2"
      shift 2
      ;;
    --disposition)
      [ "$#" -ge 2 ] || fail_input missing-option-value "Pass fixed, partial, or stale after --disposition."
      case "$2" in '' | --*) fail_input missing-option-value "Pass fixed, partial, or stale after --disposition." ;; esac
      DISPOSITION="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --*)
      fail_input unknown-argument "Remove unsupported argument '$1'."
      ;;
    *)
      [ -z "$REFERENCE" ] || fail_input unexpected-positional "Pass exactly one issue reference."
      REFERENCE="$1"
      shift
      ;;
  esac
done

case "$OPERATION" in claim | reconcile) ;; *)
  fail_input unknown-operation "Use claim or reconcile."
  ;;
esac
[ -n "$REFERENCE" ] || fail_input missing-reference "Pass the configured tracker issue after '$OPERATION'."

if [ -n "$PROJECT_ARG" ]; then
  PROJECT_ROOT="$(cd "$PROJECT_ARG" 2>/dev/null && pwd -P)" || {
    fail_input project-not-found "Pass an existing project directory; '$PROJECT_ARG' was not found."
  }
else
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
fi
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
[ -z "$NOTE_FILE" ] || NOTE_FILE="$(absolute_input_file "$NOTE_FILE")"

validate_project_contract
load_tracker
normalize_reference

if [ "$OPERATION" = claim ]; then
  [ -z "$DISPOSITION$NOTE_FILE" ] || fail_input invalid-arguments "claim accepts only an issue, --project, and --json."
  if [ "$TRACKER" = github ]; then claim_github; else claim_linear; fi
else
  case "$DISPOSITION" in fixed | partial | stale) ;; *) fail_input invalid-disposition "Use --disposition fixed, partial, or stale." ;; esac
  if [ "$TRACKER" = github ]; then reconcile_github; else reconcile_linear; fi
fi
