#!/usr/bin/env bash
#
# tests/test-update.sh — verify update-project.sh handles updates correctly.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t toolkit-test-update.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: update an existing project"
echo "    Test dir: $TEST_DIR/test-project"

ERRORS=0

assert_exists() {
  if [ ! -e "$1" ]; then
    echo "FAIL: expected $1 to exist" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_exists() {
  if [ -e "$1" ]; then
    echo "FAIL: expected $1 to NOT exist" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

PROJECT="$TEST_DIR/test-project"

# --------------------------------------------------------------------------
# Setup: bootstrap a project
# --------------------------------------------------------------------------
echo ""
echo "--- Step 1: Bootstrap ---"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$PROJECT" --no-register

# Record the initial toolkit version.
INITIAL_SHA="$(cat "$PROJECT/.toolkit-version" | tr -d '[:space:]')"
echo "    Initial .toolkit-version: $INITIAL_SHA"

# --------------------------------------------------------------------------
# Test 1: update with no toolkit changes → "already up to date"
# --------------------------------------------------------------------------
echo ""
echo "--- Step 2: Update with no changes (should report up to date) ---"
(cd "$PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-1.txt"

if grep -q "Already up to date" "$TEST_DIR/update-output-1.txt"; then
  echo "    PASS: correctly reported up to date"
else
  echo "    FAIL: did not report up to date" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 2: modify a toolkit-owned file, then update → .bak created
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3: Modify a toolkit-owned file, then update ---"

# Simulate local modification to a toolkit-owned file.
echo "# locally modified" >> "$PROJECT/principles/engineering-principles.md"
rm "$PROJECT/scripts/run-pytest-in-venv.sh"

# Fake a new toolkit version by writing a different SHA so update thinks
# there's something new. We write a fake old SHA to .toolkit-version.
echo "0000000000000000000000000000000000000000" > "$PROJECT/.toolkit-version"

(cd "$PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-2.txt"

# Verify .bak was created.
assert_exists "$PROJECT/principles/engineering-principles.md.bak"
assert_exists "$PROJECT/scripts/run-pytest-in-venv.sh"

# Verify the current file matches the toolkit version (not the modified one).
if diff -q "$TOOLKIT_ROOT/principles/engineering-principles.md" "$PROJECT/principles/engineering-principles.md" >/dev/null 2>&1; then
  echo "    PASS: file was updated to toolkit version"
else
  echo "    FAIL: file does not match toolkit version" >&2
  ERRORS=$((ERRORS + 1))
fi

# Verify .bak contains the modification.
if grep -q "locally modified" "$PROJECT/principles/engineering-principles.md.bak"; then
  echo "    PASS: .bak contains the local modification"
else
  echo "    FAIL: .bak does not contain the local modification" >&2
  ERRORS=$((ERRORS + 1))
fi

# Modify the same toolkit-owned file again. The second backup must not clobber
# the first .bak from the earlier update.
echo "# locally modified again" >> "$PROJECT/principles/engineering-principles.md"
echo "0000000000000000000000000000000000000002" > "$PROJECT/.toolkit-version"
(cd "$PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-3.txt"

assert_exists "$PROJECT/principles/engineering-principles.md.bak.1"

if grep -q "locally modified" "$PROJECT/principles/engineering-principles.md.bak" \
  && grep -q "locally modified again" "$PROJECT/principles/engineering-principles.md.bak.1"; then
  echo "    PASS: repeated updates preserve existing .bak files"
else
  echo "    FAIL: repeated update clobbered or missed backup content" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 3: project-owned files are NOT touched
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4: Verify project-owned files are untouched ---"

# Modify CLAUDE.md (project-owned).
echo "# my project context" >> "$PROJECT/CLAUDE.md"
CLAUDE_CHECKSUM="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"

# Re-fake the version and run update again.
echo "0000000000000000000000000000000000000001" > "$PROJECT/.toolkit-version"
(cd "$PROJECT" && bash "$TOOLKIT_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

CLAUDE_CHECKSUM_AFTER="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"

if [ "$CLAUDE_CHECKSUM" = "$CLAUDE_CHECKSUM_AFTER" ]; then
  echo "    PASS: CLAUDE.md was not modified by update"
else
  echo "    FAIL: CLAUDE.md was modified by update" >&2
  ERRORS=$((ERRORS + 1))
fi

# Verify no .bak for CLAUDE.md.
assert_not_exists "$PROJECT/CLAUDE.md.bak"

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all assertions passed"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
