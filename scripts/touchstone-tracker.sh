#!/usr/bin/env bash
#
# scripts/touchstone-tracker.sh — tracker-neutral claim adapter.
#
# Usage:
#   bash scripts/touchstone-tracker.sh claim <issue> [--project DIR] [--json]

set -euo pipefail

OUTPUT_SCHEMA="touchstone.tracker/v1"
JSON_MODE=false
PROJECT_ARG=""
OPERATION="${1:-}"
REFERENCE="${2:-}"
TRACKER=""
KEY_PREFIX=""
TRACKER_SCHEMA_SEEN=false
TRACKER_TYPE_SEEN=false
TRACKER_KEYS=""

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

claim_github() {
  local output rc partial
  if ! command -v gh >/dev/null 2>&1; then
    emit failed transport-unavailable "Install and authenticate the gh CLI."
    exit 1
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

case "$OPERATION" in claim) ;; *)
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
      [ "$#" -ge 2 ] || fail_input missing-option-value "Pass a directory after --project."
      PROJECT_ARG="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail_input unknown-argument "Remove unsupported argument '$1'."
      ;;
  esac
done

if [ -n "$PROJECT_ARG" ]; then
  PROJECT_ROOT="$(cd "$PROJECT_ARG" 2>/dev/null && pwd -P)" || {
    fail_input project-not-found "Pass an existing project directory; '$PROJECT_ARG' was not found."
  }
else
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
fi
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd -P)"

validate_project_contract
load_tracker
normalize_reference

if [ "$TRACKER" = github ]; then claim_github; else claim_linear; fi
