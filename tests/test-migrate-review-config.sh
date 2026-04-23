#!/usr/bin/env bash
#
# Tests for `touchstone migrate-review-config` — rewrites legacy 1.x
# .codex-review.toml configurations to the 2.0 shape so projects
# stop firing migration warnings on every push.

set -euo pipefail

TOUCHSTONE_ROOT="${TOUCHSTONE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MIGRATE="$TOUCHSTONE_ROOT/bootstrap/migrate-review-config.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-test-migrate-review.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

assert_file_contains() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE "$pattern" "$file"; then
    return 0
  fi
  echo "FAIL: $desc — pattern not found: $pattern" >&2
  echo "  in $file:" >&2
  sed 's/^/    /' "$file" >&2
  ERRORS=$((ERRORS + 1))
}

assert_file_lacks() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -qE "$pattern" "$file"; then
    return 0
  fi
  echo "FAIL: $desc — pattern unexpectedly present: $pattern" >&2
  ERRORS=$((ERRORS + 1))
}

# ----------------------------------------------------------------------------
# Test: full legacy config — every 1.x marker present
# ----------------------------------------------------------------------------
echo "==> Test: full legacy config migrates to 2.0 shape"
LEGACY="$TEST_DIR/full.toml"
cat > "$LEGACY" <<'EOF'
[codex_review]
max_iterations = 3

[review]
enabled = true
reviewers = ["claude", "codex", "gemini"]

[review.routing]
enabled = true
small_max_diff_lines = 50
small_reviewers = ["local"]
large_reviewers = ["claude"]

[review.local]
command = "my-custom-reviewer %p"

[review.assist]
enabled = true
EOF
bash "$MIGRATE" --file "$LEGACY" >/dev/null

# 2.0 shape present
assert_file_contains "$LEGACY" '^reviewer = "conductor"$'              "[review].reviewer scalar"
assert_file_contains "$LEGACY" '^\[review\.conductor\]$'                "[review.conductor] section appended"
assert_file_contains "$LEGACY" '^prefer = "best"$'                      "[review.conductor].prefer = best"
assert_file_contains "$LEGACY" '^effort = "max"$'                       "[review.conductor].effort = max"
assert_file_contains "$LEGACY" '^tags = "code-review"$'                 "[review.conductor].tags"
assert_file_contains "$LEGACY" '^with = "claude"$'                      "[review.conductor].with pinned to first reviewer"
assert_file_contains "$LEGACY" '# Original 1.x cascade was: claude, codex, gemini' "fallback chain preserved as comment"
assert_file_contains "$LEGACY" '^small_with = "ollama"$'                "small_reviewers=local → small_with=ollama"
assert_file_contains "$LEGACY" '^large_with = "claude"$'                "large_reviewers=claude → large_with=claude"

# 1.x markers gone (or commented out)
assert_file_lacks "$LEGACY" '^reviewers[[:space:]]*=[[:space:]]*\['     "1.x reviewers array removed"
assert_file_lacks "$LEGACY" '^small_reviewers[[:space:]]*=[[:space:]]*\[' "1.x small_reviewers removed"
assert_file_lacks "$LEGACY" '^large_reviewers[[:space:]]*=[[:space:]]*\[' "1.x large_reviewers removed"
assert_file_lacks "$LEGACY" '^\[review\.local\][[:space:]]*$'           "[review.local] header commented out"
assert_file_lacks "$LEGACY" '^\[review\.assist\][[:space:]]*$'          "[review.assist] header commented out"
assert_file_lacks "$LEGACY" '^command[[:space:]]*=[[:space:]]*"my-custom-reviewer' "[review.local].command commented out"

# Backup written
if [ -f "$LEGACY.bak" ]; then
  assert_file_contains "$LEGACY.bak" '^reviewers = \["claude"' "backup preserves original"
else
  echo "FAIL: backup file not created at $LEGACY.bak" >&2
  ERRORS=$((ERRORS + 1))
fi
echo "==> PASS: full legacy config migrated"

# ----------------------------------------------------------------------------
# Test: idempotent — second run is a no-op
# ----------------------------------------------------------------------------
echo "==> Test: idempotent (already-migrated config is a no-op)"
sha_before="$(shasum "$LEGACY" | awk '{print $1}')"
# Capture first, grep second (same SIGPIPE-under-pipefail race fix as the
# clean-file assertion below — grep -q exits on first match, the upstream
# bash process gets SIGPIPE, and pipefail trips the whole pipeline even
# though the match succeeded).
idempotent_out="$(bash "$MIGRATE" --file "$LEGACY" 2>&1)"
if ! printf '%s' "$idempotent_out" | grep -q "already in 2.0 shape"; then
  echo "FAIL: expected 'already in 2.0 shape' on second run" >&2
  echo "  got: $idempotent_out" >&2
  ERRORS=$((ERRORS + 1))
fi
sha_after="$(shasum "$LEGACY" | awk '{print $1}')"
if [ "$sha_before" != "$sha_after" ]; then
  echo "FAIL: idempotent run modified the file" >&2
  ERRORS=$((ERRORS + 1))
fi
echo "==> PASS: idempotent"

# ----------------------------------------------------------------------------
# Test: --dry-run leaves the file untouched
# ----------------------------------------------------------------------------
echo "==> Test: --dry-run leaves file untouched"
DRY="$TEST_DIR/dry.toml"
cat > "$DRY" <<'EOF'
[review]
reviewers = ["codex"]
EOF
sha_pre="$(shasum "$DRY" | awk '{print $1}')"
bash "$MIGRATE" --dry-run --file "$DRY" >/dev/null
sha_post="$(shasum "$DRY" | awk '{print $1}')"
if [ "$sha_pre" != "$sha_post" ]; then
  echo "FAIL: --dry-run modified the file" >&2
  ERRORS=$((ERRORS + 1))
