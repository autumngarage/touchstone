#!/usr/bin/env bash
#
# scripts/touchstone-tracker.sh — tracker-neutral claim/reconcile adapter.
#
# Usage:
#   bash scripts/touchstone-tracker.sh claim <issue> [--project DIR] [--json]
#   bash scripts/touchstone-tracker.sh reconcile <issue> --disposition fixed|partial|stale \
#     --body-file FILE [--note-file FILE] [--project DIR] [--json]

set -euo pipefail

OUTPUT_SCHEMA="touchstone.tracker/v1"
JSON_MODE=false
PROJECT_ARG=""
BODY_FILE=""
NOTE_FILE=""
DISPOSITION=""
OPERATION="${1:-}"
REFERENCE="${2:-}"
TRACKER=""
KEY_PREFIX=""
TRACKER_SECTION_SEEN=false
TRACKER_SCHEMA_SEEN=false
TRACKER_TYPE_SEEN=false
TRACKER_KEYS=""
ROOT_SCHEMA_SEEN=false

usage() {
  sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' >&2
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN { ORS="" }
    {
      gsub(/\\/, "\\\\"); gsub(/\"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
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
  local config="$PROJECT_ROOT/.touchstone.toml" section="" line key value lineno=0
  TRACKER="github"
  [ -f "$config" ] || fail_input missing-config "Create .touchstone.toml before using the tracker adapter."

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(trim "${line%%#*}")"
    [ -n "$line" ] || continue
    case "$line" in
      \[*\])
        if [ "$line" = '[[tracker]]' ]; then
          fail_input malformed-tracker-table "Use one ordinary [tracker] table, not [[tracker]]."
        fi
        section="${line#\[}"
        section="${section%\]}"
        if [ "$section" = tracker ]; then
          [ "$TRACKER_SECTION_SEEN" = false ] || fail_input duplicate-tracker-table "Keep exactly one [tracker] table."
          TRACKER_SECTION_SEEN=true
        fi
        continue
        ;;
      \[*) fail_input malformed-config "Close the section header at .touchstone.toml:$lineno." ;;
    esac
    if [ -z "$section" ]; then
      case "$line" in
        schema=*)
          key=schema
          value="${line#*=}"
          ;;
        schema[[:space:]]*=*)
          key=schema
          value="${line#*=}"
          ;;
        *) continue ;;
      esac
      [ "$ROOT_SCHEMA_SEEN" = false ] \
        || fail_input duplicate-project-schema "Keep exactly one top-level schema declaration."
      value="$(trim "$value")"
      [ "$value" = 1 ] \
        || fail_input unsupported-project-schema "Set the top-level project schema to 1 before using this tracker adapter."
      ROOT_SCHEMA_SEEN=true
      continue
    fi
    [ "$section" = tracker ] || continue
    case "$line" in
      *=*)
        key="$(trim "${line%%=*}")"
        value="${line#*=}"
        ;;
      *) fail_input malformed-config "Use key = value syntax in [tracker] at .touchstone.toml:$lineno." ;;
    esac
    case " $TRACKER_KEYS " in
      *" $key "*) fail_input duplicate-tracker-key "Keep exactly one [tracker].$key declaration." ;;
    esac
    TRACKER_KEYS="$TRACKER_KEYS $key"
    case "$key" in
      schema)
        value="$(trim "$value")"
        [ "$value" = 1 ] || fail_input unsupported-tracker-schema "Set [tracker].schema = 1."
        TRACKER_SCHEMA_SEEN=true
        ;;
      type)
        parse_string "$value" || fail_input malformed-config "Set [tracker].type to a single-line quoted string."
        TRACKER="$PARSED"
        TRACKER_TYPE_SEEN=true
        ;;
      key_prefix)
        parse_string "$value" || fail_input malformed-config "Set [tracker].key_prefix to a single-line quoted string."
        KEY_PREFIX="$PARSED"
        ;;
      *) fail_input unknown-tracker-key "Remove unsupported [tracker] key '$key'." ;;
    esac
  done <"$config"

  [ "$ROOT_SCHEMA_SEEN" = true ] \
    || fail_input missing-project-schema "Add top-level schema = 1 to .touchstone.toml."
  case "$TRACKER" in github | linear) ;; *) fail_input unknown-tracker "Set [tracker].type to \"github\" or \"linear\"." ;; esac
  if [ "$TRACKER_SECTION_SEEN" = true ] && [ "$TRACKER_SCHEMA_SEEN" = false ]; then
    fail_input missing-tracker-schema "Add schema = 1 inside [tracker]."
  fi
  if [ "$TRACKER_SECTION_SEEN" = true ] && [ "$TRACKER_TYPE_SEEN" = false ]; then
    fail_input missing-tracker-type "Add type = \"github\" or type = \"linear\" inside [tracker]."
  fi
  if [ "$TRACKER" = linear ]; then
    printf '%s' "$KEY_PREFIX" | grep -Eq '^[A-Z][A-Z0-9]*$' \
      || fail_input invalid-key-prefix "Set [tracker].key_prefix to the Linear team key, for example \"AUT\"."
  elif [ -n "$KEY_PREFIX" ]; then
    fail_input invalid-key-prefix "Remove key_prefix; it applies only to the Linear tracker."
  fi
}

