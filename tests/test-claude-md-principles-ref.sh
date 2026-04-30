#!/usr/bin/env bash
#
# tests/test-claude-md-principles-ref.sh — verify the CLAUDE.md @principles
# import-block helper and its end-to-end use through `touchstone init`.
#
# Covers:
#   1. has_principles_ref detection (complete/partial/absent)
#   2. inject_principles_block on a CLAUDE.md without imports
#   3. inject is a no-op when imports already exist (returns 2)
#   4. inject completes a partial legacy @principles/ set
#   5. decision record/read round-trip via .touchstone-config
#   6. end-to-end: --claude-principles=yes plants imports + records connected
#   7. end-to-end: partial imports are completed + recorded connected
#   8. end-to-end: --no-claude-principles records skipped
#   9. end-to-end: a prior skipped decision is respected (no re-prompt path)
#  10. end-to-end: prior connected partial imports are completed
#  11. end-to-end: existing CLAUDE.md with full imports records `connected`
#  12. end-to-end: prompt mode without a TTY warns but does not record
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-claude-md-principles.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../lib/claude-md-principles-ref.sh
source "$TOUCHSTONE_ROOT/lib/claude-md-principles-ref.sh"

ERRORS=0
fail() { echo "FAIL: $*" >&2; ERRORS=$((ERRORS + 1)); }
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
  [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- 1. Detection (complete/partial/absent) ---------------------------------
echo "==> 1. has_principles_ref detection"
mkdir -p "$TEST_DIR/case-detect"
cat > "$TEST_DIR/case-detect/CLAUDE.md" <<'EOF'
# Project

@principles/git-workflow.md
EOF
if claude_md_has_principles_ref "$TEST_DIR/case-detect/CLAUDE.md"; then
  fail "partial @principles/ set should not count as fully connected"
fi
if ! claude_md_has_any_principles_ref "$TEST_DIR/case-detect/CLAUDE.md"; then
  fail "should detect any @principles/ import when present"
fi
cat > "$TEST_DIR/case-detect/CLAUDE.md" <<'EOF'
# Project

@principles/engineering-principles.md
@principles/pre-implementation-checklist.md
@principles/documentation-ownership.md
@principles/git-workflow.md
@principles/file-upstream-bugs.md
EOF
if ! claude_md_has_principles_ref "$TEST_DIR/case-detect/CLAUDE.md"; then
  fail "should detect full required @principles/ import set"
fi
cat > "$TEST_DIR/case-detect/CLAUDE.md" <<'EOF'
# Project

No imports here, just plain text.
EOF
if claude_md_has_principles_ref "$TEST_DIR/case-detect/CLAUDE.md"; then
  fail "should NOT detect full @principles/ import set when absent"
fi
if claude_md_has_any_principles_ref "$TEST_DIR/case-detect/CLAUDE.md"; then
  fail "should NOT detect any @principles/ import when absent"
fi

# --- 2. Inject when imports missing -----------------------------------------
echo "==> 2. inject after H1 when imports missing"
mkdir -p "$TEST_DIR/case-inject"
cat > "$TEST_DIR/case-inject/CLAUDE.md" <<'EOF'
# My Project

Some intro text.

## Architecture

Stuff.
EOF
claude_md_inject_principles_block "$TEST_DIR/case-inject/CLAUDE.md"
rc=$?
assert_eq "inject rc" 0 "$rc"
assert_contains "$TEST_DIR/case-inject/CLAUDE.md" "@principles/engineering-principles.md"
assert_contains "$TEST_DIR/case-inject/CLAUDE.md" "@principles/pre-implementation-checklist.md"
assert_contains "$TEST_DIR/case-inject/CLAUDE.md" "@principles/documentation-ownership.md"
assert_contains "$TEST_DIR/case-inject/CLAUDE.md" "@principles/git-workflow.md"
# H1 must remain on line 1.
first_line="$(head -n 1 "$TEST_DIR/case-inject/CLAUDE.md")"
assert_eq "H1 preserved" "# My Project" "$first_line"
# Project content must survive.
assert_contains "$TEST_DIR/case-inject/CLAUDE.md" "Some intro text."
assert_contains "$TEST_DIR/case-inject/CLAUDE.md" "## Architecture"

# --- 3. Inject is a no-op (rc=2) when already connected ---------------------
echo "==> 3. inject is no-op when imports already present"
sha_before="$(shasum -a 256 "$TEST_DIR/case-inject/CLAUDE.md" | awk '{print $1}')"
set +e
claude_md_inject_principles_block "$TEST_DIR/case-inject/CLAUDE.md"
rc=$?
set -e
assert_eq "second-inject rc (already connected)" 2 "$rc"
sha_after="$(shasum -a 256 "$TEST_DIR/case-inject/CLAUDE.md" | awk '{print $1}')"
assert_eq "second-inject sha (untouched)" "$sha_before" "$sha_after"

# --- 4. Inject completes partial legacy imports -----------------------------
echo "==> 4. inject completes partial legacy imports"
mkdir -p "$TEST_DIR/case-partial"
cat > "$TEST_DIR/case-partial/CLAUDE.md" <<'EOF'
# My Project

Some intro text.

@principles/git-workflow.md

## Existing Notes
EOF
claude_md_inject_principles_block "$TEST_DIR/case-partial/CLAUDE.md"
rc=$?
assert_eq "partial-inject rc" 0 "$rc"
assert_contains "$TEST_DIR/case-partial/CLAUDE.md" "@principles/engineering-principles.md"
assert_contains "$TEST_DIR/case-partial/CLAUDE.md" "@principles/pre-implementation-checklist.md"
assert_contains "$TEST_DIR/case-partial/CLAUDE.md" "@principles/documentation-ownership.md"
assert_contains "$TEST_DIR/case-partial/CLAUDE.md" "@principles/git-workflow.md"
git_ref_count="$(grep -cF '@principles/git-workflow.md' "$TEST_DIR/case-partial/CLAUDE.md")"
assert_eq "partial-inject does not duplicate existing ref" "1" "$git_ref_count"
assert_contains "$TEST_DIR/case-partial/CLAUDE.md" "Some intro text."
assert_contains "$TEST_DIR/case-partial/CLAUDE.md" "## Existing Notes"

# --- 5. Decision record/read round-trip -------------------------------------
echo "==> 5. .touchstone-config decision round-trip"
DEC_DIR="$TEST_DIR/case-decision"
mkdir -p "$DEC_DIR"
# Empty config: read returns "".
got="$(claude_md_principles_ref_decision "$DEC_DIR")"
assert_eq "no-config decision" "" "$got"
# Record connected, read it back.
claude_md_principles_ref_record "$DEC_DIR" connected
got="$(claude_md_principles_ref_decision "$DEC_DIR")"
assert_eq "after record connected" "connected" "$got"
# Update to skipped, read it back.
claude_md_principles_ref_record "$DEC_DIR" skipped
got="$(claude_md_principles_ref_decision "$DEC_DIR")"
assert_eq "after rewrite skipped" "skipped" "$got"
# Make sure we didn't duplicate the line.
count="$(grep -cE '^claude_principles_ref=' "$DEC_DIR/.touchstone-config")"
assert_eq "no duplicate keys" "1" "$count"

# --- end-to-end via ensure_claude_principles_ref ---------------------------
# Drive the function directly. The bin/touchstone init wrapper calls this
# same function on every init path, so this exercises the real behavior the
# user sees — without dragging in new-project.sh's interactive wizard.

setup_existing_repo() {
  local dir="$1" with_imports="${2:-no}"
  mkdir -p "$dir"
  if [ "$with_imports" = yes ]; then
    cat > "$dir/CLAUDE.md" <<'EOF'
# My Project

@principles/engineering-principles.md
@principles/pre-implementation-checklist.md
@principles/documentation-ownership.md
@principles/git-workflow.md
@principles/file-upstream-bugs.md
EOF
  elif [ "$with_imports" = partial ]; then
    cat > "$dir/CLAUDE.md" <<'EOF'
# My Project

@principles/git-workflow.md
EOF
  else
    cat > "$dir/CLAUDE.md" <<'EOF'
# My Project

Some intro text. No imports.
EOF
  fi
}

# --- 6. mode=yes injects + records connected -------------------------------
echo "==> 6. ensure_claude_principles_ref yes plants imports"
E5="$TEST_DIR/e2e-yes"
setup_existing_repo "$E5" no
ensure_claude_principles_ref "$E5" yes >/dev/null
assert_contains "$E5/CLAUDE.md" "@principles/engineering-principles.md"
assert_contains "$E5/CLAUDE.md" "@principles/pre-implementation-checklist.md"
assert_contains "$E5/.touchstone-config" "claude_principles_ref=connected"

# --- 7. partial imports are completed + records connected -------------------
echo "==> 7. ensure_claude_principles_ref completes partial imports"
E6="$TEST_DIR/e2e-partial"
setup_existing_repo "$E6" partial
ensure_claude_principles_ref "$E6" yes >/dev/null
assert_contains "$E6/CLAUDE.md" "@principles/engineering-principles.md"
assert_contains "$E6/CLAUDE.md" "@principles/pre-implementation-checklist.md"
assert_contains "$E6/CLAUDE.md" "@principles/documentation-ownership.md"
assert_contains "$E6/CLAUDE.md" "@principles/git-workflow.md"
git_ref_count="$(grep -cF '@principles/git-workflow.md' "$E6/CLAUDE.md")"
assert_eq "e2e partial does not duplicate existing ref" "1" "$git_ref_count"
assert_contains "$E6/.touchstone-config" "claude_principles_ref=connected"

# --- 8. mode=no records skipped --------------------------------------------
echo "==> 8. ensure_claude_principles_ref no records skipped"
E6="$TEST_DIR/e2e-no"
setup_existing_repo "$E6" no
ensure_claude_principles_ref "$E6" no >/dev/null
assert_not_contains "$E6/CLAUDE.md" "@principles/pre-implementation-checklist.md"
assert_contains "$E6/.touchstone-config" "claude_principles_ref=skipped"

# --- 9. prior skipped decision is respected ---------------------------------
echo "==> 9. prior skipped decision is respected"
E7="$TEST_DIR/e2e-respect"
setup_existing_repo "$E7" no
# Pre-record a "skipped" decision before the helper runs.
printf 'claude_principles_ref=skipped\n' > "$E7/.touchstone-config"
# Caller passes mode=yes, but the prior `skipped` decision wins — the user
# already opted out and the helper must not re-prompt or silently flip the
# answer.
ensure_claude_principles_ref "$E7" yes >/dev/null
assert_not_contains "$E7/CLAUDE.md" "@principles/pre-implementation-checklist.md"
assert_contains "$E7/.touchstone-config" "claude_principles_ref=skipped"

# --- 10. prior connected partial imports are completed ----------------------
echo "==> 10. prior connected partial imports are completed"
E10="$TEST_DIR/e2e-prior-connected-partial"
setup_existing_repo "$E10" partial
printf 'claude_principles_ref=connected\n' > "$E10/.touchstone-config"
ensure_claude_principles_ref "$E10" prompt >/dev/null
assert_contains "$E10/CLAUDE.md" "@principles/engineering-principles.md"
assert_contains "$E10/CLAUDE.md" "@principles/pre-implementation-checklist.md"
assert_contains "$E10/CLAUDE.md" "@principles/documentation-ownership.md"
assert_contains "$E10/CLAUDE.md" "@principles/git-workflow.md"
git_ref_count="$(grep -cF '@principles/git-workflow.md' "$E10/CLAUDE.md")"
assert_eq "prior connected partial does not duplicate existing ref" "1" "$git_ref_count"
assert_contains "$E10/.touchstone-config" "claude_principles_ref=connected"

# --- 11. existing complete imports record connected without modification ----
echo "==> 11. existing complete imports record connected without modification"
E8="$TEST_DIR/e2e-already-connected"
setup_existing_repo "$E8" yes
sha_before="$(shasum -a 256 "$E8/CLAUDE.md" | awk '{print $1}')"
ensure_claude_principles_ref "$E8" prompt >/dev/null
sha_after="$(shasum -a 256 "$E8/CLAUDE.md" | awk '{print $1}')"
assert_eq "no modification when already connected" "$sha_before" "$sha_after"
assert_contains "$E8/.touchstone-config" "claude_principles_ref=connected"

# --- 12. mode=prompt with no TTY warns and does NOT record ------------------
echo "==> 12. prompt mode in non-TTY does not record (allows later interactive)"
E9="$TEST_DIR/e2e-prompt-noniteractive"
setup_existing_repo "$E9" no
# This script's stdin is non-TTY when run as part of the test suite, so
# prompt mode should warn-and-skip without recording.
ensure_claude_principles_ref "$E9" prompt >/dev/null 2>&1
assert_not_contains "$E9/CLAUDE.md" "@principles/pre-implementation-checklist.md"
if [ -f "$E9/.touchstone-config" ] && grep -qE '^claude_principles_ref=' "$E9/.touchstone-config"; then
  fail "prompt mode in non-TTY should not record a decision (file may be re-prompted later)"
fi

# --- Done -------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: claude-md-principles-ref behaves correctly across 12 cases"
