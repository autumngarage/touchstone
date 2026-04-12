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
    CODEX_REVIEW_NO_AUTOFIX=1 \
    bash "$TOOLKIT_ROOT/hooks/codex-review.sh" > "$CASCADE_OUTPUT" 2>&1
)

if grep -q 'Read,Grep,Glob,Bash' "$CLAUDE_ARGS_FILE" && ! grep -q 'Edit' "$CLAUDE_ARGS_FILE"; then
  echo "==> PASS: claude adapter used read-only tools in review-only mode"
else
  echo "FAIL: expected claude to use read-only tools when NO_AUTOFIX is set" >&2
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

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all review hook assertions passed"
  exit 0
fi

echo "==> FAIL: $ERRORS review hook assertion(s) failed" >&2
exit 1
