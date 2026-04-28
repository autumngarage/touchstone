#!/usr/bin/env bash
#
# tests/test-review-hook.sh — verify the hook parses multiline unsafe_paths.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-review-hook.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Prevent the hook's audit log from polluting the user's real
# ~/.touchstone-review-log when tests run. /dev/null is the documented
# disable target; per-test overrides (the skiplog-* assertions below)
# still work because env-prefixed `bash $HOOK` invocations override the
# exported default for that one subprocess.
export TOUCHSTONE_REVIEW_LOG=/dev/null

echo "==> Test: review hook parses multiline unsafe_paths"

REPO_DIR="$TEST_DIR/repo"
REPO_UNSAFE="$TEST_DIR/repo-unsafe"
FAKE_BIN="$TEST_DIR/bin"
PROMPT_FILE="$TEST_DIR/review-prompt.txt"
PROMPT_HASH_FILE="$TEST_DIR/review-prompt-hash.txt"
CACHE_OUTPUT="$TEST_DIR/cache-output.txt"
CODEX_CALLS_FILE="$TEST_DIR/codex-calls.txt"
UNSAFE_OUTPUT="$TEST_DIR/unsafe-output.txt"
ERRORS=0

unset PRE_COMMIT
unset PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF
unset PRE_COMMIT_LOCAL_BRANCH PRE_COMMIT_REMOTE_BRANCH
unset PRE_COMMIT_REMOTE_NAME PRE_COMMIT_REMOTE_URL
unset CODEX_REVIEW_FORCE CODEX_REVIEW_NO_AUTOFIX CODEX_REVIEW_DISABLE_CACHE
unset CODEX_REVIEW_ASSIST CODEX_REVIEW_ASSIST_TIMEOUT CODEX_REVIEW_ASSIST_MAX_ROUNDS
unset CODEX_REVIEW_IN_PROGRESS

mkdir -p "$REPO_DIR" "$FAKE_BIN"
git -C "$REPO_DIR" init >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"

cp "$TOUCHSTONE_ROOT/.codex-review.toml" "$REPO_DIR/.codex-review.toml"
printf 'base\n' > "$REPO_DIR/example.txt"
git -C "$REPO_DIR" add .codex-review.toml example.txt
git -C "$REPO_DIR" commit -m "base" >/dev/null 2>&1

printf 'changed\n' >> "$REPO_DIR/example.txt"
git -C "$REPO_DIR" add example.txt
git -C "$REPO_DIR" commit -m "change" >/dev/null 2>&1

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "main"
EOF

cat > "$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
prompt="$(cat)"
printf '%s' "$prompt" > "$PROMPT_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/conductor"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PROMPT_FILE="$PROMPT_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)

if grep -q -- '- Anything in bootstrap/new-project.sh' "$PROMPT_FILE" \
  && grep -q -- '- Anything in bootstrap/update-project.sh' "$PROMPT_FILE" \
  && grep -q -- '- Anything in bootstrap/sync-all.sh' "$PROMPT_FILE" \
  && grep -q -- '- Anything in hooks/codex-review.sh' "$PROMPT_FILE"; then
  echo "==> PASS: multiline unsafe_paths were included in the Codex prompt"
else
  echo "FAIL: expected multiline unsafe_paths to appear in the generated prompt" >&2
  sed -n '1,120p' "$PROMPT_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook skips feature-branch pushes but runs default-branch pushes"
cat > "$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'called\n' >> "$CODEX_CALLS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/conductor"
: > "$CODEX_CALLS_FILE"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    PRE_COMMIT=1 \
    PRE_COMMIT_LOCAL_BRANCH="refs/heads/feature/test" \
    PRE_COMMIT_REMOTE_BRANCH="refs/heads/feature/test" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TEST_DIR/feature-push-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "0" ] && grep -q 'skipping push to feature/test' "$TEST_DIR/feature-push-output.txt"; then
  echo "==> PASS: feature-branch push skipped review"
else
  echo "FAIL: expected feature-branch push to skip review" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/feature-push-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    PRE_COMMIT=1 \
    PRE_COMMIT_LOCAL_BRANCH="refs/heads/main" \
    PRE_COMMIT_REMOTE_BRANCH="refs/heads/main" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ]; then
  echo "==> PASS: default-branch push ran review"
else
  echo "FAIL: expected default-branch push to run review" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook skips first-push on fresh scaffold (HEAD = 1 commit)"
# First-push exemption: reviewing AI-generated scaffold templates is near-zero
# signal and wastes reviewer quota. A single-commit HEAD on the default branch
# is the unambiguous "initial scaffold push" signal. This test creates a fresh
# repo with exactly one commit and asserts the hook exits 0 without invoking
# the reviewer. The 2+ commit case is already covered by the preceding test.
FIRSTPUSH_REPO="$TEST_DIR/firstpush-repo"
FIRSTPUSH_OUTPUT="$TEST_DIR/firstpush-output.txt"
mkdir -p "$FIRSTPUSH_REPO"
git -C "$FIRSTPUSH_REPO" init -b main >/dev/null 2>&1
git -C "$FIRSTPUSH_REPO" config user.name "Touchstone Test"
git -C "$FIRSTPUSH_REPO" config user.email "touchstone@example.com"
cp "$TOUCHSTONE_ROOT/.codex-review.toml" "$FIRSTPUSH_REPO/.codex-review.toml"
printf 'scaffold\n' > "$FIRSTPUSH_REPO/README.md"
git -C "$FIRSTPUSH_REPO" add .codex-review.toml README.md
git -C "$FIRSTPUSH_REPO" commit -m "initial scaffold" >/dev/null 2>&1

: > "$CODEX_CALLS_FILE"
(
  cd "$FIRSTPUSH_REPO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    PRE_COMMIT=1 \
    PRE_COMMIT_LOCAL_BRANCH="refs/heads/main" \
    PRE_COMMIT_REMOTE_BRANCH="refs/heads/main" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$FIRSTPUSH_OUTPUT" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "0" ] \
  && grep -q 'first push on a fresh scaffold' "$FIRSTPUSH_OUTPUT" \
  && grep -q 'HEAD is the initial commit' "$FIRSTPUSH_OUTPUT"; then
  echo "==> PASS: first-push on fresh scaffold skipped review"
