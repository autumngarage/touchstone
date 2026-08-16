#!/usr/bin/env bash
# scripts/evaluate-steering.sh — offline steering resolution and bounded live evaluation.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
EVAL_ROOT="$ROOT/evals/steering/v1"
OPERATION="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
STRUCTURAL_TEMP=""
ACTIVE_PROCESS_PID=""
ACTIVE_WATCHDOG_PID=""
ACTIVE_TERMINATION_GRACE=1

cleanup() {
  if [ -n "$ACTIVE_WATCHDOG_PID" ]; then
    kill "$ACTIVE_WATCHDOG_PID" 2>/dev/null || true
    wait "$ACTIVE_WATCHDOG_PID" 2>/dev/null || true
    ACTIVE_WATCHDOG_PID=""
  fi
  if [ -n "$ACTIVE_PROCESS_PID" ]; then
    kill -TERM -- "-$ACTIVE_PROCESS_PID" 2>/dev/null || true
    sleep "$ACTIVE_TERMINATION_GRACE" 2>/dev/null || true
    kill -KILL -- "-$ACTIVE_PROCESS_PID" 2>/dev/null || true
    wait "$ACTIVE_PROCESS_PID" 2>/dev/null || true
    ACTIVE_PROCESS_PID=""
  fi
  [ -z "$STRUCTURAL_TEMP" ] || rm -rf -- "$STRUCTURAL_TEMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/evaluate-steering.sh structural [--json]
  bash scripts/evaluate-steering.sh behavioral --output DIR [--driver all|codex|claude|gemini] [--scenario all|ID] [--mode both|steered|control] [--repeat N]
EOF
  exit 2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

append_imports() {
  local file="$1" depth="$2" stack="$3" output="$4" line target canonical
  [ "$depth" -le 5 ] || return 1
  canonical="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
  case "$stack" in *"|$canonical|"*) return 1 ;; esac
  [ -f "$canonical" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      @*)
        target="${line#@}"
        case "$target" in "" | *[[:space:]]*) printf '%s\n' "$line" >>"$output" ;; *)
          append_imports "$(dirname "$canonical")/$target" "$((depth + 1))" "$stack|$canonical|" "$output" || return 1
          ;;
        esac
        ;;
      *) printf '%s\n' "$line" >>"$output" ;;
    esac
  done <"$canonical"
}

resolve_codex_fixture() {
  local project="$1" output="$2" directory file
  : >"$output"
  for directory in "$project" "$project/services" "$project/services/api"; do
    file="$directory/AGENTS.md"
    [ ! -f "$directory/AGENTS.override.md" ] || file="$directory/AGENTS.override.md"
    [ ! -f "$file" ] || cat "$file" >>"$output"
  done
}

resolve_import_fixture() {
  local driver="$1" project="$2" output="$3" filename
  case "$driver" in claude) filename=CLAUDE.md ;; gemini) filename=GEMINI.md ;; *) return 1 ;; esac
  : >"$output"
  append_imports "$project/$filename" 0 "" "$output" || return 1
  if [ -f "$project/services/api/$filename" ]; then
    append_imports "$project/services/api/$filename" 0 "" "$output" || return 1
  fi
}

has_rule_conflict() {
  awk -F : '
    $1 == "RULE" {
      if ($2 in action && action[$2] != $3) conflict=1
      action[$2]=$3
    }
    END { exit !conflict }
  ' "$1"
}

trim_trailing_blank_lines() {
  awk '
    { lines[NR]=$0 }
    END {
      last=NR
      while (last > 0 && lines[last] == "") last--
      for (line=1; line<=last; line++) print lines[line]
    }
  '
}

