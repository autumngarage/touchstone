#!/usr/bin/env bash
#
# tests/test-guidance-skill-activation.sh — verify Touchstone-shipped
# skills have frontmatter descriptions shaped for Claude Code activation.
#
# Claude Code activates skills from the SKILL.md frontmatter description.
# That makes this a structural contract: if a description loses the trigger
# terms for the intended work shape, the skill silently stops surfacing.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOUCHSTONE_ROOT"

OVERALL_FAIL=0

frontmatter_value() {
  local skill_file="$1" key="$2"

  awk -v key="$key" '
    NR == 1 {
      if ($0 != "---") {
        exit 2
      }
      in_frontmatter = 1
      next
    }
    in_frontmatter && $0 == "---" {
      exit 0
    }
    in_frontmatter && index($0, key ":") == 1 {
      value = substr($0, length(key) + 2)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
      found = 1
      exit 0
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$skill_file"
}

assert_description_contract() {
  local skill_dir="$1" expected_name="$2" description_regex="$3"
  shift 3
  local required_terms=("$@")
  local skill_file=".claude/skills/$skill_dir/SKILL.md"
  local name description missing=0

  echo "==> Skill: $skill_dir"
  if [ ! -f "$skill_file" ]; then
    echo "  FAIL: missing $skill_file" >&2
    OVERALL_FAIL=1
    return
  fi

  name="$(frontmatter_value "$skill_file" "name" || true)"
  description="$(frontmatter_value "$skill_file" "description" || true)"

  if [ "$name" != "$expected_name" ]; then
    echo "  FAIL: expected name '$expected_name', got '${name:-<missing>}'" >&2
    OVERALL_FAIL=1
  fi

  if [ -z "$description" ]; then
    echo "  FAIL: missing description frontmatter" >&2
    OVERALL_FAIL=1
    return
  fi

  if ! printf '%s\n' "$description" | grep -qiE '^Use (when|after) '; then
    echo "  FAIL: description must start with an activation phrase such as 'Use when' or 'Use after'" >&2
    OVERALL_FAIL=1
  fi

  if ! printf '%s\n' "$description" | grep -qiE "$description_regex"; then
    echo "  FAIL: description does not match expected activation shape" >&2
    echo "    description: $description" >&2
    echo "    expected: $description_regex" >&2
    OVERALL_FAIL=1
  fi

  for term in "${required_terms[@]}"; do
    if printf '%s\n' "$description" | grep -qiE "$term"; then
      echo "  OK: description includes trigger term /$term/"
    else
      echo "  FAIL: description missing trigger term /$term/" >&2
      missing=$((missing + 1))
    fi
  done

  if [ "$missing" -gt 0 ]; then
    OVERALL_FAIL=1
    return
  fi

  echo "  PASS"
}

# ----------------------------------------------------------------------
# touchstone-agent-swarms
# ----------------------------------------------------------------------
SWARMS_DESCRIPTION_REGEX='parallelizing work across multiple agents|fanning out'
SWARMS_TERMS=(
  'paralleliz'
  'multiple agents'
  'fanning out|fan out'
  'clean context'
  'different tools'
  'skeptical verifier'
  'parallel work'
)

assert_description_contract \
  "touchstone-agent-swarms" \
  "agent-swarms" \
  "$SWARMS_DESCRIPTION_REGEX" \
  "${SWARMS_TERMS[@]}"

# ----------------------------------------------------------------------
# touchstone-audit-weak-points
# ----------------------------------------------------------------------
AUDIT_DESCRIPTION_REGEX='structural bug|same anti-pattern|guardrail'
AUDIT_TERMS=(
  'structural bug'
  'systematically audit|audit'
  'same anti-pattern'
  'fix instances'
  'tier'
  'guardrail'
)

assert_description_contract \
  "touchstone-audit-weak-points" \
  "audit-weak-points" \
  "$AUDIT_DESCRIPTION_REGEX" \
  "${AUDIT_TERMS[@]}"

if [ "$OVERALL_FAIL" -eq 1 ]; then
  exit 1
fi
echo "==> OK: all skill activation frontmatter contracts passed"
