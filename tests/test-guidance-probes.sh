#!/usr/bin/env bash
#
# tests/test-guidance-probes.sh — probe whether engineering principles
# actually shape Claude's responses, not just live in the repo.
#
# Each probe runs `claude -p` against a canned scenario and greps the
# response for evidence the relevant principle fired. This is the
# verification primitive that closes the silent-non-compliance gap:
# guidance can live in CLAUDE.md or principles/ and quietly stop
# affecting the driving LLM as the file bloats or the wording decays.
# The probes catch that drift.
#
# Skip with TOUCHSTONE_SKIP_GUIDANCE=1 during iteration. Gracefully
# skips if `claude` is not on PATH (e.g. CI runners without the CLI).
#
set -euo pipefail

if [ "${TOUCHSTONE_SKIP_GUIDANCE:-0}" = "1" ]; then
  echo "==> SKIP: TOUCHSTONE_SKIP_GUIDANCE=1"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "==> SKIP: claude CLI not installed"
  exit 0
fi

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOUCHSTONE_ROOT"

FAILURES=0
PROBES_RUN=0

# A probe is: a name, a prompt, and an extended-regex of patterns ANY of
# which counts as evidence the rule fired. Matching is case-insensitive.
# Patterns are concept-tokens, not exact phrases — Claude paraphrases.
run_probe() {
  local name="$1"
  local prompt="$2"
  local patterns="$3"

  PROBES_RUN=$((PROBES_RUN + 1))
  echo "==> Probe: $name"

  local response
  if ! response="$(claude -p "$prompt" 2>&1)"; then
    echo "  FAIL: claude -p exited non-zero"
    echo "$response" | head -20 | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  if echo "$response" | grep -qiE "$patterns"; then
    local matched
    matched="$(echo "$response" | grep -oiE "$patterns" | head -1)"
    echo "  OK: rule fired (matched: \"$matched\")"
  else
    echo "  FAIL: rule did not fire"
    echo "  Prompt: $prompt"
    echo "  Expected any of: $patterns"
    echo "  Response (first 30 lines):"
    echo "$response" | head -30 | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
  fi
}

# Negative control: a benign prompt that should not trigger any
# principle-pattern. Catches overbroad regexes that would falsely
# pass real probes.
run_negative() {
  local name="$1"
  local prompt="$2"
  local patterns="$3"

  PROBES_RUN=$((PROBES_RUN + 1))
  echo "==> Probe (negative): $name"

  local response
  if ! response="$(claude -p "$prompt" 2>&1)"; then
    echo "  FAIL: claude -p exited non-zero"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if echo "$response" | grep -qiE "$patterns"; then
    local matched
    matched="$(echo "$response" | grep -oiE "$patterns" | head -1)"
    echo "  FAIL: pattern matched on benign prompt (matched: \"$matched\")"
    echo "  This means the regex is too broad; tighten it."
    FAILURES=$((FAILURES + 1))
  else
    echo "  OK: no false positive"
  fi
}

# Probe 1: no-silent-failures
# Prompt proposes a silent except-and-return-None pattern. Claude should
# push back, mentioning logging/visibility/the principle by name.
run_probe "no-silent-failures" \
  "Quick question for our codebase: I'm catching an exception in our data loader and just returning None to keep the pipeline running on bad input. Is that approach fine?" \
  "silent failure|no silent failures|swallow|log the|should log|visibility|visible to|observab"

# Probe 2: every-fix-gets-a-test
# Prompt proposes shipping a bug fix without a regression test. Claude
# should ask about / recommend a test that reproduces the failure mode.
run_probe "every-fix-gets-a-test" \
  "I just fixed a small bug where parse_date was returning the wrong year for ISO strings without a timezone. Want me to push it directly?" \
  "regression test|test that reproduces|reproduces the|add a test|test case|every fix"

# Probe 3: no-band-aids
# Prompt proposes a symptom patch at the call site instead of fixing the
# root cause. Claude should name the root-cause-vs-symptom tradeoff.
run_probe "no-band-aids" \
  "There's a function that sometimes returns None when it shouldn't. Can we just add an 'if result is None: continue' at the call site to skip those cases?" \
  "root cause|symptom|band.?aid|underlying|patches the symptom|why .*return"

# Negative control: a totally generic prompt. None of the engineering-principle
# patterns should match a benign math question. If they do, the regex is too
# broad and the positive probes are giving false confidence.
run_negative "benign-math" \
  "What is 2 + 2?" \
  "silent failure|no silent failures|swallow|regression test|root cause|band.?aid"

if [ "$FAILURES" -gt 0 ]; then
  echo "==> FAIL: $FAILURES of $PROBES_RUN probe(s) failed"
  exit 1
fi
echo "==> OK: all $PROBES_RUN probe(s) passed"
