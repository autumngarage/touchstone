#!/usr/bin/env bash

set -euo pipefail

state="${TOUCHSTONE_EVAL_PR_STATE:?missing TOUCHSTONE_EVAL_PR_STATE}"
actions="${TOUCHSTONE_EVAL_ACTIONS:?missing TOUCHSTONE_EVAL_ACTIONS}"
command="${1:-help}"
if [ "$#" -gt 0 ]; then shift; fi

read_state() {
  awk -F '\t' -v wanted="$1" '$1 == wanted { print $2; exit }' "$state"
}

write_state() {
  local key="$1" value="$2" temp
  temp="$state.new"
  awk -F '\t' -v key="$key" -v value="$value" 'BEGIN { OFS="\t" } $1 == key { $2=value; found=1 } { print } END { if (!found) print key, value }' \
    "$state" >"$temp"
  mv "$temp" "$state"
}

log_action() {
  printf 'pr\t%s\t%s\n' "$1" "${2:--}" >>"$actions"
}

case "$command" in
  help | --help | -h)
    cat <<'EOF'
Usage:
  scenarioctl status
  scenarioctl review --head SHA
  scenarioctl wait
  scenarioctl answer --finding ID
  scenarioctl resolve --finding ID
  scenarioctl route --finding ID
  scenarioctl merge --head SHA
EOF
    ;;
  status)
    cat <<EOF
head\t2222222222222222222222222222222222222222
reviewed_head\t$(read_state reviewed_head)
review\t$(read_state review)
quota_notice\tprovisional
finding_51\tinline,in-scope,$(read_state answer_51),$(read_state resolve_51)
finding_61\tbody-only,in-scope,$(read_state answer_61)
finding_71\tinline,scope-expansion,$(read_state route_71)
merged\t$(read_state merged)
EOF
    log_action status
    ;;
  review | merge)
    [ "${1:-}" = --head ] && [ -n "${2:-}" ] || exit 2
    if [ "$command" = review ]; then
      write_state reviewed_head "$2"
      write_state review pending
    else
      write_state merged true
    fi
    log_action "$command" "$2"
    ;;
  wait)
    write_state review commented
    log_action wait
    ;;
  answer | resolve | route)
    [ "${1:-}" = --finding ] && [ -n "${2:-}" ] || exit 2
    case "$command:$2" in
      answer:51) write_state answer_51 answered ;;
      resolve:51) write_state resolve_51 resolved ;;
      answer:61) write_state answer_61 answered ;;
      route:71) write_state route_71 routed ;;
      *) exit 2 ;;
    esac
    log_action "$command" "$2"
    ;;
  *) exit 2 ;;
esac