structural_evaluation() {
  local json=false temp driver fixture expected resolved file failures=0 checks=0
  if [ "${1:-}" = --json ]; then
    json=true
    shift
  fi
  [ "$#" -eq 0 ] || usage
  temp="$(mktemp -d -t touchstone-steering-structural.XXXXXX)"
  STRUCTURAL_TEMP="$temp"

  for driver in codex claude gemini; do
    fixture="$EVAL_ROOT/structural/$driver"
    expected="$fixture/expected.txt"
    resolved="$temp/$driver.txt"
    if [ "$driver" = codex ]; then
      resolve_codex_fixture "$fixture/project" "$resolved"
    else
      resolve_import_fixture "$driver" "$fixture/project" "$resolved" || failures=$((failures + 1))
    fi
    checks=$((checks + 1))
    cmp -s "$expected" "$resolved" || failures=$((failures + 1))
  done

  for file in AGENTS.md GEMINI.md templates/AGENTS.md templates/GEMINI.md; do
    resolved="$temp/$(printf '%s' "$file" | tr / -)"
    awk '/^## Touchstone — Shared Agent Steering/{copy=1} /<!-- touchstone:steering:end -->/{copy=0} copy' \
      "$ROOT/$file" | trim_trailing_blank_lines >"$resolved"
    checks=$((checks + 1))
    trim_trailing_blank_lines <"$ROOT/TOUCHSTONE.md" >"$temp/canonical"
    cmp -s "$temp/canonical" "$resolved" || failures=$((failures + 1))
  done

  for file in CLAUDE.md templates/CLAUDE.md; do
    checks=$((checks + 1))
    grep -qF '@TOUCHSTONE.md' "$ROOT/$file" || failures=$((failures + 1))
  done

  checks=$((checks + 1))
  [ "$(wc -c <"$ROOT/TOUCHSTONE.md" | tr -d ' ')" -le 9728 ] || failures=$((failures + 1))
  for file in AGENTS.md GEMINI.md templates/AGENTS.md templates/GEMINI.md; do
    checks=$((checks + 1))
    [ "$(wc -c <"$ROOT/$file" | tr -d ' ')" -le 24576 ] || failures=$((failures + 1))
  done

  checks=$((checks + 1))
  if resolve_import_fixture claude "$EVAL_ROOT/structural/negative/broken/project" "$temp/broken"; then
    failures=$((failures + 1))
  fi
  resolve_codex_fixture "$EVAL_ROOT/structural/negative/conflict/project" "$temp/conflict"
  # Add the nested fixture explicitly because this negative layout uses a
  # shorter path than the positive precedence fixture.
  cat "$EVAL_ROOT/structural/negative/conflict/project/nested/AGENTS.md" >>"$temp/conflict"
  checks=$((checks + 1))
  has_rule_conflict "$temp/conflict" || failures=$((failures + 1))

  checks=$((checks + 1))
  bash "$ROOT/tests/test-steering-size-caps.sh" >/dev/null || failures=$((failures + 1))
  checks=$((checks + 1))
  TOUCHSTONE_STRUCTURAL_NESTED=true \
    bash "$ROOT/tests/test-agent-steering-contract.sh" >/dev/null || failures=$((failures + 1))

  if [ "$json" = true ]; then
    printf '{"schema":"touchstone.steering-eval/v1","lane":"structural","checks":%s,"failures":%s,"status":"%s"}\n' \
      "$checks" "$failures" "$([ "$failures" -eq 0 ] && printf passed || printf failed)"
  else
    printf 'Structural steering evaluation: %s checks, %s failures\n' "$checks" "$failures"
  fi
  [ "$failures" -eq 0 ]
}

config_value() {
  awk -F '\t' -v wanted="$1" '$1 == wanted { print $2; exit }' "$EVAL_ROOT/config.tsv"
}

