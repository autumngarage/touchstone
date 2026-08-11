#!/usr/bin/env bash
#
# tests/test-touchstone-block.sh — verify the touchstone steering block helper
# for AGENTS.md / GEMINI.md.
#
# Covers:
#   1. No file → returns 2 (caller decides).
#   2. File without sentinels → block injected after the H1.
#   3. File without H1 → block injected at the very top.
#   4. File with current block → no diff (idempotent).
#   5. File with stale block → block refreshed in place.
#   6. File with project-specific content after the block → preserved verbatim.
#   7. Orphaned start sentinel without end → returns 1, file untouched.
#   8. Legacy sentinel (touchstone:shared-principles:*) is migrated on apply
#      to the new sentinel (touchstone:steering:*) without losing project
#      content outside the block.
#   9. The rendered block content matches TOUCHSTONE.md (single source of
#      truth — the lib never bakes content into bash heredoc).
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-block.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../lib/touchstone-block.sh
source "$TOUCHSTONE_ROOT/lib/touchstone-block.sh"
# shellcheck source=../lib/sha256.sh
source "$TOUCHSTONE_ROOT/lib/sha256.sh"

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
touchstone_block_apply "$TEST_DIR/does-not-exist.md" "$TOUCHSTONE_ROOT"
rc=$?
set -e
assert_eq "missing file rc" 2 "$rc"

# --- 2. Inject into a file with an H1 --------------------------------------
echo "==> inject block after H1"
target="$TEST_DIR/case-h1.md"
cat >"$target" <<'EOF'
# AGENTS.md — AI Reviewer Guide for Foo

You are reviewing pull requests for **Foo**.

## What to prioritize (in order)

1. Data integrity.
EOF
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT"
assert_contains "$target" "$TOUCHSTONE_BLOCK_BEGIN"
assert_contains "$target" "$TOUCHSTONE_BLOCK_END"
assert_contains "$target" "Touchstone — Shared Agent Steering"
assert_contains "$target" "No band-aids"
assert_contains "$target" "scripts/open-pr.sh --auto-merge"
# H1 must remain on line 1.
first_line="$(head -n 1 "$target")"
assert_eq "h1 first line" "# AGENTS.md — AI Reviewer Guide for Foo" "$first_line"
# Project-specific content must be preserved.
assert_contains "$target" "1. Data integrity."

# --- 3. Inject when no H1 ---------------------------------------------------
echo "==> inject block when no H1"
target="$TEST_DIR/case-no-h1.md"
cat >"$target" <<'EOF'
This file has no H1.

Some body.
EOF
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT"
first_line="$(head -n 1 "$target")"
assert_eq "no-h1 first line" "$TOUCHSTONE_BLOCK_BEGIN" "$first_line"
assert_contains "$target" "This file has no H1."

# --- 4. Idempotent on a current file ----------------------------------------
echo "==> idempotent on current block"
target="$TEST_DIR/case-current.md"
cat >"$target" <<'EOF'
# AGENTS.md

EOF
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT"
sha_before="$(touchstone_sha256_file "$target")"
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT"
sha_after="$(touchstone_sha256_file "$target")"
assert_eq "idempotent sha" "$sha_before" "$sha_after"

# --- 5. Refresh a stale block (current sentinel) ----------------------------
echo "==> refresh stale block (current sentinel)"
target="$TEST_DIR/case-stale.md"
cat >"$target" <<EOF
# AGENTS.md

$TOUCHSTONE_BLOCK_BEGIN
## Old Steering
- This is a stale block from an older touchstone version.
- It should be replaced wholesale.
$TOUCHSTONE_BLOCK_END

## Project-specific section
The project-specific guidance below MUST survive a refresh.
EOF
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT"
assert_contains "$target" "No band-aids"
assert_not_contains "$target" "Old Steering"
assert_not_contains "$target" "stale block from an older"
# The project-specific content after the block must survive.
assert_contains "$target" "## Project-specific section"
assert_contains "$target" "MUST survive a refresh"

# --- 6. Orphaned sentinel → refuses, file untouched -------------------------
echo "==> orphaned sentinel refuses"
target="$TEST_DIR/case-orphan.md"
cat >"$target" <<EOF
# AGENTS.md

$TOUCHSTONE_BLOCK_BEGIN
Someone deleted the end marker by accident.

