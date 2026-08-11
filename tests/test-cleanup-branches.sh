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

echo "A" >a.txt
git add a.txt
git commit -qm "initial"
git push -q -u origin main

# --- (1) Single-commit squash-merged branch.
git checkout -q -b feat/single-squash
echo "S" >s.txt
git add s.txt
git commit -qm "feat: single"
git checkout -q main
git merge --squash feat/single-squash >/dev/null
git commit -qm "feat: single (#1)"

# --- (2) Multi-commit squash-merged branch (the case the earlier tool missed).
git checkout -q -b feat/multi-squash
echo "M1" >m1.txt && git add m1.txt && git commit -qm "feat: M1"
echo "M2" >m2.txt && git add m2.txt && git commit -qm "feat: M2"
echo "M3" >m3.txt && git add m3.txt && git commit -qm "feat: M3"
git checkout -q main
git merge --squash feat/multi-squash >/dev/null
git commit -qm "feat: multi (#2)"

# --- (3) Rebase-merged branch (per-commit patch-id matches on upstream).
git checkout -q -b feat/rebase-merged
echo "R1" >r1.txt && git add r1.txt && git commit -qm "feat: R1"
echo "R2" >r2.txt && git add r2.txt && git commit -qm "feat: R2"
REBASE_FIRST="$(git rev-parse HEAD~1)"
REBASE_SECOND="$(git rev-parse HEAD)"

# An unrelated commit on main before the cherry-pick guarantees the picked
# commits land on a different parent and get new SHAs. Without this, git
# reuses the original SHAs (since parent + tree + metadata are identical),
# which makes the branch ancestor-reachable and bypasses the patch-id path
# we actually want to exercise.
git checkout -q main
echo "U" >u_unrelated.txt && git add u_unrelated.txt && git commit -qm "chore: unrelated"
git cherry-pick "$REBASE_FIRST" "$REBASE_SECOND" >/dev/null

git push -q origin main

# --- (4) Control: branch with truly unique work that must be preserved.
git checkout -q -b feat/keep-me
echo "U" >u.txt
git add u.txt
git commit -qm "feat: unique work"

# --- (5) Add-then-revert: patch-id appears in upstream history, but the
# current upstream tree no longer has the branch's changes. Must survive.
git checkout -q main
git checkout -q -b feat/added-then-reverted
echo "DEL" >to_be_reverted.txt
git add to_be_reverted.txt
git commit -qm "feat: add DEL"
git checkout -q main
git merge --squash feat/added-then-reverted >/dev/null
git commit -qm "feat: add DEL (#4)"
git revert --no-edit HEAD >/dev/null

# --- (6) Rename-half: branch renames source→dest; main adds dest
# independently but does not delete source. The branch's deletion of
# source is not on main — must survive.
echo "O" >source_to_rename.txt
git add source_to_rename.txt
git commit -qm "chore: seed source file for rename test"

git checkout -q -b feat/rename-half
git mv source_to_rename.txt dest_after_rename.txt
git commit -qm "feat: rename source to dest"

git checkout -q main
echo "O" >dest_after_rename.txt
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

# --- Fail-closed: when `gh pr list` errors, --remote-too must skip remote
# cleanup rather than treat the error as "no open PRs" and delete branches.
FAIL_BIN="$TEST_DIR/fail-bin"
mkdir -p "$FAIL_BIN"
cat >"$FAIL_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "repo view --json defaultBranchRef --jq .defaultBranchRef.name")
    echo "main"
    ;;
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "fake/repo"
    ;;
  "pr list --state open --limit 200 --json headRefName --jq .[].headRefName")
    echo "gh: simulated network failure" >&2
    exit 4
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAIL_BIN/gh"

FAIL_OUTPUT="$TEST_DIR/fail-output.txt"
PATH="$FAIL_BIN:$PATH" bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --remote-too --execute >"$FAIL_OUTPUT" 2>&1

if ! grep -q "'gh pr list' failed" "$FAIL_OUTPUT"; then
  echo "FAIL: remote cleanup should fail-closed with a visible error" >&2
  cat "$FAIL_OUTPUT" >&2
  exit 1
fi

