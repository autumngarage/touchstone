#!/usr/bin/env bash
#
# scripts/derive-consumer-policy.sh — derive an adopted repository's GitHub
# policy from the canonical Touchstone policy.
#
# Usage:
#   bash scripts/derive-consumer-policy.sh REPOSITORY [--no-queue]
#     [--require-status CONTEXT]...
#     [--require-merge-group-status CONTEXT]...
#     > policy/github/consumers/REPOSITORY.json
#
# A consumer's policy is the canonical policy with the repository name
# substituted everywhere it appears as an ownership coordinate, and without
# Touchstone's own rollback prerequisites (the legacy local workflow no
# consumer ever carried). Nothing else may differ: one contract, many
# repositories. tests/test-github-policy.sh refuses a checked-in consumer
# policy that does not equal this derivation.
#
# --no-queue drops the companion merge-queue ruleset for a repository whose
# current GitHub plan or visibility does not support it. The compatibility
# evidence lives in policy/github/README.md; the pinned required workflows,
# PR-only delivery, thread resolution, and native rules still apply. The queue
# returns when eligibility changes by regenerating without this flag.
#
# --require-status CONTEXT (repeatable) adds one repository-owned required
# status check to a queue-less consumer's ruleset, on top of the pinned
# workflows. Without it, applying the derived policy could silently stop
# requiring a pull-request-only gate the project relies on. It is the only
# per-consumer variation besides the queue: the canonical rules are never
# removed or weakened, only joined by a context the consumer names and owns.
#
# --require-merge-group-status CONTEXT is the queued counterpart. It makes the
# same required-status declaration while keeping the merge queue, and is an
# explicit assertion that the repository-owned publisher runs for
# `merge_group`. Convoy's `convoy/delivery-protocol` publisher uses this flag.
# Keeping the two flags distinct makes the event contract checked-in data
# instead of guessing from a status name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
usage() {
  echo "usage: derive-consumer-policy.sh REPOSITORY [--no-queue] [--require-status CONTEXT]... [--require-merge-group-status CONTEXT]... [--path-set NAME=FILE]..." >&2
  exit 2
}
REPOSITORY="${1:-}"
case "$REPOSITORY" in
  "" | *[!A-Za-z0-9._-]*) usage ;;
esac
shift
QUEUE=true
STATUS_CONTEXTS=()
# Counted explicitly: under bash 3.2 with set -u, ${#array[@]} on an empty
# array is an unbound-variable error.
STATUS_COUNT=0
STATUS_EVENT=""
PATH_SET_NAMES=()
PATH_SET_FILES=()
PATH_SET_COUNT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-queue)
      QUEUE=false
      shift
      ;;
    --require-status)
      [ "$#" -ge 2 ] || usage
      # A status context is whatever the publishing workflow named it --
      # `validate (ubuntu-latest)` is a normal Actions shape -- so only the
      # unrepresentable is refused: empty, or containing a line break.
      case "$2" in
        "" | *$'\n'* | *$'\r'*) usage ;;
      esac
      STATUS_CONTEXTS+=("$2")
      STATUS_COUNT=$((STATUS_COUNT + 1))
      [ -z "$STATUS_EVENT" ] || [ "$STATUS_EVENT" = pull_request ] || usage
      STATUS_EVENT=pull_request
      shift 2
      ;;
    --require-merge-group-status)
      [ "$#" -ge 2 ] || usage
      case "$2" in
        "" | *$'\n'* | *$'\r'*) usage ;;
      esac
      STATUS_CONTEXTS+=("$2")
      STATUS_COUNT=$((STATUS_COUNT + 1))
      [ -z "$STATUS_EVENT" ] || [ "$STATUS_EVENT" = merge_group ] || usage
      STATUS_EVENT=merge_group
      shift 2
      ;;
    --path-set)
      # NAME=FILE, the file holding the set's patterns in gitignore syntax.
      # A file rather than an inline list because the patterns are a
      # multi-line language whose comments and blank lines are part of it,
      # and because the declaration should be reviewable as itself.
      [ "$#" -ge 2 ] || usage
      case "$2" in
        *=*) ;;
        *) usage ;;
      esac
      ps_name="${2%%=*}"
      ps_file="${2#*=}"
      case "$ps_name" in
        "" | *[!A-Za-z0-9._-]*) usage ;;
      esac
      [ -n "$ps_file" ] && [ -f "$ps_file" ] || {
        echo "derive-consumer-policy.sh: --path-set $ps_name names no readable file: $ps_file" >&2
        exit 2
      }
      for existing in ${PATH_SET_NAMES+"${PATH_SET_NAMES[@]}"}; do
        [ "$existing" != "$ps_name" ] || {
          echo "derive-consumer-policy.sh: --path-set $ps_name declared twice" >&2
          exit 2
        }
      done
      PATH_SET_NAMES+=("$ps_name")
      PATH_SET_FILES+=("$ps_file")
      PATH_SET_COUNT=$((PATH_SET_COUNT + 1))
      shift 2
      ;;
    *) usage ;;
  esac
