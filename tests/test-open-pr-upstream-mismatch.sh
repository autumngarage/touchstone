#!/usr/bin/env bash
#
# tests/test-open-pr-upstream-mismatch.sh — Issue #169.
#
# `git checkout -b <branch> origin/main` traces the new branch's upstream
# to `origin/main` (correct for catching up), but it means a later plain
# `git push` fails with "upstream branch does not match the name of your
# current branch." `scripts/open-pr.sh` used to detect "upstream exists"
# and call `git push` (no -u), which hit that exact error.
#
# This test covers the fix: open-pr.sh detects that the upstream points
# at the wrong remote ref and rewrites it via `git push -u origin
# <branch>` on first push, so the workflow succeeds regardless of how
# the branch was created.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-upstream.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

REPO_DIR="$TEST_DIR/repo"
REMOTE_DIR="$TEST_DIR/remote.git"
SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh"

# Mock gh — open-pr.sh queries the default branch and creates the PR.
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "repo view") echo "main" ;;
  "pr list") echo "" ;;
  "pr create") echo "https://example.test/touchstone/pull/9999" ;;
  "pr view")
    json_fields=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      fi
      prev="$arg"
    done
    case "$json_fields" in
      state,mergedAt) printf '{"state":"MERGED","mergedAt":"2026-05-06T18:00:00Z"}\n' ;;
      mergedAt) echo "2026-05-06T18:00:00Z" ;;
      "") echo "" ;;
      *) echo "unexpected gh pr view json: $json_fields" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

# Real bare remote + clone, so `git push -u` actually creates a branch.
git init --bare "$REMOTE_DIR" >/dev/null 2>&1
git clone "$REMOTE_DIR" "$REPO_DIR" >/dev/null 2>&1
git -C "$REPO_DIR" switch -c main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "base" >/dev/null 2>&1
git -C "$REPO_DIR" push -u origin main >/dev/null 2>&1

# Reproduce the failure scenario: branch off origin/main with the
# canonical "branch from remote ref" form. Git points the new branch's
# upstream at origin/main, which is what triggers issue #169 on push.
git -C "$REPO_DIR" checkout -b chore/upstream-mismatch-test origin/main >/dev/null 2>&1
printf 'change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test change" >/dev/null 2>&1

# Sanity check: confirm the precondition. Without the fix, a plain
# `git push` from this state fails with the "upstream does not match"
# message. We don't need to assert that — the open-pr.sh run below
# would surface it as a fatal error if we hadn't fixed it.
UPSTREAM="$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
if [ "$UPSTREAM" != "origin/main" ]; then
  echo "FAIL: precondition: expected upstream 'origin/main', got '$UPSTREAM'" >&2
  exit 1
fi

echo "==> Running open-pr.sh against a branch whose upstream points at origin/main"
OUT="$TEST_DIR/run.out"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPT_DIR/open-pr.sh" "test PR" 2>&1
) >"$OUT" || RC=$?

if [ "$RC" -ne 0 ]; then
  echo "FAIL: open-pr.sh exited $RC; expected 0" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q "Existing upstream 'origin/main' does not match 'origin/chore/upstream-mismatch-test'" "$OUT"; then
  echo "FAIL: open-pr.sh did not emit the upstream-rewrite warning" >&2
  cat "$OUT" >&2
  exit 1
fi

# After the run, the branch must track its own remote ref, not main.
NEW_UPSTREAM="$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
if [ "$NEW_UPSTREAM" != "origin/chore/upstream-mismatch-test" ]; then
  echo "FAIL: upstream after push should be 'origin/chore/upstream-mismatch-test', got '$NEW_UPSTREAM'" >&2
  exit 1
fi

# And the remote should actually have the branch.
if ! git -C "$REPO_DIR" ls-remote --heads origin chore/upstream-mismatch-test \
  | grep -q chore/upstream-mismatch-test; then
  echo "FAIL: remote does not have the expected branch" >&2
  exit 1
fi

echo "==> PASS: open-pr.sh rewrites mismatched upstream on first push (#169)"
