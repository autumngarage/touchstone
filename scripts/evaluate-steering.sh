#!/usr/bin/env bash
# scripts/evaluate-steering.sh — structural and behavioral steering evaluation.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
EVAL_ROOT="$ROOT/evals/steering/v1"
OPERATION="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
STRUCTURAL_TEMP=""

cleanup() {
  [ -z "$STRUCTURAL_TEMP" ] || rm -rf -- "$STRUCTURAL_TEMP"
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/evaluate-steering.sh structural [--json]
  bash scripts/evaluate-steering.sh behavioral --output DIR [options]
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

case "$OPERATION" in
  structural) structural_evaluation "$@" ;;
  behavioral) exec bash "$EVAL_ROOT/run-behavioral.sh" "$ROOT" "$@" ;;
  *) usage ;;
esac
