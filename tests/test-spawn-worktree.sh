#!/usr/bin/env bash
#
# tests/test-spawn-worktree.sh — verify spawn-worktree creates isolated
# branches and copies only explicitly allowlisted ignored local files.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-spawn-worktree.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: spawn-worktree.sh creates branch worktrees with local includes"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_exists() {
  [ -e "$1" ] || fail "expected $1 to exist"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected $1 to NOT exist"
}

assert_contains() {
  grep -q "$2" "$1" 2>/dev/null || fail "expected $1 to contain '$2'"
}

REMOTE="$TEST_DIR/remote.git"
REPO="$TEST_DIR/demo"
WORKTREE="$TEST_DIR/demo-slice"
DEFAULT_WORKTREE="$TEST_DIR/demo-default-path"

git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$REMOTE"

echo "tracked" > "$REPO/tracked.txt"
cat > "$REPO/.gitignore" <<'EOF'
.env.test
local/*.json
node_modules/
EOF
git -C "$REPO" add tracked.txt .gitignore
git -C "$REPO" commit -qm "initial"
git -C "$REPO" push -q -u origin main
git -C "$REPO" remote set-head origin main

printf 'TOKEN=fake\n' > "$REPO/.env.test"
mkdir -p "$REPO/local" "$REPO/local/secrets" "$REPO/node_modules/pkg"
printf '{"debug":true}\n' > "$REPO/local/dev.json"
printf '{"prod":true}\n' > "$REPO/local/secrets/prod.json"
printf 'cached\n' > "$REPO/node_modules/pkg/cache.txt"
printf 'not ignored\n' > "$REPO/not-ignored.txt"
cat > "$REPO/.worktreeinclude" <<'EOF'
# explicit local test config
.env.test
local/*.json
not-ignored.txt
node_modules/
EOF

OUTPUT="$TEST_DIR/spawn-output.txt"
(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" feat/local-slice "$WORKTREE") >"$OUTPUT" 2>&1

assert_exists "$WORKTREE/.git"
assert_exists "$WORKTREE/tracked.txt"
assert_exists "$WORKTREE/.env.test"
assert_exists "$WORKTREE/local/dev.json"
assert_exists "$WORKTREE/node_modules/pkg/cache.txt"
assert_not_exists "$WORKTREE/not-ignored.txt"
assert_not_exists "$WORKTREE/local/secrets/prod.json"
assert_contains "$OUTPUT" 'branch: feat/local-slice'
assert_contains "$OUTPUT" 'copied: .env.test'
assert_contains "$OUTPUT" 'copied: local/dev.json'

BRANCH="$(git -C "$WORKTREE" branch --show-current)"
[ "$BRANCH" = "feat/local-slice" ] || fail "expected spawned branch feat/local-slice, got $BRANCH"

if (cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" invalid "$TEST_DIR/bad") >"$TEST_DIR/invalid-output.txt" 2>&1; then
  fail "invalid branch shape should fail"
fi
assert_contains "$TEST_DIR/invalid-output.txt" 'branch must follow <type>/<slug>'

if (cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" feat/exists "$WORKTREE") >"$TEST_DIR/exists-output.txt" 2>&1; then
  fail "existing worktree path should fail"
fi
assert_contains "$TEST_DIR/exists-output.txt" 'worktree path already exists'

(cd "$REPO" && bash "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" feat/default-path "$DEFAULT_WORKTREE") >/dev/null 2>&1
assert_exists "$DEFAULT_WORKTREE/.git"
[ "$(git -C "$DEFAULT_WORKTREE" branch --show-current)" = "feat/default-path" ] || fail "default-path branch not created"

echo "==> PASS: spawn-worktree creates isolated branches and copies allowlisted ignored files"