normalize_reference() {
  local raw="$REFERENCE"
  case "$TRACKER" in
    github)
      raw="${raw#\#}"
      printf '%s' "$raw" | grep -Eq '^[0-9]+$' \
        || fail_input wrong-tracker-reference "Use a GitHub issue number such as #123."
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

resolve_repo() {
  local resolved remote
  resolved="${GH_REPO:-}"
  if [ -z "$resolved" ]; then
    remote="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
    case "$remote" in
      http://* | https://*)
        resolved="${remote#*://}"
        resolved="${resolved#*/}"
        resolved="${resolved%.git}"
        ;;
      git@*:*)
        resolved="${remote#*:}"
        resolved="${resolved%.git}"
        ;;
    esac
  fi
  if [ -z "$resolved" ] && command -v gh >/dev/null 2>&1; then
    resolved="$(cd "$PROJECT_ROOT" && gh repo view --json nameWithOwner --jq '.nameWithOwner // empty' 2>/dev/null || true)"
  fi
  case "$resolved" in */*) CURRENT_REPO="$(printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]')" ;; *) CURRENT_REPO="" ;; esac
}

same_repo_github_closers() {
  local text="$1" match normalized target matches
  matches="$(printf '%s\n' "$text" | grep -Eoi '\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved|closes-issue):?[[:space:]]*([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+\b' || true)"
  [ -n "$matches" ] || return 0
  while IFS= read -r match; do
    normalized="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    target="$(printf '%s' "$normalized" | sed -nE 's,^(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved|closes-issue):?[[:space:]]*([[:alnum:]_.-]+/[[:alnum:]_.-]+)#[0-9]+$,\2,p')"
    if [ -z "$target" ] || [ -z "$CURRENT_REPO" ] || [ "$target" = "$CURRENT_REPO" ]; then
      printf '%s\n' "$match"
    fi
  done <<<"$matches"
}

validate_body() {
  local text wrong expected refs_expected closing_pattern
  [ -f "$BODY_FILE" ] || fail_input missing-body "Provide an existing --body-file."
  text="$(<"$BODY_FILE")"
  resolve_repo
  if [ "$TRACKER" = linear ]; then
    wrong="$(same_repo_github_closers "$text")"
    [ -z "$wrong" ] || fail_input wrong-tracker-closing-syntax "Replace '$wrong' with 'Fixes $REFERENCE'; qualify cross-repository GitHub closes as owner/repo#N."
    expected="Fixes $REFERENCE"
  else
    if printf '%s\n' "$text" | grep -Eqi '\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]*[A-Za-z][A-Za-z0-9]*-[0-9]+\b'; then
      wrong="$(printf '%s\n' "$text" | grep -Eio '\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]*[A-Za-z][A-Za-z0-9]*-[0-9]+\b' | head -n 1)"
      fail_input wrong-tracker-closing-syntax "Replace '$wrong' with 'Closes $REFERENCE'."
    fi
    expected="Closes $REFERENCE"
  fi
  if [ "$DISPOSITION" = fixed ] && ! printf '%s\n' "$text" | grep -Eqi "(^|[[:space:]])${expected// /[[:space:]]+}([[:space:]]|[.,;:!?)]|$)"; then
    fail_input missing-closing-reference "Add '$expected' to the PR body."
  fi
  if [ "$DISPOSITION" != fixed ]; then
    refs_expected="Refs $REFERENCE"
    if ! printf '%s\n' "$text" | grep -Eqi "(^|[[:space:]])${refs_expected// /[[:space:]]+}([[:space:]]|[.,;:!?)]|$)"; then
      fail_input missing-reconciliation-reference "Add '$refs_expected' to the PR body; $DISPOSITION work must not auto-close on merge."
    fi
    if [ "$TRACKER" = github ]; then
      closing_pattern="\\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved|closes-issue):?[[:space:]]*#${ISSUE_ID}\\b"
    else
      closing_pattern="\\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]*${REFERENCE}\\b"
    fi
    if printf '%s\n' "$text" | grep -Eqi "$closing_pattern"; then
      fail_input closing-nonfixed-issue "Replace the closing reference for $REFERENCE with '$refs_expected'."
    fi
  fi
}

claim_github() {
  local output rc
  if ! command -v gh >/dev/null 2>&1; then
    emit failed transport-unavailable "Install and authenticate the gh CLI."
    exit 1
  fi
  set +e
  output="$(cd "$PROJECT_ROOT" && bash "$SCRIPT_ROOT/claim-issue.sh" "$ISSUE_ID" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    emit failed github-claim-failed "$output"
    exit 1
  fi
  emit verified claimed "GitHub assignment was re-read after the claim mutation."
}

claim_linear() {
  emit unverifiable linear-transport-unavailable "Use the Linear API/MCP to assign $REFERENCE to yourself, then verify its assignee from Linear."
  exit 3
}

reconcile_github() {
  local note_url verified_url state verification_status
  if [ "$DISPOSITION" = fixed ]; then
    emit verified closing-reference-present "GitHub will reconcile $REFERENCE from the PR body when the PR merges."
    return 0
  fi
  file_has_content "$NOTE_FILE" || fail_input missing-note "Provide a non-empty --note-file for a $DISPOSITION reconciliation."
  command -v gh >/dev/null 2>&1 || {
    emit failed transport-unavailable "Install and authenticate the gh CLI."
    exit 1
  }
  if [ -z "$CURRENT_REPO" ]; then
    emit failed github-repository-unresolved "Resolve the repository through GH_REPO, the origin remote, or gh before retrying."
    exit 1
  fi
  if ! note_url="$(cd "$PROJECT_ROOT" && gh issue comment "$ISSUE_ID" --body-file "$NOTE_FILE" 2>/dev/null)" || [ -z "$note_url" ]; then
    emit failed github-comment-failed "No reconciliation comment was verified."
    exit 1
  fi
  set +e
  verified_url="$(cd "$PROJECT_ROOT" && gh api --paginate "repos/$CURRENT_REPO/issues/$ISSUE_ID/comments" \
    --jq ".[] | select(.html_url == \"$note_url\") | .html_url" 2>/dev/null)"
  verification_status=$?
  set -e
  if [ "$verification_status" -ne 0 ]; then
    emit failed github-comment-verification-failed "The mutation returned $note_url, but reading the paginated issue timeline failed." true
    exit 1
  fi
  if ! printf '%s\n' "$verified_url" | grep -Fxq "$note_url"; then
    emit failed github-comment-unverified "The mutation returned $note_url, but the paginated issue timeline did not verify it." true
    exit 1
  fi
  if [ "$DISPOSITION" = stale ]; then
    if ! (cd "$PROJECT_ROOT" && gh issue close "$ISSUE_ID" >/dev/null 2>&1); then
      emit failed github-close-failed "The comment was created at $note_url, but closing $REFERENCE failed; retry only the close after inspecting the issue." true
      exit 1
    fi
    set +e
    state="$(cd "$PROJECT_ROOT" && gh issue view "$ISSUE_ID" --json state --jq '.state' 2>/dev/null)"
    verification_status=$?
    set -e
    if [ "$verification_status" -ne 0 ]; then
      emit failed github-close-verification-failed "The comment and close mutations completed, but reading $REFERENCE final state failed." true
      exit 1
    fi
    if [ "$state" != CLOSED ]; then
      emit failed github-close-unverified "The comment was created at $note_url, but $REFERENCE was not verified closed." true
      exit 1
    fi
  fi
  emit verified reconciled "$note_url"
}

reconcile_linear() {
  local action
  case "$DISPOSITION" in
    fixed) action="ensure the PR body retains 'Fixes $REFERENCE' and verify Linear links it to the PR" ;;
    partial) action="post the --note-file contents to $REFERENCE and verify the issue remains open" ;;
    stale) action="post the --note-file contents to $REFERENCE, close it, and verify its final state" ;;
  esac
  if [ "$DISPOSITION" != fixed ] && ! file_has_content "$NOTE_FILE"; then
    fail_input missing-note "Provide a non-empty --note-file for a $DISPOSITION reconciliation."
  fi
  emit unverifiable linear-transport-unavailable "Use the Linear API/MCP to $action."
  exit 3
}

case "$OPERATION" in claim | reconcile) ;; *)
  usage
  exit 2
  ;;
esac
[ -n "$REFERENCE" ] || {
  usage
  exit 2
}
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON_MODE=true
      shift
      ;;
    --project)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      PROJECT_ARG="$2"
      shift 2
      ;;
    --body-file)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      BODY_FILE="$2"
      shift 2
      ;;
    --note-file)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      NOTE_FILE="$2"
      shift 2
      ;;
    --disposition)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      DISPOSITION="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -n "$PROJECT_ARG" ]; then
  PROJECT_ROOT="$(cd "$PROJECT_ARG" 2>/dev/null && pwd -P)" || {
    echo "ERROR: project not found: $PROJECT_ARG" >&2
    exit 2
  }
else
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
fi
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd -P)"

load_tracker
normalize_reference

if [ "$OPERATION" = claim ]; then
  [ -z "$DISPOSITION$BODY_FILE$NOTE_FILE" ] || fail_input invalid-arguments "claim accepts only an issue, --project, and --json."
  if [ "$TRACKER" = github ]; then claim_github; else claim_linear; fi
else
  case "$DISPOSITION" in fixed | partial | stale) ;; *) fail_input invalid-disposition "Use --disposition fixed, partial, or stale." ;; esac
  [ -n "$BODY_FILE" ] || fail_input missing-body "Provide --body-file for reconciliation."
  validate_body
  if [ "$TRACKER" = github ]; then reconcile_github; else reconcile_linear; fi
fi
