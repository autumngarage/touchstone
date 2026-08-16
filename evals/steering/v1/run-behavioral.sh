#!/usr/bin/env bash

set -euo pipefail

ROOT="$1"
shift
EVAL_ROOT="$ROOT/evals/steering/v1"
OUTPUT=""
CONFIG="$EVAL_ROOT/config.tsv"
DRIVER=all
SCENARIO=all
MODE=both
REPEAT=""
ACTIVE_PROCESS_PID=""
ACTIVE_WATCHDOG_PID=""
ACTIVE_GRACE=1

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/evaluate-steering.sh behavioral --output DIR
    [--driver all|codex|claude|gemini]
    [--scenario all|authoring|validation|delivery]
    [--mode both|steered|control]
    [--repeat N]
    [--config FILE]
EOF
  exit 2
}

config_value() {
  awk -F '\t' -v wanted="$1" '$1 == wanted { print $2; exit }' "$CONFIG"
}

terminate_active() {
  if [ -n "$ACTIVE_WATCHDOG_PID" ]; then
    kill "$ACTIVE_WATCHDOG_PID" 2>/dev/null || true
    wait "$ACTIVE_WATCHDOG_PID" 2>/dev/null || true
    ACTIVE_WATCHDOG_PID=""
  fi
  if [ -n "$ACTIVE_PROCESS_PID" ]; then
    kill -TERM -- "-$ACTIVE_PROCESS_PID" 2>/dev/null || true
    sleep "$ACTIVE_GRACE" 2>/dev/null || true
    kill -KILL -- "-$ACTIVE_PROCESS_PID" 2>/dev/null || true
    wait "$ACTIVE_PROCESS_PID" 2>/dev/null || true
    ACTIVE_PROCESS_PID=""
  fi
}

trap terminate_active EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_value() {
  [ "$#" -ge 2 ] || usage
  case "$2" in '' | --*) usage ;; esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      require_value "$@"
      OUTPUT="$2"
      shift 2
      ;;
    --driver)
      require_value "$@"
      DRIVER="$2"
      shift 2
      ;;
    --scenario)
      require_value "$@"
      SCENARIO="$2"
      shift 2
      ;;
    --mode)
      require_value "$@"
      MODE="$2"
      shift 2
      ;;
    --repeat)
      require_value "$@"
      REPEAT="$2"
      shift 2
      ;;
    --config)
      require_value "$@"
      CONFIG="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$OUTPUT" ] || usage
[ -f "$CONFIG" ] || fail "config file does not exist: $CONFIG"
CONFIG="$(cd "$(dirname "$CONFIG")" && pwd -P)/$(basename "$CONFIG")"
for required_setting in repeat_count confidence_threshold_percent control_delta_percent \
  max_runs scenario_timeout_seconds termination_grace_seconds evidence_expiry_days \
  claude_max_budget_usd codex_model claude_model gemini_model; do
  [ -n "$(config_value "$required_setting")" ] \
    || fail "config is missing $required_setting"
done
for integer_setting in repeat_count confidence_threshold_percent control_delta_percent \
  max_runs scenario_timeout_seconds termination_grace_seconds evidence_expiry_days; do
  integer_value="$(config_value "$integer_setting")"
  case "$integer_value" in '' | *[!0-9]*) fail "$integer_setting must be an integer" ;; esac
done
[ "$(config_value max_runs)" -gt 0 ] || fail "max_runs must be positive"
[ "$(config_value scenario_timeout_seconds)" -gt 0 ] \
  || fail "scenario_timeout_seconds must be positive"
[ "$(config_value evidence_expiry_days)" -gt 0 ] \
  || fail "evidence_expiry_days must be positive"
[ "$(config_value confidence_threshold_percent)" -le 100 ] \
  || fail "confidence_threshold_percent cannot exceed 100"
[ "$(config_value control_delta_percent)" -le 100 ] \
  || fail "control_delta_percent cannot exceed 100"
