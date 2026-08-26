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
# --no-queue drops the companion merge-queue ruleset. GitHub accepts the
# merge_queue rule on a private repository only under Enterprise Cloud
# (measured 2026-08-21: "Invalid rule 'merge_queue'" on autumngarage/vesper
# and /arpeggio, Team plan); the pinned required workflows, PR-only delivery,
# thread resolution, and the native rules still apply. The queue returns to
# such a consumer the day the plan or the visibility changes, by regenerating
# without the flag.
#
# --require-status CONTEXT (repeatable) adds one repository-owned required
# status check to the consumer's ruleset, on top of the pinned workflows. It
# exists for a consumer whose own workflow publishes a merge-blocking status
# the contract does not know about (convoy's `convoy/delivery-protocol` PR
# body check); without it, applying the derived policy would silently stop
# requiring a gate the project relies on. It is the only per-consumer
# variation besides the queue: the canonical rules are never removed or
# weakened, only joined by a context the consumer names and owns.
#
# --require-merge-group-status CONTEXT is the queued counterpart. It makes the
# same required-status declaration while keeping the merge queue, and is an
# explicit assertion that the repository-owned publisher runs for
# `merge_group`. Keeping the two flags distinct makes the event contract
# checked-in data instead of guessing from a status name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
usage() {
  echo "usage: derive-consumer-policy.sh REPOSITORY [--no-queue] [--require-status CONTEXT]... [--require-merge-group-status CONTEXT]..." >&2
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
jq --arg repo "$REPOSITORY" --argjson queue "$QUEUE" --argjson contexts "$contexts_json" '
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
' "$ROOT/policy/github/touchstone-main.json"