fi
[ -f "$DRY.bak" ] && {
  echo "FAIL: --dry-run created a backup" >&2
  ERRORS=$((ERRORS + 1))
}
echo "==> PASS: --dry-run is read-only"

# ----------------------------------------------------------------------------
# Test: --no-backup skips the .bak
# ----------------------------------------------------------------------------
echo "==> Test: --no-backup skips backup file"
NB="$TEST_DIR/nobak.toml"
cat > "$NB" <<'EOF'
[review]
reviewers = ["claude"]
EOF
bash "$MIGRATE" --no-backup --file "$NB" >/dev/null
[ -f "$NB.bak" ] && {
  echo "FAIL: --no-backup wrote a .bak anyway" >&2
  ERRORS=$((ERRORS + 1))
}
echo "==> PASS: --no-backup honored"

# ----------------------------------------------------------------------------
# Test: `local` reviewer maps to `ollama` with retired-section comment
# ----------------------------------------------------------------------------
echo "==> Test: 'local' reviewer maps to 'ollama'"
LOC="$TEST_DIR/local-reviewer.toml"
cat > "$LOC" <<'EOF'
[review]
reviewers = ["local", "codex"]

[review.local]
command = "my-script"
EOF
bash "$MIGRATE" --no-backup --file "$LOC" >/dev/null
assert_file_contains "$LOC" '^with = "ollama"$' "local → ollama in [review.conductor]"
assert_file_contains "$LOC" '# command = "my-script"' "local command preserved as comment"
echo "==> PASS: local maps to ollama"

# ----------------------------------------------------------------------------
# Test: file with no 1.x markers exits cleanly without changes
# ----------------------------------------------------------------------------
echo "==> Test: file with no 1.x markers is a no-op"
CLEAN="$TEST_DIR/clean.toml"
cat > "$CLEAN" <<'EOF'
[codex_review]
max_iterations = 3
mode = "review-only"
EOF
sha_pre="$(shasum "$CLEAN" | awk '{print $1}')"
# Capture first, grep second. Piping directly into `grep -q` under `set -o
# pipefail` occasionally races on SIGPIPE (grep exits on first match, the
# upstream bash gets SIGPIPE, pipefail trips), which surfaced as an
# intermittent "FAIL: expected 'no recognizable 1.x markers' message" even
# though the script emitted the line correctly.
cleanout="$(bash "$MIGRATE" --file "$CLEAN" 2>&1)"
if ! printf '%s' "$cleanout" | grep -q "no recognizable 1.x markers"; then
  echo "FAIL: expected 'no recognizable 1.x markers' message" >&2
  echo "  got: $cleanout" >&2
  ERRORS=$((ERRORS + 1))
fi
sha_post="$(shasum "$CLEAN" | awk '{print $1}')"
if [ "$sha_pre" != "$sha_post" ]; then
  echo "FAIL: no-op run modified the file" >&2
  ERRORS=$((ERRORS + 1))
fi
[ -f "$CLEAN.bak" ] && {
  echo "FAIL: no-op run created a backup" >&2
  ERRORS=$((ERRORS + 1))
}
echo "==> PASS: no-1.x-markers no-op"

# ----------------------------------------------------------------------------
# Test: missing file errors cleanly
# ----------------------------------------------------------------------------
echo "==> Test: missing file errors with helpful message"
set +e
out="$(bash "$MIGRATE" --file "$TEST_DIR/does-not-exist.toml" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! echo "$out" | grep -q "not found"; then
  echo "FAIL: expected non-zero exit + 'not found' message" >&2
  echo "rc=$rc out=$out" >&2
  ERRORS=$((ERRORS + 1))
fi
echo "==> PASS: missing file errors cleanly"

# ----------------------------------------------------------------------------
# Test: migrated config does not fire migration warnings on push
# ----------------------------------------------------------------------------
echo "==> Test: migrated config does not fire migration warnings"
SCRATCH="$TEST_DIR/scratch-repo"
mkdir -p "$SCRATCH" && cd "$SCRATCH"
git init -q && git config user.email t@t && git config user.name t
echo init > README.md && git add . && git commit -qm i
cp "$LEGACY" .codex-review.toml
git add . && git commit -qm cfg

# Mock conductor
mkdir fakebin
cat > fakebin/conductor <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
cat >/dev/null
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x fakebin/conductor

# Make a tracked change so there's something to review
git checkout -qb feat/m
echo c >> README.md && git add . && git commit -qm change

PUSH_OUT="$TEST_DIR/push-out.txt"
PATH="$SCRATCH/fakebin:/usr/bin:/bin" CODEX_REVIEW_BASE=HEAD~1 CODEX_REVIEW_MODE=review-only \
  CODEX_REVIEW_DISABLE_CACHE=1 \
  bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$PUSH_OUT" 2>&1 || true

# These migration-warning lines should NOT appear
if grep -qE 'is a v1\.x config|is ignored in Touchstone 2\.0|is disabled in Touchstone 2\.0' "$PUSH_OUT"; then
  echo "FAIL: migrated config still fired migration warnings on push" >&2
  cat "$PUSH_OUT" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "==> PASS: no migration warnings on migrated config"
fi
cd "$TEST_DIR"

# ----------------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
echo "==> PASS: all migrate-review-config assertions passed"
