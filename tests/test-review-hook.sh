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
unset CODEX_REVIEW_ASSIST CODEX_REVIEW_ASSIST_TIMEOUT CODEX_REVIEW_ASSIST_MAX_ROUNDS
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
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
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
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" >/dev/null
)

CODEX_CALL_COUNT="$(wc -l < "$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ]; then
  echo "==> PASS: default-branch push ran review"
else
  echo "FAIL: expected default-branch push to run review" >&2
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
if [ "$CODEX_CALL_COUNT" = "0" ] && grep -q 'skipping nested review' "$TEST_DIR/nested-review-output.txt"; then
  echo "==> PASS: nested review skipped"
else
  echo "FAIL: expected nested review to be skipped" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/nested-review-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook caches exact clean reviews"
rm -rf "$(git -C "$REPO_DIR" rev-parse --absolute-git-dir)/toolkit/codex-review-clean"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
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
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
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
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
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

# ==========================================================================
# Reviewer cascade tests
# ==========================================================================

CASCADE_REPO="$TEST_DIR/repo-cascade"
CASCADE_CALLS="$TEST_DIR/cascade-calls.txt"
CASCADE_OUTPUT="$TEST_DIR/cascade-output.txt"

setup_cascade_repo() {
  rm -rf "$CASCADE_REPO"
  mkdir -p "$CASCADE_REPO"
  git -C "$CASCADE_REPO" init >/dev/null 2>&1
  git -C "$CASCADE_REPO" config user.name "Toolkit Test"
  git -C "$CASCADE_REPO" config user.email "toolkit@example.com"
  printf 'base\n' > "$CASCADE_REPO/example.txt"
  git -C "$CASCADE_REPO" add example.txt
  git -C "$CASCADE_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >> "$CASCADE_REPO/example.txt"
  git -C "$CASCADE_REPO" add example.txt
  git -C "$CASCADE_REPO" commit -m "change" >/dev/null 2>&1
}

echo "==> Test: cascade selects first available reviewer"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude", "codex"]\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

CASCADE_BIN="$TEST_DIR/cascade-bin"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/claude" <<'CLEOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
printf '%s\n' "claude-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CLEOF
cat > "$CASCADE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/claude" "$CASCADE_BIN/codex"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'claude-called' "$CASCADE_CALLS" && ! grep -q 'codex-called' "$CASCADE_CALLS"; then
  echo "==> PASS: cascade selected claude (first available)"
else
  echo "FAIL: expected cascade to select claude as first reviewer" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: cascade skips unavailable reviewer"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude", "codex"]\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/codex"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'codex-called' "$CASCADE_CALLS" && grep -q 'Using reviewer: Codex' "$CASCADE_OUTPUT"; then
  echo "==> PASS: cascade skipped claude (unavailable), used codex"
else
  echo "FAIL: expected cascade to skip claude and use codex" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: cascade skips auth-failed reviewer"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude", "codex"]\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
# claude is installed but auth fails
cat > "$CASCADE_BIN/claude" <<'CLEOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 1; fi
printf '%s\n' "claude-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CLEOF
cat > "$CASCADE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/claude" "$CASCADE_BIN/codex"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'codex-called' "$CASCADE_CALLS" && ! grep -q 'claude-called' "$CASCADE_CALLS"; then
  echo "==> PASS: cascade skipped claude (auth failed), used codex"
else
  echo "FAIL: expected cascade to skip auth-failed claude and use codex" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)
ALL_UNAVAIL_EXIT=$?
set -e

if [ "$ALL_UNAVAIL_EXIT" -eq 0 ] \
  && grep -q 'No reviewer available' "$CASCADE_OUTPUT" \
  && grep -q 'claude: CLI not installed' "$CASCADE_OUTPUT" \
  && grep -q 'gemini: CLI not installed' "$CASCADE_OUTPUT"; then
  echo "==> PASS: all reviewers unavailable — exited 0 with diagnostics"
else
  echo "FAIL: expected exit 0 and diagnostics when all reviewers unavailable" >&2
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
cat > "$CASCADE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/codex"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if [ ! -s "$CASCADE_CALLS" ] && grep -q 'AI review disabled' "$CASCADE_OUTPUT"; then
  echo "==> PASS: review disabled by config skipped reviewer"
else
  echo "FAIL: expected enabled=false to skip reviewer" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: local reviewer command reads prompt from stdin"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["local"]\n'
  printf '[review.local]\ncommand = "local-reviewer"\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "local reviewer config" >/dev/null 2>&1

LOCAL_PROMPT_FILE="$TEST_DIR/local-review-prompt.txt"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/local-reviewer" <<'LREOF'
#!/usr/bin/env bash
cat > "$LOCAL_PROMPT_FILE"
printf 'local clean\n'
printf 'CODEX_REVIEW_CLEAN\n'
LREOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/local-reviewer"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    LOCAL_PROMPT_FILE="$LOCAL_PROMPT_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'Using reviewer: Local command' "$CASCADE_OUTPUT" \
  && grep -q 'Output contract' "$LOCAL_PROMPT_FILE"; then
  echo "==> PASS: local reviewer command received prompt on stdin"
