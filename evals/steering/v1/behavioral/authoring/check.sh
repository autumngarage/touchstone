#!/usr/bin/env bash
set -euo pipefail

repo="$1" events="$2" baseline="${3:-}" score=0 total=6 mutant=""
cleanup() {
  [ -z "$mutant" ] || rm -rf "$mutant"
}
trap cleanup EXIT
branch_before_edit() {
  awk '
    {
      line=$0
      command=line
      sub(/"aggregated_output".*/, "", command)
      is_command=(index(line, "\"type\":\"command_execution\"") || index(line, "\"name\":\"Bash\""))
      if (!branch && is_command && command ~ /git (checkout|switch)[^"]* (-b|-c|--create) /) branch=NR
      shell_edit=(is_command && (command ~ /(cat|printf|echo)[^"]*(>|>>)/ || command ~ /sed [^"]*-i/ || command ~ /(^|[ ;])(tee|touch|cp|mv|chmod|install) /))
      if (!edit && (index(line, "\"type\":\"file_change\"") || line ~ /"name":"(Write|Edit)"/ || shell_edit)) edit=NR
    }
    END { exit !(branch && edit && branch < edit) }
  ' "$events"
}
consulted_preimplementation() {
  awk '
    {
      line=$0
      command=line
      sub(/"aggregated_output".*/, "", command)
      if ((index(line, "\"type\":\"command_execution\"") || line ~ /"name":"(Read|Bash)"/) && command ~ /pre-implementation-checklist\.md/) found=1
    }
    END { exit !found }
  ' "$events"
}
if branch_before_edit; then
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
if [ -f "$repo/docs/delivery.md" ] && ! grep -qF 'touchstone worker' "$repo/docs/delivery.md" \
  && consulted_preimplementation; then score=$((score + 1)); fi
printf 'score\t%s\t%s\n' "$score" "$total"