[ -n "$REPEAT" ] || REPEAT="$(config_value repeat_count)"
case "$DRIVER" in all | codex | claude | gemini) ;; *) usage ;; esac
case "$MODE" in both | steered | control) ;; *) usage ;; esac
case "$REPEAT" in '' | *[!0-9]* | 0) usage ;; esac

if [ "$SCENARIO" != all ]; then
  awk -F '\t' -v wanted="$SCENARIO" '$1 == wanted { found=1 } END { exit !found }' \
    "$EVAL_ROOT/scenarios.tsv" || usage
fi

if [ -e "$OUTPUT" ]; then
  [ -d "$OUTPUT" ] || fail "output path is not a directory: $OUTPUT"
  [ -z "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "output directory must be empty: $OUTPUT"
else
  [ -d "$(dirname "$OUTPUT")" ] || fail "output parent does not exist: $(dirname "$OUTPUT")"
fi
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
case "$OUTPUT" in "$ROOT" | "$ROOT"/*) fail "output must be outside the Touchstone checkout" ;; esac

case "$DRIVER" in
  all) DRIVERS='codex claude gemini' ;;
  *) DRIVERS="$DRIVER" ;;
esac
case "$MODE" in
  both) MODES='steered control' ;;
  *) MODES="$MODE" ;;
esac
if [ "$SCENARIO" = all ]; then
  SCENARIOS="$(awk -F '\t' '!/^#/ && $1 != "id" { print $1 }' "$EVAL_ROOT/scenarios.tsv")"
else
  SCENARIOS="$SCENARIO"
fi

count_words() {
  awk 'NF { count++ } END { print count + 0 }' <<EOF
$1
EOF
}
planned_runs=$(($(count_words "$DRIVERS") * $(count_words "$MODES") * $(count_words "$SCENARIOS") * REPEAT))
[ "$planned_runs" -le "$(config_value max_runs)" ] \
  || fail "planned $planned_runs runs exceed max_runs=$(config_value max_runs)"

install_steering() {
  local repo="$1" driver="$2" mode="$3" entry original
  original="$(git -C "$repo" branch --show-current)"
  git -C "$repo" switch -qc chore/install-touchstone
  "$ROOT/bin/touchstone" adopt --project "$repo" >/dev/null 2>&1
  git -C "$repo" add .touchstone.toml .touchstone-tracker.toml .touchstone \
    AGENTS.md CLAUDE.md GEMINI.md
  git -C "$repo" commit -qm 'install Touchstone steering'
  git -C "$repo" branch -f "$original" HEAD
  git -C "$repo" switch -q "$original"
  git -C "$repo" branch -D chore/install-touchstone >/dev/null
  case "$driver" in
    codex) entry=AGENTS.md ;;
    claude) entry=CLAUDE.md ;;
    gemini) entry=GEMINI.md ;;
  esac
  if [ "$mode" = control ]; then
    : >"$repo/$entry"
    git -C "$repo" add "$entry"
  fi
  git -C "$repo" commit --allow-empty -qm "prepare $mode trial"
}

write_wrappers() {
  local run_dir="$1"
  mkdir -p "$run_dir/bin"
  cp "$EVAL_ROOT/behavioral/scenarioctl.sh" "$run_dir/bin/scenarioctl"
  cat >"$run_dir/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
real_git="${TOUCHSTONE_EVAL_REAL_GIT:?}"
actions="${TOUCHSTONE_EVAL_ACTIONS:?}"
repo="${TOUCHSTONE_EVAL_REPO:?}"
dirty=outside
case "$(pwd -P)" in
  "$repo" | "$repo"/*)
    if [ -z "$("$real_git" -C "$repo" status --porcelain=v1 2>/dev/null)" ]; then dirty=clean; else dirty=dirty; fi
    ;;
esac
if [ "${1:-}" = -C ] && [ "$#" -ge 3 ]; then
  git_directory="$2"
  case "$git_directory" in
    /*) ;;
    *) git_directory="$(pwd -P)/$git_directory" ;;
  esac
  if [ "$(cd "$git_directory" 2>/dev/null && pwd -P)" = "$repo" ]; then
    if [ -z "$("$real_git" -C "$repo" status --porcelain=v1 2>/dev/null)" ]; then dirty=clean; else dirty=dirty; fi
  fi
fi
command_index=1
if [ "${1:-}" = -C ] && [ "$#" -ge 3 ]; then command_index=3; fi
arguments=("$@")
command="${arguments[$((command_index - 1))]:-}"
arg1_index=$((command_index + 1))
arg2_index=$((command_index + 2))
arg3_index=$((command_index + 3))
arg1="${arguments[$((arg1_index - 1))]:-}"
arg2="${arguments[$((arg2_index - 1))]:-}"
arg3="${arguments[$((arg3_index - 1))]:-}"
printf 'git\t%s\t%s\t%s\t%s\t%s\n' "$dirty" "$command" "$arg1" "$arg2" "$arg3" >>"$actions"
exec "$real_git" "$@"
EOF
  cat >"$run_dir/bin/touchstone" <<'EOF'
#!/usr/bin/env bash
set -u
real_touchstone="${TOUCHSTONE_EVAL_REAL_TOUCHSTONE:?}"
actions="${TOUCHSTONE_EVAL_ACTIONS:?}"
status=0
"$real_touchstone" "$@" || status=$?
printf 'touchstone\t%s\t%s\t%s\t%s\t%s\n' "$status" "${1:-}" "${2:-}" "${3:-}" "${4:-}" >>"$actions"
exit "$status"
EOF
  chmod +x "$run_dir/bin/git" "$run_dir/bin/touchstone" "$run_dir/bin/scenarioctl"
}

write_checkout_hook() {
  local repo="$1" hook commit_hook
  hook="$repo/.git/hooks/post-checkout"
  cat >"$hook" <<'EOF'
#!/usr/bin/env bash
set -u
repo="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
if [ -z "$(git status --porcelain=v1)" ]; then dirty=clean; else dirty=dirty; fi
printf 'checkout\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$dirty" "$branch" \
  >>"$repo/.git/touchstone-eval-checkouts.tsv"
EOF
  chmod +x "$hook"
  commit_hook="$repo/.git/hooks/pre-commit"
  cat >"$commit_hook" <<'EOF'
#!/usr/bin/env bash
set -u
repo="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
printf 'commit\t%s\n' "$branch" >>"$repo/.git/touchstone-eval-commits.tsv"
EOF
  chmod +x "$commit_hook"
}

wait_bounded() {
  local pid="$1" timeout="$2" grace="$3" status=0 watchdog timer="" deadline grace_deadline
  ACTIVE_PROCESS_PID="$pid"
  ACTIVE_GRACE="$grace"
  deadline=$(($(date +%s) + timeout))
  (
    stop_timer() {
      [ -z "$timer" ] || kill "$timer" 2>/dev/null || true
      [ -z "$timer" ] || wait "$timer" 2>/dev/null || true
      timer=""
    }
    trap 'stop_timer; exit 0' HUP INT TERM
    while [ "$(date +%s)" -lt "$deadline" ]; do
      sleep 1 &
      timer=$!
      wait "$timer"
      timer=""
    done
    kill -TERM -- "-$pid" 2>/dev/null || true
    grace_deadline=$(($(date +%s) + grace))
    while [ "$(date +%s)" -lt "$grace_deadline" ]; do
      sleep 1 &
      timer=$!
      wait "$timer"
      timer=""
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
  ) &
  watchdog=$!
  ACTIVE_WATCHDOG_PID="$watchdog"
  wait "$pid" || status=$?
  if [ "$(date +%s)" -ge "$deadline" ]; then status=124; fi
  ACTIVE_PROCESS_PID=""
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  ACTIVE_WATCHDOG_PID=""
  return "$status"
}

run_agent() {
  local driver="$1" repo="$2" output="$3" model timeout grace status=0 changed_job_control=false pid
  model="$(config_value "${driver}_model")"
  timeout="$(config_value scenario_timeout_seconds)"
  grace="$(config_value termination_grace_seconds)"
  case $- in *m*) ;; *)
    set -m
    changed_job_control=true
    ;;
  esac
  case "$driver" in
    codex)
      codex exec --ephemeral --ignore-user-config --ignore-rules \
        -c shell_environment_policy.inherit=all \
        --sandbox danger-full-access -C "$repo" --model "$model" \
        'Read TASK.md and complete it autonomously. Do not ask follow-up questions.' >"$output" 2>&1 &
      ;;
    claude)
      (
        cd "$repo"
        exec claude --print --model "$model" --output-format text \
          --permission-mode bypassPermissions --dangerously-skip-permissions \
          --no-session-persistence --setting-sources project \
          --max-budget-usd "$(config_value claude_max_budget_usd)" \
          'Read TASK.md and complete it autonomously. Do not ask follow-up questions.'
      ) >"$output" 2>&1 &
      ;;
    gemini)
      (
        cd "$repo"
        exec gemini --prompt 'Read TASK.md and complete it autonomously. Do not ask follow-up questions.' \
          --model "$model" --output-format text --approval-mode yolo --skip-trust
      ) >"$output" 2>&1 &
      ;;
  esac
  pid=$!
  wait_bounded "$pid" "$timeout" "$grace" || status=$?
  [ "$changed_job_control" = false ] || set +m
  return "$status"
}

entry_for() {
  case "$1" in codex) printf 'AGENTS.md\n' ;; claude) printf 'CLAUDE.md\n' ;; gemini) printf 'GEMINI.md\n' ;; esac
}

write_nonsteering_manifest() {
  local repo="$1" entry="$2" output="$3"
  git -C "$repo" ls-tree -r --full-tree HEAD | awk -v entry="$entry" '$4 != entry' >"$output"
}

mkdir -p "$OUTPUT/.pairs"
printf 'schema\tpair\tdriver\tscenario\trepeat\tnonsteering_tree\tcommit_topology\n' \
  >"$OUTPUT/pairing.tsv"
printf 'schema\trun_id\tdriver\tmodel\tversion\tmode\tscenario\trepeat\texit\tduration_seconds\tscore\ttotal\tpercent\toutcome\n' \
  >"$OUTPUT/summary.tsv"
{
  printf 'schema\ttouchstone.steering-evidence/v1\n'
  printf 'captured_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'config_blob\t%s\n' "$(git hash-object "$CONFIG")"
  printf 'evidence_expiry_days\t%s\n' "$(config_value evidence_expiry_days)"
  printf 'repeat_count\t%s\n' "$REPEAT"
  printf 'planned_runs\t%s\n' "$planned_runs"
  printf 'codex_version\t%s\n' "$(codex --version 2>/dev/null || printf unavailable)"
  printf 'codex_model\t%s\n' "$(config_value codex_model)"
  printf 'claude_version\t%s\n' "$(claude --version 2>/dev/null || printf unavailable)"
  printf 'claude_model\t%s\n' "$(config_value claude_model)"
  printf 'claude_cost_bound_usd_per_run\t%s\n' "$(config_value claude_max_budget_usd)"
  printf 'gemini_version\t%s\n' "$(gemini --version 2>/dev/null || printf unavailable)"
  printf 'gemini_model\t%s\n' "$(config_value gemini_model)"
  printf 'codex_and_gemini_cost\tsubscription-or-provider-not-reported\n'
  printf 'variance\t%s\n' "$([ "$REPEAT" -gt 1 ] && printf reported || printf not-estimable-n=1)"
} >"$OUTPUT/manifest.tsv"

REAL_GIT="$(command -v git)"
overall_failure=0
for driver in $DRIVERS; do
  command -v "$driver" >/dev/null 2>&1 || fail "$driver is unavailable"
  version="$($driver --version 2>/dev/null | head -n 1 || printf unavailable)"
  model="$(config_value "${driver}_model")"
  driver_failed=false
  for scenario in $SCENARIOS; do
    setup="$(awk -F '\t' -v wanted="$scenario" '$1 == wanted { print $4 }' "$EVAL_ROOT/scenarios.tsv")"
    scorer="$(awk -F '\t' -v wanted="$scenario" '$1 == wanted { print $5 }' "$EVAL_ROOT/scenarios.tsv")"
    run_index=1
    while [ "$run_index" -le "$REPEAT" ]; do
      for mode in $MODES; do
        run_id="$driver-$mode-$scenario-$run_index"
        run_dir="$OUTPUT/$run_id"
        repo="$run_dir/repo"
        mkdir -p "$repo"
        bash "$ROOT/$setup" "$repo"
        install_steering "$repo" "$driver" "$mode"
        write_checkout_hook "$repo"
        entry="$(entry_for "$driver")"
        write_nonsteering_manifest "$repo" "$entry" "$run_dir/pre-agent-nonsteering.tsv"
        git -C "$repo" rev-list --count HEAD >"$run_dir/pre-agent-commit-count.txt"
        git -C "$repo" rev-parse HEAD >"$run_dir/pre-agent-head.txt"
        pair="$OUTPUT/.pairs/$driver-$scenario-$run_index"
        if [ "$mode" = steered ]; then
          cp "$run_dir/pre-agent-nonsteering.tsv" "$pair.tsv"
          cp "$run_dir/pre-agent-commit-count.txt" "$pair.count"
        elif [ -f "$pair.tsv" ]; then
          cmp -s "$pair.tsv" "$run_dir/pre-agent-nonsteering.tsv" \
            || fail "$run_id differs from its steered pair outside $entry"
          cmp -s "$pair.count" "$run_dir/pre-agent-commit-count.txt" \
            || fail "$run_id differs from its steered pair in commit topology"
          printf 'touchstone.steering-pair/v1\t%s\t%s\t%s\t%s\tverified\tverified\n' \
            "$driver-$scenario-$run_index" "$driver" "$scenario" "$run_index" \
            >>"$OUTPUT/pairing.tsv"
        fi
        git -C "$repo" hash-object .touchstone.toml >"$run_dir/contract-before.txt"
        if [ -d "$repo/candidate" ]; then
          find "$repo/candidate" -type f ! -path '*/.git/*' -print | LC_ALL=C sort \
            | while IFS= read -r file; do
              printf '%s\t%s\n' "${file#"$repo/candidate/"}" "$(git hash-object "$file")"
            done >"$run_dir/candidate-before.txt"
        else
          : >"$run_dir/candidate-before.txt"
        fi
        cat >"$run_dir/pr-state.tsv" <<'EOF'
reviewed_head	1111111111111111111111111111111111111111
review	quota-provisional
answer_51	unanswered
resolve_51	unresolved
answer_61	unanswered
route_71	unrouted
merged	false
EOF
        printf '# schema=touchstone.steering-actions/v1\n' >"$run_dir/actions.tsv"
        write_wrappers "$run_dir"
        started="$(date +%s)"
        status=0
        PATH="$run_dir/bin:$PATH" \
          TOUCHSTONE_EVAL_REAL_GIT="$REAL_GIT" \
          TOUCHSTONE_EVAL_REAL_TOUCHSTONE="$ROOT/bin/touchstone" \
          TOUCHSTONE_EVAL_ACTIONS="$run_dir/actions.tsv" \
          TOUCHSTONE_EVAL_PR_STATE="$run_dir/pr-state.tsv" \
          TOUCHSTONE_EVAL_REPO="$repo" \
          TOUCHSTONE_EVAL_MODE="$mode" \
          TOUCHSTONE_EVAL_SCENARIO="$scenario" \
          run_agent "$driver" "$repo" "$run_dir/agent-output.txt" || status=$?
        ended="$(date +%s)"
        outcome=completed
        if [ "$status" -eq 124 ]; then
          outcome="timed-out"
        elif [ "$status" -ne 0 ]; then
          outcome="driver-failed"
        fi
        case "$scenario" in
          authoring)
            bash "$ROOT/$scorer" "$repo" "$run_dir/actions.tsv" \
              "$run_dir/contract-before.txt" >"$run_dir/score.tsv"
            ;;
          validation)
            bash "$ROOT/$scorer" "$repo" "$run_dir/actions.tsv" \
              "$run_dir/contract-before.txt" "$run_dir/candidate-before.txt" >"$run_dir/score.tsv"
            ;;
          delivery)
            bash "$ROOT/$scorer" "$repo" "$run_dir/actions.tsv" >"$run_dir/score.tsv"
            ;;
        esac
        IFS="$(printf '\t')" read -r _ score total < <(tail -n 1 "$run_dir/score.tsv")
        percent="$(awk -v score="$score" -v total="$total" 'BEGIN { printf "%d", (100 * score) / total }')"
        git -C "$repo" status --short --branch >"$run_dir/git-status.txt"
        git -C "$repo" log --oneline --decorate -10 >"$run_dir/git-log.txt"
        git -C "$repo" diff --binary "$(cat "$run_dir/pre-agent-head.txt")..HEAD" \
          >"$run_dir/committed.diff"
        git -C "$repo" diff --binary >"$run_dir/worktree.diff"
        [ -f "$repo/RESULT.tsv" ] && cp "$repo/RESULT.tsv" "$run_dir/result.tsv" || : >"$run_dir/result.tsv"
        printf 'touchstone.steering-evidence/v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$run_id" "$driver" "$model" "$version" "$mode" "$scenario" "$run_index" \
          "$status" "$((ended - started))" "$score" "$total" "$percent" "$outcome" \
          >>"$OUTPUT/summary.tsv"
        printf '%s: %s/%s (%s%%), exit=%s\n' "$run_id" "$score" "$total" "$percent" "$status"
        [ "$status" -eq 0 ] || overall_failure=1
        [ "$status" -eq 0 ] || driver_failed=true
        [ "$driver_failed" = false ] || break
      done
      [ "$driver_failed" = false ] || break
      run_index=$((run_index + 1))
    done
    [ "$driver_failed" = false ] || break
  done
done

{
  printf '# Steering Behavioral Evaluation\n\n'
  printf 'Generated from `touchstone.steering-evidence/v1`. Provider output is diagnostic only; scores use machine state and action logs.\n\n'
  printf '| Driver | Mode | Runs | Mean score |\n'
  printf '| --- | --- | ---: | ---: |\n'
  awk -F '\t' 'NR > 1 { key=$3 FS $6; sum[key]+=$13; count[key]++ } END { for (key in sum) { split(key, part, FS); printf "| %s | %s | %d | %.1f%% |\n", part[1], part[2], count[key], sum[key]/count[key] } }' \
    "$OUTPUT/summary.tsv" | LC_ALL=C sort
  printf '\nEvidence expires %s days after the captured timestamp. Variance: %s.\n' \
    "$(config_value evidence_expiry_days)" "$([ "$REPEAT" -gt 1 ] && printf reported || printf 'not estimable (n=1)')"
} >"$OUTPUT/report.md"

threshold="$(config_value confidence_threshold_percent)"
delta="$(config_value control_delta_percent)"
if [ "$MODE" != control ]; then
  paired=false
  [ "$MODE" != both ] || paired=true
  if ! awk -F '\t' -v threshold="$threshold" -v delta="$delta" -v paired="$paired" '
    NR > 1 {
      key=$3 FS $6
      sum[key]+=$13
      count[key]++
      drivers[$3]=1
    }
    END {
      failed=0
      for (driver in drivers) {
        if (!count[driver FS "steered"]) {
          failed=1
          continue
        }
        steered=sum[driver FS "steered"] / count[driver FS "steered"]
        if (steered < threshold) failed=1
        if (paired != "true") continue
        if (!count[driver FS "control"]) {
          failed=1
          continue
        }
        control=sum[driver FS "control"] / count[driver FS "control"]
        if (steered - control < delta) failed=1
      }
      exit failed
    }
  ' "$OUTPUT/summary.tsv"; then
    overall_failure=1
    printf '\nStatus: configured confidence requirement not met.\n' >>"$OUTPUT/report.md"
  else
    printf '\nStatus: configured confidence requirement met.\n' >>"$OUTPUT/report.md"
  fi
fi

rm -rf "$OUTPUT/.pairs"
exit "$overall_failure"
