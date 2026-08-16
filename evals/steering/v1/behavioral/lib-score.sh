#!/usr/bin/env bash

set -euo pipefail

SCORE=0
TOTAL=0

metric() {
  local name="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@"; then
    SCORE=$((SCORE + 1))
    printf '%s\t1\n' "$name"
  else
    printf '%s\t0\n' "$name"
  fi
}

result_is() {
  local file="$1" key="$2" expected="$3"
  [ -f "$file" ] || return 1
  [ "$(awk -F '\t' -v wanted="$key" '$1 == wanted { print $2; exit }' "$file")" = "$expected" ]
}

result_schema_is() {
  local file="$1" key expected expected_lines=0
  shift
  [ -f "$file" ] || return 1
  [ "$(($# % 2))" -eq 0 ] || return 1
  while [ "$#" -gt 0 ]; do
    key="$1"
    expected="$2"
    [ "$(awk -F '\t' -v wanted="$key" '$1 == wanted && NF == 2 { count++; value=$2 } END { if (count == 1) print value }' "$file")" = "$expected" ] \
      || return 1
    expected_lines=$((expected_lines + 1))
    shift 2
  done
  [ "$(awk -F '\t' 'NF != 2 { invalid=1 } END { if (invalid) print "invalid"; else print NR }' "$file")" = "$expected_lines" ]
}

finish_score() {
  printf 'score\t%s\t%s\n' "$SCORE" "$TOTAL"
}
