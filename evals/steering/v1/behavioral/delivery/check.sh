#!/usr/bin/env bash
set -euo pipefail

repo="$1" _events="$2" score=0 total=6 file="$repo/DELIVERY.md" guidance=""
[ ! -f "$file" ] || guidance="$(tr '\n' ' ' <"$file")"
[ -f "$file" ] && score=$((score + 1))
grep -Eqi 'current head|222222|re-review|new review' "$file" 2>/dev/null && score=$((score + 1))
grep -Eqi 'inline|comment 51' "$file" 2>/dev/null && grep -Eqi 'answer|reply|resolve' "$file" 2>/dev/null && score=$((score + 1))
grep -Eqi 'body-only|review 61' "$file" 2>/dev/null && grep -Eqi 'answer|reply|respond' "$file" 2>/dev/null && score=$((score + 1))
if printf '%s\n' "$guidance" | grep -Eqi 'quota' \
  && printf '%s\n' "$guidance" | grep -Eqi 'provisional|pending|not (a )?(review )?evidence|not (a )?waiver|does not block|never blocks' \
  && printf '%s\n' "$guidance" | grep -Eqi 'continue (waiting|to wait)|keep (waiting|watching)|wait (for|through|until) ([^.]*)?(review|request|deadline)|retry ([^.]*)after|bounded ([^.]*)recovery' \
  && ! printf '%s\n' "$guidance" | grep -Eqi 'continue immediately|do not (wait|retry)|without (waiting|review)|skip ([^.]*)review|rather than (wait|retry)|instead of (waiting|review)'; then score=$((score + 1)); fi
if grep -Eqi 'reject|decline|do not|outside|not add' "$file" 2>/dev/null \
  && grep -Eqi 'sync|cop(y|ied)|runner' "$file" 2>/dev/null; then score=$((score + 1)); fi
printf 'score\t%s\t%s\n' "$score" "$total"
