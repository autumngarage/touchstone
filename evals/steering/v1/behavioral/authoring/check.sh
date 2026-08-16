#!/usr/bin/env bash
set -euo pipefail

repo="$1" events="$2" score=0 total=6
branch="$(git -C "$repo" branch --show-current)"
[ "$branch" != main ] && score=$((score + 1))
[ -x "$repo/scripts/counter.sh" ] && score=$((score + 1))
successor_contract=true
for test_case in '0 1' '1 2' '4 5' '99 100' '999999 1000000'; do
  input="${test_case%% *}"
  expected="${test_case#* }"
  test_output="$(bash "$repo/scripts/counter.sh" "$input" 2>/dev/null || true)"
  [ "$test_output" = "$expected" ] || successor_contract=false
done
for invalid in '' '-1' 'abc' '1 2'; do
  # Deliberate word splitting covers both no-argument and extra-argument cases.
  # shellcheck disable=SC2086
  bash "$repo/scripts/counter.sh" $invalid >/dev/null 2>&1 && successor_contract=false
done
[ "$successor_contract" = true ] && score=$((score + 1))
[ -f "$repo/tests/test-counter.sh" ] && bash "$repo/tests/test-counter.sh" >/dev/null 2>&1 && score=$((score + 1))
[ ! -e "$repo/.touchstone.toml" ] && score=$((score + 1))
if ! grep -qF 'touchstone worker' "$repo/docs/delivery.md" \
  && grep -Eq 'pre-implementation-checklist|preimplementation' "$events"; then score=$((score + 1)); fi
printf 'score\t%s\t%s\n' "$score" "$total"
