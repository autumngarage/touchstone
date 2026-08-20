#!/usr/bin/env bash
#
# scripts/derive-consumer-policy.sh — derive an adopted repository's GitHub
# policy from the canonical Touchstone policy.
#
# Usage:
#   bash scripts/derive-consumer-policy.sh REPOSITORY > policy/github/consumers/REPOSITORY.json
#
# A consumer's policy is the canonical policy with the repository name
# substituted everywhere it appears as an ownership coordinate, and without
# Touchstone's own rollback prerequisites (the legacy local workflow no
# consumer ever carried). Nothing else may differ: one contract, many
# repositories. tests/test-github-policy.sh refuses a checked-in consumer
# policy that does not equal this derivation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPOSITORY="${1:-}"
case "$REPOSITORY" in
  "" | *[!A-Za-z0-9._-]*)
    echo "usage: derive-consumer-policy.sh REPOSITORY" >&2
    exit 2
    ;;
esac
jq --arg repo "$REPOSITORY" '
  .repository = $repo
  | .rollbackPrerequisites.repositoryFiles = []
  | .managedRuleset.name = "Touchstone policy v\(.contractVersion): \(.organization)/\($repo)@\(.branch)"
  | .managedRuleset.conditions.repository_name.include = [$repo]
  | .managedRepositoryRuleset.name = "Touchstone merge queue v\(.contractVersion): \(.organization)/\($repo)@\(.branch)"
' "$ROOT/policy/github/touchstone-main.json"
