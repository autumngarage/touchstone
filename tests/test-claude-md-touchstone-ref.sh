#!/usr/bin/env bash
#
# tests/test-claude-md-touchstone-ref.sh — verify the CLAUDE.md @TOUCHSTONE.md
# import helper and its end-to-end use through `touchstone init`.
#
# Covers:
#   1. has_touchstone_ref detection (present/absent)
#   2. inject_touchstone_ref on a CLAUDE.md without the import
#   3. inject is a no-op when @TOUCHSTONE.md is already present (returns 2)
#   4. decision record/read round-trip via .touchstone-config
#   5. end-to-end: mode=yes plants the import and records connected
#   6. end-to-end: mode=no records skipped
#   7. end-to-end: a prior skipped decision is respected
#   8. end-to-end: existing CLAUDE.md with @TOUCHSTONE.md records connected
#   9. end-to-end: prompt mode without a TTY warns but does not record
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-claude-md-touchstone.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../lib/claude-md-touchstone-ref.sh
source "$TOUCHSTONE_ROOT/lib/claude-md-touchstone-ref.sh"

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
  [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- 1. detect @TOUCHSTONE.md presence -------------------------------------
echo "==> has_touchstone_ref detects presence/absence"
present="$TEST_DIR/present.md"
absent="$TEST_DIR/absent.md"
cat >"$present" <<'EOF'
# CLAUDE.md
@TOUCHSTONE.md
EOF
cat >"$absent" <<'EOF'
# CLAUDE.md
no imports here.
EOF
claude_md_has_touchstone_ref "$present" || fail "expected has_touchstone_ref on file with import"
if claude_md_has_touchstone_ref "$absent"; then
  fail "expected NO has_touchstone_ref on file without import"
fi

# --- 2. inject on a file without the import --------------------------------
echo "==> inject_touchstone_ref plants block after H1"
target="$TEST_DIR/inject-h1.md"
cat >"$target" <<'EOF'
# CLAUDE.md — Project X

Some project content.
EOF
claude_md_inject_touchstone_ref "$target"
assert_contains "$target" "@TOUCHSTONE.md"
assert_contains "$target" "$CLAUDE_MD_TOUCHSTONE_MARKER"
# H1 stays on line 1.
first_line="$(head -n 1 "$target")"
assert_eq "h1 first line" "# CLAUDE.md — Project X" "$first_line"
# Project content survives.
assert_contains "$target" "Some project content."

# --- 3. inject is a no-op when import already present ----------------------
echo "==> inject_touchstone_ref returns 2 when already connected"
set +e
claude_md_inject_touchstone_ref "$present"
rc=$?
set -e
assert_eq "no-op rc" 2 "$rc"

# --- 4. decision record/read round-trip ------------------------------------
echo "==> decision record + read round-trip"
proj="$TEST_DIR/proj"
mkdir -p "$proj"
claude_md_touchstone_ref_record "$proj" connected
val="$(claude_md_touchstone_ref_decision "$proj")"
assert_eq "record connected" "connected" "$val"
claude_md_touchstone_ref_record "$proj" skipped
val="$(claude_md_touchstone_ref_decision "$proj")"
assert_eq "record skipped" "skipped" "$val"

# --- 5. end-to-end: mode=yes plants and records ----------------------------
echo "==> end-to-end mode=yes"
proj="$TEST_DIR/e2e-yes"
mkdir -p "$proj"
cat >"$proj/CLAUDE.md" <<'EOF'
# CLAUDE.md

Hand-written project guide. No touchstone import yet.
EOF
ensure_claude_touchstone_ref "$proj" yes >/dev/null
assert_contains "$proj/CLAUDE.md" "@TOUCHSTONE.md"
val="$(claude_md_touchstone_ref_decision "$proj")"
assert_eq "yes records connected" "connected" "$val"

# --- 6. end-to-end: mode=no records skipped --------------------------------
echo "==> end-to-end mode=no"
proj="$TEST_DIR/e2e-no"
mkdir -p "$proj"
cat >"$proj/CLAUDE.md" <<'EOF'
# CLAUDE.md
EOF
ensure_claude_touchstone_ref "$proj" no >/dev/null
assert_not_contains "$proj/CLAUDE.md" "@TOUCHSTONE.md"
val="$(claude_md_touchstone_ref_decision "$proj")"
assert_eq "no records skipped" "skipped" "$val"

# --- 7. prior skipped decision is respected --------------------------------
echo "==> prior skipped decision respected"
proj="$TEST_DIR/e2e-prior-skipped"
mkdir -p "$proj"
cat >"$proj/CLAUDE.md" <<'EOF'
# CLAUDE.md
EOF
claude_md_touchstone_ref_record "$proj" skipped
ensure_claude_touchstone_ref "$proj" yes >/dev/null
assert_not_contains "$proj/CLAUDE.md" "@TOUCHSTONE.md"

# --- 8. existing CLAUDE.md with import → records connected, no prompt -----
echo "==> existing complete import → records connected without prompt"
proj="$TEST_DIR/e2e-already"
mkdir -p "$proj"
cat >"$proj/CLAUDE.md" <<'EOF'
# CLAUDE.md
@TOUCHSTONE.md
EOF
ensure_claude_touchstone_ref "$proj" prompt >/dev/null
val="$(claude_md_touchstone_ref_decision "$proj")"
assert_eq "already-connected recorded" "connected" "$val"

# --- 9. prompt mode without TTY warns but does not record -----------------
echo "==> non-TTY prompt mode does not record"
proj="$TEST_DIR/e2e-nontty"
mkdir -p "$proj"
cat >"$proj/CLAUDE.md" <<'EOF'
# CLAUDE.md
EOF
# Run with stdin/stdout closed so the helper detects non-TTY.
(ensure_claude_touchstone_ref "$proj" prompt) </dev/null >/dev/null 2>&1 || true
val="$(claude_md_touchstone_ref_decision "$proj")"
assert_eq "non-TTY no decision recorded" "" "$val"

# --- Done ------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: claude-md-touchstone-ref helper behaves correctly across 9 cases"
