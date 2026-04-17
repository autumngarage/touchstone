#!/usr/bin/env bash
#
# tests/test-migrate.sh — verify `touchstone migrate-from-toolkit` renames
# legacy .toolkit-* dotfiles to .touchstone-* equivalents and commits the
# result.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-migrate.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

make_project() {
  local project_dir="$1"
  mkdir -p "$project_dir"
  (
    cd "$project_dir"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "placeholder" > README.md
    git add README.md
    git commit -q -m "initial"
  )
}

write_legacy_state() {
  local project_dir="$1"
  (
    cd "$project_dir"
    printf 'abc123\n' > .toolkit-version
    cat > .toolkit-manifest <<'EOF'
# Managed by toolkit. These paths may be updated by `toolkit update`.
.toolkit-manifest
.toolkit-version
scripts/toolkit-run.sh
EOF
    printf 'project_type=python\n' > .toolkit-config
    git add .toolkit-version .toolkit-manifest .toolkit-config
    git commit -q -m "add legacy toolkit files"
  )
}

run_migrate() {
  local project_dir="$1"
  (
    cd "$project_dir"
    TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" migrate-from-toolkit
  )
}

# ------------------------------------------------------------------
# Test 1: happy path — all three legacy files get renamed + committed
# ------------------------------------------------------------------
echo "==> Test 1: migrates legacy files and commits"

PROJECT_DIR="$TEST_DIR/project1"
make_project "$PROJECT_DIR"
write_legacy_state "$PROJECT_DIR"
run_migrate "$PROJECT_DIR" >/dev/null

for f in .touchstone-version .touchstone-manifest .touchstone-config; do
  [ -f "$PROJECT_DIR/$f" ] || fail "$f should exist after migrate"
done
for f in .toolkit-version .toolkit-manifest .toolkit-config; do
  [ ! -f "$PROJECT_DIR/$f" ] || fail "$f should be gone after migrate"
done

if ! grep -q '\.touchstone-version' "$PROJECT_DIR/.touchstone-manifest" \
  || ! grep -q 'touchstone-run.sh' "$PROJECT_DIR/.touchstone-manifest"; then
  fail "manifest path references should be rewritten"
fi
if grep -qE '\.toolkit-|toolkit-run\.sh' "$PROJECT_DIR/.touchstone-manifest"; then
  fail "manifest should not contain any toolkit-* references"
fi

HEAD_MSG="$(git -C "$PROJECT_DIR" log -1 --format=%s)"
if [ "$HEAD_MSG" != "chore: migrate from toolkit to touchstone" ]; then
  fail "expected migration commit on HEAD, got: $HEAD_MSG"
fi

if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
  fail "working tree should be clean after migrate"
fi

# ------------------------------------------------------------------
# Test 2: idempotent — running on already-migrated repo is a no-op
# ------------------------------------------------------------------
echo "==> Test 2: no-op when no legacy files exist"

run_migrate "$PROJECT_DIR" >/dev/null

# Should still only have the one migration commit (no new commit created).
COMMIT_COUNT_AFTER="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
if [ "$COMMIT_COUNT_AFTER" != "3" ]; then
  fail "expected 3 commits (initial + legacy + migrate), got $COMMIT_COUNT_AFTER"
fi

# ------------------------------------------------------------------
# Test 3: refuses to run with dirty tree
# ------------------------------------------------------------------
echo "==> Test 3: refuses when working tree is dirty"

PROJECT_DIR2="$TEST_DIR/project2"
make_project "$PROJECT_DIR2"
write_legacy_state "$PROJECT_DIR2"
echo "dirty" > "$PROJECT_DIR2/uncommitted.txt"

set +e
run_migrate "$PROJECT_DIR2" 2>/dev/null
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  fail "expected non-zero exit when tree is dirty"
fi
if [ ! -f "$PROJECT_DIR2/.toolkit-version" ]; then
  fail ".toolkit-version should still exist (no rename on dirty refusal)"
fi

# ------------------------------------------------------------------
# Test 4: conflict — both .toolkit-* and .touchstone-* present is rejected
# ------------------------------------------------------------------
echo "==> Test 4: refuses when both legacy and new files coexist"

PROJECT_DIR3="$TEST_DIR/project3"
make_project "$PROJECT_DIR3"
(
  cd "$PROJECT_DIR3"
  printf 'legacy\n' > .toolkit-version
  printf 'newer\n'  > .touchstone-version
  git add .toolkit-version .touchstone-version
  git commit -q -m "conflicting state"
)

set +e
run_migrate "$PROJECT_DIR3" 2>/dev/null
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  fail "expected non-zero exit when both versions exist"
fi

# ------------------------------------------------------------------
# Test 5: `touchstone update` directs user to migrate when legacy detected
# ------------------------------------------------------------------
echo "==> Test 5: update prints migration hint for legacy projects"

PROJECT_DIR4="$TEST_DIR/project4"
make_project "$PROJECT_DIR4"
write_legacy_state "$PROJECT_DIR4"

set +e
UPDATE_OUT="$(cd "$PROJECT_DIR4" && TOUCHSTONE_NO_AUTO_UPDATE=1 \
  "$TOUCHSTONE_ROOT/bin/touchstone" update 2>&1)"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  fail "expected update to fail on legacy project"
fi
if ! grep -q 'migrate-from-toolkit' <<< "$UPDATE_OUT"; then
  fail "expected update error to mention 'migrate-from-toolkit', got:\n$UPDATE_OUT"
fi

# ------------------------------------------------------------------
if [ "$ERRORS" -eq 0 ]; then
  echo ""
  echo "==> PASS: all migrate assertions passed"
  exit 0
else
  echo ""
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
