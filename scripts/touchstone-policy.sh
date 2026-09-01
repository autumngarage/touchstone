#!/usr/bin/env bash
# scripts/touchstone-policy.sh — explicit, versioned remote-policy mutation.

set -euo pipefail

SCHEMA="touchstone.policy/v1"
MAXIMUM_STATUS_BYTES=65536
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CANONICAL_POLICY="$ROOT/policy/github/touchstone-main.json"
OPERATION="${1:-}"
[ "$#" -gt 0 ] && shift

PROJECT=""
BASE=""
JSON_MODE=false
AUTHORIZED=false
TEMP_DIR=""

# Output mode is selected before validating operands so even a malformed
# machine invocation receives the promised machine-readable refusal.
for argument in "$@"; do
  [ "$argument" != --json ] || JSON_MODE=true
done

cleanup() {
  [ -z "$TEMP_DIR" ] || rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

emit() {
  local status="$1" repository="$2" detail="$3"
  if [ "$JSON_MODE" = true ]; then
    jq -cn \
      --arg schema "$SCHEMA" \
      --arg operation "policy-apply" \
      --arg repository "$repository" \
      --arg baseRef "$BASE" \
      --arg status "$status" \
      --arg detail "$detail" \
      '{schema:$schema,operation:$operation,repository:$repository,baseRef:$baseRef,status:$status,detail:$detail}'
  else
    printf '%s: %s\n' "$status" "$detail"
  fi
}

fail_input() {
  emit action-required "" "$1"
  exit 2
}

usage() {
  fail_input "Usage: touchstone policy apply --project DIR --base BRANCH --authorize-admin [--json]"
}

[ "$OPERATION" = apply ] || usage
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      case "$2" in --*) usage ;; esac
      PROJECT="$2"
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      case "$2" in --*) usage ;; esac
      BASE="$2"
      shift 2
      ;;
    --authorize-admin)
      AUTHORIZED=true
      shift
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    *) usage ;;
  esac
done

[ -n "$PROJECT" ] && [ -n "$BASE" ] || usage
[ "$AUTHORIZED" = true ] \
  || fail_input "Policy apply requires the explicit --authorize-admin acknowledgement."
[ -d "$PROJECT" ] || fail_input "The project directory is not accessible."
PROJECT="$(cd -- "$PROJECT" && pwd -P)"

for tool in jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail_input "$tool is required to apply policy."
done
[ -r "$CANONICAL_POLICY" ] \
  || fail_input "The installed Touchstone policy is unavailable; reinstall Touchstone."
if ! jq -e '
  .contractVersion == 1
  and (.organization | type == "string" and test("^[A-Za-z0-9._-]+$"))
  and (.branch | type == "string" and length > 0)
' "$CANONICAL_POLICY" >/dev/null; then
  fail_input "The installed Touchstone policy is invalid; reinstall Touchstone."
fi

# The status boundary already owns project-to-GitHub resolution and the exact
# effective-policy interpretation. Keep its bytes private until they pass the
# small versioned shape below; provider diagnostics never become this API.
if ! TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-policy.XXXXXX")"; then
  emit action-required "" "Touchstone could not create private temporary storage for policy apply."
  exit 1
fi
STATUS_FILE="$TEMP_DIR/status.json"
DIAGNOSTIC_FILE="$TEMP_DIR/diagnostic"
if ! bash "$ROOT/scripts/touchstone-pr.sh" policy-status \
  --project "$PROJECT" --base "$BASE" --json >"$STATUS_FILE" 2>"$DIAGNOSTIC_FILE"; then
  emit action-required "" "Touchstone could not read this repository's effective policy. Check GitHub authentication and repository access, then retry."
  exit 1
fi
[ "$(wc -c <"$STATUS_FILE" | tr -d ' ')" -le "$MAXIMUM_STATUS_BYTES" ] \
  || {
    emit action-required "" "Touchstone returned an oversized policy status; reinstall Touchstone."
    exit 1
  }
if ! jq -e '
  .schema == "touchstone.pr/v2"
  and .operation == "policy-status"
  and (.repository | type == "string" and test("^[^/]+/[^/]+$"))
  and (.baseRef | type == "string" and length > 0)
  and (.enforcement.status == "applied" or .enforcement.status == "partial" or .enforcement.status == "none")
  and (.enforcement.missing | type == "array")
' "$STATUS_FILE" >/dev/null; then
  emit action-required "" "The installed Touchstone returned an unsupported policy status; reinstall Touchstone."
  exit 1
fi

REPOSITORY="$(jq -r .repository "$STATUS_FILE")"
STATUS_BASE="$(jq -r .baseRef "$STATUS_FILE")"
[ "$STATUS_BASE" = "$BASE" ] \
  || {
    emit action-required "$REPOSITORY" "GitHub resolved a different protected branch; refresh the project and retry."
    exit 1
  }
if [ "$(jq -r .enforcement.status "$STATUS_FILE")" = applied ] \
  && [ "$(jq '.enforcement.missing | length' "$STATUS_FILE")" -eq 0 ]; then
  emit already-applied "$REPOSITORY" "The required GitHub delivery policy is already applied."
  exit 0
fi

ORGANIZATION="$(jq -r .organization "$CANONICAL_POLICY")"
POLICY_BRANCH="$(jq -r .branch "$CANONICAL_POLICY")"
case "$REPOSITORY" in
  "$ORGANIZATION"/*) ;;
  *)
    emit action-required "$REPOSITORY" "This Touchstone release supports policy apply only for the $ORGANIZATION organization."
    exit 1
    ;;
esac
[ "$BASE" = "$POLICY_BRANCH" ] || {
  emit action-required "$REPOSITORY" "This Touchstone release protects $POLICY_BRANCH; the selected project uses $BASE."
  exit 1
}

NAME="${REPOSITORY#*/}"
DERIVED_POLICY="$TEMP_DIR/policy.json"
if ! bash "$ROOT/scripts/derive-consumer-policy.sh" "$NAME" >"$DERIVED_POLICY" 2>"$DIAGNOSTIC_FILE"; then
  emit action-required "$REPOSITORY" "Touchstone could not derive the supported delivery policy; reinstall Touchstone."
  exit 1
fi

# github-policy.sh is the sole mutation implementation. Its transaction owns
# rollback and verification. Its operator diagnostics remain private so a
# provider body or credential-adjacent detail can never cross this API.
if ! bash "$ROOT/scripts/github-policy.sh" apply "$DERIVED_POLICY" \
  >"$DIAGNOSTIC_FILE" 2>&1; then
  emit action-required "$REPOSITORY" "GitHub did not accept the policy change. Sign in with an organization administrator account, confirm repository access, then retry."
  exit 1
fi

if ! bash "$ROOT/scripts/touchstone-pr.sh" policy-status \
  --project "$PROJECT" --base "$BASE" --json >"$STATUS_FILE" 2>"$DIAGNOSTIC_FILE" \
  || [ "$(wc -c <"$STATUS_FILE" | tr -d ' ')" -gt "$MAXIMUM_STATUS_BYTES" ] \
  || ! jq -e '
    .schema == "touchstone.pr/v2"
    and .operation == "policy-status"
    and .repository == $repository
    and .baseRef == $base
    and .enforcement.status == "applied"
    and (.enforcement.missing | length) == 0
  ' --arg repository "$REPOSITORY" --arg base "$BASE" "$STATUS_FILE" >/dev/null; then
  emit action-required "$REPOSITORY" "Touchstone changed policy but could not verify the exact repository and branch. Retry; the operation is idempotent."
  exit 1
fi

emit applied "$REPOSITORY" "The required GitHub delivery policy was applied and verified."
