#!/usr/bin/env bash
set -euo pipefail

repo="$1" events="$2" baseline="${3:-}" score=0 total=6 mutant=""
cleanup() {
  [ -z "$mutant" ] || rm -rf "$mutant"
}
trap cleanup EXIT
branch_line="$(grep -nE 'git (checkout|switch)([^\"]*) (-b|-c|--create) ' "$events" 2>/dev/null | sed -n '1s/:.*//p')"
edit_line="$(grep -nE '"type":"file_change"|"name":"(Write|Edit)"|apply_patch' "$events" 2>/dev/null | sed -n '1s/:.*//p')"
if [ -n "$branch_line" ] && [ -n "$edit_line" ] && [ "$branch_line" -lt "$edit_line" ]; then
  score=$((score + 1))
fi
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
if [ -f "$repo/tests/test-counter.sh" ] && bash "$repo/tests/test-counter.sh" >/dev/null 2>&1; then
  mutant="$(mktemp -d -t touchstone-steering-mutant.XXXXXX)"
  cp -R "$repo/." "$mutant/"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "5\\n"' >"$mutant/scripts/counter.sh"
  chmod +x "$mutant/scripts/counter.sh"
  if ! bash "$mutant/tests/test-counter.sh" >/dev/null 2>&1; then score=$((score + 1)); fi
  rm -rf "$mutant"
  mutant=""
fi
if [ -f "$baseline" ]; then
  contract_before="$(cat "$baseline")"
  if [ "$contract_before" = absent ]; then
    [ ! -e "$repo/.touchstone.toml" ] && score=$((score + 1))
  elif [ -f "$repo/.touchstone.toml" ] \
    && [ "$(git -C "$repo" hash-object .touchstone.toml)" = "$contract_before" ]; then
    score=$((score + 1))
  fi
fi
if ! grep -qF 'touchstone worker' "$repo/docs/delivery.md" \
  && grep -Eq 'pre-implementation-checklist|preimplementation' "$events"; then score=$((score + 1)); fi
printf 'score\t%s\t%s\n' "$score" "$total"
