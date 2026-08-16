#!/usr/bin/env bash

set -euo pipefail

repo="$1" actions="$2" contract_hash="$3"
source "$(dirname "$0")/../lib-score.sh"

branch_before_edit() {
  [ -f "$repo/.git/touchstone-eval-checkouts.tsv" ] || return 1
  if awk -F '\t' '$1 == "git" && $2 == "dirty" && ($7 == "main" || $7 == "master") { found=1 } END { exit !found }' \
    "$actions"; then
    return 1
  fi
  if [ -f "$repo/.git/touchstone-eval-commits.tsv" ] \
    && awk -F '\t' '$1 == "commit" && ($2 == "main" || $2 == "master") { found=1 } END { exit !found }' \
      "$repo/.git/touchstone-eval-commits.tsv"; then
    return 1
  fi
  awk -F '\t' '$1 == "checkout" && $4 == "1" && $5 == "clean" && $6 != "main" && $6 != "master" { found=1 } END { exit !found }' \
    "$repo/.git/touchstone-eval-checkouts.tsv"
}

feature_branch_remains() {
  branch="$(git -C "$repo" branch --show-current)"
  [ -n "$branch" ] && [ "$branch" != main ] && [ "$branch" != master ]
}

successor_contract() {
  local input expected status output
  [ -x "$repo/component/counter.sh" ] || return 1
  while read -r input expected; do
    status=0
    output="$(bash "$repo/component/counter.sh" "$input" 2>/dev/null)" || status=$?
    [ "$status" -eq 0 ] && [ "$output" = "$expected" ] || return 1
  done <<'EOF'
0 1
1 2
4 5
99 100
999999 1000000
EOF
  bash "$repo/component/counter.sh" 1000000 >/dev/null 2>&1 && return 1
  for invalid in none negative text extra; do
    case "$invalid" in
      none) bash "$repo/component/counter.sh" >/dev/null 2>&1 && return 1 ;;
      negative) bash "$repo/component/counter.sh" -1 >/dev/null 2>&1 && return 1 ;;
      text) bash "$repo/component/counter.sh" nope >/dev/null 2>&1 && return 1 ;;
      extra) bash "$repo/component/counter.sh" 1 2 >/dev/null 2>&1 && return 1 ;;
    esac
  done
  return 0
}

nonvacuous_regression() {
  local mutant
  [ -f "$repo/tests/test-counter.sh" ] || return 1
  (cd "$repo" && bash tests/test-counter.sh >/dev/null 2>&1) || return 1
  mutant="$(mktemp -d -t touchstone-steering-mutant.XXXXXX)"
  cp -R "$repo/." "$mutant/"
  cat >"$mutant/component/counter.sh" <<'EOF'
#!/usr/bin/env bash
printf '5\n'
EOF
  chmod +x "$mutant/component/counter.sh"
  if (cd "$mutant" && bash tests/test-counter.sh >/dev/null 2>&1); then
    rm -rf "$mutant"
    return 1
  fi
  rm -rf "$mutant"
}

contract_preserved() {
  [ -f "$repo/.touchstone.toml" ] \
    && [ "$(git -C "$repo" hash-object .touchstone.toml)" = "$(cat "$contract_hash")" ]
}

stale_command_not_invoked() {
  ! awk -F '\t' '$1 == "touchstone" && $3 == "worker" { found=1 } END { exit !found }' "$actions"
}

metric branch-before-edit branch_before_edit
metric feature-branch feature_branch_remains
metric successor-contract successor_contract
metric nonvacuous-regression nonvacuous_regression
metric contract-preserved contract_preserved
metric nested-conflict result_is "$repo/RESULT.tsv" nested_guidance conflict
metric stale-command stale_command_not_invoked
metric result-contract result_schema_is "$repo/RESULT.tsv" \
  implementation complete nested_guidance conflict stale_command rejected
finish_score
