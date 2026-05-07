#!/usr/bin/env bash
#
# tests/test-cleanup-branches-squash-map.sh — regression test for issue #165.
#
# Scenario: a branch's PR was squash-merged some time ago. Since then, main
# picked up another commit that touched the same file. The branch's content
# is no longer byte-identical to main on every file it changed, so the
# tree-equivalence heuristic (is_fully_applied) flips to "unique commits"
# and the branch is stuck in the "needs human decision" bucket forever.
#
# The fix: scripts/merge-pr.sh records a squash-map entry at merge time
# capturing the branch tip. scripts/cleanup-branches.sh consults the map
# first, classifying as squash-merged when (branch, oid) match — letting
# the existing `is_fully_applied` path remain the safety net for branches
# whose tip moved past the recorded oid (no false positives).
#
# Two cases:
#   (1) Branch with a squash-map record AND main moved on — must be
#       force-deleted (the regression).
#   (2) Branch with a squash-map record but the local tip has moved past
#       the recorded oid — must NOT be force-deleted via the map; falls
#       through to is_fully_applied, which correctly preserves it.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-cleanup-squash-map.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: cleanup-branches.sh consults squash-map for squash-merged-then-moved-past branches"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
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

echo "A" >shared.txt
git add shared.txt
git commit -qm "initial"
git push -q -u origin main

# (1) Squash-merged branch whose changes were applied to main, then main
# evolved past it: another commit on main edits the SAME file. The branch's
# content is no longer byte-identical to main, so is_fully_applied returns
# false. Without the squash-map record, this branch would land in the
# "needs human decision" bucket and stay there forever — the issue.
git checkout -q -b feat/squash-then-moved-past
echo "BRANCH_CONTENT" >shared.txt
git add shared.txt
git commit -qm "feat: change shared.txt"
RECORDED_OID="$(git rev-parse HEAD)"

git checkout -q main
git merge --squash feat/squash-then-moved-past >/dev/null
git commit -qm "feat: change shared.txt (#100)"

# Main moves on — another commit edits the same file. This is what breaks
# the tree-equivalence check on feat/squash-then-moved-past.
echo "EVOLVED_PAST_BRANCH" >shared.txt
git add shared.txt
git commit -qm "chore: further edits"

# (2) Branch where the squash-map record exists but the local branch picked
# up new commits AFTER the squash. The recorded oid is stale; the OID
# equality check must reject the map record and let is_fully_applied take
# over (which will correctly classify this branch as not-yet-applied).
git checkout -q -b feat/squash-then-new-commits-locally
echo "INITIAL_WORK" >new_file.txt
git add new_file.txt
git commit -qm "feat: initial work"
STALE_RECORDED_OID="$(git rev-parse HEAD)"

git checkout -q main
git merge --squash feat/squash-then-new-commits-locally >/dev/null
git commit -qm "feat: initial work (#101)"

# Main moves on, breaking tree equivalence for this branch too.
echo "DRIFT" >new_file.txt
git add new_file.txt
git commit -qm "chore: drift"

git checkout -q feat/squash-then-new-commits-locally
echo "POST_MERGE_LOCAL_WORK" >local_only.txt
git add local_only.txt
git commit -qm "feat: post-merge local work (not yet on main)"

git push -q origin main

# (3) Control: branch with no squash-map record and genuinely unique work
# — must survive both classifiers and land in "Has unique commits".
git checkout -q main
git checkout -q -b feat/keep-me-unrelated
echo "UNIQUE" >unique.txt
git add unique.txt
git commit -qm "feat: unique work no record"

git checkout -q main

# Build the synthetic squash-map at the right git-path. Use git rev-parse
# from the repo so worktree-aware path resolution matches what the script
# does at runtime.
MAP_PATH="$(git rev-parse --git-path touchstone/squash-map.jsonl)"
mkdir -p "$(dirname "$MAP_PATH")"
cat >"$MAP_PATH" <<EOF
{"branch":"feat/squash-then-moved-past","pr":"100","branch_oid":"$RECORDED_OID","squash_commit":"deadbeef","ts":"2026-05-06T00:00:00Z"}
{"branch":"feat/squash-then-new-commits-locally","pr":"101","branch_oid":"$STALE_RECORDED_OID","squash_commit":"deadbee2","ts":"2026-05-06T00:01:00Z"}
EOF