else
  echo "FAIL: expected first-push skip on fresh scaffold" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$FIRSTPUSH_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook does NOT skip when HEAD has 2+ commits on default branch"
# Guard the boundary: once a second commit lands on top of the scaffold, the
# first-push exemption must turn off — otherwise any push of only two commits
# to the default branch would also skip review, which is the opposite of what
# we want for a stacked hotfix flow.
printf 'second\n' >> "$FIRSTPUSH_REPO/README.md"
git -C "$FIRSTPUSH_REPO" add README.md
git -C "$FIRSTPUSH_REPO" commit -m "second commit" >/dev/null 2>&1

: > "$CODEX_CALLS_FILE"
(
  cd "$FIRSTPUSH_REPO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    PRE_COMMIT=1 \
    PRE_COMMIT_LOCAL_BRANCH="refs/heads/main" \
    PRE_COMMIT_REMOTE_BRANCH="refs/heads/main" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TEST_DIR/firstpush-second-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ] \
  && ! grep -q 'first push on a fresh scaffold' "$TEST_DIR/firstpush-second-output.txt"; then
  echo "==> PASS: second-commit push on default branch ran review (first-push exemption did not misfire)"
else
  echo "FAIL: expected second-commit push to run review, not skip" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/firstpush-second-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook skips nested Codex review subprocesses"
: > "$CODEX_CALLS_FILE"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_IN_PROGRESS=1 \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TEST_DIR/nested-review-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "0" ] && grep -q 'skipping nested review' "$TEST_DIR/nested-review-output.txt"; then
  echo "==> PASS: nested review skipped"
else
  echo "FAIL: expected nested review to be skipped" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/nested-review-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook caches exact clean reviews"
rm -rf "$(git -C "$REPO_DIR" rev-parse --absolute-git-dir)/touchstone/codex-review-clean"
cat > "$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'called\n' >> "$CODEX_CALLS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/conductor"
: > "$CODEX_CALLS_FILE"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CACHE_OUTPUT" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ] && grep -q 'previously passed for this exact diff' "$CACHE_OUTPUT"; then
  echo "==> PASS: clean review cache skipped the repeated review call"
else
  echo "FAIL: expected clean review cache to skip the repeated review call" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$CACHE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "2" ]; then
  echo "==> PASS: CODEX_REVIEW_DISABLE_CACHE forces a fresh review"
else
  echo "FAIL: expected CODEX_REVIEW_DISABLE_CACHE to force a fresh review" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: changing conductor knobs invalidates the cache"
# After the prior runs the cache holds CLEAN keyed on (default) conductor
# config. A push with TOUCHSTONE_CONDUCTOR_WITH=claude has a different
# effective config and must NOT reuse that cache entry.
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    TOUCHSTONE_CONDUCTOR_WITH=claude \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)
CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "3" ]; then
  echo "==> PASS: TOUCHSTONE_CONDUCTOR_WITH change invalidated cache"
else
  echo "FAIL: expected fresh review after TOUCHSTONE_CONDUCTOR_WITH change" >&2
  echo "codex call count: $CODEX_CALL_COUNT (expected 3)" >&2
  ERRORS=$((ERRORS + 1))
fi

# A second push with the same TOUCHSTONE_CONDUCTOR_WITH=claude should hit
# the new cache entry (so we know it's the env CHANGE that invalidates,
# not just env presence).
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    TOUCHSTONE_CONDUCTOR_WITH=claude \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)
CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "3" ]; then
  echo "==> PASS: same conductor knobs hit the new cache entry"
else
  echo "FAIL: expected cache hit on repeat with same env" >&2
  echo "codex call count: $CODEX_CALL_COUNT (expected 3)" >&2
  ERRORS=$((ERRORS + 1))
fi

# Changing prefer or effort should also invalidate.
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    TOUCHSTONE_CONDUCTOR_WITH=claude \
    TOUCHSTONE_CONDUCTOR_EFFORT=low \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)
CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "4" ]; then
  echo "==> PASS: TOUCHSTONE_CONDUCTOR_EFFORT change invalidated cache"
else
  echo "FAIL: expected fresh review after TOUCHSTONE_CONDUCTOR_EFFORT change" >&2
  echo "codex call count: $CODEX_CALL_COUNT (expected 4)" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook preserves # inside quoted unsafe_paths"
cat > "$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
prompt="$(cat)"
printf '%s' "$prompt" > "$PROMPT_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/conductor"
{
  printf '[codex_review]\n'
  printf 'safe_by_default = true\n'
  printf 'unsafe_paths = ["src/#secret/", "lib/ok/"] # trailing comment\n'
} > "$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "quoted unsafe paths" >/dev/null 2>&1
printf 'changed again\n' >> "$REPO_DIR/example.txt"
git -C "$REPO_DIR" add example.txt
git -C "$REPO_DIR" commit -m "change again" >/dev/null 2>&1

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PROMPT_FILE="$PROMPT_HASH_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)

if grep -q -- '- Anything in src/#secret/' "$PROMPT_HASH_FILE" \
  && grep -q -- '- Anything in lib/ok/' "$PROMPT_HASH_FILE"; then
  echo "==> PASS: # inside quoted unsafe_paths was preserved"
else
  echo "FAIL: expected quoted # in unsafe_paths to be preserved" >&2
  sed -n '1,120p' "$PROMPT_HASH_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook refuses to auto-commit unsafe path fixes"
mkdir -p "$REPO_UNSAFE/bootstrap"
git -C "$REPO_UNSAFE" init >/dev/null 2>&1
git -C "$REPO_UNSAFE" config user.name "Touchstone Test"
git -C "$REPO_UNSAFE" config user.email "touchstone@example.com"
{
  printf '[codex_review]\n'
  printf 'safe_by_default = true\n'
  printf 'unsafe_paths = ["bootstrap/"]\n'
} > "$REPO_UNSAFE/.codex-review.toml"
printf 'base\n' > "$REPO_UNSAFE/bootstrap/new-project.sh"
printf 'base\n' > "$REPO_UNSAFE/example.txt"
git -C "$REPO_UNSAFE" add .codex-review.toml bootstrap/new-project.sh example.txt
git -C "$REPO_UNSAFE" commit -m "base" >/dev/null 2>&1
printf 'changed\n' >> "$REPO_UNSAFE/example.txt"
git -C "$REPO_UNSAFE" add example.txt
git -C "$REPO_UNSAFE" commit -m "change" >/dev/null 2>&1

