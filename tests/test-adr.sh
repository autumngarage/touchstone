#!/usr/bin/env bash
#
# tests/test-adr.sh — verify ADR creation handles sed metacharacters safely.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-adr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

assert_contains() {
  if ! grep -q "$2" "$1" 2>/dev/null; then
    echo "FAIL: expected $1 to contain '$2'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

echo "==> Test: create ADR with slash in title"

PROJECT_DIR="$TEST_DIR/project"
mkdir -p "$PROJECT_DIR"

(
  cd "$PROJECT_DIR"
  TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" adr "Auth/API contract"
) >/dev/null

ADR_FILE="$(find "$PROJECT_DIR/docs/adr" -maxdepth 1 -type f -name '*.md' | head -1)"

if [ -z "$ADR_FILE" ]; then
  echo "FAIL: expected ADR file to be created" >&2
  exit 1
fi

if grep -q '^# ADR-0001: Auth/API contract$' "$ADR_FILE" \
  && ! grep -q 'TITLE' "$ADR_FILE" \
  && ! grep -q '\*\*Date:\*\* DATE' "$ADR_FILE"; then
  echo "==> PASS: ADR placeholders were replaced correctly"
else
  echo "FAIL: ADR file still contains unresolved placeholders or wrong title" >&2
  sed -n '1,12p' "$ADR_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: project Claude skills are discoverable and valid"

SKILLS_HOME="$TEST_DIR/home"
mkdir -p "$SKILLS_HOME"

(
  cd "$TOUCHSTONE_ROOT"
  HOME="$SKILLS_HOME" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" skills
) > "$TEST_DIR/skills-list.txt"

assert_contains "$TEST_DIR/skills-list.txt" 'touchstone-audit'
assert_contains "$TEST_DIR/skills-list.txt" 'memory-audit'

(
  cd "$TOUCHSTONE_ROOT"
  HOME="$SKILLS_HOME" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" skills check
) > "$TEST_DIR/skills-check.txt"

assert_contains "$TEST_DIR/skills-check.txt" 'All 2 skills valid'

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all assertions passed"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
