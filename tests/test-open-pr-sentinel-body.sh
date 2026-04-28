#!/usr/bin/env bash
#
# tests/test-open-pr-sentinel-body.sh — guard sentinel-cycle PR body sourcing.
#
# When a branch is sentinel-authored (.sentinel/runs/*.md present), open-pr.sh
# must source the PR body from the <!-- pr-body-start/end --> anchored region
# of the latest cycle artifact rather than the last commit message.
#
# Cases covered:
#   1. Sentinel branch with anchors → body from artifact, not commit message.
#   2. Non-sentinel branch → body from commit message as before.
#   3. Empty anchors → warning on stderr, fallback to commit-message body.
#   4. schema-version: 2.0 → warning on stderr, body still extracted.
#   5. Malformed run file (no anchors) → warning on stderr, fallback graceful.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-sentinel.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh"

# ---------------------------------------------------------------------------
# Fake gh: captures the --body-file content so tests can assert on it.
# GH_HAS_EXISTING_PR — unused here (always 0 / no existing PR).
# ---------------------------------------------------------------------------
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
    echo "https://example.test/touchstone/pull/123"
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

# Stub git push so the script never talks to a real remote.
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

# ---------------------------------------------------------------------------
# Helper: build a clean feature-branch repo and return its path.
# The repo has one base commit on main and one commit (with a known body)
# on feat/test.
# ---------------------------------------------------------------------------
make_repo() {
  local repo="$1"
  local commit_body="${2:-Commit body from message}"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null 2>&1
  git -C "$repo" config user.name "Touchstone Test"
  git -C "$repo" config user.email "touchstone@example.com"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m "base commit" >/dev/null 2>&1
  git -C "$repo" checkout -b feat/test >/dev/null 2>&1
  printf 'change\n' >> "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m "test commit subject

$commit_body" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Helper: run open-pr.sh (without --auto-merge) inside a repo.
# ---------------------------------------------------------------------------
run_open_pr() {
  local repo="$1"
  (
    cd "$repo"
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      bash "$SCRIPT_DIR/open-pr.sh"
  )
}

# ===========================================================================
# Case 1: sentinel branch with anchors → body from artifact.
# ===========================================================================
echo "==> Case 1: sentinel branch with anchors uses artifact body"

REPO1="$TEST_DIR/repo1"
make_repo "$REPO1" "Commit body: should NOT appear"

mkdir -p "$REPO1/.sentinel/runs"
cat > "$REPO1/.sentinel/runs/2026-04-28-run.md" <<'RUNEOF'
---
schema-version: 1.0
---

Some narrative before the body.

<!-- pr-body-start -->
## Summary
- Sentinel authored this PR.

## Details
Fix applied by sentinel.
<!-- pr-body-end -->

Trailing content.
RUNEOF
git -C "$REPO1" add .sentinel && git -C "$REPO1" commit -m "chore: add sentinel run" >/dev/null 2>&1

OUT1="$TEST_DIR/case1.out"
RC1=0
run_open_pr "$REPO1" > "$OUT1" 2>&1 || RC1=$?

if [ "$RC1" = "0" ] \
  && grep -q "Sentinel authored this PR" "$OUT1" \
  && grep -q "Fix applied by sentinel" "$OUT1" \
  && ! grep -q "Commit body: should NOT appear" "$OUT1" \
  && ! grep -q "WARNING" "$OUT1"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + sentinel body + no commit body + no warning" >&2
  echo "    rc=$RC1" >&2
  cat "$OUT1" >&2
  ERRORS=$((ERRORS + 1))
fi

# ===========================================================================
# Case 2: non-sentinel branch → body from commit message.
# ===========================================================================
echo "==> Case 2: non-sentinel branch uses commit-message body"

REPO2="$TEST_DIR/repo2"
make_repo "$REPO2" "Commit body: expected in PR"

OUT2="$TEST_DIR/case2.out"
RC2=0
run_open_pr "$REPO2" > "$OUT2" 2>&1 || RC2=$?

if [ "$RC2" = "0" ] \
  && grep -q "Commit body: expected in PR" "$OUT2" \
  && ! grep -q "WARNING" "$OUT2"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + commit body + no warning" >&2
  echo "    rc=$RC2" >&2
  cat "$OUT2" >&2
  ERRORS=$((ERRORS + 1))
fi

# ===========================================================================
# Case 3: empty anchors → warning to stderr, fallback to commit-message body.
# ===========================================================================
echo "==> Case 3: empty anchors fall back to commit-message body with warning"

REPO3="$TEST_DIR/repo3"
make_repo "$REPO3" "Commit body: fallback expected"

mkdir -p "$REPO3/.sentinel/runs"
cat > "$REPO3/.sentinel/runs/2026-04-28-run.md" <<'RUNEOF'
---
schema-version: 1.0
---

<!-- pr-body-start -->
<!-- pr-body-end -->
RUNEOF
git -C "$REPO3" add .sentinel \
  && git -C "$REPO3" commit -m "chore: add sentinel run

Commit body: fallback expected" >/dev/null 2>&1

OUT3="$TEST_DIR/case3.out"
RC3=0
run_open_pr "$REPO3" > "$OUT3" 2>&1 || RC3=$?

if [ "$RC3" = "0" ] \
  && grep -q "Commit body: fallback expected" "$OUT3" \
  && grep -q "WARNING.*anchors are empty" "$OUT3"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + commit body in PR + warning about empty anchors" >&2
  echo "    rc=$RC3" >&2
  cat "$OUT3" >&2
  ERRORS=$((ERRORS + 1))
fi

# ===========================================================================
# Case 4: schema-version: 2.0 → warning logged, body still extracted.
# ===========================================================================
echo "==> Case 4: schema-version 2.0 warns but still extracts PR body"

REPO4="$TEST_DIR/repo4"
make_repo "$REPO4" "Commit body: should NOT appear in v2"

mkdir -p "$REPO4/.sentinel/runs"
cat > "$REPO4/.sentinel/runs/2026-04-28-run.md" <<'RUNEOF'
---
schema-version: 2.0
---

<!-- pr-body-start -->
Schema v2 body content.
<!-- pr-body-end -->
RUNEOF
git -C "$REPO4" add .sentinel && git -C "$REPO4" commit -m "chore: add sentinel run" >/dev/null 2>&1

OUT4="$TEST_DIR/case4.out"
RC4=0
run_open_pr "$REPO4" > "$OUT4" 2>&1 || RC4=$?

if [ "$RC4" = "0" ] \
  && grep -q "Schema v2 body content" "$OUT4" \
  && grep -q "WARNING.*schema-version 2" "$OUT4" \
  && ! grep -q "Commit body: should NOT appear in v2" "$OUT4"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + body extracted + schema warning + no commit body" >&2
  echo "    rc=$RC4" >&2
  cat "$OUT4" >&2
  ERRORS=$((ERRORS + 1))
fi

# ===========================================================================
# Case 5: malformed run file (no anchors at all) → warning, graceful fallback.
# ===========================================================================
echo "==> Case 5: malformed run file (no anchors) falls back gracefully"

REPO5="$TEST_DIR/repo5"
make_repo "$REPO5" "Commit body: malformed fallback"

mkdir -p "$REPO5/.sentinel/runs"
cat > "$REPO5/.sentinel/runs/2026-04-28-run.md" <<'RUNEOF'
---
schema-version: 1.0
---

This file has no PR-body anchors at all.
Just some free-form content.
RUNEOF
git -C "$REPO5" add .sentinel \
  && git -C "$REPO5" commit -m "chore: add sentinel run

Commit body: malformed fallback" >/dev/null 2>&1

OUT5="$TEST_DIR/case5.out"
RC5=0
run_open_pr "$REPO5" > "$OUT5" 2>&1 || RC5=$?

if [ "$RC5" = "0" ] \
  && grep -q "Commit body: malformed fallback" "$OUT5" \
  && grep -q "WARNING.*anchors are empty" "$OUT5"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + commit body in PR + warning about missing anchors" >&2
  echo "    rc=$RC5" >&2
  cat "$OUT5" >&2
  ERRORS=$((ERRORS + 1))
fi

# ===========================================================================
# Summary
# ===========================================================================
if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh sentinel-cycle PR body sourcing works correctly"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