cat > "$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'codex edit\n' >> bootstrap/new-project.sh
printf 'fixed unsafe path\n'
printf 'CODEX_REVIEW_FIXED\n'
EOF
chmod +x "$FAKE_BIN/conductor"

BEFORE_HEAD="$(git -C "$REPO_UNSAFE" rev-parse HEAD)"
set +e
(
  cd "$REPO_UNSAFE"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$UNSAFE_OUTPUT" 2>&1
)
UNSAFE_EXIT=$?
set -e
AFTER_HEAD="$(git -C "$REPO_UNSAFE" rev-parse HEAD)"

if [ "$UNSAFE_EXIT" -eq 1 ] \
  && [ "$BEFORE_HEAD" = "$AFTER_HEAD" ] \
  && grep -q 'not allowed' "$UNSAFE_OUTPUT" \
  && grep -q 'bootstrap/new-project.sh' "$UNSAFE_OUTPUT"; then
  echo "==> PASS: unsafe auto-fix was blocked before commit"
else
  echo "FAIL: expected unsafe auto-fix to be blocked without creating a commit" >&2
  cat "$UNSAFE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ==========================================================================
# Conductor reviewer tests (Touchstone 2.0+). The v1.x multi-reviewer
# cascade tests were retired when the single `conductor` adapter shipped;
# per-provider selection now lives inside Conductor's auto-router.
# ==========================================================================

CASCADE_REPO="$TEST_DIR/repo-cascade"
CASCADE_BIN="$TEST_DIR/cascade-bin"
CASCADE_CALLS="$TEST_DIR/cascade-calls.txt"
CASCADE_OUTPUT="$TEST_DIR/cascade-output.txt"

# Mode-specific fixtures — reused by the REVIEW_MODE + timeout + error
# tests below. These tests capture conductor's argv so we can assert that
# Touchstone translates REVIEW_MODE into the expected --tools / --sandbox
# flags passed to conductor exec.
MODE_REPO="$TEST_DIR/repo-mode"
MODE_BIN="$TEST_DIR/mode-bin"
MODE_OUTPUT="$TEST_DIR/mode-output.txt"
CODEX_ARGS_FILE="$TEST_DIR/conductor-args.txt"

setup_cascade_repo() {
  rm -rf "$CASCADE_REPO"
  mkdir -p "$CASCADE_REPO"
  git -C "$CASCADE_REPO" init >/dev/null 2>&1
  git -C "$CASCADE_REPO" config user.name "Touchstone Test"
  git -C "$CASCADE_REPO" config user.email "touchstone@example.com"
  printf 'base\n' > "$CASCADE_REPO/example.txt"
  git -C "$CASCADE_REPO" add example.txt
  git -C "$CASCADE_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >> "$CASCADE_REPO/example.txt"
  git -C "$CASCADE_REPO" add example.txt
  git -C "$CASCADE_REPO" commit -m "change" >/dev/null 2>&1
}

setup_mode_repo() {
  rm -rf "$MODE_REPO"
  mkdir -p "$MODE_REPO"
  git -C "$MODE_REPO" init >/dev/null 2>&1
  git -C "$MODE_REPO" config user.name "Touchstone Test"
  git -C "$MODE_REPO" config user.email "touchstone@example.com"
  printf 'base\n' > "$MODE_REPO/example.txt"
  git -C "$MODE_REPO" add example.txt
  git -C "$MODE_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >> "$MODE_REPO/example.txt"
  git -C "$MODE_REPO" add example.txt
  git -C "$MODE_REPO" commit -m "change" >/dev/null 2>&1
}

echo "==> Test: all reviewers unavailable exits 0 with diagnostics"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude", "gemini"]\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
chmod +x "$CASCADE_BIN/gh"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)
ALL_UNAVAIL_EXIT=$?
set -e

if [ "$ALL_UNAVAIL_EXIT" -eq 0 ] \
  && grep -q 'No reviewer available' "$CASCADE_OUTPUT" \
  && grep -q 'conductor: CLI not found on PATH' "$CASCADE_OUTPUT" \
  && grep -q 'brew install autumngarage/conductor/conductor' "$CASCADE_OUTPUT" \
  && grep -q 'conductor init' "$CASCADE_OUTPUT"; then
  echo "==> PASS: reviewer unavailable — exited 0 with conductor install hint"
else
  echo "FAIL: expected exit 0 and conductor install diagnostics" >&2
  echo "exit code: $ALL_UNAVAIL_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review can be disabled by config"
setup_cascade_repo
{
  printf '[review]\n'
  printf 'enabled = false\n'
  printf 'reviewers = ["codex"]\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "review disabled" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if [ ! -s "$CASCADE_CALLS" ] && grep -q 'AI review disabled' "$CASCADE_OUTPUT"; then
  echo "==> PASS: review disabled by config skipped reviewer"
else
  echo "FAIL: expected enabled=false to skip reviewer" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: CODEX_REVIEW_NO_AUTOFIX backward compat maps to review-only"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat > "$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"

{
  printf '[codex_review]\nsafe_by_default = true\n'
} > "$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "codex config" >/dev/null 2>&1

(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_NO_AUTOFIX=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
)

if grep -q -- '--sandbox read-only' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: CODEX_REVIEW_NO_AUTOFIX=1 mapped to review-only (read-only sandbox)"
else
  echo "FAIL: expected CODEX_REVIEW_NO_AUTOFIX to map to review-only mode" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: FIXED sentinel in review-only mode exits 1"
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat > "$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'CODEX_REVIEW_FIXED\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"

set +e
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
)
FIXED_RO_EXIT=$?
set -e

if [ "$FIXED_RO_EXIT" -eq 1 ] && grep -q "emitted FIXED in 'review-only' mode" "$MODE_OUTPUT"; then
  echo "==> PASS: FIXED in review-only mode exits 1 with warning"
else
  echo "FAIL: expected exit 1 and warning when FIXED emitted in review-only mode" >&2
  echo "exit code: $FIXED_RO_EXIT" >&2
  cat "$MODE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: invalid mode warns and falls back to fix"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat > "$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"

(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=invalid \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
)

