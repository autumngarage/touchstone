#!/usr/bin/env bash
#
# tests/test-agents-principles-block.sh — verify the shared-principles block
# helper for AGENTS.md.
#
# Covers:
#   1. No file → returns 2 (caller decides).
#   2. File without sentinels → block injected after the H1.
#   3. File without H1 → block injected at the very top.
#   4. File with current block → no diff (idempotent).
#   5. File with stale block → block refreshed in place.
#   6. File with project-specific content after the block → preserved verbatim.
#   7. Orphaned start sentinel without end → returns 1, file untouched.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-agents-principles.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../lib/agents-principles-block.sh
source "$TOUCHSTONE_ROOT/lib/agents-principles-block.sh"

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -qF "$needle" "$file"; then
    fail "expected $file to contain '$needle'"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -qF "$needle" "$file"; then
    fail "expected $file to NOT contain '$needle'"
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

# --- 1. Missing file → exit 2 ----------------------------------------------
echo "==> missing file returns 2"
set +e
agents_principles_block_apply "$TEST_DIR/does-not-exist.md"
rc=$?
set -e
assert_eq "missing file rc" 2 "$rc"

# --- 2. Inject into a file with an H1 --------------------------------------
echo "==> inject block after H1"
target="$TEST_DIR/case-h1.md"
cat > "$target" <<'EOF'
# AGENTS.md — AI Reviewer Guide for Foo

You are reviewing pull requests for **Foo**.

## What to prioritize (in order)

1. Data integrity.
EOF
agents_principles_block_apply "$target"
assert_contains "$target" "$AGENTS_PRINCIPLES_BLOCK_BEGIN"
assert_contains "$target" "$AGENTS_PRINCIPLES_BLOCK_END"
assert_contains "$target" "Shared Engineering Principles"
assert_contains "$target" "No band-aids"
assert_contains "$target" "Required Delivery Workflow"
assert_contains "$target" "Before the first edit"
assert_contains "$target" "scripts/open-pr.sh --auto-merge"
# H1 must remain on line 1.
first_line="$(head -n 1 "$target")"
assert_eq "h1 first line" "# AGENTS.md — AI Reviewer Guide for Foo" "$first_line"
# Project-specific content must be preserved.
assert_contains "$target" "1. Data integrity."

# --- 3. Inject when no H1 ---------------------------------------------------
echo "==> inject block when no H1"
target="$TEST_DIR/case-no-h1.md"
cat > "$target" <<'EOF'
This file has no H1.

Some body.
EOF
agents_principles_block_apply "$target"
first_line="$(head -n 1 "$target")"
assert_eq "no-h1 first line" "$AGENTS_PRINCIPLES_BLOCK_BEGIN" "$first_line"
assert_contains "$target" "This file has no H1."

# --- 4. Idempotent on a current file ----------------------------------------
echo "==> idempotent on current block"
target="$TEST_DIR/case-current.md"
cat > "$target" <<'EOF'
# AGENTS.md

EOF
agents_principles_block_apply "$target"
sha_before="$(shasum -a 256 "$target" | awk '{print $1}')"
agents_principles_block_apply "$target"
sha_after="$(shasum -a 256 "$target" | awk '{print $1}')"
assert_eq "idempotent sha" "$sha_before" "$sha_after"

# --- 5. Refresh a stale block ----------------------------------------------
echo "==> refresh stale block"
target="$TEST_DIR/case-stale.md"
cat > "$target" <<EOF
# AGENTS.md

$AGENTS_PRINCIPLES_BLOCK_BEGIN
## Old Principles
- This is a stale block from an older touchstone version.
- It should be replaced wholesale.
$AGENTS_PRINCIPLES_BLOCK_END

## Project-specific section
The project-specific guidance below MUST survive a refresh.
EOF
agents_principles_block_apply "$target"
assert_contains "$target" "No band-aids"
assert_not_contains "$target" "Old Principles"
assert_not_contains "$target" "stale block from an older"
# The project-specific content after the block must survive.
assert_contains "$target" "## Project-specific section"
assert_contains "$target" "MUST survive a refresh"

# --- 6. Orphaned sentinel → refuses, file untouched -------------------------
echo "==> orphaned sentinel refuses"
target="$TEST_DIR/case-orphan.md"
cat > "$target" <<EOF
# AGENTS.md

$AGENTS_PRINCIPLES_BLOCK_BEGIN
Someone deleted the end marker by accident.

## Project content still here.
EOF
sha_before="$(shasum -a 256 "$target" | awk '{print $1}')"
set +e
agents_principles_block_apply "$target" 2>/dev/null
rc=$?
set -e
assert_eq "orphan rc" 1 "$rc"
sha_after="$(shasum -a 256 "$target" | awk '{print $1}')"
assert_eq "orphan untouched" "$sha_before" "$sha_after"

# --- 7. Block lands BEFORE existing project content (top-of-file priority) --
echo "==> block lands at top, ahead of project content"
target="$TEST_DIR/case-ordering.md"
cat > "$target" <<'EOF'
# AGENTS.md — AI Reviewer Guide for Foo

Project-specific intro.

## Priorities
EOF
agents_principles_block_apply "$target"
# Line numbers: H1 is line 1, blank line 2, BEGIN sentinel on line 3.
sentinel_line="$(grep -nF "$AGENTS_PRINCIPLES_BLOCK_BEGIN" "$target" | head -1 | cut -d: -f1)"
project_line="$(grep -nF 'Project-specific intro.' "$target" | head -1 | cut -d: -f1)"
if [ "$sentinel_line" -ge "$project_line" ]; then
  fail "block (line $sentinel_line) must precede project content (line $project_line)"
fi

# --- Done -------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: agents-principles-block helper behaves correctly across 7 cases"
