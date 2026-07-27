#!/usr/bin/env bash
#
# tests/test-update-migrate-reviewer-config.sh — Issue #177:
# `bin/touchstone update` (= bootstrap/update-project.sh) identifies a
# project's legacy `.codex-review.toml` shape but preserves the project-owned
# file and directs the user to the explicit migration command.
#
# Cases covered:
#   1. v1.x reviewers cascade → preserved with an explicit migration hint.
#   2. v1.x [review.local] block → preserved with an explicit migration hint.
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
  git -C "$repo" add -A -- .touchstone-review.toml .codex-review.toml || true
  git -C "$repo" commit --no-verify -m "$message" >/dev/null 2>&1 || true
}

run_update() {
  local dir="$1"
  (cd "$dir" \
    && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place \
      </dev/null) >"$TEST_DIR/update.out" 2>&1
}

# ---------------------------------------------------------------------------
# Case 1: v1.x reviewers cascade is preserved.
# ---------------------------------------------------------------------------
echo "==> Case 1: v1.x reviewers cascade gets an explicit migration hint"
P1="$TEST_DIR/p1"
bootstrap_project "$P1"
rm -f "$P1/.touchstone-review.toml"
cat >"$P1/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewers = ["codex", "claude"]
mode = "fix"
unsafe_paths = ["src/auth/"]
EOF
commit_file "$P1" "test: legacy reviewer config"
P1_BEFORE="$(shasum "$P1/.codex-review.toml" | awk '{print $1}')"

if ! run_update "$P1"; then
  fail "case 1: update exited non-zero"
  cat "$TEST_DIR/update.out" >&2
fi

if [ "$P1_BEFORE" != "$(shasum "$P1/.codex-review.toml" | awk '{print $1}')" ]; then
  fail "case 1: project-owned legacy config was modified"
fi
if [ -n "$(git -C "$P1" status --porcelain -- .codex-review.toml)" ]; then
  fail "case 1: .codex-review.toml has uncommitted changes after update"
fi
if ! grep -qF 'touchstone migrate-review-config --file .codex-review.toml' "$TEST_DIR/update.out"; then
  fail "case 1: explicit migration command missing"
fi

# ---------------------------------------------------------------------------
# Case 2: [review.local] block triggers the advisory without mutation.
# ---------------------------------------------------------------------------
echo "==> Case 2: [review.local] block triggers migration advisory"
P2="$TEST_DIR/p2"
bootstrap_project "$P2"
rm -f "$P2/.touchstone-review.toml"
cat >"$P2/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"

[review.local]
command = "my-local-reviewer --model demo"
EOF
commit_file "$P2" "test: legacy review.local block"
P2_BEFORE="$(shasum "$P2/.codex-review.toml" | awk '{print $1}')"

if ! run_update "$P2"; then
  fail "case 2: update exited non-zero"
fi

if [ "$P2_BEFORE" != "$(shasum "$P2/.codex-review.toml" | awk '{print $1}')" ]; then
  fail "case 2: project-owned legacy config was modified"
fi
if ! grep -qF 'touchstone migrate-review-config --file .codex-review.toml' "$TEST_DIR/update.out"; then
  fail "case 2: explicit migration command missing"
fi

# ---------------------------------------------------------------------------
# Case 3: already-v2.x config is unchanged (idempotent re-run).
# ---------------------------------------------------------------------------
echo "==> Case 3: already-v2.x config is unchanged"
P3="$TEST_DIR/p3"
bootstrap_project "$P3"
rm -f "$P3/.touchstone-review.toml"
cat >"$P3/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"

[review.conductor]
with = "codex"
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
rm -f "$P4/.touchstone-review.toml" "$P4/.codex-review.toml"
git -C "$P4" add -A
git -C "$P4" commit --no-verify -m "test: removed config" >/dev/null 2>&1 || true

if ! run_update "$P4"; then
  fail "case 4: update exited non-zero with no .codex-review.toml"
  cat "$TEST_DIR/update.out" >&2
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS assertion(s) failed" >&2
  exit 1
fi

echo "==> PASS: update preserves project-owned review configs"