if grep -q "Invalid mode" "$MODE_OUTPUT" \
  && grep -q -- '--sandbox workspace-write' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: invalid mode warned and fell back to fix (workspace-write)"
else
  echo "FAIL: expected invalid mode to warn and fall back to fix" >&2
  cat "$MODE_OUTPUT" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

# ==========================================================================
# Timeout and error policy tests
# ==========================================================================

TIMEOUT_REPO="$TEST_DIR/repo-timeout"
TIMEOUT_OUTPUT="$TEST_DIR/timeout-output.txt"
TIMEOUT_PID_FILE="$TEST_DIR/timeout-reviewer.pid"
TIMEOUT_CHILD_PID_FILE="$TEST_DIR/timeout-reviewer-child.pid"

setup_timeout_repo() {
  rm -rf "$TIMEOUT_REPO"
  mkdir -p "$TIMEOUT_REPO"
  git -C "$TIMEOUT_REPO" init >/dev/null 2>&1
  git -C "$TIMEOUT_REPO" config user.name "Touchstone Test"
  git -C "$TIMEOUT_REPO" config user.email "touchstone@example.com"
  printf 'base\n' > "$TIMEOUT_REPO/example.txt"
  git -C "$TIMEOUT_REPO" add example.txt
  git -C "$TIMEOUT_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >> "$TIMEOUT_REPO/example.txt"
  git -C "$TIMEOUT_REPO" add example.txt
  git -C "$TIMEOUT_REPO" commit -m "change" >/dev/null 2>&1
}

sleep_command_active() {
  local seconds="$1"

  ps -axo stat=,command= 2>/dev/null | awk -v command="sleep $seconds" '
    $1 !~ /^Z/ {
      $1 = ""
      sub(/^[[:space:]]+/, "")
      if ($0 == command) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

echo "==> Test: clean review cancels timeout watchdog"
setup_timeout_repo
TIMEOUT_BIN="$TEST_DIR/timeout-bin"
rm -rf "$TIMEOUT_BIN"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/conductor"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_TIMEOUT=13 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
)
CLEAN_TIMEOUT_EXIT=$?
set -e

if [ "$CLEAN_TIMEOUT_EXIT" -eq 0 ] && ! sleep_command_active 13; then
  echo "==> PASS: clean review canceled timeout watchdog"
else
  echo "FAIL: expected clean review to cancel timeout watchdog" >&2
  echo "exit code: $CLEAN_TIMEOUT_EXIT" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: timeout kills reviewer and exits per on_error"
setup_timeout_repo
TIMEOUT_BIN="$TEST_DIR/timeout-bin"
rm -rf "$TIMEOUT_BIN"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
sleep 999 &
child_pid=$!
printf '%s\n' "$$" > "$TIMEOUT_PID_FILE"
printf '%s\n' "$child_pid" > "$TIMEOUT_CHILD_PID_FILE"
wait "$child_pid"
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/conductor"
rm -f "$TIMEOUT_PID_FILE" "$TIMEOUT_CHILD_PID_FILE"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TIMEOUT_PID_FILE="$TIMEOUT_PID_FILE" \
    TIMEOUT_CHILD_PID_FILE="$TIMEOUT_CHILD_PID_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_TIMEOUT=2 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
)
TIMEOUT_EXIT=$?
set -e

if [ "$TIMEOUT_EXIT" -eq 0 ] && grep -q 'timed out after 2s' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: timeout killed reviewer and exited 0 (fail-open default)"
else
  echo "FAIL: expected timeout to kill reviewer and exit 0" >&2
  echo "exit code: $TIMEOUT_EXIT" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

process_still_active() {
  local pid="$1"
  local stat

  stat="$(ps -p "$pid" -o stat= 2>/dev/null | awk '{print $1}' || true)"
  [ -n "$stat" ] && [[ "$stat" != Z* ]]
}

if [ -s "$TIMEOUT_PID_FILE" ] \
  && [ -s "$TIMEOUT_CHILD_PID_FILE" ] \
  && ! process_still_active "$(cat "$TIMEOUT_PID_FILE")" \
  && ! process_still_active "$(cat "$TIMEOUT_CHILD_PID_FILE")"; then
  echo "==> PASS: timeout cleaned up reviewer process tree"
else
  echo "FAIL: expected timeout to clean up reviewer process tree" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: on_error=fail-closed blocks push on reviewer crash"
setup_timeout_repo
rm -rf "$TIMEOUT_BIN"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
exit 1
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/conductor"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
)
CLOSED_EXIT=$?
set -e

if [ "$CLOSED_EXIT" -eq 1 ] && grep -q 'fail-closed' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: on_error=fail-closed blocked push on reviewer crash"
else
  echo "FAIL: expected fail-closed to block push on reviewer crash" >&2
  echo "exit code: $CLOSED_EXIT" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: on_error=fail-open allows push on reviewer crash (default)"
setup_timeout_repo
set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
)
OPEN_EXIT=$?
set -e

if [ "$OPEN_EXIT" -eq 0 ] && grep -q 'fail-open' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: on_error=fail-open allowed push on reviewer crash"
else
  echo "FAIL: expected fail-open to allow push on reviewer crash" >&2
  echo "exit code: $OPEN_EXIT" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: on_error=fail-closed blocks on malformed output"
setup_timeout_repo
rm -rf "$TIMEOUT_BIN"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
echo "no sentinel here"
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/conductor"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
)
MALFORMED_EXIT=$?
set -e

if [ "$MALFORMED_EXIT" -eq 1 ] && grep -q 'malformed sentinel' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: on_error=fail-closed blocked on malformed output"
else
  echo "FAIL: expected fail-closed to block on malformed output" >&2
  echo "exit code: $MALFORMED_EXIT" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ==========================================================================
# Repo-provided context tests
# ==========================================================================

CTX_REPO="$TEST_DIR/repo-ctx"
CTX_OUTPUT="$TEST_DIR/ctx-output.txt"
CTX_PROMPT="$TEST_DIR/ctx-prompt.txt"