## Project content still here.
EOF
sha_before="$(touchstone_sha256_file "$target")"
set +e
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT" 2>/dev/null
rc=$?
set -e
assert_eq "orphan rc" 1 "$rc"
sha_after="$(touchstone_sha256_file "$target")"
assert_eq "orphan untouched" "$sha_before" "$sha_after"

# --- 7. Block lands BEFORE existing project content (top-of-file priority) --
echo "==> block lands at top, ahead of project content"
target="$TEST_DIR/case-ordering.md"
cat >"$target" <<'EOF'
# AGENTS.md — AI Reviewer Guide for Foo

Project-specific intro.

## Priorities
EOF
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT"
sentinel_line="$(grep -nF "$TOUCHSTONE_BLOCK_BEGIN" "$target" | head -1 | cut -d: -f1)"
project_line="$(grep -nF 'Project-specific intro.' "$target" | head -1 | cut -d: -f1)"
if [ "$sentinel_line" -ge "$project_line" ]; then
  fail "block (line $sentinel_line) must precede project content (line $project_line)"
fi

# --- 8. Legacy sentinel migrates on apply ----------------------------------
echo "==> legacy sentinel (shared-principles) migrates to steering on apply"
target="$TEST_DIR/case-legacy.md"
cat >"$target" <<EOF
# AGENTS.md

$TOUCHSTONE_BLOCK_BEGIN_LEGACY
## Old shared-principles block
- old content
$TOUCHSTONE_BLOCK_END_LEGACY

## Project section
project line that must survive.
EOF
touchstone_block_apply "$target" "$TOUCHSTONE_ROOT"
# Legacy sentinels are gone; new sentinels are present.
assert_not_contains "$target" "$TOUCHSTONE_BLOCK_BEGIN_LEGACY"
assert_not_contains "$target" "$TOUCHSTONE_BLOCK_END_LEGACY"
assert_contains "$target" "$TOUCHSTONE_BLOCK_BEGIN"
assert_contains "$target" "$TOUCHSTONE_BLOCK_END"
# Old block content is gone, new content is in.
assert_not_contains "$target" "Old shared-principles block"
assert_not_contains "$target" "old content"
assert_contains "$target" "No band-aids"
# Project content outside the legacy block survives.
assert_contains "$target" "## Project section"
assert_contains "$target" "project line that must survive."

# --- 9. Rendered block tracks TOUCHSTONE.md (single source of truth) -------
echo "==> rendered block content tracks TOUCHSTONE.md"
rendered="$(touchstone_block_render "$TOUCHSTONE_ROOT")"
# Key phrases from TOUCHSTONE.md must appear in rendered output.
echo "$rendered" | grep -qF "Touchstone — Shared Agent Steering" \
  || fail "rendered block missing TOUCHSTONE.md H1"
echo "$rendered" | grep -qF "No band-aids" \
  || fail "rendered block missing daily-reminder bullets"
echo "$rendered" | grep -qF "scripts/open-pr.sh --auto-merge" \
  || fail "rendered block missing lifecycle commands"

# --- Case 10: a failed replacement write is a FAILURE, not a silent success --
# A readable-but-unwritable target (0444) fails the final redirect; the
# cleanup after it must not launder that into return 0 — update-project
# commits version bumps on this function's word (PR #703 review).
RO_TARGET="$TEST_DIR/readonly-target.md"
printf '# Project\n\n<!-- touchstone:begin -->\nstale\n<!-- touchstone:end -->\n' >"$RO_TARGET"
# Ensure the content WOULD change, then drop write permission.
chmod 0444 "$RO_TARGET"
if [ -w "$RO_TARGET" ]; then
  echo "  SKIP: platform ignores mode 0444 (no unwritable-file precondition)"
else
  RO_STATUS=0
  touchstone_block_apply "$RO_TARGET" "$TOUCHSTONE_ROOT" 2>/dev/null || RO_STATUS=$?
  if [ "$RO_STATUS" -eq 0 ]; then
    fail "block_apply reported success while the target was unwritable"
  fi
  grep -qF 'stale' "$RO_TARGET" || fail "unwritable target was somehow modified"
fi
chmod 0644 "$RO_TARGET" 2>/dev/null || true

# --- Done -------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: touchstone-block helper behaves correctly across 9 cases"
