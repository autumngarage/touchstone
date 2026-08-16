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
      is_gemini_shell=(line ~ /"type":"tool_use"/ && line ~ /"tool_name":"run_shell_command"/)
      is_command=(index(line, "\"type\":\"command_execution\"") || index(line, "\"name\":\"Bash\"") || is_gemini_shell)
      if (!branch && line ~ /Switched to a new branch/ \
          && !(line ~ /"type":"tool_result"/ && line ~ /"tool_id":/)) branch=NR
      shell_edit=(is_command && (command ~ /(cat|printf|echo)[^"]*(>|>>)/ || command ~ /sed [^"]*-i/ || command ~ /(^|[ ;])(tee|touch|cp|mv|chmod|install) /))
      gemini_edit=(line ~ /"type":"tool_use"/ && line ~ /"tool_name":"(write_file|replace)"/)
      if (!edit && (index(line, "\"type\":\"file_change\"") || line ~ /"name":"(Write|Edit)"/ || gemini_edit || shell_edit)) edit=NR
      if (!branch && line ~ /"type":"tool_result"/ && line ~ /"status":"success"/ \
          && line ~ /Switched to a new branch/) branch=NR
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
      if (index(line, "\"type\":\"item.completed\"") \
          && index(line, "\"type\":\"command_execution\"") \
          && index(line, "\"exit_code\":0") \
          && command ~ /pre-implementation-checklist\.md/) found=1
      if (line ~ /"type":"tool_use"/ && line ~ /"name":"(Read|Bash)"/ \
          && command ~ /pre-implementation-checklist\.md/) {
        id=line
        sub(/^.*"id":"/, "", id)
        sub(/".*$/, "", id)
        pending[id]=1
      }
      if (line ~ /"type":"tool_result"/ && index(line, "\"is_error\":false")) {
        id=line
        sub(/^.*"tool_use_id":"/, "", id)
        sub(/".*$/, "", id)
        if (pending[id]) found=1
      }
      if (line ~ /"type":"tool_use"/ \
          && line ~ /"tool_name":"(read_file|run_shell_command)"/ \
          && command ~ /pre-implementation-checklist\.md/) {
        id=line
        sub(/^.*"tool_id":"/, "", id)
        sub(/".*$/, "", id)
        gemini_pending[id]=1
      }
      if (line ~ /"type":"tool_result"/ && line ~ /"status":"success"/) {
        id=line
        sub(/^.*"tool_id":"/, "", id)
        sub(/".*$/, "", id)
        if (gemini_pending[id]) found=1
      }
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
if [ -f "$repo/tests/test-counter.sh" ] \
  && (cd "$repo" && bash tests/test-counter.sh >/dev/null 2>&1); then
  mutant="$(mktemp -d -t touchstone-steering-mutant.XXXXXX)"
  cp -R "$repo/." "$mutant/"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "5\\n"' >"$mutant/scripts/counter.sh"
  chmod +x "$mutant/scripts/counter.sh"
  if ! (cd "$mutant" && bash tests/test-counter.sh >/dev/null 2>&1); then score=$((score + 1)); fi
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