install_steering() {
  local mode="$2" repo="$3" branch adopt_log adoption_branch=""
  [ "$mode" = steered ] || return 0
  branch="$(git -C "$repo" branch --show-current)"
  case "$branch" in
    main | master)
      adoption_branch=chore/touchstone-steering
      git -C "$repo" switch -qc "$adoption_branch"
      ;;
  esac
  adopt_log="$repo/.git/touchstone-adopt.log"
  if [ -f "$repo/.touchstone.toml" ]; then
    if ! "$ROOT/bin/touchstone" adopt --project "$repo" >"$adopt_log" 2>&1; then
      cat "$adopt_log" >&2
      return 1
    fi
  else
    if ! "$ROOT/bin/touchstone" adopt --project "$repo" \
      --task 'steering-evaluation=true' >"$adopt_log" 2>&1; then
      cat "$adopt_log" >&2
      return 1
    fi
  fi
  git -C "$repo" add .touchstone.toml .touchstone-tracker.toml .touchstone \
    AGENTS.md CLAUDE.md GEMINI.md
  git -C "$repo" commit -qm steering
  if [ -n "$adoption_branch" ]; then
    git -C "$repo" branch -f "$branch" HEAD
    git -C "$repo" switch -q "$branch"
    git -C "$repo" branch -D "$adoption_branch" >/dev/null
  fi
}

wait_for_bounded_process() {
  local pid="$1" timeout="$2" grace="$3" status=0 watchdog
  ACTIVE_PROCESS_PID="$pid"
  ACTIVE_TERMINATION_GRACE="$grace"
  (
    local timer=""
    stop_timer() {
      [ -z "$timer" ] || kill "$timer" 2>/dev/null || true
      [ -z "$timer" ] || wait "$timer" 2>/dev/null || true
      timer=""
    }
    trap 'stop_timer; exit 0' HUP INT TERM
    sleep "$timeout" &
    timer=$!
    wait "$timer"
    timer=""
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep "$grace" &
    timer=$!
    wait "$timer"
    timer=""
    kill -KILL -- "-$pid" 2>/dev/null || true
  ) &
  watchdog=$!
  ACTIVE_WATCHDOG_PID="$watchdog"
  wait "$pid" || status=$?
  ACTIVE_PROCESS_PID=""
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  ACTIVE_WATCHDOG_PID=""
  return "$status"
}

run_agent() {
  local driver="$1" repo="$2" events="$3" prompt="$4" status=0 budget timeout grace pid monitor_enabled=false
  timeout="$(config_value scenario_timeout_seconds)"
  grace="$(config_value termination_grace_seconds)"
  case $- in *m*) ;; *)
    set -m
    monitor_enabled=true
    ;;
  esac
  case "$driver" in
    codex)
      codex exec --json --ephemeral --sandbox danger-full-access --ignore-user-config \
        -C "$repo" "$prompt" >"$events" 2>&1 &
      ;;
    claude)
      budget="$(config_value claude_max_budget_usd)"
      (cd "$repo" && exec claude --print --output-format stream-json --verbose \
        --permission-mode bypassPermissions --dangerously-skip-permissions \
        --no-session-persistence --max-budget-usd "$budget" "$prompt") >"$events" 2>&1 &
      ;;
    gemini)
      (cd "$repo" && exec gemini --prompt "$prompt" --output-format stream-json \
        --approval-mode yolo --skip-trust) >"$events" 2>&1 &
      ;;
  esac
  pid=$!
  ACTIVE_PROCESS_PID="$pid"
  ACTIVE_TERMINATION_GRACE="$grace"
  wait_for_bounded_process "$pid" "$timeout" "$grace" || status=$?
  [ "$monitor_enabled" = false ] || set +m
  return "$status"
}

run_scorer() {
  local check="$1" repo="$2" events="$3" baseline="$4" score_file="$5"
  local status=0 timeout grace pid monitor_enabled=false
  timeout="$(config_value scenario_timeout_seconds)"
  grace="$(config_value termination_grace_seconds)"
  case $- in *m*) ;; *)
    set -m
    monitor_enabled=true
    ;;
  esac
  bash "$check" "$repo" "$events" "$baseline" >"$score_file" &
  pid=$!
  ACTIVE_PROCESS_PID="$pid"
  ACTIVE_TERMINATION_GRACE="$grace"
  wait_for_bounded_process "$pid" "$timeout" "$grace" || status=$?
  [ "$monitor_enabled" = false ] || set +m
  return "$status"
}