setup_ctx_repo() {
  rm -rf "$CTX_REPO"
  mkdir -p "$CTX_REPO"
  git -C "$CTX_REPO" init >/dev/null 2>&1
  git -C "$CTX_REPO" config user.name "Touchstone Test"
  git -C "$CTX_REPO" config user.email "touchstone@example.com"
  printf 'base\n' > "$CTX_REPO/example.txt"
  git -C "$CTX_REPO" add example.txt
  git -C "$CTX_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >> "$CTX_REPO/example.txt"
  git -C "$CTX_REPO" add example.txt
  git -C "$CTX_REPO" commit -m "change" >/dev/null 2>&1
}

CTX_BIN="$TEST_DIR/ctx-bin"

setup_ctx_bin() {
  rm -rf "$CTX_BIN"
  mkdir -p "$CTX_BIN"
  cat > "$CTX_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
  cat > "$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
prompt="$(cat)"
printf '%s' "$prompt" > "$CTX_PROMPT"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
  chmod +x "$CTX_BIN/gh" "$CTX_BIN/conductor"
}

echo "==> Test: context file at repo root is appended to prompt"
setup_ctx_repo
setup_ctx_bin
printf 'UNIQUE_CTX_MARKER_12345\n' > "$CTX_REPO/.codex-review-context.md"
git -C "$CTX_REPO" add .codex-review-context.md
git -C "$CTX_REPO" commit -m "add context" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if grep -q 'UNIQUE_CTX_MARKER_12345' "$CTX_PROMPT" \
  && grep -q 'Review context' "$CTX_OUTPUT"; then
  echo "==> PASS: context file appended to prompt"
else
  echo "FAIL: expected context file content in prompt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: context file under .github/ is discovered"
setup_ctx_repo
setup_ctx_bin
mkdir -p "$CTX_REPO/.github"
printf 'GITHUB_CTX_MARKER_67890\n' > "$CTX_REPO/.github/codex-review-context.md"
git -C "$CTX_REPO" add .github/codex-review-context.md
git -C "$CTX_REPO" commit -m "add github context" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if grep -q 'GITHUB_CTX_MARKER_67890' "$CTX_PROMPT"; then
  echo "==> PASS: .github/ context file discovered"
else
  echo "FAIL: expected .github/ context file in prompt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: no context file = no error"
setup_ctx_repo
setup_ctx_bin
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if ! grep -q 'Review context' "$CTX_OUTPUT" \
  && ! grep -q 'Project review context' "$CTX_PROMPT"; then
  echo "==> PASS: no context file, no error"
else
  echo "FAIL: expected no context section when file is missing" >&2
  ERRORS=$((ERRORS + 1))
fi

# ==========================================================================
# Observability tests (phase labels, summary)
# ==========================================================================

echo "==> Test: phase labels appear in output"
setup_ctx_repo
setup_ctx_bin
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if grep -q 'loading diff' "$CTX_OUTPUT" \
  && grep -q 'checking cache' "$CTX_OUTPUT" \
  && grep -q 'reviewing with' "$CTX_OUTPUT" \
  && grep -q 'done — clean' "$CTX_OUTPUT"; then
  echo "==> PASS: phase labels appear in output"
else
  echo "FAIL: expected phase labels in output" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: summary block appears at end"
if grep -q 'review summary' "$CTX_OUTPUT" \
  && grep -q 'exit reason:.*clean' "$CTX_OUTPUT" \
  && grep -q 'elapsed:' "$CTX_OUTPUT"; then
  echo "==> PASS: summary block appears at end"
else
  echo "FAIL: expected summary block in output" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: conductor route-log surfaces in transcript"
# Mock conductor emits a route-log to stderr on call; transcript should
# contain the `[conductor]` header line plus the wrapped cost/token line.
# Uses ASCII (-> and .) intentionally — the print_route_log filter must
# tolerate any wrap-line punctuation since it's whitespace-anchored.
cat > "$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
cat >/dev/null
printf '[conductor] auto (prefer=best, effort=max) -> claude (tier: frontier)\n' >&2
printf '            . 4.2s . 1284 tok in . 420 tok out . sandbox=read-only\n' >&2
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CTX_BIN/conductor"
printf 'route log test\n' >> "$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt
git -C "$CTX_REPO" commit -m "route log" >/dev/null 2>&1
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

# Header line + the wrapped cost/token line must both reach the transcript.
if grep -q '\[conductor\] auto' "$CTX_OUTPUT" \
  && grep -qE 'tier: frontier' "$CTX_OUTPUT" \
  && grep -qE '4\.2s' "$CTX_OUTPUT"; then
  echo "==> PASS: conductor route-log surfaces in transcript"
else
  echo "FAIL: expected conductor route-log in transcript" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: peer review fires when [review.assist].enabled = true"
# Mock conductor responds differently to `exec` (primary) and `call`
# (peer). The primary emits a route-log to stderr naming itself, which
# touchstone parses out to set --exclude on the peer call. The peer
# prints distinctive text so we can assert it surfaces in the transcript.
cat > "$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="$1"; shift
# Record every invocation's argv so the test can inspect --exclude presence
# independently of stdout assertions.
printf '%s\n' "$subcmd $*" >> "$CONDUCTOR_ARGS_LOG"
cat >/dev/null  # drain stdin
case "$subcmd" in
  exec)
    printf '[conductor] auto -> claude (tier: frontier)\n' >&2
    printf '            · 4.2s · 100 tok in · 20 tok out · sandbox=read-only\n' >&2
    printf 'Primary review says nothing to change.\n'
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  call)
    printf 'AGREE\n'
    printf 'Peer has nothing additional to add — the primary reviewer covered it.\n'
    ;;
esac
CXEOF
chmod +x "$CTX_BIN/conductor"
# New commit → defeats the cache, and lets us diff vs HEAD~1.
printf 'peer-review test\n' >> "$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt && git -C "$CTX_REPO" commit -m "peer review" >/dev/null 2>&1
# Enable peer review in the project config.
{
  cat "$CTX_REPO/.codex-review.toml"
  printf '\n[review.assist]\nenabled = true\nmax_rounds = 1\n'
} > "$CTX_REPO/.codex-review.toml.tmp" && mv "$CTX_REPO/.codex-review.toml.tmp" "$CTX_REPO/.codex-review.toml"
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "enable assist" >/dev/null 2>&1

CONDUCTOR_ARGS_LOG="$TEST_DIR/conductor-args.log"
: > "$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~2" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if grep -q 'peer review' "$CTX_OUTPUT" \
  && grep -q 'AGREE' "$CTX_OUTPUT" \
  && grep -q '^call .*--exclude claude' "$CONDUCTOR_ARGS_LOG"; then
  echo "==> PASS: peer review fired with --exclude and surfaced in transcript"
