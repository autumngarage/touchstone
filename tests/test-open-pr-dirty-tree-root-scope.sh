#!/usr/bin/env bash
#
# tests/test-open-pr-dirty-tree-root-scope.sh — Issue #402.
#
# open-pr.sh must compute dirty-tree state from REPO_ROOT even when launched
# from a nested directory. In particular, root-level untracked files must be
# surfaced in the warning with root-relative paths.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-dirty-root.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

REPO_DIR="$TEST_DIR/repo"
REMOTE_DIR="$TEST_DIR/remote.git"
SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh"

# Mock gh — open-pr.sh only needs default branch, existing-PR probe, and create.
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "repo view") echo "main" ;;
  "pr list") echo "" ;;
  "pr create") echo "https://example.test/touchstone/pull/402" ;;
  "pr view") echo "" ;;
  "api user") echo "alice" ;;
  "issue view")
    if [ "$5" = "state" ]; then
      echo "OPEN"
    elif [ "$5" = "assignees" ]; then
      echo "alice"
    else
      echo "unexpected gh issue view args: $*" >&2
      exit 1
    fi
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

git init --bare "$REMOTE_DIR" >/dev/null 2>&1
git clone "$REMOTE_DIR" "$REPO_DIR" >/dev/null 2>&1
git -C "$REPO_DIR" switch -c main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"

mkdir -p "$REPO_DIR/sub/dir"
printf 'base\n' >"$REPO_DIR/file.txt"
printf 'nested\n' >"$REPO_DIR/sub/dir/nested.txt"
git -C "$REPO_DIR" add file.txt sub/dir/nested.txt
git -C "$REPO_DIR" commit -m "base" >/dev/null 2>&1
git -C "$REPO_DIR" push -u origin main >/dev/null 2>&1

git -C "$REPO_DIR" switch -c feat/dirty-root-scope >/dev/null 2>&1
printf 'feature\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "feature change" >/dev/null 2>&1

# Repro setup for issue #402: launch from nested dir, with an untracked file
# at repo root (outside current directory).
printf 'untracked\n' >"$REPO_DIR/root-untracked.txt"

echo "==> Running open-pr.sh from nested directory with root-level untracked file"
OUT="$TEST_DIR/run.out"
RC=0
(
  cd "$REPO_DIR/sub/dir"
  printf 'y\n' | PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPT_DIR/open-pr.sh" "test PR"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
  echo "FAIL: open-pr.sh exited $RC; expected 0" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q 'WARNING: working tree has uncommitted changes' "$OUT"; then
  echo "FAIL: expected dirty-tree warning" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q 'Untracked files detected:' "$OUT"; then
  echo "FAIL: expected untracked-files section" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q 'root-untracked.txt' "$OUT"; then
  echo "FAIL: expected root-level untracked file in warning" >&2
  cat "$OUT" >&2
  exit 1
fi

if grep -q '\.\./\.\./root-untracked.txt' "$OUT"; then
  echo "FAIL: expected root-relative untracked path, not cwd-relative traversal" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "==> PASS: open-pr.sh dirty warning is repo-root scoped from nested directories (#402)"
