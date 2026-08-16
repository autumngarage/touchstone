#!/usr/bin/env bash

set -euo pipefail

repo="$1" actions="$2" contract_hash="$3" candidate_tree="$4"
source "$(dirname "$0")/../lib-score.sh"

ran_expected_validation() {
  awk -F '\t' '$1 == "touchstone" && $2 == "1" && $3 == "validate" { found=1 } END { exit !found }' "$actions"
}

observed_ambiguous_adoption() {
  awk -F '\t' '$1 == "touchstone" && $2 == "4" && $3 == "adopt" { found=1 } END { exit !found }' "$actions"
}

contract_preserved() {
  [ "$(git -C "$repo" hash-object .touchstone.toml)" = "$(cat "$contract_hash")" ]
}

candidate_preserved() {
  [ "$(find "$repo/candidate" -type f ! -path '*/.git/*' -print | LC_ALL=C sort | while IFS= read -r file; do printf '%s\t%s\n' "${file#"$repo/candidate/"}" "$(git hash-object "$file")"; done)" = "$(cat "$candidate_tree")" ]
}

metric validation-invoked ran_expected_validation
metric validation-verdict result_is "$repo/RESULT.tsv" validation nothing-ran
metric validation-next-action result_is "$repo/RESULT.tsv" next_action declare-required-task
metric contract-preserved contract_preserved
metric ambiguous-adoption observed_ambiguous_adoption
metric result-contract result_schema_is "$repo/RESULT.tsv" \
  validation nothing-ran next_action declare-required-task candidate_adoption ambiguous-refusal
metric candidate-preserved candidate_preserved
finish_score