else
  echo "FAIL: expected local reviewer to run with prompt on stdin" >&2
  cat "$CASCADE_OUTPUT" >&2
  sed -n '1,80p' "$LOCAL_PROMPT_FILE" >&2 || true
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: TOOLKIT_REVIEWER forces a specific reviewer"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude", "codex"]\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/claude" <<'CLEOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
printf '%s\n' "claude-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CLEOF
cat > "$CASCADE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/claude" "$CASCADE_BIN/codex"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    TOOLKIT_REVIEWER=codex \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'codex-called' "$CASCADE_CALLS" && ! grep -q 'claude-called' "$CASCADE_CALLS" \
  && grep -q 'Using reviewer: Codex' "$CASCADE_OUTPUT"; then
  echo "==> PASS: TOOLKIT_REVIEWER=codex forced codex despite claude being first"
else
  echo "FAIL: expected TOOLKIT_REVIEWER to force codex" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: TOOLKIT_REVIEWER hard-fails when reviewer unavailable"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
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
    TOOLKIT_REVIEWER=claude \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)
FORCED_UNAVAIL_EXIT=$?
set -e

if [ "$FORCED_UNAVAIL_EXIT" -eq 1 ] \
  && grep -q 'TOOLKIT_REVIEWER=claude' "$CASCADE_OUTPUT"; then
  echo "==> PASS: TOOLKIT_REVIEWER hard-failed when reviewer unavailable"
else
  echo "FAIL: expected exit 1 when TOOLKIT_REVIEWER names unavailable reviewer" >&2
  echo "exit code: $FORCED_UNAVAIL_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: missing [review] section defaults to codex"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/codex"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'codex-called' "$CASCADE_CALLS" && grep -q 'Using reviewer: Codex' "$CASCADE_OUTPUT"; then
  echo "==> PASS: missing [review] section defaulted to codex"
else
  echo "FAIL: expected missing [review] to default to codex" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: primary reviewer can request peer assistance"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude"]\n'
  printf '[review.assist]\nenabled = true\nhelpers = ["codex"]\ntimeout = 5\nmax_rounds = 1\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "assist config" >/dev/null 2>&1

ASSIST_CODEX_PROMPT="$TEST_DIR/assist-codex-prompt.txt"
ASSIST_CLAUDE_PROMPT="$TEST_DIR/assist-claude-prompt.txt"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/claude" <<'CLEOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
printf '%s\n' "claude-called" >> "$CASCADE_CALLS"
prompt="${@: -1}"
printf '%s' "$prompt" > "$ASSIST_CLAUDE_PROMPT"
if printf '%s' "$prompt" | grep -q 'Peer reviewer answer'; then
  printf 'peer answer considered\n'
  printf 'CODEX_REVIEW_CLEAN\n'
else
  printf 'TOOLKIT_HELP_REQUEST_BEGIN\n'
  printf 'question: Is this larger shell change safe on macOS?\n'
  printf 'context: focus on process cleanup and push hook behavior\n'
  printf 'TOOLKIT_HELP_REQUEST_END\n'
  printf 'CODEX_REVIEW_BLOCKED\n'
fi
CLEOF
cat > "$CASCADE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
prompt="${@: -1}"
printf '%s' "$prompt" > "$ASSIST_CODEX_PROMPT"
printf 'codex second opinion: no blocker found\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/claude" "$CASCADE_BIN/codex"
: > "$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    ASSIST_CLAUDE_PROMPT="$ASSIST_CLAUDE_PROMPT" \
    ASSIST_CODEX_PROMPT="$ASSIST_CODEX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

CLAUDE_ASSIST_CALLS="$(grep -c 'claude-called' "$CASCADE_CALLS" || true)"
CODEX_ASSIST_CALLS="$(grep -c 'codex-called' "$CASCADE_CALLS" || true)"
if [ "$CLAUDE_ASSIST_CALLS" = "2" ] \
  && [ "$CODEX_ASSIST_CALLS" = "1" ] \
  && grep -q 'Peer reviewer answer' "$ASSIST_CLAUDE_PROMPT" \
  && grep -q 'Is this larger shell change safe on macOS' "$ASSIST_CODEX_PROMPT" \
  && grep -q 'peer assists:   1' "$CASCADE_OUTPUT"; then
  echo "==> PASS: primary reviewer requested and used peer assistance"
else
  echo "FAIL: expected peer assistance round between claude and codex" >&2
  echo "calls:" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: claude adapter restricts tools in review-only mode"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude"]\n'
} > "$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

CLAUDE_ARGS_FILE="$TEST_DIR/claude-args.txt"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat > "$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$CASCADE_BIN/claude" <<'CLEOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
printf '%s\n' "$*" > "$CLAUDE_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CLEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/claude"

# Test review-only mode (no Edit/Write)
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CLAUDE_ARGS_FILE="$CLAUDE_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'Read,Grep,Glob,Bash' "$CLAUDE_ARGS_FILE" && ! grep -q 'Edit' "$CLAUDE_ARGS_FILE"; then
  echo "==> PASS: claude adapter used read-only tools in review-only mode"
