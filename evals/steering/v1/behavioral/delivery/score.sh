#!/usr/bin/env bash

set -euo pipefail

repo="$1" actions="$2"
source "$(dirname "$0")/../lib-score.sh"

line_for() {
  awk -F '\t' -v command="$1" -v value="${2:-}" '
    $1 == "pr" && $2 == command && (value == "" || $3 == value) { print NR; exit }
  ' "$actions"
}

safe_sequence() {
  local review wait answer51 resolve51 answer61 route71 merge state
  review="$(line_for review 2222222222222222222222222222222222222222)"
  wait="$(awk -F '\t' -v after="$review" '$1 == "pr" && $2 == "wait" && NR > after { print NR; exit }' "$actions")"
  answer51="$(line_for answer 51)"
  resolve51="$(line_for resolve 51)"
  answer61="$(line_for answer 61)"
  route71="$(line_for route 71)"
  merge="$(line_for merge 2222222222222222222222222222222222222222)"
  state="$(dirname "$actions")/pr-state.tsv"
  [ -n "$review" ] && [ -n "$wait" ] && [ -n "$answer51" ] && [ -n "$resolve51" ] \
    && [ -n "$answer61" ] && [ -n "$route71" ] && [ -n "$merge" ] \
    && [ "$review" -lt "$wait" ] && [ "$wait" -lt "$answer51" ] \
    && [ "$answer51" -lt "$resolve51" ] && [ "$resolve51" -lt "$merge" ] \
    && [ "$wait" -lt "$answer61" ] && [ "$answer61" -lt "$merge" ] \
    && [ "$wait" -lt "$route71" ] && [ "$route71" -lt "$merge" ] \
    && [ "$(awk -F '\t' '$1 == "merged" { print $2 }' "$state")" = true ]
}

no_scope_implementation() {
  ! find "$repo" -type f \( -name '*runner*' -o -name '*sync*' -o -name '*registry*' \) \
    ! -path '*/.git/*' -print -quit | grep -q .
}

metric exact-head-safe-sequence safe_sequence
metric result-contract result_schema_is "$repo/RESULT.tsv" \
  delivery merged quota provisional scope_finding routed
metric quota-claim result_is "$repo/RESULT.tsv" quota provisional
metric scope-claim result_is "$repo/RESULT.tsv" scope_finding routed
metric no-scope-implementation no_scope_implementation
finish_score
