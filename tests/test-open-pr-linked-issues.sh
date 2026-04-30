#!/usr/bin/env bash
#
# tests/test-open-pr-linked-issues.sh — guard issue-closing PR body injection.
#
# open-pr.sh should derive linked issues from commit message bodies on the PR
# branch and inject GitHub closing keywords into the PR body before creating
# the PR. The source of truth is the branch commits since the merge-base with
# the target branch; base-branch history must not leak into the new PR body.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-linked.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
REMOTE_DIR="$TEST_DIR/remote.git"
REPO_DIR="$TEST_DIR/repo"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh"

# Fake gh: captures --body-file content so this test can assert on the exact
# PR body that would be sent to GitHub. Git push still talks to a real local
# bare remote so branch/upstream behavior stays realistic.
cat > "$FAKE_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "repo view")
    echo "main"
    ;;
  "pr list")
    echo ""
    ;;
  "pr create")
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--body-file" ]; then
        echo "=== BODY ==="
        cat "$arg"
        printf '\n=== END BODY ===\n'
      fi
      prev="$arg"
    done
    echo "https://example.test/touchstone/pull/4242"
    ;;
  "pr view")
    echo ""
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
GHEOF
chmod +x "$FAKE_BIN/gh"

git init --bare "$REMOTE_DIR" >/dev/null 2>&1
git clone "$REMOTE_DIR" "$REPO_DIR" >/dev/null 2>&1
git -C "$REPO_DIR" switch -c main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
mkdir -p "$REPO_DIR/.github"
cp "$TOUCHSTONE_ROOT/templates/pull_request_template.md" "$REPO_DIR/.github/pull_request_template.md"
printf 'base\n' > "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add .github/pull_request_template.md file.txt
git -C "$REPO_DIR" commit -m "base commit

Closes #99" >/dev/null 2>&1
git -C "$REPO_DIR" push -u origin main >/dev/null 2>&1

git -C "$REPO_DIR" switch -c feat/issue-close-test >/dev/null 2>&1
printf 'change\n' >> "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test change

Exercise linked issue detection.

Closes #42" >/dev/null 2>&1
printf 'second change\n' >> "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test trailer

Exercise trailer-style linked issue detection.

Refs: #43
Fixes: #42" >/dev/null 2>&1

echo "==> Case 1: commit bodies with closing keywords inject Linked Issues section"
OUT="$TEST_DIR/linked.out"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPT_DIR/open-pr.sh"
) > "$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '^## Linked Issues$' "$OUT" \
  && grep -q '^Closes #42$' "$OUT" \
  && grep -q '^Closes #43$' "$OUT" \
  && ! grep -q '^Closes #99$' "$OUT" \
  && [ "$(grep -c '^Closes #42$' "$OUT")" = "1" ] \
  && grep -q '^## Summary$' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + Linked Issues section with Closes #42" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh injects issue-closing keywords from branch commits"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