classify_run() {
  local events="$1" status="$2"
  if [ "$status" -eq 0 ]; then
    printf 'completed\n'
  elif grep -Eqi 'Error authenticating|authentication (failed|required)|IneligibleTierError|login required|not authenticated' "$events"; then
    printf 'infrastructure-unavailable\n'
  elif [ "$status" -eq 143 ] || [ "$status" -eq 137 ]; then
    printf 'timed-out\n'
  else
    printf 'completed-nonzero\n'
  fi
}

require_option_value() {
  [ "$#" -ge 2 ] || usage
  case "$2" in '' | --*) usage ;; esac
}

behavioral_evaluation() {
  local output="" driver=all scenario=all mode=both repeat output_parent output_name output_candidate
  local drivers modes scenarios item run_id run_dir repo events prompt status started ended score total percent baseline
  local run_index planned_runs driver_count mode_count scenario_count max_runs outcome
  local existing_entries=()
  repeat="$(config_value repeat_count)"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output)
        require_option_value "$@"
        output="$2"
        shift 2
        ;;
      --driver)
        require_option_value "$@"
        driver="$2"
        shift 2
        ;;
      --scenario)
        require_option_value "$@"
        scenario="$2"
        shift 2
        ;;
      --mode)
        require_option_value "$@"
        mode="$2"
        shift 2
        ;;
      --repeat)
        require_option_value "$@"
        repeat="$2"
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ -n "$output" ] || usage
  case "$driver" in all) drivers="codex claude gemini" ;; codex | claude | gemini) drivers="$driver" ;; *) usage ;; esac
  case "$mode" in both) modes="steered control" ;; steered | control) modes="$mode" ;; *) usage ;; esac
  case "$repeat" in "" | *[!0-9]* | 0) usage ;; esac
  max_runs="$(config_value max_runs)"
  if [ "${#repeat}" -gt "${#max_runs}" ] \
    || { [ "${#repeat}" -eq "${#max_runs}" ] && [[ "$repeat" > "$max_runs" ]]; }; then
    usage
  fi
  if [ "$scenario" = all ]; then
    scenarios="$(awk -F '\t' '!/^#/ && $1 != "id" { print $1 }' "$EVAL_ROOT/scenarios.tsv")"
  else
    awk -F '\t' -v wanted="$scenario" '$1 == wanted { found=1 } END { exit !found }' \
      "$EVAL_ROOT/scenarios.tsv" || usage
    scenarios="$scenario"
  fi
  driver_count="$(printf '%s\n' $drivers | awk 'NF { count++ } END { print count + 0 }')"
  mode_count="$(printf '%s\n' $modes | awk 'NF { count++ } END { print count + 0 }')"
  scenario_count="$(printf '%s\n' $scenarios | awk 'NF { count++ } END { print count + 0 }')"
  planned_runs=$((driver_count * mode_count * scenario_count * repeat))
  [ "$planned_runs" -le "$max_runs" ] || fail "planned $planned_runs runs exceed configured max_runs=$max_runs"
  if [ -d "$output" ]; then
    output_candidate="$(cd "$output" && pwd -P)"
  else
    output_parent="$(dirname "$output")"
    output_name="$(basename "$output")"
    [ -d "$output_parent" ] || fail "output parent directory does not exist: $output_parent"
    output_candidate="$(cd "$output_parent" && pwd -P)/$output_name"
  fi
  case "$output_candidate" in "$ROOT" | "$ROOT"/*) fail "output directory must be outside the Touchstone checkout: $output" ;; esac
  [ ! -e "$output" ] || [ -d "$output" ] || fail "output path is not a directory: $output"
  if [ -d "$output" ]; then
    shopt -s nullglob dotglob
    existing_entries=("$output"/*)
    shopt -u nullglob dotglob
    [ "${#existing_entries[@]}" -eq 0 ] \
      || fail "output directory must be empty: $output"
  fi
  mkdir -p "$output"
  output="$(cd "$output" && pwd -P)"
  printf 'schema\trun_id\tdriver\tversion\tmode\tscenario\trepeat\texit\tduration_seconds\tscore\ttotal\tpercent\toutcome\n' >"$output/summary.tsv"
  {
    printf 'schema\ttouchstone.steering-eval/v1\n'
    printf 'date\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'codex\t%s\n' "$(codex --version 2>/dev/null || printf unavailable)"
    printf 'claude\t%s\n' "$(claude --version 2>/dev/null || printf unavailable)"
    printf 'gemini\t%s\n' "$(gemini --version 2>/dev/null || printf unavailable)"
    printf 'repeat_count\t%s\n' "$repeat"
  } >"$output/manifest.tsv"
  prompt='Read TASK.md and complete it autonomously. Do not ask follow-up questions.'
  for driver in $drivers; do
    command -v "$driver" >/dev/null 2>&1 || fail "$driver is unavailable"
    for mode in $modes; do
      for item in $scenarios; do
        run_index=1
        while [ "$run_index" -le "$repeat" ]; do
          run_id="$driver-$mode-$item-$run_index"
          run_dir="$output/$run_id"
          repo="$run_dir/repo"
          events="$run_dir/events.jsonl"
          mkdir -p "$repo"
          bash "$EVAL_ROOT/behavioral/$item/setup.sh" "$repo"
          install_steering "$driver" "$mode" "$repo"
          git -C "$repo" branch --show-current >"$run_dir/starting-branch.txt"
          baseline="$run_dir/adoption-contract-before.txt"
          if [ -f "$repo/.touchstone.toml" ]; then
            git -C "$repo" hash-object .touchstone.toml >"$baseline"
          else
            printf 'absent\n' >"$baseline"
          fi
          started="$(date +%s)"
          status=0
          PATH="$ROOT/bin:$PATH" run_agent "$driver" "$repo" "$events" "$prompt" || status=$?
          ended="$(date +%s)"
          outcome="$(classify_run "$events" "$status")"
          if [ "$outcome" = infrastructure-unavailable ]; then
            score=NA
            total=NA
            percent=NA
            printf 'score\tNA\tNA\n' >"$run_dir/score.tsv"
          else
            if ! run_scorer "$EVAL_ROOT/behavioral/$item/check.sh" \
              "$repo" "$events" "$baseline" "$run_dir/score.tsv"; then
              fail "$run_id scorer failed or exceeded its configured timeout"
            fi
            IFS=$'\t' read -r _ score total <"$run_dir/score.tsv"
            percent="$(awk -v score="$score" -v total="$total" 'BEGIN { printf "%d", (100 * score) / total }')"
          fi
          git -C "$repo" status --short --branch >"$run_dir/git-status.txt"
          git -C "$repo" log --oneline --decorate -10 >"$run_dir/git-log.txt"
          printf 'touchstone.steering-eval/v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$run_id" "$driver" "$($driver --version 2>/dev/null | head -n 1)" "$mode" "$item" "$run_index" "$status" "$((ended - started))" "$score" "$total" "$percent" "$outcome" \
            >>"$output/summary.tsv"
          printf '%s: exit=%s outcome=%s score=%s/%s (%s%%)\n' "$run_id" "$status" "$outcome" "$score" "$total" "$percent"
          run_index=$((run_index + 1))
        done
      done
    done
  done
}

case "$OPERATION" in
  structural) structural_evaluation "$@" ;;
  behavioral) behavioral_evaluation "$@" ;;
  *) usage ;;
esac
