#!/usr/bin/env bash
#
# tests/test-cleanup-branches.sh — verify cleanup detects branches whose
# changes are already on the default branch via patch-id equivalence.
#
# Covers four shapes of "already applied but SHA-divergent":
#   - single-commit squash   (common with simple feature branches)
#   - multi-commit squash    (what `gh pr merge --squash` actually produces
#                             for N-commit feature branches — the case an
#                             earlier revision of this tool missed)
#   - rebase-merge           (N commits with matching patch-ids on upstream)
#
# Plus three branches that must survive cleanup:
#   - a control with genuinely unique work
#   - an add-then-revert case — the branch's patch-id still appears in
#     upstream history, but the current tree no longer has the changes, so
#     deleting would lose work. A history-based patch-id check would fail
#     this; the tree-equivalence check passes it.
#   - a rename-half case — branch renames source→dest; upstream added dest
#     independently but kept source. Rename detection on the branch's file
#     list would hide the unverified deletion of source; --no-renames
#     exposes both paths so the tree check catches the half-apply.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-cleanup.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: cleanup-branches.sh detects tree-equivalent branches"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'EOF'
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

echo "A" > a.txt
git add a.txt
git commit -qm "initial"
git push -q -u origin main

# --- (1) Single-commit squash-merged branch.
git checkout -q -b feat/single-squash
echo "S" > s.txt
git add s.txt
git commit -qm "feat: single"
git checkout -q main
git merge --squash feat/single-squash >/dev/null
git commit -qm "feat: single (#1)"

# --- (2) Multi-commit squash-merged branch (the case the earlier tool missed).
git checkout -q -b feat/multi-squash
echo "M1" > m1.txt && git add m1.txt && git commit -qm "feat: M1"
echo "M2" > m2.txt && git add m2.txt && git commit -qm "feat: M2"
echo "M3" > m3.txt && git add m3.txt && git commit -qm "feat: M3"
git checkout -q main
git merge --squash feat/multi-squash >/dev/null
git commit -qm "feat: multi (#2)"

# --- (3) Rebase-merged branch (per-commit patch-id matches on upstream).
git checkout -q -b feat/rebase-merged
echo "R1" > r1.txt && git add r1.txt && git commit -qm "feat: R1"
echo "R2" > r2.txt && git add r2.txt && git commit -qm "feat: R2"
REBASE_FIRST="$(git rev-parse HEAD~1)"
REBASE_SECOND="$(git rev-parse HEAD)"

# An unrelated commit on main before the cherry-pick guarantees the picked
# commits land on a different parent and get new SHAs. Without this, git
# reuses the original SHAs (since parent + tree + metadata are identical),
# which makes the branch ancestor-reachable and bypasses the patch-id path
# we actually want to exercise.
git checkout -q main
echo "U" > u_unrelated.txt && git add u_unrelated.txt && git commit -qm "chore: unrelated"
git cherry-pick "$REBASE_FIRST" "$REBASE_SECOND" >/dev/null

git push -q origin main

# --- (4) Control: branch with truly unique work that must be preserved.
git checkout -q -b feat/keep-me
echo "U" > u.txt
git add u.txt
git commit -qm "feat: unique work"

# --- (5) Add-then-revert: patch-id appears in upstream history, but the
# current upstream tree no longer has the branch's changes. Must survive.
git checkout -q main
git checkout -q -b feat/added-then-reverted
echo "DEL" > to_be_reverted.txt
git add to_be_reverted.txt
git commit -qm "feat: add DEL"
git checkout -q main
git merge --squash feat/added-then-reverted >/dev/null
git commit -qm "feat: add DEL (#4)"
git revert --no-edit HEAD >/dev/null

# --- (6) Rename-half: branch renames source→dest; main adds dest
# independently but does not delete source. The branch's deletion of
# source is not on main — must survive.
echo "O" > source_to_rename.txt
git add source_to_rename.txt
git commit -qm "chore: seed source file for rename test"

git checkout -q -b feat/rename-half
git mv source_to_rename.txt dest_after_rename.txt
git commit -qm "feat: rename source to dest"

git checkout -q main
echo "O" > dest_after_rename.txt
git add dest_after_rename.txt
git commit -qm "chore: add dest (source left in place)"
git push -q origin main

git checkout -q main

OUTPUT="$TEST_DIR/output.txt"
PATH="$FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --execute >"$OUTPUT" 2>&1

fail() {
  echo "FAIL: $1" >&2
  echo "---- script output ----" >&2
  cat "$OUTPUT" >&2
  exit 1
}

for deleted in feat/single-squash feat/multi-squash feat/rebase-merged; do
  if git rev-parse --verify --quiet "refs/heads/$deleted" >/dev/null; then
    fail "$deleted should have been force-deleted"
  fi
  if ! grep -q "force-deleted local (squash-merged): $deleted" "$OUTPUT"; then
    fail "execute log should report force-deletion of $deleted"
  fi
done

for preserved in feat/keep-me feat/added-then-reverted feat/rename-half; do
  if ! git rev-parse --verify --quiet "refs/heads/$preserved" >/dev/null; then
    fail "$preserved should have been preserved"
  fi
  if grep -q "force-deleted local (squash-merged): $preserved" "$OUTPUT"; then
    fail "$preserved was incorrectly classified as squash-merged and force-deleted"
  fi
done

if ! grep -q "Squash-merged into main" "$OUTPUT"; then
  fail "output should list the tree-equivalent branches under 'Squash-merged into main'"
fi

if ! grep -q "Has unique commits" "$OUTPUT"; then
  fail "unmerged branches should be classified under 'Has unique commits'"
fi

# --help output must include every safety bullet (regression guard for the
# earlier hardcoded sed range that silently truncated as the header grew).
HELP="$TEST_DIR/help.txt"
PATH="$FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --help >"$HELP" 2>&1
for required in "Default mode is DRY RUN" "Ancestor-merged" "Squash-merged" "Worktree-checked-out"; do
  if ! grep -q "$required" "$HELP"; then
    echo "FAIL: --help output missing '$required'" >&2
    echo "---- help output ----" >&2
    cat "$HELP" >&2
    exit 1
  fi
done

echo "==> PASS: squash, multi-squash, and rebase-merged branches force-deleted;"
echo "         unique, add-then-reverted, and rename-half branches preserved;"
echo "         --help covers full safety block"