done
# A pull-request status cannot gate a queued consumer: the queue commit would
# never carry the context and every entry would be rejected. The distinct
# merge-group flag is the explicit assertion that makes the queued case safe.
if [ "$STATUS_COUNT" -gt 0 ] && [ "$QUEUE" = true ] && [ "$STATUS_EVENT" != merge_group ]; then
  echo "derive-consumer-policy.sh: --require-status needs --no-queue; a pull_request-only publisher never reports on a merge-queue commit" >&2
  exit 2
fi
if [ "$STATUS_COUNT" -gt 0 ] && [ "$QUEUE" = false ] && [ "$STATUS_EVENT" = merge_group ]; then
  echo "derive-consumer-policy.sh: --require-merge-group-status needs the merge queue; use --require-status for a queue-less consumer" >&2
  exit 2
fi
if [ "$STATUS_COUNT" -gt 0 ]; then
  contexts_json="$(printf '%s\n' "${STATUS_CONTEXTS[@]}" | jq -R . | jq -s 'unique')"
else
  contexts_json='[]'
fi

# Path sets are omitted entirely when none is declared, rather than emitted as
# an empty object: no repository gains classification behaviour by accident,
# and a consumer asking for a set it never declared must get the error, not an
# empty set that silently classifies every head as `none`.
path_sets_json='null'
if [ "$PATH_SET_COUNT" -gt 0 ]; then
  path_sets_json='{}'
  i=0
  while [ "$i" -lt "$PATH_SET_COUNT" ]; do
    ps_name="${PATH_SET_NAMES[$i]}"
    ps_file="${PATH_SET_FILES[$i]}"
    # Blank lines and whole-line comments are gitignore's own syntax for the
    # declaration file; they carry no rule, so they do not reach the policy.
    # A pattern that really begins with '#' is written '\#' in gitignore and
    # survives, because only an unescaped leading '#' is a comment.
    # `|| true` on the filter: a file of nothing but comments makes grep exit
    # 1, and under `set -o pipefail` that aborted the script with status 1
    # before the "declares no patterns" refusal below could run. Exit 1 is a
    # meaningful answer elsewhere in this surface, so an input error arriving
    # as 1 is the same defect the matcher's EXIT trap had.
    # Only a CR is stripped, and only because it is a line-ending artefact of a
    # file authored on Windows. Trailing whitespace is NOT stripped: gitignore
    # gives it meaning -- `foo\ ` is a pattern ending in a literal space -- and
    # normalising it here would store a pattern that differs from the
    # declaration, which the drift check cannot catch because it re-derives
    # from what was already stored. git owns these semantics; this does not.
    ps_filtered="$(tr -d '\r' <"$ps_file" \
      | { grep -v -e '^[[:space:]]*$' -e '^#' || true; })"
    [ -n "$ps_filtered" ] || {
      echo "derive-consumer-policy.sh: --path-set $ps_name declares no patterns: $ps_file" >&2
      exit 2
    }
    patterns_json="$(printf '%s\n' "$ps_filtered" | jq -R . | jq -sc .)"
    path_sets_json="$(jq -c --arg n "$ps_name" --argjson p "$patterns_json" \
      '.[$n] = $p' <<<"$path_sets_json")"
    i=$((i + 1))
  done
fi

derived="$(jq --arg repo "$REPOSITORY" --argjson queue "$QUEUE" --argjson contexts "$contexts_json" --argjson pathSets "$path_sets_json" '
  .repository = $repo
  | .rollbackPrerequisites.repositoryFiles = []
  | .managedRuleset.name = "Touchstone policy v\(.contractVersion): \(.organization)/\($repo)@\(.branch)"
  | .managedRuleset.conditions.repository_name.include = [$repo]
  | if ($contexts | length) > 0 then
      .managedRuleset.rules += [{
        type: "required_status_checks",
        parameters: {
          strict_required_status_checks_policy: false,
          do_not_enforce_on_create: false,
          required_status_checks: [$contexts[] | {context: .}]
        }
      }]
    else . end
  | if $queue then
      .managedRepositoryRuleset.name = "Touchstone merge queue v\(.contractVersion): \(.organization)/\($repo)@\(.branch)"
    else
      .managedRepositoryRuleset = null
    end
  | if $pathSets == null then . else .pathSets = $pathSets end
' "$ROOT/policy/github/touchstone-main.json")"

# The refusal runs here, at derivation, and it is the SAME check the matcher
# runs at evaluation -- one code path, so a set cannot be accepted by the tool
# that writes the policy and refused by the tool that reads it. AUT-1242 states
# the rule as refused "when it is applied, not when it is used"; that is only
# safe if both ends agree, and they agree by being the same function.
if [ "$path_sets_json" != null ]; then
  derived_check="$(mktemp -t touchstone-derive-check.XXXXXX)"
  trap 'rm -f "$derived_check"' EXIT
  printf '%s\n' "$derived" >"$derived_check"
  # Once, capturing: running it again to obtain the message for a failure it
  # had already diagnosed would repeat the whole match and could in principle
  # print a different one.
  if ! check_output="$(bash "$ROOT/scripts/touchstone-paths.sh" check --policy "$derived_check" 2>&1)"; then
    printf '%s\n' "$check_output" >&2
    exit 2
  fi
fi
printf '%s\n' "$derived"
