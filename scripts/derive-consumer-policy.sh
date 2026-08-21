#!/usr/bin/env bash
#
# scripts/derive-consumer-policy.sh — derive an adopted repository's GitHub
# policy from the canonical Touchstone policy.
#
# Usage:
#   bash scripts/derive-consumer-policy.sh REPOSITORY [--no-queue] [--require-status CONTEXT]... > policy/github/consumers/REPOSITORY.json
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
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
usage() {
  echo "usage: derive-consumer-policy.sh REPOSITORY [--no-queue] [--require-status CONTEXT]..." >&2
  exit 2
}
REPOSITORY="${1:-}"
case "$REPOSITORY" in
  "" | *[!A-Za-z0-9._-]*) usage ;;
esac
shift
QUEUE=true
STATUS_CONTEXTS=()
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
      shift 2
      ;;
    *) usage ;;
  esac
done
if [ "${#STATUS_CONTEXTS[@]}" -gt 0 ]; then
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
