#!/usr/bin/env bash
#
# tests/test-open-pr-exit-contract.sh — guard the open-pr.sh exit contract.
#
# Failure mode being prevented (flagged by the user 2026-04-28 with concrete
# example outriderintel #90-94): a swarm agent runs `open-pr.sh --auto-merge`,
# the PR opens, review passes, but the agent's session ends before merge
# completes. The script must NEVER exit 0 unless the PR is actually merged on
# GitHub, and any non-success terminal state must print the PR URL so a human
# (or the next agent) can see what's stuck.
#
# Cases covered:
#   1. Happy path — PR opens, merge-pr.sh succeeds, mergedAt non-null → exit 0.
#   2. merge-pr.sh fails (review blocks, conflict, etc.) → nonzero + URL printed.
#   3. merge-pr.sh exits 0 but PR is NOT actually merged (the silent-orphan
#      class — gh API hiccup post-review) → nonzero + URL printed.
#   4. merge-pr.sh missing on disk → nonzero + URL printed (no silent skip).
#
# Design: the script under test is copied into a temp dir, real `git` is used
# (the repo is local), and `gh` plus `merge-pr.sh` are stubbed out. Stub
# behaviour is keyed by env vars so each test scenario reuses the same mocks
# with different toggles.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

REPO_DIR="$TEST_DIR/repo"
SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$REPO_DIR" "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh"

# Real git inside a fresh repo with a feature branch checked out, so the
# branch-name and uncommitted-tree checks all use real behaviour.
git -C "$REPO_DIR" init -b main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' > "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "base commit" >/dev/null 2>&1
git -C "$REPO_DIR" checkout -b feat/test >/dev/null 2>&1
printf 'change\n' >> "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test change" >/dev/null 2>&1

# Mock gh — behaviour controlled by env vars so each scenario reuses one mock.
# GH_MERGED_AT  — value returned for `gh pr view --json mergedAt --jq …`
# GH_HAS_EXISTING_PR — if "1", `gh pr list` returns an existing PR URL
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "repo view")
    echo "main"
    ;;
  "pr list")
    if [ "${GH_HAS_EXISTING_PR:-0}" = "1" ]; then
      echo "https://example.test/touchstone/pull/777"
    else
      echo ""
    fi
    ;;
  "pr create")
    # Last positional is the body file flag pair; we only need to emit a URL.
    echo "https://example.test/touchstone/pull/123"
    ;;
  "pr view")
    # Calls of interest:
    #   gh pr view <n> --json mergedAt --jq '.mergedAt // empty'
    # Return GH_MERGED_AT (may be empty string).
    echo "${GH_MERGED_AT:-}"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

# Stub git push so the script doesn't try to talk to a real remote.
# We wrap real git via $REAL_GIT for everything else.
REAL_GIT="$(command -v git)"
cat > "$FAKE_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "push" ]; then
  echo "[mock] git push \$*"
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE_BIN/git"

# Stub merge-pr.sh — behaviour controlled by MERGE_PR_EXIT (default 0).
# When nonzero, simulates "Conductor blocked" or similar review-failure.
cat > "$SCRIPT_DIR/merge-pr.sh" <<'EOF'
#!/usr/bin/env bash
echo "[mock merge-pr.sh] called for PR $1"
exit "${MERGE_PR_EXIT:-0}"
EOF
chmod +x "$SCRIPT_DIR/merge-pr.sh"

# Helper: run open-pr.sh in the test repo with a given mock environment.
# Sets a clean PATH so only the fake gh+git are visible (plus system bins).
run_open_pr() {
  (
    cd "$REPO_DIR"
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      GH_MERGED_AT="${GH_MERGED_AT:-}" \
      GH_HAS_EXISTING_PR="${GH_HAS_EXISTING_PR:-0}" \
      MERGE_PR_EXIT="${MERGE_PR_EXIT:-0}" \
      bash "$SCRIPT_DIR/open-pr.sh" --auto-merge
  )
}

# ---------------------------------------------------------------------------
# Case 1: happy path — exit 0, no orphan banner, mergedAt confirmed.
# ---------------------------------------------------------------------------
echo "==> Case 1: happy path"
OUT="$TEST_DIR/case1.out"
RC=0
GH_MERGED_AT="2026-04-28T12:00:00Z" GH_HAS_EXISTING_PR=0 MERGE_PR_EXIT=0 \
  run_open_pr > "$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '==> Verified: PR #123 merged at 2026-04-28T12:00:00Z' "$OUT" \
  && ! grep -q 'ORPHAN RISK' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + verified-merge line + no orphan banner" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 2: merge-pr.sh blocks (review failure / conductor blocked).
# Expect: nonzero exit + ORPHAN RISK banner with PR URL.
# ---------------------------------------------------------------------------
echo "==> Case 2: merge-pr.sh blocks (Conductor blocks review)"
OUT="$TEST_DIR/case2.out"
RC=0
GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 MERGE_PR_EXIT=1 \
  run_open_pr > "$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT" \
  && grep -q 'gh pr merge 123 --squash --delete-branch' "$OUT" \
  && grep -q 'gh pr close 123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + orphan banner + PR URL + recovery hints" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 3: silent orphan — merge-pr.sh exits 0 but mergedAt is empty.
# This is the dangerous case the new exit contract specifically catches:
# without verify_pr_merged the script would have exited 0 with an open PR.
# ---------------------------------------------------------------------------
echo "==> Case 3: silent orphan — merge-pr.sh exits 0 but PR not actually merged"
OUT="$TEST_DIR/case3.out"
RC=0
GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 MERGE_PR_EXIT=0 \
  run_open_pr > "$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'merge-pr.sh exited 0 but PR #123 is not merged on GitHub' "$OUT" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + post-merge verification failure + orphan banner" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 4: merge-pr.sh missing on disk — script must NOT silently exit 0.
# Earlier behaviour: WARNING + fall through to exit 0 (the orphan trap).
# New behaviour: ERROR + nonzero exit + orphan banner.
# ---------------------------------------------------------------------------
echo "==> Case 4: merge-pr.sh missing on disk"
OUT="$TEST_DIR/case4.out"
RC=0
mv "$SCRIPT_DIR/merge-pr.sh" "$SCRIPT_DIR/merge-pr.sh.hidden"
GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 \
  run_open_pr > "$OUT" 2>&1 || RC=$?
mv "$SCRIPT_DIR/merge-pr.sh.hidden" "$SCRIPT_DIR/merge-pr.sh"

if [ "$RC" != "0" ] \
  && grep -q 'merge-pr.sh not found' "$OUT" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + missing-script error + orphan banner" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 5: idempotency — invoked when a PR already exists, the script delegates
# to merge-pr.sh and verifies merge state. With merge-pr.sh succeeding and
# mergedAt populated, exit 0. (The earlier `exec` form also reached merge-pr;
# the new form additionally verifies — make sure the existing-PR path didn't
# regress on the happy path.)
# ---------------------------------------------------------------------------
echo "==> Case 5: existing-PR path with --auto-merge succeeds and verifies"
OUT="$TEST_DIR/case5.out"
RC=0
GH_MERGED_AT="2026-04-28T13:00:00Z" GH_HAS_EXISTING_PR=1 MERGE_PR_EXIT=0 \
  run_open_pr > "$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'PR already open' "$OUT" \
  && grep -q '==> Verified: PR #777 merged at 2026-04-28T13:00:00Z' "$OUT" \
  && ! grep -q 'ORPHAN RISK' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + verified-merge for existing-PR path" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh exit contract holds across orphan-risk paths"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
