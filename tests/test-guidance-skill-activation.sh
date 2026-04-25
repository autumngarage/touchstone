#!/usr/bin/env bash
#
# tests/test-guidance-skill-activation.sh — probe whether Touchstone-
# shipped skills activate when given trigger phrases that match their
# `description` field. Skill descriptions are the only handle Claude
# Code has for deciding which skills to surface; if a description rots,
# the skill silently stops firing. This test catches that regression.
#
# Currently covers: touchstone-agent-swarms (Phase 3 of the plan).
# When new skills ship, add a new case below.
#
# Modes:
#   default (fast)   — 1 trial × 5 phrasings + 5 negatives = ~10 claude -p calls
#   TOUCHSTONE_FULL_SKILL_PROBES=1 — 5 × 5 + 5 = 30 calls (the documented
#                                     measurement; ~3 min)
#   TOUCHSTONE_SKIP_SKILL_PROBES=1 — exit 0 immediately (iteration mode)
#
# Pass criteria:
#   - positive trials ≥80% activation
#   - 0 false-positive activations on benign prompts
#
set -euo pipefail

if [ "${TOUCHSTONE_SKIP_SKILL_PROBES:-0}" = "1" ]; then
  echo "==> SKIP: TOUCHSTONE_SKIP_SKILL_PROBES=1"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "==> SKIP: claude CLI not installed"
  exit 0
fi

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOUCHSTONE_ROOT"

if [ "${TOUCHSTONE_FULL_SKILL_PROBES:-0}" = "1" ]; then
  TRIALS_PER=5
  echo "==> FULL mode: 5 × 5 phrasings + 5 negatives (~3 min)"
else
  TRIALS_PER=1
  echo "==> FAST mode: 1 × 5 phrasings + 5 negatives (~70s). Set TOUCHSTONE_FULL_SKILL_PROBES=1 for the 25-trial measurement."
fi

NEGATIVES=(
  "What is 2 + 2?"
  "Show me the README of this project."
  "How do I run the test suite?"
  "What's the current git branch?"
  "List the files in the principles directory."
)

OVERALL_FAIL=0

run_trial() {
  local prompt="$1" regex="$2"
  local response
  response="$(claude -p "$prompt" 2>&1 || true)"
  if printf '%s' "$response" | grep -qiE "$regex"; then
    return 0
  fi
  return 1
}

# Run an activation suite for one skill: 5 trigger phrasings × $TRIALS_PER
# trials each (positive) + the shared NEGATIVES list (must not match the
# skill's activation regex). Pass requires ≥80% positive activation and
# zero false positives. A failure for any skill flips OVERALL_FAIL to 1
# but the function still runs its full positive/negative sweep so the
# operator sees the complete picture per run.
run_skill_suite() {
  local skill_name="$1" activation_regex="$2"
  shift 2
  local triggers=("$@")
  local positive_pass=0 positive_total=0 negative_fp=0

  echo "==> Skill: $skill_name"
  echo "  positive trials"
  local i=0
  for trigger in "${triggers[@]}"; do
    i=$((i + 1))
    for trial in $(seq 1 "$TRIALS_PER"); do
      positive_total=$((positive_total + 1))
      if run_trial "$trigger" "$activation_regex"; then
        positive_pass=$((positive_pass + 1))
        echo "    OK: phrasing $i trial $trial"
      else
        echo "    MISS: phrasing $i trial $trial"
      fi
    done
  done

  echo "  negative trials"
  i=0
  for benign in "${NEGATIVES[@]}"; do
    i=$((i + 1))
    if run_trial "$benign" "$activation_regex"; then
      negative_fp=$((negative_fp + 1))
      echo "    FALSE POSITIVE: negative $i"
    else
      echo "    OK: negative $i"
    fi
  done

  local threshold=$((positive_total * 80 / 100))
  echo "  results: $positive_pass/$positive_total positive (need ≥$threshold), $negative_fp false positive(s)"

  if [ "$positive_pass" -lt "$threshold" ]; then
    echo "  FAIL: $skill_name activation below 80%" >&2
    OVERALL_FAIL=1
  elif [ "$negative_fp" -gt 0 ]; then
    echo "  FAIL: $skill_name false-positive on benign prompt" >&2
    OVERALL_FAIL=1
  else
    echo "  PASS"
  fi
  echo ""
}

# ----------------------------------------------------------------------
# touchstone-agent-swarms
# ----------------------------------------------------------------------
SWARMS_TRIGGERS=(
  "I have three independent refactors across separate packages that I want to ship in parallel. How should I approach this?"
  "Can you help me fan out this work to multiple Claude agents running concurrently?"
  "I want to split this batch of unrelated tasks across parallel agent runs. What's the right shape?"
  "Should I orchestrate multiple subagents for this set of file-disjoint changes?"
  "I need to parallelize four independent investigations. Walk me through how to coordinate them."
)
SWARMS_REGEX='four.question gate|skeptical verifier|clean context|file.disjoint|disjoint file|concurrency cap|3.{0,3}5 agents|swarm pattern|swarm shape|files.not.to.touch|brief.quality'

run_skill_suite "touchstone-agent-swarms" "$SWARMS_REGEX" "${SWARMS_TRIGGERS[@]}"

# ----------------------------------------------------------------------
# touchstone-audit-weak-points
# ----------------------------------------------------------------------
AUDIT_TRIGGERS=(
  "I just found a bug where a cache was returning stale data. Should I look for similar patterns elsewhere?"
  "I noticed this same anti-pattern in three files. How do I systematically check the rest of the codebase?"
  "Help me audit this class of bug across the project — I want to find every instance."
  "Found a structural issue with how we handle null returns. What's the methodology to find and fix all of them?"
  "There's a recurring bug shape we keep hitting. How do I do a comprehensive audit and stop it from coming back?"
)
AUDIT_REGEX='ranked punch.?list|production impact|reviewed and bounded|fix in tiers|audit \+ guardrail|every instance|systematic audit|class of bug|whole class|hand.write the guardrail|add a guardrail'

run_skill_suite "touchstone-audit-weak-points" "$AUDIT_REGEX" "${AUDIT_TRIGGERS[@]}"

if [ "$OVERALL_FAIL" -eq 1 ]; then
  exit 1
fi
echo "==> OK: all skill activation suites passed"
