#!/usr/bin/env bash
#
# tests/test-review-hook.sh — verify the hook parses multiline unsafe_paths.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t toolkit-test-review-hook.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

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
unset CODEX_REVIEW_IN_PROGRESS

mkdir -p "$REPO_DIR" "$FAKE_BIN"
git -C "$REPO_DIR" init >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Toolkit Test"
git -C "$REPO_DIR" config user.email "toolkit@example.com"

cp "$TOOLKIT_ROOT/.codex-review.toml" "$REPO_DIR/.codex-review.toml"
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

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="${@: -1}"
printf '%s' "$prompt" > "$PROMPT_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/codex"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PROMPT_FILE="$PROMPT_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" >/dev/null
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
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >> "$CODEX_CALLS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/codex"
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$TEST_DIR/feature-push-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "0" ] && grep -q 'skipping push to feature/test' "$TEST_DIR/feature-push-output.txt"; then
  echo "==> PASS: feature-branch push skipped Codex"
else
  echo "FAIL: expected feature-branch push to skip Codex" >&2
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" >/dev/null
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ]; then
  echo "==> PASS: default-branch push ran Codex"
else
  echo "FAIL: expected default-branch push to run Codex" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$TEST_DIR/nested-review-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "0" ] && grep -q 'skipping nested Codex review' "$TEST_DIR/nested-review-output.txt"; then
  echo "==> PASS: nested Codex review skipped"
else
  echo "FAIL: expected nested Codex review to skip Codex" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/nested-review-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook caches exact clean reviews"
rm -rf "$(git -C "$REPO_DIR" rev-parse --absolute-git-dir)/toolkit/codex-review-clean"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >> "$CODEX_CALLS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/codex"
: > "$CODEX_CALLS_FILE"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" >/dev/null
)

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CACHE_OUTPUT" 2>&1
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ] && grep -q 'previously passed for this exact diff' "$CACHE_OUTPUT"; then
  echo "==> PASS: clean review cache skipped the repeated Codex call"
else
  echo "FAIL: expected clean review cache to skip the repeated Codex call" >&2
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" >/dev/null
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "2" ]; then
  echo "==> PASS: CODEX_REVIEW_DISABLE_CACHE forces a fresh review"
else
  echo "FAIL: expected CODEX_REVIEW_DISABLE_CACHE to force a fresh review" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook preserves # inside quoted unsafe_paths"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="${@: -1}"
printf '%s' "$prompt" > "$PROMPT_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/codex"
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" >/dev/null
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
git -C "$REPO_UNSAFE" config user.name "Toolkit Test"
git -C "$REPO_UNSAFE" config user.email "toolkit@example.com"
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

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex edit\n' >> bootstrap/new-project.sh
printf 'fixed unsafe path\n'
printf 'CODEX_REVIEW_FIXED\n'
EOF
chmod +x "$FAKE_BIN/codex"

BEFORE_HEAD="$(git -C "$REPO_UNSAFE" rev-parse HEAD)"
set +e
(
  cd "$REPO_UNSAFE"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$UNSAFE_OUTPUT" 2>&1
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

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all review hook assertions passed"
  exit 0
fi

echo "==> FAIL: $ERRORS review hook assertion(s) failed" >&2
exit 1
