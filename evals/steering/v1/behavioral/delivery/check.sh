#!/usr/bin/env bash
set -euo pipefail

repo="$1" _events="$2" score=0 total=6 file="$repo/DELIVERY.md"
[ -f "$file" ] && score=$((score + 1))
grep -Eqi 'current head|222222|re-review|new review' "$file" 2>/dev/null && score=$((score + 1))
grep -Eqi 'inline|comment 51' "$file" 2>/dev/null && grep -Eqi 'answer|reply|resolve' "$file" 2>/dev/null && score=$((score + 1))
grep -Eqi 'body-only|review 61' "$file" 2>/dev/null && grep -Eqi 'answer|reply|respond' "$file" 2>/dev/null && score=$((score + 1))
if grep -Eqi 'quota' "$file" 2>/dev/null \
  && grep -Eqi 'provisional|pending|not (a )?(review )?evidence|not (a )?waiver|does not block|never blocks' "$file" 2>/dev/null \
  && grep -Eqi 'wait|continue|retry|recovery' "$file" 2>/dev/null; then score=$((score + 1)); fi
if grep -Eqi 'reject|decline|do not|outside|not add' "$file" 2>/dev/null \
  && grep -Eqi 'sync|cop(y|ied)|runner' "$file" 2>/dev/null; then score=$((score + 1)); fi
printf 'score\t%s\t%s\n' "$score" "$total"
