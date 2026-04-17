#!/usr/bin/env bash
#
# tests/test-cleanup-branches.sh — verify cleanup detects squash-merged
# branches (commits not ancestors of main, but patch-ids applied).
#
# This is the common shape of branches left behind by
# `scripts/open-pr.sh --auto-merge`. Ancestor-only detection would miss them
# and leave the user with stale branches to clean up manually.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-cleanup.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: cleanup-branches.sh detects squash-merged branches"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Minimal gh stub: resolve default branch; never reached for pr list in this test.
case "$*" in
  "repo view --json defaultBranchRef --jq .defaultBranchRef.name")
    echo "main"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

REMOTE="$TEST_DIR/remote.git"
REPO="$TEST_DIR/repo"

git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "Test"
git remote add origin "$REMOTE"

echo "A" > a.txt
git add a.txt
git commit -qm "initial"
git push -q -u origin main

# Feature branch with a single commit — the kind open-pr.sh --auto-merge would squash.
git checkout -q -b feat/squash-me
echo "B" > b.txt
git add b.txt
git commit -qm "feat: add B"

# Simulate the squash-merge on main: identical tree change, new commit.
git checkout -q main
git merge --squash feat/squash-me >/dev/null
git commit -qm "feat: add B (#1)"
git push -q origin main

# Also create a branch with genuinely unique unmerged work — must survive cleanup.
git checkout -q -b feat/keep-me
echo "C" > c.txt
git add c.txt
git commit -qm "feat: unique work"

git checkout -q main

OUTPUT="$TEST_DIR/output.txt"
PATH="$FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --execute >"$OUTPUT" 2>&1

if git rev-parse --verify --quiet refs/heads/feat/squash-me >/dev/null; then
  echo "FAIL: feat/squash-me should have been force-deleted" >&2
  cat "$OUTPUT" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet refs/heads/feat/keep-me >/dev/null; then
  echo "FAIL: feat/keep-me should have been preserved" >&2
  cat "$OUTPUT" >&2
  exit 1
fi

if ! grep -q "Squash-merged into main" "$OUTPUT"; then
  echo "FAIL: output should list feat/squash-me under 'Squash-merged into main'" >&2
  cat "$OUTPUT" >&2
  exit 1
fi

if ! grep -q "force-deleted local (squash-merged): feat/squash-me" "$OUTPUT"; then
  echo "FAIL: execute log should report force-deletion of feat/squash-me" >&2
  cat "$OUTPUT" >&2
  exit 1
fi

if ! grep -q "feat/keep-me" "$OUTPUT" || ! grep -q "Has unique commits" "$OUTPUT"; then
  echo "FAIL: feat/keep-me should be classified as 'Has unique commits'" >&2
  cat "$OUTPUT" >&2
  exit 1
fi

echo "==> PASS: squash-merged branch detected and force-deleted; unmerged work preserved"
