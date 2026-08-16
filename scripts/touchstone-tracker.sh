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
REFERENCE=""
TRACKER=""
KEY_PREFIX=""
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd -P)"

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

tracker_contract_failure() {
  fail_input "$1" "$2"
}

# shellcheck disable=SC1091 # source resolves from the installed CLI root.
source "$SCRIPT_ROOT/lib/touchstone-tracker-config.sh"

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

case "$OPERATION" in claim) ;; *)
  fail_input unknown-operation "Use the claim operation."
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
validate_project_contract
load_tracker_contract "$PROJECT_ROOT/.touchstone-tracker.toml"
normalize_reference

if [ "$TRACKER" = github ]; then claim_github; else claim_linear; fi
