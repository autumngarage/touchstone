#!/usr/bin/env bash
#
# scripts/derive-consumer-policy.sh — derive an adopted repository's GitHub
# policy from the canonical Touchstone policy.
#
# Usage:
#   bash scripts/derive-consumer-policy.sh REPOSITORY [--no-queue] > policy/github/consumers/REPOSITORY.json
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
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPOSITORY="${1:-}"
QUEUE=true
case "$REPOSITORY" in
  "" | *[!A-Za-z0-9._-]*)
    echo "usage: derive-consumer-policy.sh REPOSITORY [--no-queue]" >&2
    exit 2
    ;;
esac
case "${2:-}" in
  "") ;;
  --no-queue) QUEUE=false ;;
  *)
    echo "usage: derive-consumer-policy.sh REPOSITORY [--no-queue]" >&2
    exit 2
    ;;
esac
jq --arg repo "$REPOSITORY" --argjson queue "$QUEUE" '
  .repository = $repo
  | .rollbackPrerequisites.repositoryFiles = []
  | .managedRuleset.name = "Touchstone policy v\(.contractVersion): \(.organization)/\($repo)@\(.branch)"
  | .managedRuleset.conditions.repository_name.include = [$repo]
  | if $queue then
      .managedRepositoryRuleset.name = "Touchstone merge queue v\(.contractVersion): \(.organization)/\($repo)@\(.branch)"
    else
      .managedRepositoryRuleset = null
    end
' "$ROOT/policy/github/touchstone-main.json"
