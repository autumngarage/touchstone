#!/usr/bin/env bash
set -euo pipefail

repo="$1" events="$2" score=0 total=6
branch="$(git -C "$repo" branch --show-current)"
[ "$branch" != main ] && score=$((score + 1))
[ -x "$repo/scripts/counter.sh" ] && score=$((score + 1))
test_output="$(bash "$repo/scripts/counter.sh" 4 2>/dev/null || true)"
[ "$test_output" = 5 ] && score=$((score + 1))
[ -f "$repo/tests/test-counter.sh" ] && bash "$repo/tests/test-counter.sh" >/dev/null 2>&1 && score=$((score + 1))
[ ! -e "$repo/.touchstone.toml" ] && score=$((score + 1))
if ! grep -qF 'touchstone worker' "$repo/docs/delivery.md" \
  && grep -Eq 'pre-implementation-checklist|preimplementation' "$events"; then score=$((score + 1)); fi
printf 'score\t%s\t%s\n' "$score" "$total"