else
  echo "FAIL: expected peer review block with AGREE and --exclude claude" >&2
  echo "--- CTX_OUTPUT ---" >&2
  cat "$CTX_OUTPUT" >&2
  echo "--- conductor args log ---" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: peer review silent when [review.assist].enabled = false"
# Reset config (strip the assist block) and rerun; peer should NOT fire.
sed -i.bak '/\[review.assist\]/,$d' "$CTX_REPO/.codex-review.toml" && rm -f "$CTX_REPO/.codex-review.toml.bak"
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "disable assist" >/dev/null 2>&1
printf 'another change\n' >> "$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt && git -C "$CTX_REPO" commit -m "change" >/dev/null 2>&1

: > "$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~2" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if ! grep -q '^call ' "$CONDUCTOR_ARGS_LOG" && ! grep -q 'AGREE' "$CTX_OUTPUT"; then
  echo "==> PASS: peer review does not fire when disabled"
else
  echo "FAIL: peer review fired when disabled" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: JSON summary file written when env var set"
setup_ctx_repo
setup_ctx_bin
JSON_SUMMARY="$TEST_DIR/review-summary.json"
rm -f "$JSON_SUMMARY"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_SUMMARY_FILE="$JSON_SUMMARY" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if [ -f "$JSON_SUMMARY" ] \
  && grep -q '"exit_reason":"clean"' "$JSON_SUMMARY" \
  && grep -q '"reviewer":"Conductor"' "$JSON_SUMMARY"; then
  echo "==> PASS: JSON summary file written"
else
  echo "FAIL: expected JSON summary file" >&2
  cat "$JSON_SUMMARY" 2>/dev/null >&2
  ERRORS=$((ERRORS + 1))
fi

# ==========================================================================
# Skip-event audit log
# ==========================================================================
#
# hooks/codex-review.sh writes one TSV line per skip path and per
# successful run to ~/.touchstone-review-log (overridable via
# TOUCHSTONE_REVIEW_LOG). The audit lets the user see how often the AI
# review safety net falls open silently — see "No silent failures" in
# principles/engineering-principles.md.
#
# Each assertion isolates the log file via TOUCHSTONE_REVIEW_LOG so the
# tests never touch the real ~/.touchstone-review-log.

setup_skiplog_repo() {
  # setup_skiplog_repo <dir> [--with-config-toml]
  local dir="$1"; shift || true
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  printf 'base\n' > "$dir/file.txt"
  if [ "${1:-}" = "--with-config-toml" ]; then
    cat > "$dir/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"
[review.conductor]
prefer = "best"
effort = "max"
EOF
  fi
  git -C "$dir" add . && git -C "$dir" commit -qm init
  printf 'change\n' >> "$dir/file.txt"
  git -C "$dir" add . && git -C "$dir" commit -qm change
}

make_skiplog_bin_with_conductor() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
echo main
EOF
  cat > "$dir/conductor" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then
  printf '{"providers":[{"configured":true}]}\n'; exit 0
fi
printf 'CODEX_REVIEW_CLEAN\n'
EOF
  chmod +x "$dir/gh" "$dir/conductor"
}

make_skiplog_bin_without_conductor() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
echo main
EOF
  chmod +x "$dir/gh"
}

run_skiplog_hook() {
  local repo="$1"; shift
  local sink="$1"; shift
  (
    cd "$repo"
    "$@" bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" > "$sink" 2>&1
  )
}

assert_skiplog_last_reason() {
  local label="$1" log="$2" expected="$3"

  if [ ! -s "$log" ]; then
    echo "FAIL [$label]: log file empty or missing: $log" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  local last
  last="$(tail -n 1 "$log")"

  local tab_count
  tab_count="$(printf '%s' "$last" | tr -cd '\t' | wc -c | tr -d ' ')"
  if [ "$tab_count" != "5" ]; then
    echo "FAIL [$label]: expected 6 tab-separated fields (5 tabs), got $tab_count" >&2
    echo "  line: $last" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  local reason
  reason="$(printf '%s' "$last" | awk -F'\t' '{print $5}')"
  if [ "$reason" != "$expected" ]; then
    echo "FAIL [$label]: expected reason '$expected', got '$reason'" >&2
    echo "  line: $last" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  echo "==> PASS [$label]: logged reason=$expected"
}

# ---------------------------------------------------------------------------
# Test: conductor-missing — PATH stripped of `conductor`
# ---------------------------------------------------------------------------
echo "==> Test: conductor-missing skip path logs reason=conductor-missing"
SKIPLOG_REPO1="$TEST_DIR/skiplog-repo1"
SKIPLOG_BIN1="$TEST_DIR/skiplog-bin1"
SKIPLOG_LOG1="$TEST_DIR/skiplog-log1.tsv"
setup_skiplog_repo "$SKIPLOG_REPO1" --with-config-toml
make_skiplog_bin_without_conductor "$SKIPLOG_BIN1"

run_skiplog_hook "$SKIPLOG_REPO1" "$TEST_DIR/skiplog-out1.txt" \
  env PATH="$SKIPLOG_BIN1:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG1" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
assert_skiplog_last_reason "conductor-missing" "$SKIPLOG_LOG1" "conductor-missing"

# ---------------------------------------------------------------------------
# Test: config-disabled — [review].enabled=false in .codex-review.toml
# ---------------------------------------------------------------------------
echo "==> Test: config-disabled skip path logs reason=config-disabled"
SKIPLOG_REPO2="$TEST_DIR/skiplog-repo2"
SKIPLOG_BIN2="$TEST_DIR/skiplog-bin2"
SKIPLOG_LOG2="$TEST_DIR/skiplog-log2.tsv"
mkdir -p "$SKIPLOG_REPO2"
git -C "$SKIPLOG_REPO2" init -q
git -C "$SKIPLOG_REPO2" config user.email t@t
git -C "$SKIPLOG_REPO2" config user.name t
cat > "$SKIPLOG_REPO2/.codex-review.toml" <<'EOF'
[review]
enabled = false
reviewer = "conductor"
EOF
printf 'a\n' > "$SKIPLOG_REPO2/f.txt"
git -C "$SKIPLOG_REPO2" add . && git -C "$SKIPLOG_REPO2" commit -qm init
printf 'b\n' >> "$SKIPLOG_REPO2/f.txt"
git -C "$SKIPLOG_REPO2" add . && git -C "$SKIPLOG_REPO2" commit -qm change
make_skiplog_bin_with_conductor "$SKIPLOG_BIN2"