else
  echo "FAIL: expected claude to use read-only tools in review-only mode" >&2
  cat "$CLAUDE_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

# Test auto-fix mode (includes Edit/Write)
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CLAUDE_ARGS_FILE="$CLAUDE_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'Edit,Write' "$CLAUDE_ARGS_FILE"; then
  echo "==> PASS: claude adapter included Edit,Write tools in auto-fix mode"
else
  echo "FAIL: expected claude to include Edit,Write tools when autofix enabled" >&2
  cat "$CLAUDE_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

# ==========================================================================
# Mode enforcement tests
# ==========================================================================

MODE_REPO="$TEST_DIR/repo-mode"
MODE_OUTPUT="$TEST_DIR/mode-output.txt"
CODEX_ARGS_FILE="$TEST_DIR/codex-args.txt"

setup_mode_repo() {
  rm -rf "$MODE_REPO"
  mkdir -p "$MODE_REPO"
  git -C "$MODE_REPO" init >/dev/null 2>&1
  git -C "$MODE_REPO" config user.name "Toolkit Test"
  git -C "$MODE_REPO" config user.email "toolkit@example.com"
  printf 'base\n' > "$MODE_REPO/example.txt"
  git -C "$MODE_REPO" add example.txt
  git -C "$MODE_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >> "$MODE_REPO/example.txt"
  git -C "$MODE_REPO" add example.txt
  git -C "$MODE_REPO" commit -m "change" >/dev/null 2>&1
}

echo "==> Test: codex adapter uses --sandbox read-only in review-only mode"
setup_mode_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
} > "$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "config" >/dev/null 2>&1

MODE_BIN="$TEST_DIR/mode-bin"
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat > "$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$MODE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/codex"

(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
)

if grep -q -- '--sandbox read-only' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: codex used --sandbox read-only in review-only mode"
else
  echo "FAIL: expected codex to use --sandbox read-only in review-only mode" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: codex adapter uses --sandbox workspace-write in fix mode"
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=fix \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
)

if grep -q -- '--sandbox workspace-write' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: codex used --sandbox workspace-write in fix mode"
else
  echo "FAIL: expected codex to use --sandbox workspace-write in fix mode" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: claude adapter restricts to Read,Grep,Glob in diff-only mode"
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat > "$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$MODE_BIN/claude" <<'CLEOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
printf '%s\n' "$*" > "$CLAUDE_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CLEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/claude"

{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude"]\n'
} > "$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "claude config" >/dev/null 2>&1

(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CLAUDE_ARGS_FILE="$CLAUDE_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=diff-only \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
)

if grep -q 'Read,Grep,Glob' "$CLAUDE_ARGS_FILE" \
  && ! grep -q 'Bash' "$CLAUDE_ARGS_FILE" \
  && ! grep -q 'Edit' "$CLAUDE_ARGS_FILE"; then
  echo "==> PASS: claude restricted to Read,Grep,Glob in diff-only mode"
else
  echo "FAIL: expected claude to use only Read,Grep,Glob in diff-only mode" >&2
  cat "$CLAUDE_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: CODEX_REVIEW_NO_AUTOFIX backward compat maps to review-only"
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat > "$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat > "$MODE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/codex"

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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
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
cat > "$MODE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf 'CODEX_REVIEW_FIXED\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/codex"

set +e
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
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
cat > "$MODE_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/codex"

(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=invalid \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$MODE_OUTPUT" 2>&1
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
  git -C "$TIMEOUT_REPO" config user.name "Toolkit Test"
  git -C "$TIMEOUT_REPO" config user.email "toolkit@example.com"
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
cat > "$TIMEOUT_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/codex"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_TIMEOUT=13 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
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
cat > "$TIMEOUT_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
sleep 999 &
child_pid=$!
printf '%s\n' "$$" > "$TIMEOUT_PID_FILE"
printf '%s\n' "$child_pid" > "$TIMEOUT_CHILD_PID_FILE"
wait "$child_pid"
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/codex"
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
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
cat > "$TIMEOUT_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
exit 1
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/codex"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
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
cat > "$TIMEOUT_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
echo "no sentinel here"
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/codex"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$TIMEOUT_OUTPUT" 2>&1
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
  git -C "$CTX_REPO" config user.name "Toolkit Test"
  git -C "$CTX_REPO" config user.email "toolkit@example.com"
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
  cat > "$CTX_BIN/codex" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then exit 0; fi
prompt="${@: -1}"
printf '%s' "$prompt" > "$CTX_PROMPT"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
  chmod +x "$CTX_BIN/gh" "$CTX_BIN/codex"
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
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
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CTX_OUTPUT" 2>&1
)

if [ -f "$JSON_SUMMARY" ] \
  && grep -q '"exit_reason":"clean"' "$JSON_SUMMARY" \
  && grep -q '"reviewer":"Codex"' "$JSON_SUMMARY"; then
  echo "==> PASS: JSON summary file written"
else
  echo "FAIL: expected JSON summary file" >&2
  cat "$JSON_SUMMARY" 2>/dev/null >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all review hook assertions passed"
  exit 0
fi

echo "==> FAIL: $ERRORS review hook assertion(s) failed" >&2
exit 1