OUTPUT="$TEST_DIR/output.txt"
PATH="$FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --execute >"$OUTPUT" 2>&1

fail() {
  echo "FAIL: $1" >&2
  echo "---- script output ----" >&2
  cat "$OUTPUT" >&2
  echo "---- squash-map ----" >&2
  cat "$MAP_PATH" >&2 || true
  exit 1
}

# (1) Must be deleted via the squash-map path — this is the regression.
if git rev-parse --verify --quiet refs/heads/feat/squash-then-moved-past >/dev/null; then
  fail "feat/squash-then-moved-past should have been force-deleted via squash-map"
fi
if ! grep -q "force-deleted local (squash-merged): feat/squash-then-moved-past" "$OUTPUT"; then
  fail "execute log should report force-deletion of feat/squash-then-moved-past"
fi

# (2) Must be preserved — the local branch tip moved past the recorded oid,
# so the squash-map record does not apply, and is_fully_applied correctly
# refuses (the post-merge local commit is not on main).
if ! git rev-parse --verify --quiet refs/heads/feat/squash-then-new-commits-locally >/dev/null; then
  fail "feat/squash-then-new-commits-locally should NOT have been deleted (tip moved past recorded oid)"
fi
if grep -q "force-deleted local (squash-merged): feat/squash-then-new-commits-locally" "$OUTPUT"; then
  fail "feat/squash-then-new-commits-locally was incorrectly classified as squash-merged"
fi

# (3) Must be preserved as "Has unique commits".
if ! git rev-parse --verify --quiet refs/heads/feat/keep-me-unrelated >/dev/null; then
  fail "feat/keep-me-unrelated should have been preserved"
fi
if ! grep -q "Has unique commits" "$OUTPUT"; then
  fail "output should still classify unique-work branches under 'Has unique commits'"
fi

# Negative tests against the map reader: a missing map and a corrupt map
# must both be treated as "no record" without breaking the run.
echo "==> Sub-test: missing squash-map is fail-soft"
rm -f "$MAP_PATH"
git checkout -q -b feat/no-map-still-classified
echo "X" >x.txt
git add x.txt
git commit -qm "feat: x"
git checkout -q main
git merge --squash feat/no-map-still-classified >/dev/null
git commit -qm "feat: x (#102)"
git push -q origin main

OUT2="$TEST_DIR/output-no-map.txt"
PATH="$FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --execute >"$OUT2" 2>&1 \
  || {
    echo "FAIL: cleanup must not fail when squash-map is missing"
    cat "$OUT2" >&2
    exit 1
  }
# This branch should still be classified by the existing tree-equivalence
# fallback (tree on main matches branch's changed files since main hasn't
# moved past it on this file).
if git rev-parse --verify --quiet refs/heads/feat/no-map-still-classified >/dev/null; then
  fail "feat/no-map-still-classified should be force-deleted by the tree-equivalence fallback"
fi

echo "==> Sub-test: corrupt squash-map is fail-soft (no records)"
mkdir -p "$(dirname "$MAP_PATH")"
printf '{not valid json at all\nsecond garbage line\n' >"$MAP_PATH"
git checkout -q main
git checkout -q -b feat/corrupt-map-leaves-unique
echo "Y" >y_unique.txt
git add y_unique.txt
git commit -qm "feat: y (still has unique work)"
OUT3="$TEST_DIR/output-corrupt-map.txt"
git checkout -q main
PATH="$FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --execute >"$OUT3" 2>&1 \
  || {
    echo "FAIL: cleanup must not fail on corrupt squash-map"
    cat "$OUT3" >&2
    exit 1
  }
if ! git rev-parse --verify --quiet refs/heads/feat/corrupt-map-leaves-unique >/dev/null; then
  fail "feat/corrupt-map-leaves-unique should NOT be deleted; corrupt map must yield no records"
fi

echo "==> PASS: squash-map record force-deletes squash-merged-then-moved-past;"
echo "         stale-oid records fall through to tree check (no false positive);"
echo "         missing map and corrupt map are fail-soft"