run_skiplog_hook "$SKIPLOG_REPO2" "$TEST_DIR/skiplog-out2.txt" \
  env PATH="$SKIPLOG_BIN2:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG2" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
assert_skiplog_last_reason "config-disabled" "$SKIPLOG_LOG2" "config-disabled"

# ---------------------------------------------------------------------------
# Test: review-disabled-by-user — CODEX_REVIEW_ENABLED=false at env layer
#
# CODEX_REVIEW_ENABLED is the canonical user-facing skip toggle today —
# a per-push override that wins over the TOML setting.
# ---------------------------------------------------------------------------
echo "==> Test: CODEX_REVIEW_ENABLED=false logs reason=review-disabled-by-user"
SKIPLOG_REPO3="$TEST_DIR/skiplog-repo3"
SKIPLOG_BIN3="$TEST_DIR/skiplog-bin3"
SKIPLOG_LOG3="$TEST_DIR/skiplog-log3.tsv"
setup_skiplog_repo "$SKIPLOG_REPO3" --with-config-toml
make_skiplog_bin_with_conductor "$SKIPLOG_BIN3"

run_skiplog_hook "$SKIPLOG_REPO3" "$TEST_DIR/skiplog-out3.txt" \
  env PATH="$SKIPLOG_BIN3:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG3" \
      CODEX_REVIEW_ENABLED=false \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
assert_skiplog_last_reason "review-disabled-by-user" "$SKIPLOG_LOG3" "review-disabled-by-user"

# ---------------------------------------------------------------------------
# Test: ran — successful review with mock conductor returning CLEAN
#
# The denominator the audit needs: skip-rate = skips / (skips + ran).
# ---------------------------------------------------------------------------
echo "==> Test: successful review logs reason=ran (audit denominator)"
SKIPLOG_REPO4="$TEST_DIR/skiplog-repo4"
SKIPLOG_BIN4="$TEST_DIR/skiplog-bin4"
SKIPLOG_LOG4="$TEST_DIR/skiplog-log4.tsv"
setup_skiplog_repo "$SKIPLOG_REPO4" --with-config-toml
make_skiplog_bin_with_conductor "$SKIPLOG_BIN4"

run_skiplog_hook "$SKIPLOG_REPO4" "$TEST_DIR/skiplog-out4.txt" \
  env PATH="$SKIPLOG_BIN4:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG4" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || { echo "FAIL: hook exited non-zero on a clean review" >&2; cat "$TEST_DIR/skiplog-out4.txt" >&2; ERRORS=$((ERRORS + 1)); }
assert_skiplog_last_reason "ran" "$SKIPLOG_LOG4" "ran"