if grep -q "deleted remote" "$FAIL_OUTPUT"; then
  echo "FAIL: remote cleanup must not delete anything when gh pr list fails" >&2
  cat "$FAIL_OUTPUT" >&2
  exit 1
fi

# --- Post-lease verification is ONE inspection request, and never
# manufactures a definite answer from a degenerate reply (PR #715 review).
# Scenario: the remote branch advanced after classification, so the leased
# delete is rejected. The single ls-remote reply reports the advanced OID.
# The earlier two-call shape asked once for existence and AGAIN for the OID;
# a transient empty second reply produced current_oid="" which was misread
# as "still at its classified OID" — a definite answer the remote never gave.
echo "==> Test: post-lease verification uses one ls-remote and reports the advance"

git checkout -q main
git push -q origin main:refs/heads/feat/remote-advanced

VERIFY_BIN="$TEST_DIR/verify-bin"
mkdir -p "$VERIFY_BIN"
cat >"$VERIFY_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "repo view --json defaultBranchRef --jq .defaultBranchRef.name")
    echo "main"
    ;;
  "pr list --state open --limit 200 --json number --jq length")
    echo "0"
    ;;
  "pr list --state open --limit 200 --json headRefName,baseRefName "*)
    :
    ;;
  "pr list --state open --base "*)
    :
    ;;
  "pr list --state open --head "*)
    :
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$VERIFY_BIN/gh"

# git wrapper: reject the leased delete (the branch "moved"), answer the FIRST
# ls-remote with the advanced OID, and answer any LATER ls-remote with a
# degenerate success — exit 0, no payload — the transient shape that the old
# two-call verification misread as "still at its classified OID".
REAL_GIT="$(command -v git)"
cat >"$VERIFY_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "push" ]; then
  case " \$* " in
    *" --force-with-lease="*)
      echo "remote rejected (stale info)" >&2
      exit 1
      ;;
  esac
fi
if [ "\${1:-}" = "ls-remote" ]; then
  n=0
  [ -f "\${LS_REMOTE_COUNT_FILE:?}" ] && n="\$(cat "\$LS_REMOTE_COUNT_FILE")"
  n=\$((n + 1))
  printf '%s\n' "\$n" >"\$LS_REMOTE_COUNT_FILE"
  if [ "\$n" -eq 1 ]; then
    printf '%s\trefs/heads/%s\n' "\${LS_REMOTE_ADVANCED_OID:?}" "feat/remote-advanced"
  fi
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$VERIFY_BIN/git"

VERIFY_OUT="$TEST_DIR/verify-output.txt"
rm -f "$TEST_DIR/ls-remote-count"
PATH="$VERIFY_BIN:$PATH" \
  LS_REMOTE_COUNT_FILE="$TEST_DIR/ls-remote-count" \
  LS_REMOTE_ADVANCED_OID="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  bash "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" --remote-too --execute \
  >"$VERIFY_OUT" 2>&1

verify_fail() {
  echo "FAIL: $1" >&2
  echo "---- verification script output ----" >&2
  cat "$VERIFY_OUT" >&2
  exit 1
}

if ! grep -q "advanced to deadbeefdead" "$VERIFY_OUT"; then
  verify_fail "a rejected delete on an advanced branch must report the advance it saw"
fi
if grep -q "still at its classified OID" "$VERIFY_OUT"; then
  verify_fail "verification claimed 'still at classified OID' — a definite answer the remote reply did not support"
fi
if [ "$(cat "$TEST_DIR/ls-remote-count")" != "1" ]; then
  verify_fail "verification must be a single ls-remote request (saw $(cat "$TEST_DIR/ls-remote-count"))"
fi
if ! git ls-remote --exit-code origin refs/heads/feat/remote-advanced >/dev/null 2>&1; then
  verify_fail "the advanced remote branch must survive the rejected delete"
fi

echo "==> PASS: squash, multi-squash, and rebase-merged branches force-deleted;"
echo "         unique, add-then-reverted, and rename-half branches preserved;"
echo "         --help covers full safety block;"
echo "         remote cleanup fails closed when gh pr list errors;"
echo "         post-lease verification is one request and reports the advance"
