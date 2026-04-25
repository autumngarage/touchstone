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

# ----------------------------------------------------------------------
# touchstone-agent-swarms
# ----------------------------------------------------------------------
TRIGGERS=(
  "I have three independent refactors across separate packages that I want to ship in parallel. How should I approach this?"
  "Can you help me fan out this work to multiple Claude agents running concurrently?"
  "I want to split this batch of unrelated tasks across parallel agent runs. What's the right shape?"
  "Should I orchestrate multiple subagents for this set of file-disjoint changes?"
  "I need to parallelize four independent investigations. Walk me through how to coordinate them."
)

NEGATIVES=(
  "What is 2 + 2?"
  "Show me the README of this project."
  "How do I run the test suite?"
  "What's the current git branch?"
  "List the files in the principles directory."
)

# Activation signal — strong markers from the skill body that wouldn't
# typically appear in a response that hadn't loaded the skill.
ACTIVATION_REGEX='four.question gate|skeptical verifier|clean context|file.disjoint|disjoint file|concurrency cap|3.{0,3}5 agents|swarm pattern|swarm shape|files.not.to.touch|brief.quality'

POSITIVE_PASS=0
POSITIVE_TOTAL=0
NEGATIVE_FALSE_POS=0

run_trial() {
  local prompt="$1"
  local response
  response="$(claude -p "$prompt" 2>&1 || true)"
  if printf '%s' "$response" | grep -qiE "$ACTIVATION_REGEX"; then
    return 0
  fi
  return 1
}

echo "==> Positive trials (touchstone-agent-swarms)"
i=0
for trigger in "${TRIGGERS[@]}"; do
  i=$((i + 1))
  for trial in $(seq 1 "$TRIALS_PER"); do
    POSITIVE_TOTAL=$((POSITIVE_TOTAL + 1))
    if run_trial "$trigger"; then
      POSITIVE_PASS=$((POSITIVE_PASS + 1))
      echo "  OK: phrasing $i trial $trial"
    else
      echo "  MISS: phrasing $i trial $trial"
    fi
  done
done

echo "==> Negative trials"
i=0
for benign in "${NEGATIVES[@]}"; do
  i=$((i + 1))
  if run_trial "$benign"; then
    NEGATIVE_FALSE_POS=$((NEGATIVE_FALSE_POS + 1))
    echo "  FALSE POSITIVE: phrasing $i"
  else
    echo "  OK: phrasing $i (no false positive)"
  fi
done

THRESHOLD=$((POSITIVE_TOTAL * 80 / 100))
echo ""
echo "==> Results: $POSITIVE_PASS/$POSITIVE_TOTAL positive (need ≥$THRESHOLD), $NEGATIVE_FALSE_POS false positive(s)"

FAIL=0
if [ "$POSITIVE_PASS" -lt "$THRESHOLD" ]; then
  echo "FAIL: activation rate below 80% — iterate the skill description and re-run" >&2
  FAIL=1
fi
if [ "$NEGATIVE_FALSE_POS" -gt 0 ]; then
  echo "FAIL: skill activated on benign prompts — description is too broad" >&2
  FAIL=1
fi
if [ "$FAIL" -eq 1 ]; then
  exit 1
fi
echo "==> OK"
