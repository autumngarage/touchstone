#!/usr/bin/env bash
#
# tests/test-update-migrate-reviewer-config.sh — Issue #177:
# `bin/touchstone update` (= bootstrap/update-project.sh) auto-migrates a
# project's `.codex-review.toml` from the v1.x `reviewers = [...]` shape
# to the v2.x `reviewer = "conductor"` + `[review.conductor]` shape so
# the deprecation note in scripts/codex-review.sh stops firing on every
# push.
#
# Cases covered:
#   1. v1.x reviewers cascade → migrated; commit includes the rewrite.
#   2. v1.x [review.local] block → migrated.
#   3. Already-v2.x config → unchanged (idempotent re-run).
#   4. Absent .codex-review.toml → no error.
#
set -euo pipefail
exec </dev/null

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# tests/fixtures/ provides stub cortex/sentinel/conductor binaries so the
# bootstrap calls below complete without touching the real interpreters.
export PATH="$TOUCHSTONE_ROOT/tests/fixtures:$PATH"
export YES_MODE=true

TEST_DIR="$(mktemp -d -t touchstone-test-update-migrate.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

bootstrap_project() {
  local dir="$1"
  bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$dir" --no-register --yes >/dev/null 2>&1
}

# --no-verify is needed because bootstrap installs pre-commit hooks and the
# test fixtures intentionally write minimal/legacy content the hooks may
# block. The unit under test is update-project.sh, not pre-commit policy.
commit_file() {
  local repo="$1" message="$2"
  git -C "$repo" add -- .codex-review.toml || true
  git -C "$repo" commit --no-verify -m "$message" >/dev/null 2>&1 || true
}

run_update() {
  local dir="$1"
  (cd "$dir" \
    && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place \
      </dev/null) >"$TEST_DIR/update.out" 2>&1
}

# ---------------------------------------------------------------------------
# Case 1: v1.x reviewers cascade is migrated.
# ---------------------------------------------------------------------------
echo "==> Case 1: v1.x reviewers cascade migrates to v2.x conductor shape"
P1="$TEST_DIR/p1"
bootstrap_project "$P1"
cat >"$P1/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewers = ["codex", "claude"]
mode = "fix"
unsafe_paths = ["src/auth/"]
EOF
commit_file "$P1" "test: legacy reviewer config"

if ! run_update "$P1"; then
  fail "case 1: update exited non-zero"
  cat "$TEST_DIR/update.out" >&2
fi

if ! grep -qE '^[[:space:]]*reviewer[[:space:]]*=[[:space:]]*"conductor"' "$P1/.codex-review.toml"; then
  fail "case 1: .codex-review.toml does not have reviewer = \"conductor\""
fi
if grep -qE '^[[:space:]]*reviewers[[:space:]]*=[[:space:]]*\[' "$P1/.codex-review.toml"; then
  fail "case 1: legacy reviewers = [...] line still present"
fi
if ! grep -qE '^\[review\.conductor\]' "$P1/.codex-review.toml"; then
  fail "case 1: [review.conductor] block missing"
fi
if ! grep -q 'unsafe_paths' "$P1/.codex-review.toml"; then
  fail "case 1: user-set unsafe_paths line lost"
fi
if ! git -C "$P1" log -1 --format=%s | grep -q 'chore: update touchstone'; then
  fail "case 1: latest commit is not the touchstone update commit"
fi
if [ -n "$(git -C "$P1" status --porcelain -- .codex-review.toml)" ]; then
  fail "case 1: .codex-review.toml has uncommitted changes after update"
fi

# ---------------------------------------------------------------------------
# Case 2: [review.local] block triggers migration.
# ---------------------------------------------------------------------------
echo "==> Case 2: [review.local] block triggers migration"
P2="$TEST_DIR/p2"
bootstrap_project "$P2"
cat >"$P2/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"

[review.local]
command = "my-local-reviewer --model demo"
EOF
commit_file "$P2" "test: legacy review.local block"

if ! run_update "$P2"; then
  fail "case 2: update exited non-zero"
fi

if grep -qE '^\[review\.local\]' "$P2/.codex-review.toml"; then
  fail "case 2: [review.local] header remains uncommented"
fi
if ! grep -qF '[review.local] — retired in Touchstone 2.0' "$P2/.codex-review.toml"; then
  fail "case 2: retired-section comment marker missing"
fi

# ---------------------------------------------------------------------------
# Case 3: already-v2.x config is unchanged (idempotent re-run).
# ---------------------------------------------------------------------------
echo "==> Case 3: already-v2.x config is unchanged"
P3="$TEST_DIR/p3"
bootstrap_project "$P3"
cat >"$P3/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"

[review.conductor]
prefer = "best"
effort = "max"
EOF
commit_file "$P3" "test: already v2 config"

V2_BEFORE="$(shasum "$P3/.codex-review.toml" | awk '{print $1}')"
if ! run_update "$P3"; then
  fail "case 3: update exited non-zero"
fi
V2_AFTER="$(shasum "$P3/.codex-review.toml" | awk '{print $1}')"
if [ "$V2_BEFORE" != "$V2_AFTER" ]; then
  fail "case 3: already-v2 config was modified by migration (should be no-op)"
fi
if grep -q 'Migrating .codex-review.toml' "$TEST_DIR/update.out"; then
  fail "case 3: migration message printed for already-v2 config"
fi

# ---------------------------------------------------------------------------
# Case 4: missing .codex-review.toml is not an error.
# ---------------------------------------------------------------------------
echo "==> Case 4: absent .codex-review.toml does not error"
P4="$TEST_DIR/p4"
bootstrap_project "$P4"
rm -f "$P4/.codex-review.toml"
git -C "$P4" rm -- .codex-review.toml >/dev/null 2>&1 || true
git -C "$P4" commit --no-verify -m "test: removed config" >/dev/null 2>&1 || true

if ! run_update "$P4"; then
  fail "case 4: update exited non-zero with no .codex-review.toml"
  cat "$TEST_DIR/update.out" >&2
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS assertion(s) failed" >&2
  exit 1
fi

echo "==> PASS: update auto-migrates .codex-review.toml (#177)"
