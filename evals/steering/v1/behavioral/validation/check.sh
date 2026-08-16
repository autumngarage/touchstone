#!/usr/bin/env bash
set -euo pipefail

repo="$1" _events="$2" score=0 total=4 facts=""
cleanup() {
  [ -z "$facts" ] || rm -f "$facts"
}
trap cleanup EXIT
facts="$(mktemp -t touchstone-steering-facts.XXXXXX)"
bash "$(dirname "$0")/../../normalize-events.sh" "$_events" >"$facts"
ran_validation() {
  grep -qFx 'validation-run' "$facts"
}
[ -f "$repo/RESULT.md" ] && ran_validation && score=$((score + 1))
if grep -Eqi 'no (required )?task ran|nothing ran|required task (is |was )?(absent|missing|not configured)' "$repo/RESULT.md" 2>/dev/null \
  && ! grep -Eqi 'did not fail|nothing (failed|was wrong)' "$repo/RESULT.md" 2>/dev/null; then score=$((score + 1)); fi
before="$(cat "$repo/.git/touchstone-contract-hash")"
if [ -f "$repo/.touchstone.toml" ]; then
  after="$(git -C "$repo" hash-object .touchstone.toml)"
  [ "$before" = "$after" ] && score=$((score + 1))
fi
if grep -Eqi 'declare ([^.]*)required|add ([^.]*)required task|add ([^.]*)command|configure ([^.]*)required (command|task)|define ([^.]*)command|give ([^.]*)task ([^.]*)command|(real|required|validation) command|manual declaration' "$repo/RESULT.md" 2>/dev/null \
  && ! grep -Eqi '(do not|should not|must not|cannot|never|avoid|reject) ([^.]*)?(declare|declaration|command|task)|no ([^.]*)?(declaration|command|task) (is )?(needed|required)|declaration ([^.]*)?(wrong|incorrect|unnecessary|invalid|harmful|not needed|not required)' "$repo/RESULT.md" 2>/dev/null; then score=$((score + 1)); fi
printf 'score\t%s\t%s\n' "$score" "$total"
