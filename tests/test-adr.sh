#!/usr/bin/env bash
#
# tests/test-adr.sh — verify ADR creation handles sed metacharacters safely.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t toolkit-test-adr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: create ADR with slash in title"

PROJECT_DIR="$TEST_DIR/project"
mkdir -p "$PROJECT_DIR"

(
  cd "$PROJECT_DIR"
  TOOLKIT_NO_AUTO_UPDATE=1 "$TOOLKIT_ROOT/bin/toolkit" adr "Auth/API contract"
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
  exit 0
fi

echo "FAIL: ADR file still contains unresolved placeholders or wrong title" >&2
sed -n '1,12p' "$ADR_FILE" >&2
exit 1