# ---------------------------------------------------------------------------
# Test: malformed .codex-review.toml does not break the hook
#
# Today's TOML parser is permissive — it skips lines it doesn't recognize.
# The regression we care about is: a malformed TOML must still leave the
# audit log in a consistent state — the hook reaches SOME log call rather
# than crashing without writing anything.
# ---------------------------------------------------------------------------
echo "==> Test: malformed .codex-review.toml does not crash logging"
SKIPLOG_REPO5="$TEST_DIR/skiplog-repo5"
SKIPLOG_BIN5="$TEST_DIR/skiplog-bin5"
SKIPLOG_LOG5="$TEST_DIR/skiplog-log5.tsv"
mkdir -p "$SKIPLOG_REPO5"
git -C "$SKIPLOG_REPO5" init -q
git -C "$SKIPLOG_REPO5" config user.email t@t
git -C "$SKIPLOG_REPO5" config user.name t
cat > "$SKIPLOG_REPO5/.codex-review.toml" <<'EOF'
[review
this-is = not = valid =
=== no key here ===
EOF
printf 'a\n' > "$SKIPLOG_REPO5/f.txt"
git -C "$SKIPLOG_REPO5" add . && git -C "$SKIPLOG_REPO5" commit -qm init
printf 'b\n' >> "$SKIPLOG_REPO5/f.txt"
git -C "$SKIPLOG_REPO5" add . && git -C "$SKIPLOG_REPO5" commit -qm change
make_skiplog_bin_with_conductor "$SKIPLOG_BIN5"

run_skiplog_hook "$SKIPLOG_REPO5" "$TEST_DIR/skiplog-out5.txt" \
  env PATH="$SKIPLOG_BIN5:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG5" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
if [ -s "$SKIPLOG_LOG5" ]; then
  echo "==> PASS: malformed TOML still produced a log entry"
else
  echo "FAIL: malformed TOML left log file empty" >&2
  cat "$TEST_DIR/skiplog-out5.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Test: rollover at 1000 entries
# ---------------------------------------------------------------------------
echo "==> Test: log rollover caps the file at 1000 entries"
SKIPLOG_REPO6="$TEST_DIR/skiplog-repo6"
SKIPLOG_BIN6="$TEST_DIR/skiplog-bin6"
SKIPLOG_LOG6="$TEST_DIR/skiplog-log6.tsv"
setup_skiplog_repo "$SKIPLOG_REPO6" --with-config-toml
make_skiplog_bin_with_conductor "$SKIPLOG_BIN6"

: > "$SKIPLOG_LOG6"
i=0
while [ "$i" -lt 1000 ]; do
  printf 'seed-ts\trepo\tbranch\tsha\tseed\trow-%s\n' "$i" >> "$SKIPLOG_LOG6"
  i=$((i + 1))
done

seeded_count="$(wc -l < "$SKIPLOG_LOG6" | tr -d ' ')"
if [ "$seeded_count" != "1000" ]; then
  echo "FAIL: seeding sanity check — expected 1000 lines, got $seeded_count" >&2
  ERRORS=$((ERRORS + 1))
fi

run_skiplog_hook "$SKIPLOG_REPO6" "$TEST_DIR/skiplog-out6.txt" \
  env PATH="$SKIPLOG_BIN6:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG6" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || { echo "FAIL: hook exited non-zero in rollover test" >&2; cat "$TEST_DIR/skiplog-out6.txt" >&2; ERRORS=$((ERRORS + 1)); }

final_count="$(wc -l < "$SKIPLOG_LOG6" | tr -d ' ')"
if [ "$final_count" = "1000" ]; then
  echo "==> PASS: log capped at 1000 entries after rollover"
else
  echo "FAIL: expected 1000 lines after rollover, got $final_count" >&2
  ERRORS=$((ERRORS + 1))
fi

if grep -q '	row-0$' "$SKIPLOG_LOG6"; then
  echo "FAIL: oldest entry (row-0) was not evicted on rollover" >&2
  ERRORS=$((ERRORS + 1))
fi

last_reason="$(tail -n 1 "$SKIPLOG_LOG6" | awk -F'\t' '{print $5}')"
if [ "$last_reason" = "seed" ]; then
  echo "FAIL: tail of log is still a seed entry — new event not appended" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Test: format invariant — every line is exactly 6 tab-separated fields
# ---------------------------------------------------------------------------
echo "==> Test: every log entry is exactly 6 tab-separated fields"
SKIPLOG_FORMAT_OK=true
for log in "$SKIPLOG_LOG1" "$SKIPLOG_LOG2" "$SKIPLOG_LOG3" "$SKIPLOG_LOG4" "$SKIPLOG_LOG6"; do
  [ -s "$log" ] || continue
  if ! awk -F'\t' 'NF != 6 { exit 1 }' "$log"; then
    echo "FAIL: $log has lines that are not 6-field TSV" >&2
    SKIPLOG_FORMAT_OK=false
    ERRORS=$((ERRORS + 1))
  fi
done
if [ "$SKIPLOG_FORMAT_OK" = true ]; then
  echo "==> PASS: all logs are 6-field TSV"
fi

# ---------------------------------------------------------------------------
# Test: TOUCHSTONE_REVIEW_LOG=/dev/null and ="" disable logging cleanly
#
# log_skip_event has two early-return paths: empty string and /dev/null.
# Both must leave no trace and let the hook complete normally.
# ---------------------------------------------------------------------------
echo "==> Test: TOUCHSTONE_REVIEW_LOG=/dev/null disables logging"
SKIPLOG_REPO7="$TEST_DIR/skiplog-repo7"
SKIPLOG_BIN7="$TEST_DIR/skiplog-bin7"
SKIPLOG_PROBE7="$TEST_DIR/skiplog-probe7"
setup_skiplog_repo "$SKIPLOG_REPO7" --with-config-toml
make_skiplog_bin_with_conductor "$SKIPLOG_BIN7"

# Pre-create the would-be sentinel path. If the hook tried to log to a
# non-/dev/null target by mistake, the file's mtime would advance.
: > "$SKIPLOG_PROBE7"
SKIPLOG_PROBE7_MTIME_BEFORE="$(stat -f %m "$SKIPLOG_PROBE7" 2>/dev/null || stat -c %Y "$SKIPLOG_PROBE7")"

run_skiplog_hook "$SKIPLOG_REPO7" "$TEST_DIR/skiplog-out7.txt" \
  env PATH="$SKIPLOG_BIN7:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG=/dev/null \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || { echo "FAIL: hook exited non-zero with TOUCHSTONE_REVIEW_LOG=/dev/null" >&2; cat "$TEST_DIR/skiplog-out7.txt" >&2; ERRORS=$((ERRORS + 1)); }

SKIPLOG_PROBE7_MTIME_AFTER="$(stat -f %m "$SKIPLOG_PROBE7" 2>/dev/null || stat -c %Y "$SKIPLOG_PROBE7")"
if [ "$SKIPLOG_PROBE7_MTIME_BEFORE" = "$SKIPLOG_PROBE7_MTIME_AFTER" ]; then
  echo "==> PASS: TOUCHSTONE_REVIEW_LOG=/dev/null wrote nothing detectable"
else
  echo "FAIL: probe file mtime changed despite /dev/null target" >&2
  ERRORS=$((ERRORS + 1))
fi

# Same invariant for empty string. This test is the one that catches
# the `${VAR:-default}` vs `${VAR-default}` bug: with `:-`, an empty
# string gets replaced by the default path and the hook silently
# pollutes whatever $HOME points at. With `-`, an empty string survives
# and the early-return fires.
echo "==> Test: TOUCHSTONE_REVIEW_LOG='' disables logging"
SKIPLOG_REPO8="$TEST_DIR/skiplog-repo8"
SKIPLOG_BIN8="$TEST_DIR/skiplog-bin8"
SKIPLOG_FAKEHOME8="$TEST_DIR/skiplog-fakehome8"
mkdir -p "$SKIPLOG_FAKEHOME8"
setup_skiplog_repo "$SKIPLOG_REPO8" --with-config-toml
make_skiplog_bin_with_conductor "$SKIPLOG_BIN8"

run_skiplog_hook "$SKIPLOG_REPO8" "$TEST_DIR/skiplog-out8.txt" \
  env PATH="$SKIPLOG_BIN8:/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$SKIPLOG_FAKEHOME8" \
      TOUCHSTONE_REVIEW_LOG="" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || { echo "FAIL: hook exited non-zero with TOUCHSTONE_REVIEW_LOG=''" >&2; cat "$TEST_DIR/skiplog-out8.txt" >&2; ERRORS=$((ERRORS + 1)); }

# Negative invariant — no log file should exist anywhere under the
# fake $HOME. The bug surfaces here: a `:-` expansion would substitute
# $HOME/.touchstone-review-log for the empty string and write to it.
if [ -e "$SKIPLOG_FAKEHOME8/.touchstone-review-log" ]; then
  echo "FAIL: TOUCHSTONE_REVIEW_LOG='' wrote to \$HOME/.touchstone-review-log" >&2
  echo "  (the \${VAR:-default} pattern silently re-defaults empty strings)" >&2
  ls -la "$SKIPLOG_FAKEHOME8/" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "==> PASS: TOUCHSTONE_REVIEW_LOG='' wrote nothing to \$HOME"
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all review hook assertions passed"
  exit 0
fi

echo "==> FAIL: $ERRORS review hook assertion(s) failed" >&2
exit 1
