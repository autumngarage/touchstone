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

setup_test_repo() {
  local dir="$1"
  mkdir -p "$dir/lib"
  git -C "$dir" init -q >/dev/null 2>&1
  git -C "$dir" config user.name "Touchstone Test"
  git -C "$dir" config user.email "touchstone@example.com"
  cp -r "$TOUCHSTONE_ROOT/lib/"* "$dir/lib/"
  git -C "$dir" add lib/
}

unset PRE_COMMIT
unset PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF
unset PRE_COMMIT_LOCAL_BRANCH PRE_COMMIT_REMOTE_BRANCH
unset PRE_COMMIT_REMOTE_NAME PRE_COMMIT_REMOTE_URL
unset CODEX_REVIEW_BASE CODEX_REVIEW_ENABLED CODEX_REVIEW_FORCE
unset CODEX_REVIEW_MODE CODEX_REVIEW_NO_AUTOFIX CODEX_REVIEW_DISABLE_CACHE
unset CODEX_REVIEW_TIMEOUT CODEX_REVIEW_ON_ERROR CODEX_REVIEW_CONTEXT_MODE
unset CODEX_REVIEW_CONTEXT_SMALL_MAX_DIFF_LINES CODEX_REVIEW_CONTEXT_SMALL_MAX_FILES
unset CODEX_REVIEW_ASSIST CODEX_REVIEW_ASSIST_TIMEOUT CODEX_REVIEW_ASSIST_MAX_ROUNDS
unset CODEX_REVIEW_IN_PROGRESS
unset TOUCHSTONE_CONDUCTOR_WITH TOUCHSTONE_CONDUCTOR_PREFER
unset TOUCHSTONE_CONDUCTOR_EFFORT TOUCHSTONE_CONDUCTOR_TAGS TOUCHSTONE_CONDUCTOR_EXCLUDE
unset TOUCHSTONE_PREFLIGHT_ALREADY_RAN TOUCHSTONE_REVIEWER
unset TOUCHSTONE_NO_PREFLIGHT TOUCHSTONE_NO_AUTO_UPDATE

codex() {
  if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
    if [ "${CODEX_LOGIN_STATUS:-}" = "status-failed" ]; then
      return 1
    fi
    printf '%s\n' "${CODEX_LOGIN_STATUS:-Logged in using ChatGPT}"
    return 0
  fi
  printf 'unexpected Codex command: %s\n' "$*" >&2
  return 99
}
export -f codex

mkdir -p "$FAKE_BIN"
setup_test_repo "$REPO_DIR"

cp "$TOUCHSTONE_ROOT/.touchstone-review.toml" "$REPO_DIR/.codex-review.toml"
printf 'base\n' >"$REPO_DIR/example.txt"
git -C "$REPO_DIR" add .codex-review.toml example.txt
git -C "$REPO_DIR" commit -m "base" >/dev/null 2>&1

printf 'changed\n' >>"$REPO_DIR/example.txt"
git -C "$REPO_DIR" add example.txt
git -C "$REPO_DIR" commit -m "change" >/dev/null 2>&1

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "main"
EOF

cat >"$FAKE_BIN/conductor" <<'EOF'
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
    CODEX_REVIEW_CONTEXT_MODE=full \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=fix \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)

if grep -q -- '- Anything in bootstrap/new-project.sh' "$PROMPT_FILE" \
  && grep -q -- '- Anything in bootstrap/update-project.sh' "$PROMPT_FILE" \
  && grep -q -- '- Anything in bootstrap/sync-all.sh' "$PROMPT_FILE" \
  && grep -q -- '- Anything in hooks/codex-review.sh' "$PROMPT_FILE" \
  && grep -q -- '- Anything in templates/' "$PROMPT_FILE" \
  && grep -q -- 'Deterministic preflight already passed for this diff before the live review' "$PROMPT_FILE" \
  && grep -q -- 'Do not rerun the full preflight' "$PROMPT_FILE"; then
  echo "==> PASS: multiline unsafe_paths were included in the Codex prompt"
else
  echo "FAIL: expected unsafe_paths and preflight guidance to appear in the generated prompt" >&2
  sed -n '1,120p' "$PROMPT_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook sources helper libraries from script install path"
NO_LIB_REPO="$TEST_DIR/no-lib-repo"
NO_LIB_OUTPUT="$TEST_DIR/no-lib-output.txt"
mkdir -p "$NO_LIB_REPO"
git -C "$NO_LIB_REPO" init -q >/dev/null 2>&1
git -C "$NO_LIB_REPO" config user.name "Touchstone Test"
git -C "$NO_LIB_REPO" config user.email "touchstone@example.com"
cat >"$NO_LIB_REPO/.codex-review.toml" <<'EOF'
[review]
enabled = false
EOF
printf 'base\n' >"$NO_LIB_REPO/example.txt"
git -C "$NO_LIB_REPO" add .codex-review.toml example.txt
git -C "$NO_LIB_REPO" commit -m "base" >/dev/null 2>&1
printf 'changed\n' >>"$NO_LIB_REPO/example.txt"
git -C "$NO_LIB_REPO" add example.txt
git -C "$NO_LIB_REPO" commit -m "change" >/dev/null 2>&1

if (
  cd "$NO_LIB_REPO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$NO_LIB_OUTPUT" 2>&1
) && grep -q 'AI review disabled' "$NO_LIB_OUTPUT"; then
  echo "==> PASS: hook parsed config without repo-local lib/toml.sh"
else
  echo "FAIL: hook should source lib/toml.sh relative to its install path" >&2
  cat "$NO_LIB_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook skips feature-branch pushes but runs default-branch pushes"
cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'called\n' >> "$CODEX_CALLS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/conductor"
: >"$CODEX_CALLS_FILE"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    PRE_COMMIT=1 \
    PRE_COMMIT_LOCAL_BRANCH="refs/heads/feature/test" \
    PRE_COMMIT_REMOTE_BRANCH="refs/heads/feature/test" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TEST_DIR/feature-push-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
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

CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
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
mkdir -p "$FIRSTPUSH_REPO" "$FIRSTPUSH_REPO/lib"
git -C "$FIRSTPUSH_REPO" init -b main >/dev/null 2>&1
git -C "$FIRSTPUSH_REPO" config user.name "Touchstone Test"
git -C "$FIRSTPUSH_REPO" config user.email "touchstone@example.com"
cp "$TOUCHSTONE_ROOT/.touchstone-review.toml" "$FIRSTPUSH_REPO/.touchstone-review.toml"
cp -r "$TOUCHSTONE_ROOT/lib/"* "$FIRSTPUSH_REPO/lib/"
printf 'scaffold\n' >"$FIRSTPUSH_REPO/README.md"
git -C "$FIRSTPUSH_REPO" add .touchstone-review.toml README.md
git -C "$FIRSTPUSH_REPO" commit -m "initial scaffold" >/dev/null 2>&1

: >"$CODEX_CALLS_FILE"
(
  cd "$FIRSTPUSH_REPO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    PRE_COMMIT=1 \
    PRE_COMMIT_LOCAL_BRANCH="refs/heads/main" \
    PRE_COMMIT_REMOTE_BRANCH="refs/heads/main" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$FIRSTPUSH_OUTPUT" 2>&1
)

CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
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
printf 'second\n' >>"$FIRSTPUSH_REPO/README.md"
git -C "$FIRSTPUSH_REPO" add README.md
git -C "$FIRSTPUSH_REPO" commit -m "second commit" >/dev/null 2>&1

: >"$CODEX_CALLS_FILE"
(
  cd "$FIRSTPUSH_REPO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    PRE_COMMIT=1 \
    PRE_COMMIT_LOCAL_BRANCH="refs/heads/main" \
    PRE_COMMIT_REMOTE_BRANCH="refs/heads/main" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TEST_DIR/firstpush-second-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ] \
  && ! grep -q 'first push on a fresh scaffold' "$TEST_DIR/firstpush-second-output.txt"; then
  echo "==> PASS: second-commit push on default branch ran review (first-push exemption did not misfire)"
else
  echo "FAIL: expected second-commit push to run review, not skip" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/firstpush-second-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook skips nested Conductor review subprocesses"
: >"$CODEX_CALLS_FILE"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_IN_PROGRESS=1 \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TEST_DIR/nested-review-output.txt" 2>&1
)

CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "0" ] && grep -q 'skipping nested review' "$TEST_DIR/nested-review-output.txt"; then
  echo "==> PASS: nested review skipped"
else
  echo "FAIL: expected nested review to be skipped" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/nested-review-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: Conductor reviewer inherits nested review guard"
CONDUCTOR_ENV_FILE="$TEST_DIR/conductor-env.txt"
cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
cat >/dev/null
printf '%s\n' "${CODEX_REVIEW_IN_PROGRESS:-}" >"$CONDUCTOR_ENV_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/conductor"
rm -f "$CONDUCTOR_ENV_FILE"

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ENV_FILE="$CONDUCTOR_ENV_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TEST_DIR/conductor-env-output.txt" 2>&1
)

if [ "$(cat "$CONDUCTOR_ENV_FILE" 2>/dev/null || true)" = "1" ]; then
  echo "==> PASS: Conductor receives CODEX_REVIEW_IN_PROGRESS=1"
else
  echo "FAIL: expected Conductor to inherit CODEX_REVIEW_IN_PROGRESS=1" >&2
  cat "$TEST_DIR/conductor-env-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook serializes duplicate top-level review gates"
cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
cat >/dev/null
printf 'called\n' >>"$CODEX_CALLS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/conductor"
LOCK_DIR="$(git -C "$REPO_DIR" rev-parse --absolute-git-dir)/touchstone/codex-review.lock"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
{
  printf 'pid=%s\n' "$$"
  printf 'started_at_epoch=%s\n' "$(date +%s)"
  printf 'branch=main\n'
  printf 'base=HEAD~1\n'
  printf 'head=%s\n' "$(git -C "$REPO_DIR" rev-parse HEAD)"
} >"$LOCK_DIR/metadata"
: >"$CODEX_CALLS_FILE"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_LOCK_WAIT_SECONDS=0 \
    CODEX_REVIEW_ON_ERROR=fail-open \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TEST_DIR/lock-busy-output.txt" 2>&1
)
CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "0" ] \
  && grep -q 'Another Touchstone review gate is already running' "$TEST_DIR/lock-busy-output.txt" \
  && grep -q 'review lock busy' "$TEST_DIR/lock-busy-output.txt"; then
  echo "==> PASS: active review lock prevented duplicate review work"
else
  echo "FAIL: active review lock should prevent duplicate review work" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/lock-busy-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
{
  printf 'pid=999999\n'
  printf 'started_at_epoch=%s\n' "$(date +%s)"
  printf 'branch=main\n'
  printf 'base=HEAD~1\n'
  printf 'head=%s\n' "$(git -C "$REPO_DIR" rev-parse HEAD)"
} >"$LOCK_DIR/metadata"
: >"$CODEX_CALLS_FILE"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TEST_DIR/lock-stale-output.txt" 2>&1
)
CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "1" ] \
  && grep -q 'Removing stale review lock' "$TEST_DIR/lock-stale-output.txt"; then
  echo "==> PASS: stale review lock was removed and review proceeded"
else
  echo "FAIL: stale review lock should be removed before reviewing" >&2
  echo "codex call count: $CODEX_CALL_COUNT" >&2
  cat "$TEST_DIR/lock-stale-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi
rm -rf "$LOCK_DIR"

echo "==> Test: review hook caches exact clean reviews"
rm -rf "$(git -C "$REPO_DIR" rev-parse --absolute-git-dir)/touchstone/codex-review-clean"
cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'called\n' >> "$CODEX_CALLS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$FAKE_BIN/conductor"
: >"$CODEX_CALLS_FILE"

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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CACHE_OUTPUT" 2>&1
)

CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
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

CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
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
CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
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
CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
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
CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "4" ]; then
  echo "==> PASS: TOUCHSTONE_CONDUCTOR_EFFORT change invalidated cache"
else
  echo "FAIL: expected fresh review after TOUCHSTONE_CONDUCTOR_EFFORT change" >&2
  echo "codex call count: $CODEX_CALL_COUNT (expected 4)" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: changing prompt context mode invalidates the cache"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_CONTEXT_MODE=full \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)
CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "5" ]; then
  echo "==> PASS: CODEX_REVIEW_CONTEXT_MODE=full invalidated bounded-context cache"
else
  echo "FAIL: expected fresh review after context mode changed to full" >&2
  echo "codex call count: $CODEX_CALL_COUNT (expected 5)" >&2
  ERRORS=$((ERRORS + 1))
fi

(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_CALLS_FILE="$CODEX_CALLS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_CONTEXT_MODE=full \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >/dev/null
)
CODEX_CALL_COUNT="$(wc -l <"$CODEX_CALLS_FILE" | tr -d ' ')"
if [ "$CODEX_CALL_COUNT" = "5" ]; then
  echo "==> PASS: repeated full-context review hit its own cache entry"
else
  echo "FAIL: expected repeated full-context review to hit cache" >&2
  echo "codex call count: $CODEX_CALL_COUNT (expected 5)" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review hook preserves # inside quoted unsafe_paths"
cat >"$FAKE_BIN/conductor" <<'EOF'
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
} >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "quoted unsafe paths" >/dev/null 2>&1
printf 'changed again\n' >>"$REPO_DIR/example.txt"
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

echo "==> Test: review hook refuses to auto-commit unsafe directory fixes"
mkdir -p "$REPO_UNSAFE/templates"
setup_test_repo "$REPO_UNSAFE"
{
  printf '[codex_review]\n'
  printf 'safe_by_default = true\n'
  printf 'unsafe_paths = ["templates/"]\n'
} >"$REPO_UNSAFE/.codex-review.toml"
printf 'base\n' >"$REPO_UNSAFE/templates/AGENTS.md"
printf 'base\n' >"$REPO_UNSAFE/example.txt"
git -C "$REPO_UNSAFE" add .codex-review.toml templates/AGENTS.md example.txt
git -C "$REPO_UNSAFE" commit -m "base" >/dev/null 2>&1
printf 'changed\n' >>"$REPO_UNSAFE/example.txt"
git -C "$REPO_UNSAFE" add example.txt
git -C "$REPO_UNSAFE" commit -m "change" >/dev/null 2>&1

UNSAFE_FIX_STATE="$TEST_DIR/unsafe-fix-state"
rm -f "$UNSAFE_FIX_STATE"
cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
case "${1:-}" in
  review)
    printf -- '- templates/AGENTS.md:1 — [fixable] unsafe path edit requested\n'
    printf 'CODEX_REVIEW_BLOCKED\n'
    ;;
  exec)
    printf 'codex edit\n' >> templates/AGENTS.md
    touch "$UNSAFE_FIX_STATE"
    printf 'fixed unsafe path\n'
    printf 'CODEX_REVIEW_FIXED\n'
    ;;
esac
EOF
chmod +x "$FAKE_BIN/conductor"

BEFORE_HEAD="$(git -C "$REPO_UNSAFE" rev-parse HEAD)"
set +e
(
  cd "$REPO_UNSAFE"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    UNSAFE_FIX_STATE="$UNSAFE_FIX_STATE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$UNSAFE_OUTPUT" 2>&1
)
UNSAFE_EXIT=$?
set -e
AFTER_HEAD="$(git -C "$REPO_UNSAFE" rev-parse HEAD)"

if [ "$UNSAFE_EXIT" -eq 1 ] \
  && [ "$BEFORE_HEAD" = "$AFTER_HEAD" ] \
  && grep -q 'not allowed' "$UNSAFE_OUTPUT" \
  && grep -q 'templates/AGENTS.md' "$UNSAFE_OUTPUT"; then
  echo "==> PASS: unsafe auto-fix was blocked before commit"
else
  echo "FAIL: expected unsafe auto-fix to be blocked without creating a commit" >&2
  cat "$UNSAFE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: blocked review persists alternate finding formats"
PARSER_REPO="$TEST_DIR/repo-parser"
PARSER_BIN="$TEST_DIR/parser-bin"
PARSER_OUTPUT="$TEST_DIR/parser-output.txt"
rm -rf "$PARSER_BIN"
mkdir -p "$PARSER_BIN"
setup_test_repo "$PARSER_REPO"
printf 'base\n' >"$PARSER_REPO/example.txt"
git -C "$PARSER_REPO" add example.txt
git -C "$PARSER_REPO" commit -m "base" >/dev/null 2>&1
printf 'changed\n' >>"$PARSER_REPO/example.txt"
git -C "$PARSER_REPO" add example.txt
git -C "$PARSER_REPO" commit -m "change" >/dev/null 2>&1
cat >"$PARSER_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$PARSER_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '1. example.txt:2 - numbered failure\n'
printf '### Finding 2\n'
printf 'heading-only detail survived\n'
printf 'CODEX_REVIEW_BLOCKED\n'
EOF
chmod +x "$PARSER_BIN/gh" "$PARSER_BIN/conductor"

set +e
(
  cd "$PARSER_REPO"
  PATH="$PARSER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_BRANCH_NAME="feature/parser" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$PARSER_OUTPUT" 2>&1
)
PARSER_EXIT=$?
set -e
PARSER_FINDINGS_FILE="$PARSER_REPO/.git/touchstone/reviewer-findings/feature_parser.findings"
PARSER_HISTORY_FILE="$PARSER_REPO/.git/touchstone/reviewer-findings-history/feature_parser.jsonl"
if [ "$PARSER_EXIT" -eq 1 ] \
  && grep -q 'findings:       2' "$PARSER_OUTPUT" \
  && grep -q -- '- example.txt:2 - numbered failure' "$PARSER_FINDINGS_FILE" \
  && grep -q -- '- Finding 2 - heading-only detail survived' "$PARSER_FINDINGS_FILE" \
  && grep -q '"findings_count":2' "$PARSER_HISTORY_FILE"; then
  echo "==> PASS: alternate finding formats were normalized and persisted"
else
  echo "FAIL: expected alternate finding formats to be actionable" >&2
  echo "exit code: $PARSER_EXIT" >&2
  cat "$PARSER_OUTPUT" >&2
  [ -f "$PARSER_FINDINGS_FILE" ] && cat "$PARSER_FINDINGS_FILE" >&2
  [ -f "$PARSER_HISTORY_FILE" ] && cat "$PARSER_HISTORY_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

# ==========================================================================
# Conductor reviewer tests (Touchstone 2.0+). The v1.x multi-reviewer
# cascade tests were retired when the single `conductor` adapter shipped;
# cross-provider selection now requires an explicit Conductor auto-route opt-in.
# ==========================================================================

CASCADE_REPO="$TEST_DIR/repo-cascade"
CASCADE_BIN="$TEST_DIR/cascade-bin"
CASCADE_CALLS="$TEST_DIR/cascade-calls.txt"
CASCADE_OUTPUT="$TEST_DIR/cascade-output.txt"

# Mode-specific fixtures — reused by the REVIEW_MODE + timeout + error
# tests below. These tests capture conductor's argv so we can assert that
# Touchstone translates REVIEW_MODE into the expected Conductor subcommand
# and --tools flags.
MODE_REPO="$TEST_DIR/repo-mode"
MODE_BIN="$TEST_DIR/mode-bin"
MODE_OUTPUT="$TEST_DIR/mode-output.txt"
CODEX_ARGS_FILE="$TEST_DIR/conductor-args.txt"

setup_cascade_repo() {
  rm -rf "$CASCADE_REPO"
  setup_test_repo "$CASCADE_REPO"
  printf 'base\n' >"$CASCADE_REPO/example.txt"
  git -C "$CASCADE_REPO" add example.txt
  git -C "$CASCADE_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >>"$CASCADE_REPO/example.txt"
  git -C "$CASCADE_REPO" add example.txt
  git -C "$CASCADE_REPO" commit -m "change" >/dev/null 2>&1
}

setup_mode_repo() {
  rm -rf "$MODE_REPO"
  setup_test_repo "$MODE_REPO"
  printf 'base\n' >"$MODE_REPO/example.txt"
  git -C "$MODE_REPO" add example.txt
  git -C "$MODE_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >>"$MODE_REPO/example.txt"
  git -C "$MODE_REPO" add example.txt
  git -C "$MODE_REPO" commit -m "change" >/dev/null 2>&1
}

echo "==> Test: all reviewers unavailable exits 0 with diagnostics"
setup_cascade_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
  printf '[review]\nreviewers = ["claude", "gemini"]\n'
} >"$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "config" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
chmod +x "$CASCADE_BIN/gh"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_BIN=missing-conductor \
    CODEX_REVIEW_BASE="HEAD~1" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
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

echo "==> Test: provider unavailable fails closed with zero-findings status"
setup_cascade_repo
NO_PROVIDER_SUMMARY="$TEST_DIR/no-provider-summary.json"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$CASCADE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then
  printf '{"providers":[{"configured":false}]}\n'
  exit 0
fi
printf 'unexpected invocation\n' >&2
exit 99
EOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    CODEX_REVIEW_SUMMARY_FILE="$NO_PROVIDER_SUMMARY" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
)
NO_PROVIDER_EXIT=$?
set -e

if [ "$NO_PROVIDER_EXIT" -eq 1 ] \
  && grep -q 'provider/infrastructure unavailable; findings=0; exit_reason=provider-unavailable' "$CASCADE_OUTPUT" \
  && grep -q '\[fail-closed:FAIL_OPEN_PROVIDER_UNAVAILABLE\]' "$CASCADE_OUTPUT" \
  && grep -q '"findings":0' "$NO_PROVIDER_SUMMARY" \
  && grep -q '"review_status":"review_not_completed"' "$NO_PROVIDER_SUMMARY" \
  && grep -q '"exit_reason":"provider-unavailable"' "$NO_PROVIDER_SUMMARY"; then
  echo "==> PASS: provider unavailable failed closed with explicit zero-findings status"
else
  echo "FAIL: expected provider-unavailable fail-closed status and summary" >&2
  echo "exit code: $NO_PROVIDER_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  [ -f "$NO_PROVIDER_SUMMARY" ] && cat "$NO_PROVIDER_SUMMARY" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: pinned route auth allows merge review when doctor misses provider"
setup_cascade_repo
rm -f "$CASCADE_CALLS"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$CASCADE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  doctor)
    printf '{"providers":[{"configured":false}]}\n'
    ;;
  route)
    if [ "${2:-}" = "--help" ]; then
      exit 0
    fi
    printf 'route %s\n' "$*" >>"$CASCADE_CALLS"
    printf '{"selected_provider":"openrouter"}\n'
    ;;
  review)
    printf 'review %s\n' "$*" >>"$CASCADE_CALLS"
    cat >/dev/null
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    printf 'unexpected conductor command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    CODEX_REVIEW_PR_NUMBER=123 \
    TOUCHSTONE_CONDUCTOR_WITH=openrouter \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
)
ROUTE_AUTH_EXIT=$?
set -e

if [ "$ROUTE_AUTH_EXIT" -eq 0 ] \
  && grep -q '^route .*--kind review .*--with openrouter' "$CASCADE_CALLS" \
  && [ -z "$(awk '/^route / && /--estimated-input-tokens/ && !/--with openrouter/ { print }' "$CASCADE_CALLS")" ] \
  && grep -q '^review .*--with openrouter' "$CASCADE_CALLS" \
  && ! grep -q 'No reviewer available' "$CASCADE_OUTPUT"; then
  echo "==> PASS: pinned route auth allowed review despite doctor miss"
else
  echo "FAIL: expected pinned route auth to allow the review" >&2
  echo "exit code: $ROUTE_AUTH_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  [ -f "$CASCADE_CALLS" ] && cat "$CASCADE_CALLS" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: merge review route preflight accepts viable auto route"
setup_cascade_repo
rm -f "$CASCADE_CALLS"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$CASCADE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  doctor)
    printf '{"providers":[{"configured":true}]}\n'
    ;;
  route)
    if [ "${2:-}" = "--help" ]; then
      exit 0
    fi
    printf 'route %s\n' "$*" >>"$CASCADE_CALLS"
    printf '{"provider":"openrouter"}\n'
    ;;
  review)
    printf 'review %s\n' "$*" >>"$CASCADE_CALLS"
    cat >/dev/null
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    printf 'unexpected conductor command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    CODEX_REVIEW_PR_NUMBER=123 \
    TOUCHSTONE_CONDUCTOR_WITH=auto \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
)
ROUTE_VIABLE_EXIT=$?
set -e

if [ "$ROUTE_VIABLE_EXIT" -eq 0 ] \
  && grep -q 'Review route preflight: mode=fix' "$CASCADE_OUTPUT" \
  && grep -q 'review route viable via openrouter' "$CASCADE_OUTPUT" \
  && grep -q 'fix route viable via openrouter' "$CASCADE_OUTPUT" \
  && grep -q '^route .*--kind review' "$CASCADE_CALLS" \
  && grep -q '^route .*--kind exec' "$CASCADE_CALLS" \
  && grep -q '^review .*--with openrouter' "$CASCADE_CALLS"; then
  echo "==> PASS: merge route preflight pinned the viable auto route"
else
  echo "FAIL: expected viable route preflight to pin the live review provider" >&2
  echo "exit code: $ROUTE_VIABLE_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  [ -f "$CASCADE_CALLS" ] && cat "$CASCADE_CALLS" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: merge review fallback clears preflight provider pin"
setup_cascade_repo
rm -f "$CASCADE_CALLS"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$CASCADE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  doctor)
    printf '{"providers":[{"configured":true}]}\n'
    ;;
  route)
    if [ "${2:-}" = "--help" ]; then
      exit 0
    fi
    printf 'route %s\n' "$*" >>"$CASCADE_CALLS"
    printf '{"provider":"claude"}\n'
    ;;
  review)
    printf 'review %s\n' "$*" >>"$CASCADE_CALLS"
    review_count="$(grep -c '^review ' "$CASCADE_CALLS" 2>/dev/null | tr -d ' ')"
    cat >/dev/null
    if [ "$review_count" = "1" ]; then
      printf '[conductor] review tried providers: claude (provider unavailable)\n' >&2
      exit 42
    fi
    printf '[conductor] review tried providers: openrouter (success)\n' >&2
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    printf 'unexpected conductor command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    CODEX_REVIEW_PR_NUMBER=123 \
    TOUCHSTONE_CONDUCTOR_WITH=auto \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=true \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
)
ROUTE_FALLBACK_EXIT=$?
set -e

ROUTE_FALLBACK_FIRST_REVIEW="$(grep '^review ' "$CASCADE_CALLS" | sed -n '1p')"
ROUTE_FALLBACK_SECOND_REVIEW="$(grep '^review ' "$CASCADE_CALLS" | sed -n '2p')"
if [ "$ROUTE_FALLBACK_EXIT" -eq 0 ] \
  && printf '%s\n' "$ROUTE_FALLBACK_FIRST_REVIEW" | grep -q -- '--with claude' \
  && ! printf '%s\n' "$ROUTE_FALLBACK_SECOND_REVIEW" | grep -q -- '--with claude' \
  && printf '%s\n' "$ROUTE_FALLBACK_SECOND_REVIEW" | grep -q -- '--exclude ollama,claude' \
  && grep -q 'fallback:       claude -> openrouter (reviewer exit 42)' "$CASCADE_OUTPUT"; then
  echo "==> PASS: fallback cleared the preflight provider pin"
else
  echo "FAIL: expected fallback retry to escape the preflight-pinned provider" >&2
  echo "exit code: $ROUTE_FALLBACK_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  [ -f "$CASCADE_CALLS" ] && cat "$CASCADE_CALLS" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: merge review route preflight fails when exclusions leave no provider"
setup_cascade_repo
rm -f "$CASCADE_CALLS"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$CASCADE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  doctor)
    printf '{"providers":[{"configured":true}]}\n'
    ;;
  route)
    if [ "${2:-}" = "--help" ]; then
      exit 0
    fi
    printf 'route %s\n' "$*" >>"$CASCADE_CALLS"
    printf '{"error":"no provider satisfies the routing request after planning exclusions"}\n'
    exit 2
    ;;
  review)
    printf 'review should not run\n' >>"$CASCADE_CALLS"
    exit 99
    ;;
  *)
    printf 'unexpected conductor command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    CODEX_REVIEW_PR_NUMBER=123 \
    TOUCHSTONE_CONDUCTOR_WITH=auto \
    TOUCHSTONE_CONDUCTOR_EXCLUDE="claude,codex,gemini,openrouter,kimi,deepseek-chat,deepseek-reasoner,ollama" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
)
ROUTE_EXCLUDED_EXIT=$?
set -e

if [ "$ROUTE_EXCLUDED_EXIT" -eq 1 ] \
  && grep -q 'Review route preflight failed before invoking reviewer' "$CASCADE_OUTPUT" \
  && grep -q 'provider exclusions: claude,codex,gemini,openrouter,kimi,deepseek-chat,deepseek-reasoner,ollama' "$CASCADE_OUTPUT" \
  && grep -q 'exit reason:.*provider-unavailable' "$CASCADE_OUTPUT" \
  && ! grep -q 'review should not run' "$CASCADE_CALLS"; then
  echo "==> PASS: all-excluded route failed before review"
else
  echo "FAIL: expected all-excluded route to fail before review" >&2
  echo "exit code: $ROUTE_EXCLUDED_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  [ -f "$CASCADE_CALLS" ] && cat "$CASCADE_CALLS" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: merge review route preflight names pinned provider missing tools"
setup_cascade_repo
rm -f "$CASCADE_CALLS"
rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$CASCADE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  doctor)
    printf '{"providers":[{"configured":true}]}\n'
    ;;
  route)
    if [ "${2:-}" = "--help" ]; then
      exit 0
    fi
    printf 'route %s\n' "$*" >>"$CASCADE_CALLS"
    case " $* " in
      *" --tools Read,Grep,Glob,Edit,Write "*)
        printf '{"error":"no provider satisfies the routing request. Skipped: claude does not support tools: [Read, Grep, Glob, Edit, Write]"}\n'
        exit 2
        ;;
      *)
        printf '{"provider":"claude"}\n'
        ;;
    esac
    ;;
  review)
    printf 'review should not run\n' >>"$CASCADE_CALLS"
    exit 99
    ;;
  *)
    printf 'unexpected conductor command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"

set +e
(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    CODEX_REVIEW_PR_NUMBER=123 \
    TOUCHSTONE_CONDUCTOR_WITH=claude \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
)
ROUTE_PINNED_EXIT=$?
set -e

if [ "$ROUTE_PINNED_EXIT" -eq 1 ] \
  && grep -q 'requested provider: claude' "$CASCADE_OUTPUT" \
  && grep -q 'missing capability: .*does not support tools' "$CASCADE_OUTPUT" \
  && grep -q -- '--tools Read,Grep,Glob,Edit,Write' "$CASCADE_CALLS" \
  && ! grep -q 'review should not run' "$CASCADE_CALLS"; then
  echo "==> PASS: pinned nonviable provider failed with missing capability"
else
  echo "FAIL: expected pinned provider missing tools to fail before review" >&2
  echo "exit code: $ROUTE_PINNED_EXIT" >&2
  cat "$CASCADE_OUTPUT" >&2
  [ -f "$CASCADE_CALLS" ] && cat "$CASCADE_CALLS" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review can be disabled by config"
setup_cascade_repo
{
  printf '[review]\n'
  printf 'enabled = false\n'
  printf 'reviewers = ["codex"]\n'
} >"$CASCADE_REPO/.codex-review.toml"
git -C "$CASCADE_REPO" add .codex-review.toml
git -C "$CASCADE_REPO" commit -m "review disabled" >/dev/null 2>&1

rm -rf "$CASCADE_BIN"
mkdir -p "$CASCADE_BIN"
cat >"$CASCADE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$CASCADE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "codex-called" >> "$CASCADE_CALLS"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CASCADE_BIN/gh" "$CASCADE_BIN/conductor"
: >"$CASCADE_CALLS"

(
  cd "$CASCADE_REPO"
  PATH="$CASCADE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CASCADE_CALLS="$CASCADE_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CASCADE_OUTPUT" 2>&1
)

if [ ! -s "$CASCADE_CALLS" ] && grep -q 'AI review disabled' "$CASCADE_OUTPUT"; then
  echo "==> PASS: review disabled by config skipped reviewer"
else
  echo "FAIL: expected enabled=false to skip reviewer" >&2
  cat "$CASCADE_CALLS" >&2
  cat "$CASCADE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: conductor source checkout uses uv run conductor"
setup_mode_repo
mkdir -p "$MODE_REPO/src/conductor"
printf '[project]\nname = "conductor"\n' >"$MODE_REPO/pyproject.toml"
printf '# source checkout\n' >"$MODE_REPO/src/conductor/cli.py"
git -C "$MODE_REPO" add pyproject.toml src/conductor/cli.py
git -C "$MODE_REPO" commit -m "source checkout marker" >/dev/null 2>&1
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/uv" <<'UVEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODEX_ARGS_FILE"
if [ "${1:-}" = "run" ] && [ "${2:-}" = "conductor" ]; then
  shift 2
else
  exit 9
fi
case "${1:-}" in
  doctor)
    printf '{"configured": true}\n'
    ;;
  review | exec)
    cat >/dev/null
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    exit 1
    ;;
esac
UVEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/uv"
: >"$CODEX_ARGS_FILE"

(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)

if grep -q '^run conductor doctor --json$' "$CODEX_ARGS_FILE" \
  && grep -q '^run conductor review ' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: source checkout preferred uv run conductor"
else
  echo "FAIL: expected source checkout to invoke uv run conductor" >&2
  cat "$MODE_OUTPUT" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: configured max_stall_sec reaches review and fix phases"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
case "${1:-}" in
  doctor)
    printf '{"configured": true}\n'
    ;;
  review)
    printf 'review: %s\n' "$*" >> "$CODEX_ARGS_FILE"
    cat >/dev/null
    printf 'CODEX_REVIEW_BLOCKED\n'
    ;;
  exec)
    printf 'exec: %s\n' "$*" >> "$CODEX_ARGS_FILE"
    cat >/dev/null
    printf 'CODEX_REVIEW_BLOCKED\n'
    ;;
  *)
    exit 1
    ;;
esac
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"
{
  printf '[codex_review]\n'
  printf 'safe_by_default = true\n'
  printf 'max_stall_sec = 300\n'
} >"$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "max stall config" >/dev/null 2>&1
: >"$CODEX_ARGS_FILE"

set +e
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=fix \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)
MAX_STALL_EXIT=$?
set -e

if [ "$MAX_STALL_EXIT" -eq 1 ] \
  && grep -q -- '^review: .*--max-stall-seconds 300' "$CODEX_ARGS_FILE" \
  && grep -q -- '^exec: .*--max-stall-seconds 300' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: max_stall_sec was forwarded to review and fix phases"
else
  echo "FAIL: expected --max-stall-seconds 300 in review and fix args" >&2
  echo "exit code: $MAX_STALL_EXIT" >&2
  cat "$MODE_OUTPUT" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: configured minimum Conductor version blocks old binaries"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf 'conductor, version 0.10.29\n'
    ;;
  doctor)
    printf '{"configured": true}\n'
    ;;
  review | exec)
    printf 'review should not run\n' >> "$CODEX_ARGS_FILE"
    cat >/dev/null
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    exit 1
    ;;
esac
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"
{
  printf '[review.conductor]\n'
  printf 'minimum_version = "99.0.0"\n'
} >"$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "minimum conductor version" >/dev/null 2>&1
: >"$CODEX_ARGS_FILE"

set +e
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)
MIN_VERSION_EXIT=$?
set -e

if [ "$MIN_VERSION_EXIT" -eq 1 ] \
  && grep -q 'requires conductor >= 99.0.0' "$MODE_OUTPUT" \
  && grep -q 'installed: 0.10.29' "$MODE_OUTPUT" \
  && ! grep -q 'review should not run' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: too-old Conductor binary blocked before review"
else
  echo "FAIL: expected minimum-version guard to block before review" >&2
  echo "exit code: $MIN_VERSION_EXIT" >&2
  cat "$MODE_OUTPUT" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: minimum Conductor version fails closed before provider fallback"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf 'conductor, version 0.10.29\n'
    ;;
  doctor)
    printf 'old conductor doctor failure\n' >&2
    exit 2
    ;;
  route)
    printf 'old conductor route failure\n' >&2
    exit 2
    ;;
  review | exec)
    printf 'review should not run\n' >> "$CODEX_ARGS_FILE"
    cat >/dev/null
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    exit 1
    ;;
esac
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"
{
  printf '[review.conductor]\n'
  printf 'minimum_version = "99.0.0"\n'
} >"$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "minimum conductor version" >/dev/null 2>&1
: >"$CODEX_ARGS_FILE"

set +e
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)
MIN_VERSION_FALLBACK_EXIT=$?
set -e

if [ "$MIN_VERSION_FALLBACK_EXIT" -eq 1 ] \
  && grep -q 'requires conductor >= 99.0.0' "$MODE_OUTPUT" \
  && grep -q 'installed: 0.10.29' "$MODE_OUTPUT" \
  && ! grep -q '\[fail-open:FAIL_OPEN_PROVIDER_UNAVAILABLE\]' "$MODE_OUTPUT" \
  && ! grep -q 'review should not run' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: too-old Conductor binary did not fall open as provider-unavailable"
else
  echo "FAIL: expected minimum-version guard to run before provider fallback" >&2
  echo "exit code: $MIN_VERSION_FALLBACK_EXIT" >&2
  cat "$MODE_OUTPUT" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: CODEX_REVIEW_NO_AUTOFIX backward compat maps to review-only"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"

{
  printf '[codex_review]\nsafe_by_default = true\n'
} >"$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "codex config" >/dev/null 2>&1

(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_NO_AUTOFIX=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)

if grep -q '^review ' "$CODEX_ARGS_FILE" \
  && grep -q -- '--base HEAD~1' "$CODEX_ARGS_FILE" \
  && grep -q -- '--brief-file -' "$CODEX_ARGS_FILE" \
  && ! grep -q -- '--tools' "$CODEX_ARGS_FILE" \
  && ! grep -q -- '--sandbox' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: CODEX_REVIEW_NO_AUTOFIX=1 mapped to Conductor semantic review without sandbox flag"
else
  echo "FAIL: expected CODEX_REVIEW_NO_AUTOFIX to map to review-only mode" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: FIXED sentinel in review-only mode exits 1"
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
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

echo "==> Test: FIXED with no edits blocks as ambiguous"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'Potential concern: freshness canary no longer covers the new source.\n'
printf 'CODEX_REVIEW_FIXED\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"
AMBIGUOUS_SUMMARY="$TEST_DIR/ambiguous-fixed-summary.json"
AMBIGUOUS_HISTORY_FILE="$MODE_REPO/.git/touchstone/reviewer-findings-history/feature_ambiguous.jsonl"
rm -f "$AMBIGUOUS_SUMMARY"

set +e
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_BRANCH_NAME="feature/ambiguous" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=fix \
    CODEX_REVIEW_SUMMARY_FILE="$AMBIGUOUS_SUMMARY" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)
AMBIGUOUS_EXIT=$?
set -e

if [ "$AMBIGUOUS_EXIT" -eq 1 ] \
  && [ -s "$AMBIGUOUS_SUMMARY" ] \
  && grep -q '"exit_reason":"ambiguous-fixed-no-changes"' "$AMBIGUOUS_SUMMARY" \
  && grep -q '"findings":1' "$AMBIGUOUS_SUMMARY" \
  && grep -q 'FIXED but no working-tree changes detected' "$MODE_OUTPUT" \
  && grep -q 'Treating as ambiguous — blocking push' "$MODE_OUTPUT" \
  && grep -q 'Potential concern: freshness canary' "$MODE_OUTPUT" \
  && grep -q '"result":"CODEX_REVIEW_BLOCKED"' "$AMBIGUOUS_HISTORY_FILE" \
  && grep -q '"findings_count":1' "$AMBIGUOUS_HISTORY_FILE" \
  && grep -q 'Potential concern: freshness canary' "$AMBIGUOUS_HISTORY_FILE"; then
  echo "==> PASS: ambiguous FIXED path blocks and writes a non-clean summary"
else
  echo "FAIL: expected FIXED-without-edits path to block and write summary" >&2
  echo "exit code: $AMBIGUOUS_EXIT" >&2
  cat "$MODE_OUTPUT" >&2
  [ ! -f "$AMBIGUOUS_SUMMARY" ] || cat "$AMBIGUOUS_SUMMARY" >&2
  [ ! -f "$AMBIGUOUS_HISTORY_FILE" ] || cat "$AMBIGUOUS_HISTORY_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: invalid mode warns and falls back to fix"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)

if grep -q "Invalid mode" "$MODE_OUTPUT" \
  && grep -q '^review ' "$CODEX_ARGS_FILE" \
  && grep -q -- '--base HEAD~1' "$CODEX_ARGS_FILE" \
  && ! grep -q -- '--tools' "$CODEX_ARGS_FILE" \
  && ! grep -q -- '--sandbox' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: invalid mode warned and fell back to fix/read-only review without sandbox flag"
else
  echo "FAIL: expected invalid mode to warn and fall back to fix" >&2
  cat "$MODE_OUTPUT" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: review modes map to conductor job shape without sandbox flag"
setup_mode_repo
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
cat >/dev/null
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"

run_mode_check() {
  local mode="$1"
  local expected_subcommand="$2"
  local expected_tools="$3"
  : >"$CODEX_ARGS_FILE"
  (
    cd "$MODE_REPO"
    PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
      CODEX_REVIEW_MODE="$mode" \
      bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
  )

  if ! grep -q "^$expected_subcommand" "$CODEX_ARGS_FILE"; then
    echo "FAIL: expected mode $mode to call conductor $expected_subcommand" >&2
    cat "$CODEX_ARGS_FILE" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  if [ -n "$expected_tools" ]; then
    if ! grep -q -- "--tools $expected_tools" "$CODEX_ARGS_FILE"; then
      echo "FAIL: expected mode $mode to pass --tools $expected_tools" >&2
      cat "$CODEX_ARGS_FILE" >&2
      ERRORS=$((ERRORS + 1))
      return
    fi
  elif grep -q -- '--tools' "$CODEX_ARGS_FILE"; then
    echo "FAIL: expected mode $mode to omit --tools" >&2
    cat "$CODEX_ARGS_FILE" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  if grep -q -- '--sandbox' "$CODEX_ARGS_FILE"; then
    echo "FAIL: expected mode $mode to omit deprecated --sandbox" >&2
    cat "$CODEX_ARGS_FILE" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  if grep -q -- '--timeout' "$CODEX_ARGS_FILE"; then
    echo "FAIL: expected mode $mode to omit Touchstone wrapper --timeout by default" >&2
    cat "$CODEX_ARGS_FILE" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi
}

run_mode_check "diff-only" "call" ""
run_mode_check "review-only" "review" ""
run_mode_check "no-tests" "review" ""
run_mode_check "fix" "review" ""

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: review modes preserve Conductor contract and omit sandbox/timeout defaults"
fi

echo "==> Test: fix mode reviews read-only before edit-capable fix pass"
setup_mode_repo
{
  printf '[codex_review]\nsafe_by_default = true\n'
} >"$MODE_REPO/.codex-review.toml"
git -C "$MODE_REPO" add .codex-review.toml
git -C "$MODE_REPO" commit -m "codex config" >/dev/null 2>&1
rm -rf "$MODE_BIN"
mkdir -p "$MODE_BIN"
FIX_STATE="$TEST_DIR/fix-phase-state"
rm -f "$FIX_STATE"
cat >"$MODE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$MODE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" >> "$CODEX_ARGS_FILE"
case "${1:-}" in
  review)
    if grep -q 'fixed by conductor' example.txt 2>/dev/null; then
      printf 'CODEX_REVIEW_CLEAN\n'
    else
      printf -- '- example.txt:2 — [fixable] missing review fix marker\n'
      printf 'CODEX_REVIEW_BLOCKED\n'
    fi
    ;;
  exec)
    printf 'fixed by conductor\n' >> example.txt
    printf -- '- example.txt:2 — added review fix marker\n'
    printf 'CODEX_REVIEW_FIXED\n'
    ;;
  *)
    printf 'unexpected subcommand: %s\n' "${1:-}" >&2
    exit 2
    ;;
esac
CXEOF
chmod +x "$MODE_BIN/gh" "$MODE_BIN/conductor"
: >"$CODEX_ARGS_FILE"
set +e
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=fix \
    FIX_STATE="$FIX_STATE" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)
FIX_PHASE_EXIT=$?
set -e

if [ "$FIX_PHASE_EXIT" -eq 0 ] \
  && sed -n '1p' "$CODEX_ARGS_FILE" | grep -q '^review ' \
  && sed -n '2p' "$CODEX_ARGS_FILE" | grep -q '^exec ' \
  && sed -n '2p' "$CODEX_ARGS_FILE" | grep -q -- '--tools Read,Grep,Glob,Bash,Edit,Write' \
  && sed -n '3p' "$CODEX_ARGS_FILE" | grep -q '^review ' \
  && git -C "$MODE_REPO" log -1 --format=%s | grep -q 'fix: address Conductor review findings'; then
  echo "==> PASS: fix mode uses read-only review, then edit-capable fix, then re-review"
else
  echo "FAIL: expected fix mode to run review -> exec fix -> review" >&2
  echo "exit code: $FIX_PHASE_EXIT" >&2
  cat "$CODEX_ARGS_FILE" >&2
  cat "$MODE_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: explicit CODEX_REVIEW_TIMEOUT reaches Conductor semantic review"
: >"$CODEX_ARGS_FILE"
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    FIX_STATE="$FIX_STATE" \
    CODEX_REVIEW_TIMEOUT=17 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)

if grep -q -- '--timeout 17' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: explicit timeout is still forwarded to Conductor"
else
  echo "FAIL: expected explicit CODEX_REVIEW_TIMEOUT to become --timeout 17" >&2
  cat "$CODEX_ARGS_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: large explicit CODEX_REVIEW_TIMEOUT leaves diagnostic grace for Conductor"
: >"$CODEX_ARGS_FILE"
(
  cd "$MODE_REPO"
  PATH="$MODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_ARGS_FILE="$CODEX_ARGS_FILE" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    FIX_STATE="$FIX_STATE" \
    CODEX_REVIEW_TIMEOUT=300 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$MODE_OUTPUT" 2>&1
)

if grep -q -- '--timeout 270' "$CODEX_ARGS_FILE"; then
  echo "==> PASS: large wrapper timeout forwards a shorter Conductor timeout"
else
  echo "FAIL: expected CODEX_REVIEW_TIMEOUT=300 to become Conductor --timeout 270" >&2
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
  setup_test_repo "$TIMEOUT_REPO"
  printf 'base\n' >"$TIMEOUT_REPO/example.txt"
  git -C "$TIMEOUT_REPO" add example.txt
  git -C "$TIMEOUT_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >>"$TIMEOUT_REPO/example.txt"
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
cat >"$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
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
cat >"$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
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
    TOUCHSTONE_REVIEW_HEARTBEAT_SEC=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)
TIMEOUT_EXIT=$?
set -e

if [ "$TIMEOUT_EXIT" -eq 0 ] \
  && grep -q 'Review still running (1s/2s)' "$TIMEOUT_OUTPUT" \
  && grep -q 'timed out after 2s' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: timeout emitted heartbeat, killed reviewer, and exited 0 (fail-open default)"
else
  echo "FAIL: expected timeout to heartbeat, kill reviewer, and exit 0" >&2
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

echo "==> Test: timeout fail-closed reports zero findings and retryable status"
setup_timeout_repo
rm -rf "$TIMEOUT_BIN"
mkdir -p "$TIMEOUT_BIN"
TIMEOUT_FAILCLOSED_SUMMARY="$TEST_DIR/timeout-failclosed-summary.json"
cat >"$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
sleep 999
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/conductor"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_TIMEOUT=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=false \
    CODEX_REVIEW_SUMMARY_FILE="$TIMEOUT_FAILCLOSED_SUMMARY" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)
TIMEOUT_FAILCLOSED_EXIT=$?
set -e

if [ "$TIMEOUT_FAILCLOSED_EXIT" -eq 1 ] \
  && grep -q 'timed out after 1s' "$TIMEOUT_OUTPUT" \
  && grep -q 'findings:       0' "$TIMEOUT_OUTPUT" \
  && grep -q 'review status:  review_not_completed' "$TIMEOUT_OUTPUT" \
  && grep -q 'Review did not complete' "$TIMEOUT_OUTPUT" \
  && grep -q 'exit reason:    timeout' "$TIMEOUT_OUTPUT" \
  && grep -q '"findings":0' "$TIMEOUT_FAILCLOSED_SUMMARY" \
  && grep -q '"review_status":"review_not_completed"' "$TIMEOUT_FAILCLOSED_SUMMARY" \
  && grep -q '"exit_reason":"timeout"' "$TIMEOUT_FAILCLOSED_SUMMARY"; then
  echo "==> PASS: timeout fail-closed surfaced incomplete zero-findings infra status"
else
  echo "FAIL: expected timeout fail-closed incomplete zero-findings status" >&2
  echo "exit code: $TIMEOUT_FAILCLOSED_EXIT" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  [ -f "$TIMEOUT_FAILCLOSED_SUMMARY" ] && cat "$TIMEOUT_FAILCLOSED_SUMMARY" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: on_error=fail-closed blocks push on reviewer crash"
setup_timeout_repo
rm -rf "$TIMEOUT_BIN"
mkdir -p "$TIMEOUT_BIN"
cat >"$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)
OPEN_EXIT=$?
set -e

if [ "$OPEN_EXIT" -eq 0 ] \
  && grep -q '\[fail-open:FAIL_OPEN_REVIEWER_ERROR\]' "$TIMEOUT_OUTPUT"; then
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
cat >"$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
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

echo "==> Test: reviewer crash retries once through Conductor fallback"
setup_timeout_repo
rm -rf "$TIMEOUT_BIN"
mkdir -p "$TIMEOUT_BIN"
FALLBACK_ARGS_FILE="$TEST_DIR/fallback-crash-args.txt"
cat >"$TIMEOUT_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" >> "$FALLBACK_ARGS_FILE"
call_count="$(wc -l < "$FALLBACK_ARGS_FILE" | tr -d ' ')"
provider="openrouter"
log_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with)
      provider="$2"
      shift 2
      ;;
    --log-file)
      log_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >/dev/null
if [ -n "$log_file" ]; then
  printf '{"event":"provider_started","data":{"provider":"%s"}}\n' "$provider" > "$log_file"
  if [ "$call_count" = "1" ]; then
    printf '{"event":"provider_failed","data":{"provider":"%s"}}\n' "$provider" >> "$log_file"
  else
    printf '{"event":"provider_finished","data":{"provider":"%s","model":"fixture"}}\n' "$provider" >> "$log_file"
  fi
fi
if [ "$call_count" = "1" ]; then
  exit 42
fi
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$TIMEOUT_BIN/gh" "$TIMEOUT_BIN/conductor"
: >"$FALLBACK_ARGS_FILE"

(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FALLBACK_ARGS_FILE="$FALLBACK_ARGS_FILE" \
    TOUCHSTONE_CONDUCTOR_WITH=gemini \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=true \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)

if [ "$(wc -l <"$FALLBACK_ARGS_FILE" | tr -d ' ')" = "2" ] \
  && sed -n '1p' "$FALLBACK_ARGS_FILE" | grep -q -- '--with gemini' \
  && sed -n '2p' "$FALLBACK_ARGS_FILE" | grep -q '^review ' \
  && sed -n '2p' "$FALLBACK_ARGS_FILE" | grep -q -- '--exclude ollama,gemini' \
  && grep -q 'fallback:       gemini -> unknown (reviewer exit 42)' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: reviewer crash retried through auto-routing with failed provider excluded"
else
  echo "FAIL: expected reviewer crash to retry once through fallback provider" >&2
  cat "$FALLBACK_ARGS_FILE" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: fallback retry excludes every provider Conductor already tried"
setup_timeout_repo
: >"$FALLBACK_ARGS_FILE"
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" >> "$FALLBACK_ARGS_FILE"
call_count="$(wc -l < "$FALLBACK_ARGS_FILE" | tr -d ' ')"
cat >/dev/null
if [ "$call_count" = "1" ]; then
  printf '[conductor] review tried providers: claude (timeout), gemini (provider unavailable)\n' >&2
  exit 42
fi
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$TIMEOUT_BIN/conductor"

(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FALLBACK_ARGS_FILE="$FALLBACK_ARGS_FILE" \
    TOUCHSTONE_CONDUCTOR_WITH=auto \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=true \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)

if [ "$(wc -l <"$FALLBACK_ARGS_FILE" | tr -d ' ')" = "2" ] \
  && sed -n '2p' "$FALLBACK_ARGS_FILE" | grep -q -- '--exclude ollama,claude,gemini' \
  && grep -q 'fallback skip:  claude,gemini' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: fallback retry skipped all providers from the failed route"
else
  echo "FAIL: expected fallback retry to exclude all already-tried providers" >&2
  cat "$FALLBACK_ARGS_FILE" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: malformed sentinel retries once through Conductor fallback"
setup_timeout_repo
: >"$FALLBACK_ARGS_FILE"
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" >> "$FALLBACK_ARGS_FILE"
call_count="$(wc -l < "$FALLBACK_ARGS_FILE" | tr -d ' ')"
provider="openrouter"
log_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with)
      provider="$2"
      shift 2
      ;;
    --log-file)
      log_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >/dev/null
if [ -n "$log_file" ]; then
  printf '{"event":"provider_started","data":{"provider":"%s"}}\n' "$provider" > "$log_file"
  printf '{"event":"provider_finished","data":{"provider":"%s","model":"fixture"}}\n' "$provider" >> "$log_file"
fi
if [ "$call_count" = "1" ]; then
  printf 'looks clean but forgot the marker\n'
else
  printf 'CODEX_REVIEW_CLEAN\n'
fi
CXEOF
chmod +x "$TIMEOUT_BIN/conductor"

(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FALLBACK_ARGS_FILE="$FALLBACK_ARGS_FILE" \
    TOUCHSTONE_CONDUCTOR_WITH=gemini \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=true \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)

if [ "$(wc -l <"$FALLBACK_ARGS_FILE" | tr -d ' ')" = "2" ] \
  && grep -q 'fallback:       gemini -> unknown (malformed sentinel)' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: malformed sentinel retried through fallback provider"
else
  echo "FAIL: expected malformed sentinel to retry once through fallback provider" >&2
  cat "$FALLBACK_ARGS_FILE" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: concrete CODEX_REVIEW_BLOCKED findings are not retried"
setup_timeout_repo
: >"$FALLBACK_ARGS_FILE"
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" >> "$FALLBACK_ARGS_FILE"
cat >/dev/null
printf '%s\n' '- example.txt:1 - concrete blocker'
printf 'CODEX_REVIEW_BLOCKED\n'
CXEOF
chmod +x "$TIMEOUT_BIN/conductor"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FALLBACK_ARGS_FILE="$FALLBACK_ARGS_FILE" \
    TOUCHSTONE_CONDUCTOR_WITH=gemini \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=true \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)
BLOCKED_RETRY_EXIT=$?
set -e

if [ "$BLOCKED_RETRY_EXIT" -eq 1 ] \
  && [ "$(wc -l <"$FALLBACK_ARGS_FILE" | tr -d ' ')" = "1" ] \
  && grep -q 'CODEX_REVIEW_BLOCKED' "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: concrete blocked findings did not trigger fallback retry"
else
  echo "FAIL: expected concrete findings to block without fallback retry" >&2
  echo "exit code: $BLOCKED_RETRY_EXIT" >&2
  cat "$FALLBACK_ARGS_FILE" >&2
  cat "$TIMEOUT_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: fallback retry cannot mutate worktree in review-only mode"
setup_timeout_repo
: >"$FALLBACK_ARGS_FILE"
FALLBACK_MUTATION_FILE="$TIMEOUT_REPO/fallback-mutated.txt"
cat >"$TIMEOUT_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "$*" >> "$FALLBACK_ARGS_FILE"
call_count="$(wc -l < "$FALLBACK_ARGS_FILE" | tr -d ' ')"
provider="openrouter"
log_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with)
      provider="$2"
      shift 2
      ;;
    --log-file)
      log_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >/dev/null
if [ -n "$log_file" ]; then
  printf '{"event":"provider_started","data":{"provider":"%s"}}\n' "$provider" > "$log_file"
  if [ "$call_count" = "1" ]; then
    printf '{"event":"provider_failed","data":{"provider":"%s"}}\n' "$provider" >> "$log_file"
  else
    printf '{"event":"provider_finished","data":{"provider":"%s","model":"fixture"}}\n' "$provider" >> "$log_file"
  fi
fi
if [ "$call_count" = "1" ]; then
  exit 42
fi
printf 'mutated by fallback\n' > "$FALLBACK_MUTATION_FILE"
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$TIMEOUT_BIN/conductor"

set +e
(
  cd "$TIMEOUT_REPO"
  PATH="$TIMEOUT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FALLBACK_ARGS_FILE="$FALLBACK_ARGS_FILE" \
    FALLBACK_MUTATION_FILE="$FALLBACK_MUTATION_FILE" \
    TOUCHSTONE_CONDUCTOR_WITH=gemini \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=true \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MODE=review-only \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$TIMEOUT_OUTPUT" 2>&1
)
FALLBACK_MUTATION_EXIT=$?
set -e

if [ "$FALLBACK_MUTATION_EXIT" -eq 1 ] \
  && [ "$(wc -l <"$FALLBACK_ARGS_FILE" | tr -d ' ')" = "2" ] \
  && grep -q "Worktree was mutated in 'review-only' mode" "$TIMEOUT_OUTPUT"; then
  echo "==> PASS: fallback mutation blocked in review-only mode"
else
  echo "FAIL: expected fallback mutation to block in review-only mode" >&2
  echo "exit code: $FALLBACK_MUTATION_EXIT" >&2
  cat "$FALLBACK_ARGS_FILE" >&2
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
  setup_test_repo "$CTX_REPO"
  printf 'base\n' >"$CTX_REPO/example.txt"
  git -C "$CTX_REPO" add example.txt
  git -C "$CTX_REPO" commit -m "base" >/dev/null 2>&1
  printf 'changed\n' >>"$CTX_REPO/example.txt"
  git -C "$CTX_REPO" add example.txt
  git -C "$CTX_REPO" commit -m "change" >/dev/null 2>&1
}

CTX_BIN="$TEST_DIR/ctx-bin"

setup_ctx_bin() {
  rm -rf "$CTX_BIN"
  mkdir -p "$CTX_BIN"
  cat >"$CTX_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "main"
EOF
  cat >"$CTX_BIN/conductor" <<'CXEOF'
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
printf 'UNIQUE_CTX_MARKER_12345\n' >"$CTX_REPO/.codex-review-context.md"
git -C "$CTX_REPO" add .codex-review-context.md
git -C "$CTX_REPO" commit -m "add context" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
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
printf 'GITHUB_CTX_MARKER_67890\n' >"$CTX_REPO/.github/codex-review-context.md"
git -C "$CTX_REPO" add .github/codex-review-context.md
git -C "$CTX_REPO" commit -m "add github context" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if ! grep -q 'Review context' "$CTX_OUTPUT" \
  && ! grep -q 'Project review context' "$CTX_PROMPT"; then
  echo "==> PASS: no context file, no error"
else
  echo "FAIL: expected no context section when file is missing" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: small/simple diffs use bounded prompt context"
setup_ctx_repo
setup_ctx_bin
printf 'AGENTS_FULL_CONTEXT_MARKER\n' >"$CTX_REPO/AGENTS.md"
printf 'CLAUDE_FULL_CONTEXT_MARKER\n' >"$CTX_REPO/CLAUDE.md"
git -C "$CTX_REPO" add AGENTS.md CLAUDE.md
git -C "$CTX_REPO" commit -m "add steering files" >/dev/null 2>&1
printf 'small prompt context change\n' >>"$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt
git -C "$CTX_REPO" commit -m "small prompt context change" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'Full AGENTS.md and CLAUDE.md context was intentionally omitted' "$CTX_PROMPT" \
  && grep -q 'Bounded project review context' "$CTX_PROMPT" \
  && ! grep -q 'Read AGENTS.md at the repo root' "$CTX_PROMPT" \
  && grep -q 'Prompt context: bounded' "$CTX_OUTPUT"; then
  echo "==> PASS: small/simple diff used bounded prompt context"
else
  echo "FAIL: expected bounded prompt context for small/simple diff" >&2
  sed -n '1,80p' "$CTX_PROMPT" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: low-risk large diffs use bounded prompt context"
setup_ctx_repo
setup_ctx_bin
printf 'AGENTS_FULL_CONTEXT_MARKER\n' >"$CTX_REPO/AGENTS.md"
printf 'CLAUDE_FULL_CONTEXT_MARKER\n' >"$CTX_REPO/CLAUDE.md"
git -C "$CTX_REPO" add AGENTS.md CLAUDE.md
git -C "$CTX_REPO" commit -m "add steering before large diff" >/dev/null 2>&1
printf 'large prompt context change\n' >>"$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt
git -C "$CTX_REPO" commit -m "large prompt context change" >/dev/null 2>&1
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_CONTEXT_SMALL_MAX_DIFF_LINES=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'low-risk large diff' "$CTX_PROMPT" \
  && grep -q 'Bounded project review context' "$CTX_PROMPT" \
  && ! grep -q 'Read AGENTS.md at the repo root' "$CTX_PROMPT" \
  && grep -q 'Prompt context: bounded' "$CTX_OUTPUT"; then
  echo "==> PASS: low-risk large diff used bounded prompt context"
else
  echo "FAIL: expected bounded prompt context for low-risk large diff" >&2
  sed -n '1,80p' "$CTX_PROMPT" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: architectural files keep full AGENTS/CLAUDE context"
setup_ctx_repo
setup_ctx_bin
printf 'architectural review guidance\n' >"$CTX_REPO/AGENTS.md"
git -C "$CTX_REPO" add AGENTS.md
git -C "$CTX_REPO" commit -m "touch agents" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'Full project context is required because architectural path AGENTS.md' "$CTX_PROMPT" \
  && grep -q 'Read AGENTS.md at the repo root' "$CTX_PROMPT"; then
  echo "==> PASS: architectural file kept full prompt context"
else
  echo "FAIL: expected full prompt context for architectural file" >&2
  sed -n '1,80p' "$CTX_PROMPT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: bootstrap scripts keep full AGENTS/CLAUDE context"
setup_ctx_repo
setup_ctx_bin
mkdir -p "$CTX_REPO/bootstrap"
cat >"$CTX_REPO/bootstrap/new-project.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'bootstrap review guidance\n'
EOF
git -C "$CTX_REPO" add bootstrap/new-project.sh
git -C "$CTX_REPO" commit -m "touch bootstrap script" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    TOUCHSTONE_NO_PREFLIGHT=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'Full project context is required because architectural path bootstrap/new-project.sh' "$CTX_PROMPT" \
  && grep -q 'Prompt context: full' "$CTX_OUTPUT"; then
  echo "==> PASS: bootstrap script kept full prompt context"
else
  echo "FAIL: expected full prompt context for bootstrap script" >&2
  sed -n '1,80p' "$CTX_PROMPT" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: unsafe paths keep full AGENTS/CLAUDE context"
setup_ctx_repo
setup_ctx_bin
{
  printf '[codex_review]\n'
  printf 'unsafe_paths = ["sensitive/"]\n'
} >"$CTX_REPO/.codex-review.toml"
git -C "$CTX_REPO" add .codex-review.toml
git -C "$CTX_REPO" commit -m "configure unsafe path" >/dev/null 2>&1
mkdir -p "$CTX_REPO/sensitive"
printf 'secret change\n' >"$CTX_REPO/sensitive/config.txt"
git -C "$CTX_REPO" add sensitive/config.txt
git -C "$CTX_REPO" commit -m "touch sensitive config" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'Full project context is required because high-risk path sensitive/config.txt' "$CTX_PROMPT" \
  && grep -q 'Read AGENTS.md at the repo root' "$CTX_PROMPT"; then
  echo "==> PASS: unsafe path kept full prompt context"
else
  echo "FAIL: expected full prompt context for unsafe path" >&2
  sed -n '1,100p' "$CTX_PROMPT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: configured full-context patterns keep full AGENTS/CLAUDE context"
setup_ctx_repo
setup_ctx_bin
{
  printf '[review.context]\n'
  printf 'full_context_paths = ["docs/"]\n'
} >"$CTX_REPO/.codex-review.toml"
git -C "$CTX_REPO" add .codex-review.toml
git -C "$CTX_REPO" commit -m "configure full context path" >/dev/null 2>&1
mkdir -p "$CTX_REPO/docs"
printf 'doc change\n' >"$CTX_REPO/docs/note.md"
git -C "$CTX_REPO" add docs/note.md
git -C "$CTX_REPO" commit -m "touch docs" >/dev/null 2>&1

(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'Full project context is required because configured full-context path docs/note.md' "$CTX_PROMPT" \
  && grep -q 'Read AGENTS.md at the repo root' "$CTX_PROMPT"; then
  echo "==> PASS: configured full-context path kept full prompt context"
else
  echo "FAIL: expected full prompt context for configured full-context path" >&2
  sed -n '1,100p' "$CTX_PROMPT" >&2
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
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
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
cat >/dev/null
printf '[conductor] auto (prefer=best, effort=max) -> claude (tier: frontier)\n' >&2
printf '            . 4.2s . 1284 tok in . 420 tok out . sandbox=read-only\n' >&2
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CTX_BIN/conductor"
printf 'route log test\n' >>"$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt
git -C "$CTX_REPO" commit -m "route log" >/dev/null 2>&1
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CTX_PROMPT="$CTX_PROMPT" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
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

echo "==> Test: conductor review strips tool-use tag"
setup_ctx_repo
setup_ctx_bin
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="$1"; shift
printf '%s\n' "$subcmd $*" >> "$CONDUCTOR_ARGS_LOG"
cat >/dev/null
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CTX_BIN/conductor"
CONDUCTOR_ARGS_LOG="$TEST_DIR/conductor-review-tags.log"
: >"$CONDUCTOR_ARGS_LOG"
printf 'tag sanitizer test\n' >>"$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt
git -C "$CTX_REPO" commit -m "tag sanitizer" >/dev/null 2>&1
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    TOUCHSTONE_CONDUCTOR_WITH=auto \
    TOUCHSTONE_CONDUCTOR_TAGS="code-review,tool-use,long-context" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q '^review .*--tags code-review,long-context' "$CONDUCTOR_ARGS_LOG" \
  && grep -q '^review .*--exclude ollama' "$CONDUCTOR_ARGS_LOG" \
  && ! grep -q '^review .*tool-use' "$CONDUCTOR_ARGS_LOG"; then
  echo "==> PASS: conductor review strips tool-use tag and excludes offline provider"
else
  echo "FAIL: conductor review should strip tool-use tag and pass ollama exclusion" >&2
  echo "--- CTX_OUTPUT ---" >&2
  cat "$CTX_OUTPUT" >&2
  echo "--- conductor args log ---" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: peer review fires when [review.assist].enabled = true"
# Mock conductor responds differently to `review` (primary) and `call`
# (peer). The primary emits a route-log to stderr naming itself, which
# touchstone parses out to set --exclude on the peer call. The peer
# prints distinctive text so we can assert it surfaces in the transcript.
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="$1"; shift
# Record every invocation's argv so the test can inspect --exclude presence
# independently of stdout assertions.
printf '%s\n' "$subcmd $*" >> "$CONDUCTOR_ARGS_LOG"
cat >/dev/null  # drain stdin
case "$subcmd" in
  review | exec)
    printf '[conductor] auto -> claude (tier: frontier, model=sonnet)\n' >&2
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
printf 'peer-review test\n' >>"$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt && git -C "$CTX_REPO" commit -m "peer review" >/dev/null 2>&1
# Enable peer review in the project config.
{
  cat "$CTX_REPO/.codex-review.toml" 2>/dev/null || true
  printf '\n[review.assist]\nenabled = true\nmax_rounds = 1\n'
} >"$CTX_REPO/.codex-review.toml.tmp" && mv "$CTX_REPO/.codex-review.toml.tmp" "$CTX_REPO/.codex-review.toml"
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "enable assist" >/dev/null 2>&1

CONDUCTOR_ARGS_LOG="$TEST_DIR/conductor-args.log"
: >"$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~2" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
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

echo "==> Test: peer review uses pinned provider when telemetry is missing"
setup_ctx_repo
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="$1"; shift
printf '%s\n' "$subcmd $*" >> "$CONDUCTOR_ARGS_LOG"
cat >/dev/null
case "$subcmd" in
  review | exec)
    printf 'Primary review emitted no provider telemetry.\n'
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  call)
    printf 'AGREE\n'
    printf 'Peer ran with the pinned primary excluded.\n'
    ;;
esac
CXEOF
chmod +x "$CTX_BIN/conductor"
{
  cat "$CTX_REPO/.codex-review.toml" 2>/dev/null || true
  printf '\n[review.assist]\nenabled = true\nmax_rounds = 1\n'
} >"$CTX_REPO/.codex-review.toml.tmp" && mv "$CTX_REPO/.codex-review.toml.tmp" "$CTX_REPO/.codex-review.toml"
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "enable pinned assist" >/dev/null 2>&1

: >"$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~2" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    TOUCHSTONE_CONDUCTOR_WITH=openrouter \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'peer review' "$CTX_OUTPUT" \
  && ! grep -q "couldn't identify primary provider" "$CTX_OUTPUT" \
  && grep -q '^call .*--exclude openrouter' "$CONDUCTOR_ARGS_LOG"; then
  echo "==> PASS: peer review excluded pinned provider without telemetry"
else
  echo "FAIL: peer review should use pinned provider as telemetry fallback" >&2
  echo "--- CTX_OUTPUT ---" >&2
  cat "$CTX_OUTPUT" >&2
  echo "--- conductor args log ---" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: peer review excludes successful fallback provider"
setup_ctx_repo
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="$1"; shift
printf '%s\n' "$subcmd $*" >> "$CONDUCTOR_ARGS_LOG"
cat >/dev/null
case "$subcmd" in
  review | exec)
    printf '[conductor] best (effort=high) -> claude (tier: frontier, model=sonnet)\n' >&2
    printf '[conductor] claude review failed (rate-limit) · falling back -> openrouter\n' >&2
    printf '[conductor] review tried providers: claude (rate-limit), openrouter (success)\n' >&2
    printf 'Primary fallback review says nothing to change.\n'
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  call)
    printf 'AGREE\n'
    printf 'Peer has nothing additional to add.\n'
    ;;
esac
CXEOF
chmod +x "$CTX_BIN/conductor"
{
  cat "$CTX_REPO/.codex-review.toml" 2>/dev/null || true
  printf '\n[review.assist]\nenabled = true\nmax_rounds = 1\n'
} >"$CTX_REPO/.codex-review.toml.tmp" && mv "$CTX_REPO/.codex-review.toml.tmp" "$CTX_REPO/.codex-review.toml"
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "enable assist fallback" >/dev/null 2>&1

: >"$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~2" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'peer review' "$CTX_OUTPUT" \
  && grep -q '^call .*--exclude openrouter' "$CONDUCTOR_ARGS_LOG"; then
  echo "==> PASS: peer review excluded successful fallback provider"
else
  echo "FAIL: peer review should exclude fallback success provider" >&2
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
printf 'another change\n' >>"$CTX_REPO/example.txt"
git -C "$CTX_REPO" add example.txt && git -C "$CTX_REPO" commit -m "change" >/dev/null 2>&1

: >"$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~2" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if ! grep -q '^call ' "$CONDUCTOR_ARGS_LOG" && ! grep -q 'AGREE' "$CTX_OUTPUT"; then
  echo "==> PASS: peer review does not fire when disabled"
else
  echo "FAIL: peer review fired when disabled" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: high-scrutiny paths auto-enable peer review with diff context"
setup_ctx_repo
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="$1"; shift
printf '%s\n' "$subcmd $*" >> "$CONDUCTOR_ARGS_LOG"
input="$(cat)"
case "$subcmd" in
  review | exec)
    printf '[conductor] auto -> claude (tier: frontier, model=sonnet)\n' >&2
    printf 'Primary review clean.\n'
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  call)
    if [ -n "${PEER_PROMPT_LOG:-}" ]; then
      printf '%s\n' "$input" >"$PEER_PROMPT_LOG"
    fi
    printf 'AGREE\n'
    printf 'Peer agrees on the high-scrutiny diff.\n'
    ;;
esac
CXEOF
chmod +x "$CTX_BIN/conductor"
cat >"$CTX_REPO/.codex-review.toml" <<'EOF'
[review]
high_scrutiny_mode = "peer"
high_scrutiny_paths = ["critical/"]
EOF
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "configure high scrutiny" >/dev/null 2>&1
mkdir -p "$CTX_REPO/critical"
printf 'important\n' >"$CTX_REPO/critical/file.txt"
git -C "$CTX_REPO" add critical/file.txt && git -C "$CTX_REPO" commit -m "touch critical path" >/dev/null 2>&1

PEER_PROMPT_LOG="$TEST_DIR/high-scrutiny-peer-prompt.log"
: >"$PEER_PROMPT_LOG"
: >"$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    PEER_PROMPT_LOG="$PEER_PROMPT_LOG" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'High-scrutiny review: configured high-scrutiny path critical/file.txt' "$CTX_OUTPUT" \
  && grep -q 'Review routing: high-risk diff (configured high-scrutiny path critical/file.txt' "$CTX_OUTPUT" \
  && grep -q 'peer review' "$CTX_OUTPUT" \
  && grep -q '^call .*--exclude claude' "$CONDUCTOR_ARGS_LOG" \
  && grep -q '## Branch context' "$PEER_PROMPT_LOG" \
  && grep -q 'High scrutiny: configured high-scrutiny path critical/file.txt' "$PEER_PROMPT_LOG" \
  && grep -q '## Diff' "$PEER_PROMPT_LOG" \
  && grep -q '^+important' "$PEER_PROMPT_LOG" \
  && grep -q '## Primary reviewer output' "$PEER_PROMPT_LOG"; then
  echo "==> PASS: high-scrutiny path triggered peer review with diff context"
else
  echo "FAIL: high-scrutiny path should trigger peer review with diff context" >&2
  echo "--- CTX_OUTPUT ---" >&2
  cat "$CTX_OUTPUT" >&2
  echo "--- conductor args log ---" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
  echo "--- peer prompt ---" >&2
  cat "$PEER_PROMPT_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: high-scrutiny council mode uses conductor ask"
setup_ctx_repo
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="$1"; shift
printf '%s\n' "$subcmd $*" >> "$CONDUCTOR_ARGS_LOG"
case "$subcmd" in
  review | exec)
    cat >/dev/null
    printf '[conductor] auto -> claude (tier: frontier, model=sonnet)\n' >&2
    printf 'Primary review clean.\n'
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  ask)
    printf 'AGREE\n'
    printf 'Council agrees on the high-scrutiny diff.\n'
    ;;
  call)
    cat >/dev/null
    printf 'unexpected peer call\n'
    ;;
esac
CXEOF
chmod +x "$CTX_BIN/conductor"
cat >"$CTX_REPO/.codex-review.toml" <<'EOF'
[review]
high_scrutiny_mode = "council"
high_scrutiny_paths = ["critical/"]
EOF
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "configure council scrutiny" >/dev/null 2>&1
mkdir -p "$CTX_REPO/critical"
printf 'important\n' >"$CTX_REPO/critical/file.txt"
git -C "$CTX_REPO" add critical/file.txt && git -C "$CTX_REPO" commit -m "touch critical path" >/dev/null 2>&1

: >"$CONDUCTOR_ARGS_LOG"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q 'council review' "$CTX_OUTPUT" \
  && grep -q '^ask .*--kind council' "$CONDUCTOR_ARGS_LOG" \
  && ! grep -q '^call ' "$CONDUCTOR_ARGS_LOG"; then
  echo "==> PASS: high-scrutiny council mode used conductor ask"
else
  echo "FAIL: high-scrutiny council mode should use conductor ask, not peer call" >&2
  echo "--- CTX_OUTPUT ---" >&2
  cat "$CTX_OUTPUT" >&2
  echo "--- conductor args log ---" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
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
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
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

echo "==> Test: JSON summary extracts provider/model from Conductor session log"
setup_ctx_repo
setup_ctx_bin
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
log_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-file)
      log_file="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >/dev/null
if [ -n "$log_file" ]; then
  printf '{"event":"route_decision","data":{"provider":"gemini"}}\n' >"$log_file"
  printf '{"event":"provider_finished","data":{"provider":"claude","model":"sonnet","duration_ms":1234,"session_id":"primary-fixture"}}\n' >>"$log_file"
fi
printf '[conductor] auto -> claude (tier: frontier, model=sonnet)\n' >&2
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CTX_BIN/conductor"
JSON_SUMMARY="$TEST_DIR/review-summary-provider.json"
rm -f "$JSON_SUMMARY"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_SUMMARY_FILE="$JSON_SUMMARY" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q '"provider":"claude"' "$JSON_SUMMARY" \
  && grep -q '"model":"sonnet"' "$JSON_SUMMARY" \
  && grep -q '"peer_provider":"none"' "$JSON_SUMMARY"; then
  echo "==> PASS: summary used structured Conductor provider/model"
else
  echo "FAIL: expected structured provider/model in JSON summary" >&2
  cat "$JSON_SUMMARY" 2>/dev/null >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: fallback persists failed attempt diagnostics"
setup_ctx_repo
setup_ctx_bin
CONDUCTOR_COUNT_FILE="$TEST_DIR/conductor-fallback-count"
DIAGNOSTICS_FILE="$TEST_DIR/review-diagnostics.jsonl"
JSON_SUMMARY="$TEST_DIR/review-summary-diagnostics.json"
rm -f "$CONDUCTOR_COUNT_FILE" "$DIAGNOSTICS_FILE" "$JSON_SUMMARY"
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
count="$(cat "$CONDUCTOR_COUNT_FILE" 2>/dev/null || printf '0')"
next=$((count + 1))
printf '%s\n' "$next" >"$CONDUCTOR_COUNT_FILE"
cat >/dev/null
if [ "$count" = "0" ]; then
  printf '[conductor] pinned -> codex (tier: frontier, model=codex-test)\n' >&2
  printf 'first\tattempt missing sentinel\n'
  exit 1
fi
printf '[conductor] auto -> openrouter (tier: frontier, model=openrouter-test)\n' >&2
printf 'LGTM\nCODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CTX_BIN/conductor"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_COUNT_FILE="$CONDUCTOR_COUNT_FILE" \
    TOUCHSTONE_CONDUCTOR_WITH=codex \
    TOUCHSTONE_CONDUCTOR_FALLBACK_RETRY=true \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_SUMMARY_FILE="$JSON_SUMMARY" \
    CODEX_REVIEW_DIAGNOSTICS_FILE="$DIAGNOSTICS_FILE" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if [ -f "$DIAGNOSTICS_FILE" ] \
  && [ "$(wc -l <"$DIAGNOSTICS_FILE" | tr -d ' ')" = "1" ] \
  && grep -q '"event":"fallback-trigger"' "$DIAGNOSTICS_FILE" \
  && grep -q '"provider":"codex"' "$DIAGNOSTICS_FILE" \
  && grep -q '"reason":"reviewer exit 1"' "$DIAGNOSTICS_FILE" \
  && grep -q 'first\\tattempt missing sentinel' "$DIAGNOSTICS_FILE" \
  && ! grep -q "$(printf '\t')" "$DIAGNOSTICS_FILE" \
  && grep -q '"fallback_attempted":true' "$JSON_SUMMARY" \
  && grep -q '"fallback_retry_provider":"openrouter"' "$JSON_SUMMARY" \
  && grep -q '"diagnostics_events":1' "$JSON_SUMMARY" \
  && grep -Fq "\"diagnostics_file\":\"$DIAGNOSTICS_FILE\"" "$JSON_SUMMARY" \
  && grep -q 'Review diagnostics:' "$CTX_OUTPUT" \
  && grep -q 'diagnostics:' "$CTX_OUTPUT"; then
  echo "==> PASS: fallback diagnostics persisted and summarized"
else
  echo "FAIL: expected fallback diagnostics artifact and summary fields" >&2
  echo "--- diagnostics ---" >&2
  cat "$DIAGNOSTICS_FILE" 2>/dev/null >&2
  echo "--- summary ---" >&2
  cat "$JSON_SUMMARY" 2>/dev/null >&2
  echo "--- output ---" >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: missing Conductor session log keeps pinned provider visible"
setup_ctx_repo
setup_ctx_bin
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
cat >/dev/null
printf 'CODEX_REVIEW_CLEAN\n'
CXEOF
chmod +x "$CTX_BIN/conductor"
JSON_SUMMARY="$TEST_DIR/review-summary-missing-log.json"
rm -f "$JSON_SUMMARY"
(
  cd "$CTX_REPO"
  PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_SUMMARY_FILE="$JSON_SUMMARY" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q '"provider":"codex"' "$JSON_SUMMARY" \
  && grep -q '"model":"unknown"' "$JSON_SUMMARY" \
  && grep -q '"peer_provider":"none"' "$JSON_SUMMARY"; then
  echo "==> PASS: missing session log retained the configured provider boundary"
else
  echo "FAIL: expected configured provider with unknown model" >&2
  cat "$JSON_SUMMARY" 2>/dev/null >&2
  cat "$CTX_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: peer review provider is extracted when peer session exists"
setup_ctx_repo
setup_ctx_bin
cat >"$CTX_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
subcmd="${1:-}"; shift || true
log_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-file)
      log_file="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >/dev/null
case "$subcmd" in
  review | exec)
    if [ -n "$log_file" ]; then
      printf '{"event":"provider_finished","data":{"provider":"claude","model":"sonnet","duration_ms":1234,"session_id":"primary-fixture"}}\n' >"$log_file"
    fi
    printf '[conductor] auto -> claude (tier: frontier, model=sonnet)\n' >&2
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  call)
    session_dir="$HOME/.cache/conductor/sessions"
    mkdir -p "$session_dir"
    printf '{"event":"provider_finished","data":{"provider":"gemini","model":"gemini-2.5-pro","duration_ms":4321,"session_id":"peer-fixture"}}\n' >"$session_dir/peer-fixture.ndjson"
    printf 'AGREE\n'
    ;;
esac
CXEOF
chmod +x "$CTX_BIN/conductor"
{
  cat "$CTX_REPO/.codex-review.toml" 2>/dev/null || true
  printf '\n[review.assist]\nenabled = true\nmax_rounds = 1\n'
} >"$CTX_REPO/.codex-review.toml.tmp" && mv "$CTX_REPO/.codex-review.toml.tmp" "$CTX_REPO/.codex-review.toml"
git -C "$CTX_REPO" add .codex-review.toml && git -C "$CTX_REPO" commit -m "enable assist summary" >/dev/null 2>&1
JSON_SUMMARY="$TEST_DIR/review-summary-peer.json"
PEER_HOME="$TEST_DIR/peer-home"
rm -rf "$PEER_HOME"
mkdir -p "$PEER_HOME"
rm -f "$JSON_SUMMARY"
(
  cd "$CTX_REPO"
  HOME="$PEER_HOME" \
    PATH="$CTX_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE="HEAD~2" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_SUMMARY_FILE="$JSON_SUMMARY" \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$CTX_OUTPUT" 2>&1
)

if grep -q '"provider":"claude"' "$JSON_SUMMARY" \
  && grep -q '"model":"sonnet"' "$JSON_SUMMARY" \
  && grep -q '"peer_provider":"gemini"' "$JSON_SUMMARY"; then
  echo "==> PASS: peer provider surfaced in summary"
else
  echo "FAIL: expected peer provider in JSON summary" >&2
  cat "$JSON_SUMMARY" 2>/dev/null >&2
  cat "$CTX_OUTPUT" >&2
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
  local dir="$1"
  shift || true
  rm -rf "$dir"
  setup_test_repo "$dir"
  printf 'base\n' >"$dir/file.txt"
  if [ "${1:-}" = "--with-config-toml" ]; then
    cat >"$dir/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"
[review.conductor]
prefer = "best"
effort = "max"
EOF
  fi
  git -C "$dir" add . && git -C "$dir" commit -qm init
  printf 'change\n' >>"$dir/file.txt"
  git -C "$dir" add . && git -C "$dir" commit -qm change
}

make_skiplog_bin_with_conductor() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/gh" <<'EOF'
#!/usr/bin/env bash
echo main
EOF
  cat >"$dir/conductor" <<'EOF'
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
  cat >"$dir/gh" <<'EOF'
#!/usr/bin/env bash
echo main
EOF
  chmod +x "$dir/gh"
}

run_skiplog_hook() {
  local repo="$1"
  shift
  local sink="$1"
  shift
  (
    cd "$repo"
    "$@" bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$sink" 2>&1
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
  CONDUCTOR_BIN=missing-conductor \
  TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG1" \
  CODEX_REVIEW_BASE="HEAD~1" \
  CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
assert_skiplog_last_reason "conductor-missing" "$SKIPLOG_LOG1" "FAIL_OPEN_DEPENDENCY_MISSING"

# ---------------------------------------------------------------------------
# Test: config-disabled — [review].enabled=false in .codex-review.toml
# ---------------------------------------------------------------------------
echo "==> Test: config-disabled skip path logs reason=config-disabled"
SKIPLOG_REPO2="$TEST_DIR/skiplog-repo2"
SKIPLOG_BIN2="$TEST_DIR/skiplog-bin2"
SKIPLOG_LOG2="$TEST_DIR/skiplog-log2.tsv"
rm -rf "$SKIPLOG_REPO2"
setup_test_repo "$SKIPLOG_REPO2"
cat >"$SKIPLOG_REPO2/.codex-review.toml" <<'EOF'
[review]
enabled = false
reviewer = "conductor"
EOF
printf 'a\n' >"$SKIPLOG_REPO2/f.txt"
git -C "$SKIPLOG_REPO2" add . && git -C "$SKIPLOG_REPO2" commit -qm init
printf 'b\n' >>"$SKIPLOG_REPO2/f.txt"
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
  || {
    echo "FAIL: hook exited non-zero on a clean review" >&2
    cat "$TEST_DIR/skiplog-out4.txt" >&2
    ERRORS=$((ERRORS + 1))
  }
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
rm -rf "$SKIPLOG_REPO5"
setup_test_repo "$SKIPLOG_REPO5"
cat >"$SKIPLOG_REPO5/.codex-review.toml" <<'EOF'
[review
this-is = not = valid =
=== no key here ===
EOF
printf 'a\n' >"$SKIPLOG_REPO5/f.txt"
git -C "$SKIPLOG_REPO5" add . && git -C "$SKIPLOG_REPO5" commit -qm init
printf 'b\n' >>"$SKIPLOG_REPO5/f.txt"
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

: >"$SKIPLOG_LOG6"
i=0
while [ "$i" -lt 1000 ]; do
  printf 'seed-ts\trepo\tbranch\tsha\tseed\trow-%s\n' "$i" >>"$SKIPLOG_LOG6"
  i=$((i + 1))
done

seeded_count="$(wc -l <"$SKIPLOG_LOG6" | tr -d ' ')"
if [ "$seeded_count" != "1000" ]; then
  echo "FAIL: seeding sanity check — expected 1000 lines, got $seeded_count" >&2
  ERRORS=$((ERRORS + 1))
fi

run_skiplog_hook "$SKIPLOG_REPO6" "$TEST_DIR/skiplog-out6.txt" \
  env PATH="$SKIPLOG_BIN6:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_REVIEW_LOG="$SKIPLOG_LOG6" \
  CODEX_REVIEW_BASE="HEAD~1" \
  CODEX_REVIEW_DISABLE_CACHE=1 \
  || {
    echo "FAIL: hook exited non-zero in rollover test" >&2
    cat "$TEST_DIR/skiplog-out6.txt" >&2
    ERRORS=$((ERRORS + 1))
  }

final_count="$(wc -l <"$SKIPLOG_LOG6" | tr -d ' ')"
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
: >"$SKIPLOG_PROBE7"
SKIPLOG_PROBE7_MTIME_BEFORE="$(stat -f %m "$SKIPLOG_PROBE7" 2>/dev/null || stat -c %Y "$SKIPLOG_PROBE7")"

run_skiplog_hook "$SKIPLOG_REPO7" "$TEST_DIR/skiplog-out7.txt" \
  env PATH="$SKIPLOG_BIN7:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_REVIEW_LOG=/dev/null \
  CODEX_REVIEW_BASE="HEAD~1" \
  CODEX_REVIEW_DISABLE_CACHE=1 \
  || {
    echo "FAIL: hook exited non-zero with TOUCHSTONE_REVIEW_LOG=/dev/null" >&2
    cat "$TEST_DIR/skiplog-out7.txt" >&2
    ERRORS=$((ERRORS + 1))
  }

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
  || {
    echo "FAIL: hook exited non-zero with TOUCHSTONE_REVIEW_LOG=''" >&2
    cat "$TEST_DIR/skiplog-out8.txt" >&2
    ERRORS=$((ERRORS + 1))
  }

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

echo "==> Test: large Touchstone-managed diffs run scoped project-owned review"
SCOPED_REPO="$TEST_DIR/scoped-large-repo"
SCOPED_BIN="$TEST_DIR/scoped-large-bin"
SCOPED_PROMPT="$TEST_DIR/scoped-large-prompt.txt"
SCOPED_OUTPUT="$TEST_DIR/scoped-large-output.txt"
SCOPED_SUBCOMMAND="$TEST_DIR/scoped-large-subcommand.txt"
mkdir -p "$SCOPED_REPO/managed" "$SCOPED_REPO/scripts" "$SCOPED_REPO/lib" "$SCOPED_BIN"
git -C "$SCOPED_REPO" init -q >/dev/null 2>&1
git -C "$SCOPED_REPO" config user.name "Touchstone Test"
git -C "$SCOPED_REPO" config user.email "touchstone@example.com"
cp "$TOUCHSTONE_ROOT/.touchstone-review.toml" "$SCOPED_REPO/.touchstone-review.toml"
cp "$TOUCHSTONE_ROOT/scripts/codex-review.sh" "$SCOPED_REPO/scripts/codex-review.sh"
cp -r "$TOUCHSTONE_ROOT/lib/"* "$SCOPED_REPO/lib/"
cat >"$SCOPED_REPO/.touchstone-manifest" <<'EOF'
# Managed by touchstone.
.touchstone-manifest
managed/generated.txt
EOF
printf 'base\n' >"$SCOPED_REPO/app.txt"
printf 'one\n' >"$SCOPED_REPO/managed/generated.txt"
git -C "$SCOPED_REPO" add .touchstone-review.toml .touchstone-manifest app.txt managed/generated.txt
git -C "$SCOPED_REPO" commit -m "base" >/dev/null 2>&1
for i in $(seq 1 80); do
  printf 'managed line %s\n' "$i"
done >"$SCOPED_REPO/managed/generated.txt"
printf 'app change\n' >>"$SCOPED_REPO/app.txt"
git -C "$SCOPED_REPO" add app.txt managed/generated.txt
git -C "$SCOPED_REPO" commit -m "large managed sync plus app change" >/dev/null 2>&1

cat >"$SCOPED_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "main"
EOF

cat >"$SCOPED_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf '%s\n' "${1:-}" >"$SCOPED_SUBCOMMAND"
cat >"$SCOPED_PROMPT"
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$SCOPED_BIN/gh" "$SCOPED_BIN/conductor"

if (
  cd "$SCOPED_REPO"
  PATH="$SCOPED_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    SCOPED_PROMPT="$SCOPED_PROMPT" \
    SCOPED_SUBCOMMAND="$SCOPED_SUBCOMMAND" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MAX_DIFF_LINES=20 \
    TOUCHSTONE_NO_PREFLIGHT=1 \
    bash "$SCOPED_REPO/scripts/codex-review.sh" >"$SCOPED_OUTPUT" 2>&1
); then
  if [ "$(cat "$SCOPED_SUBCOMMAND" 2>/dev/null || true)" = "call" ] \
    && grep -q 'Large-diff scoped review boundary' "$SCOPED_PROMPT" \
    && grep -q 'Diff (scoped project-owned slice)' "$SCOPED_PROMPT" \
    && grep -q 'app.txt' "$SCOPED_PROMPT" \
    && ! grep -q 'managed/generated.txt' "$SCOPED_PROMPT" \
    && grep -q 'Running scoped project-owned review' "$SCOPED_OUTPUT"; then
    echo "==> PASS: large managed diff reviewed only the project-owned slice via Conductor call"
  else
    echo "FAIL: expected scoped project-owned review via Conductor call" >&2
    echo "subcommand: $(cat "$SCOPED_SUBCOMMAND" 2>/dev/null || true)" >&2
    sed -n '1,160p' "$SCOPED_PROMPT" >&2
    cat "$SCOPED_OUTPUT" >&2
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "FAIL: scoped large-diff review should exit cleanly" >&2
  cat "$SCOPED_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: unsliceable large diffs fail closed at merge gate"
UNSCOPED_REPO="$TEST_DIR/unscoped-large-repo"
UNSCOPED_BIN="$TEST_DIR/unscoped-large-bin"
UNSCOPED_OUTPUT="$TEST_DIR/unscoped-large-output.txt"
UNSCOPED_CALLS="$TEST_DIR/unscoped-large-calls.txt"
mkdir -p "$UNSCOPED_REPO" "$UNSCOPED_BIN"
git -C "$UNSCOPED_REPO" init -q >/dev/null 2>&1
git -C "$UNSCOPED_REPO" config user.name "Touchstone Test"
git -C "$UNSCOPED_REPO" config user.email "touchstone@example.com"
cp "$TOUCHSTONE_ROOT/.touchstone-review.toml" "$UNSCOPED_REPO/.touchstone-review.toml"
printf 'base\n' >"$UNSCOPED_REPO/app.txt"
git -C "$UNSCOPED_REPO" add .touchstone-review.toml app.txt
git -C "$UNSCOPED_REPO" commit -m "base" >/dev/null 2>&1
for i in $(seq 1 80); do
  printf 'app line %s\n' "$i"
done >"$UNSCOPED_REPO/app.txt"
git -C "$UNSCOPED_REPO" add app.txt
git -C "$UNSCOPED_REPO" commit -m "large app change" >/dev/null 2>&1

cat >"$UNSCOPED_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "main"
EOF

cat >"$UNSCOPED_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "doctor" ]; then printf '{"providers":[{"configured":true}]}\n'; exit 0; fi
printf 'called\n' >>"$UNSCOPED_CALLS"
cat >/dev/null
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$UNSCOPED_BIN/gh" "$UNSCOPED_BIN/conductor"
: >"$UNSCOPED_CALLS"

set +e
(
  cd "$UNSCOPED_REPO"
  PATH="$UNSCOPED_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    UNSCOPED_CALLS="$UNSCOPED_CALLS" \
    CODEX_REVIEW_BASE="HEAD~1" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    CODEX_REVIEW_MAX_DIFF_LINES=20 \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    TOUCHSTONE_NO_PREFLIGHT=1 \
    bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh" >"$UNSCOPED_OUTPUT" 2>&1
)
UNSCOPED_EXIT=$?
set -e
UNSCOPED_CALL_COUNT="$(wc -l <"$UNSCOPED_CALLS" | tr -d ' ')"
if [ "$UNSCOPED_EXIT" -eq 1 ] \
  && [ "$UNSCOPED_CALL_COUNT" = "0" ] \
  && grep -q 'diff too large' "$UNSCOPED_OUTPUT" \
  && grep -q 'on_error=fail-closed' "$UNSCOPED_OUTPUT"; then
  echo "==> PASS: unsliceable large diff blocks under fail-closed policy without spending review tokens"
else
  echo "FAIL: unsliceable large diff should block under fail-closed without invoking Conductor" >&2
  echo "exit code: $UNSCOPED_EXIT" >&2
  echo "conductor calls: $UNSCOPED_CALL_COUNT" >&2
  cat "$UNSCOPED_OUTPUT" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -ne 0 ]; then
  echo "==> FAIL: $ERRORS review hook assertion(s) failed" >&2
  exit 1
fi
echo "==> PASS: all review hook assertions passed"

# -----------------------------------------------------------------------------
# Consolidated feature coverage: subscription-only review routing
# -----------------------------------------------------------------------------
(
  #
  # Regression coverage for the subscription-only local review boundary.

  set -euo pipefail

  TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  HOOK="$TOUCHSTONE_ROOT/hooks/codex-review.sh"
  TEST_DIR="$(mktemp -d -t touchstone-subscription-review.XXXXXX)"
  trap 'rm -rf "$TEST_DIR"' EXIT

  ERRORS=0
  FAKE_BIN="$TEST_DIR/bin"
  mkdir -p "$FAKE_BIN"

  cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'main\n'
EOF

  cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  doctor)
    printf '{"providers":[{"configured":true}]}\n'
    exit 0
    ;;
  review | exec | call)
    printf '%s\n' "$*" >>"$CONDUCTOR_ARGS_LOG"
    cat >/dev/null
    if [ "${CONDUCTOR_RESULT:-clean}" = "fail" ]; then
      printf 'configured provider unavailable\n' >&2
      exit 42
    fi
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    printf 'unexpected conductor command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF

  chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/conductor"

  setup_repo() {
    local repo="$1"
    local config="${2:-}"

    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Touchstone Test"
    git -C "$repo" config user.email "touchstone@example.com"
    printf 'base\n' >"$repo/example.txt"
    if [ -n "$config" ]; then
      printf '%s\n' "$config" >"$repo/.touchstone-review.toml"
    fi
    git -C "$repo" add .
    git -C "$repo" commit -qm base
    printf 'change\n' >>"$repo/example.txt"
    git -C "$repo" add example.txt
    git -C "$repo" commit -qm change
  }

  run_review() {
    local repo="$1"
    local output="$2"
    local result="${3:-clean}"
    local auth_status="${4:-Logged in using ChatGPT}"
    local on_error="${5:-fail-closed}"

    (
      cd "$repo"
      PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
        CONDUCTOR_RESULT="$result" \
        CODEX_LOGIN_STATUS="$auth_status" \
        CODEX_REVIEW_BASE=HEAD~1 \
        CODEX_REVIEW_DISABLE_CACHE=1 \
        CODEX_REVIEW_MODE=review-only \
        CODEX_REVIEW_ON_ERROR="$on_error" \
        TOUCHSTONE_REVIEW_LOG=/dev/null \
        bash "$HOOK" >"$output" 2>&1
    )
  }

  echo "==> Test: omitted provider defaults to subscription Codex without fallback"
  DEFAULT_REPO="$TEST_DIR/default"
  DEFAULT_OUTPUT="$TEST_DIR/default.out"
  CONDUCTOR_ARGS_LOG="$TEST_DIR/default.args"
  export CONDUCTOR_ARGS_LOG
  setup_repo "$DEFAULT_REPO"
  set +e
  run_review "$DEFAULT_REPO" "$DEFAULT_OUTPUT" fail
  default_rc=$?
  set -e

  if [ "$default_rc" -eq 1 ] \
    && [ "$(wc -l <"$CONDUCTOR_ARGS_LOG" | tr -d ' ')" = "1" ] \
    && grep -q -- '^review .*--with codex' "$CONDUCTOR_ARGS_LOG" \
    && grep -q 'cost boundary:  subscription-codex' "$DEFAULT_OUTPUT" \
    && ! grep -q 'Retrying once' "$DEFAULT_OUTPUT"; then
    echo "==> PASS: default stayed on subscription Codex"
  else
    echo "FAIL: omitted provider should invoke Codex once and fail per on_error" >&2
    cat "$DEFAULT_OUTPUT" >&2
    cat "$CONDUCTOR_ARGS_LOG" >&2
    ERRORS=$((ERRORS + 1))
  fi

  echo "==> Test: subscription Codex rejects API-key authentication before Conductor"
  API_KEY_REPO="$TEST_DIR/api-key"
  API_KEY_OUTPUT="$TEST_DIR/api-key.out"
  CONDUCTOR_ARGS_LOG="$TEST_DIR/api-key.args"
  export CONDUCTOR_ARGS_LOG
  : >"$CONDUCTOR_ARGS_LOG"
  setup_repo "$API_KEY_REPO"
  set +e
  run_review "$API_KEY_REPO" "$API_KEY_OUTPUT" clean "Logged in using an API key"
  api_key_rc=$?
  set -e

  if [ "$api_key_rc" -eq 1 ] \
    && [ ! -s "$CONDUCTOR_ARGS_LOG" ] \
    && grep -q 'requires verified ChatGPT authentication (api-key)' "$API_KEY_OUTPUT" \
    && grep -q 'refusing API-key or unknown auth to avoid metered review spend' "$API_KEY_OUTPUT"; then
    echo "==> PASS: API-key auth was refused before provider invocation"
  else
    echo "FAIL: subscription Codex must never invoke Conductor under API-key auth" >&2
    cat "$API_KEY_OUTPUT" >&2
    cat "$CONDUCTOR_ARGS_LOG" >&2
    ERRORS=$((ERRORS + 1))
  fi

  echo "==> Test: unverifiable subscription auth follows fail-open without spending"
  AUTH_FAILURE_REPO="$TEST_DIR/auth-failure"
  AUTH_FAILURE_OUTPUT="$TEST_DIR/auth-failure.out"
  CONDUCTOR_ARGS_LOG="$TEST_DIR/auth-failure.args"
  export CONDUCTOR_ARGS_LOG
  : >"$CONDUCTOR_ARGS_LOG"
  setup_repo "$AUTH_FAILURE_REPO"
  run_review "$AUTH_FAILURE_REPO" "$AUTH_FAILURE_OUTPUT" clean status-failed fail-open

  if [ ! -s "$CONDUCTOR_ARGS_LOG" ] \
    && grep -q 'ChatGPT authentication not verified: status-failed' "$AUTH_FAILURE_OUTPUT" \
    && grep -Fq '[fail-open:FAIL_OPEN_PROVIDER_UNAVAILABLE]' "$AUTH_FAILURE_OUTPUT"; then
    echo "==> PASS: unverifiable auth failed open without provider invocation"
  else
    echo "FAIL: auth-status failure must preserve on_error without provider spend" >&2
    cat "$AUTH_FAILURE_OUTPUT" >&2
    cat "$CONDUCTOR_ARGS_LOG" >&2
    ERRORS=$((ERRORS + 1))
  fi

  echo "==> Test: explicit auto route is visible and unpinned"
  AUTO_REPO="$TEST_DIR/auto"
  AUTO_OUTPUT="$TEST_DIR/auto.out"
  CONDUCTOR_ARGS_LOG="$TEST_DIR/auto.args"
  export CONDUCTOR_ARGS_LOG
  setup_repo "$AUTO_REPO" '[review.conductor]
with = "auto"'
  run_review "$AUTO_REPO" "$AUTO_OUTPUT"

  if grep -q '^review ' "$CONDUCTOR_ARGS_LOG" \
    && ! grep -q -- '--with ' "$CONDUCTOR_ARGS_LOG" \
    && grep -q -- '--prefer ' "$CONDUCTOR_ARGS_LOG" \
    && grep -q 'cost boundary:  auto-explicit-may-be-metered' "$AUTO_OUTPUT"; then
    echo "==> PASS: auto-routing required explicit, visible opt-in"
  else
    echo "FAIL: explicit auto route should be unpinned and visibly metered-capable" >&2
    cat "$AUTO_OUTPUT" >&2
    cat "$CONDUCTOR_ARGS_LOG" >&2
    ERRORS=$((ERRORS + 1))
  fi

  echo "==> Test: explicit provider pin remains supported"
  METERED_REPO="$TEST_DIR/metered"
  METERED_OUTPUT="$TEST_DIR/metered.out"
  CONDUCTOR_ARGS_LOG="$TEST_DIR/metered.args"
  export CONDUCTOR_ARGS_LOG
  setup_repo "$METERED_REPO" '[review.conductor]
with = "openrouter"'
  run_review "$METERED_REPO" "$METERED_OUTPUT"

  if grep -q -- '^review .*--with openrouter' "$CONDUCTOR_ARGS_LOG" \
    && grep -q 'cost boundary:  explicit-provider:openrouter' "$METERED_OUTPUT"; then
    echo "==> PASS: metered provider required an explicit pin"
  else
    echo "FAIL: explicit provider should be forwarded and labeled" >&2
    cat "$METERED_OUTPUT" >&2
    cat "$CONDUCTOR_ARGS_LOG" >&2
    ERRORS=$((ERRORS + 1))
  fi

  echo "==> Test: managed defaults and installed hook mirror preserve the boundary"
  if grep -q '^with = "codex"$' "$TOUCHSTONE_ROOT/.touchstone-review.toml" \
    && grep -q '^high_scrutiny_mode = "off"$' "$TOUCHSTONE_ROOT/.touchstone-review.toml" \
    && grep -q 'AI_CONDUCTOR_WITH="codex"' "$TOUCHSTONE_ROOT/templates/setup.sh" \
    && cmp -s "$TOUCHSTONE_ROOT/hooks/codex-review.sh" "$TOUCHSTONE_ROOT/scripts/codex-review.sh"; then
    echo "==> PASS: managed defaults are subscription-only"
  else
    echo "FAIL: managed config, setup status, and hook mirror must agree" >&2
    ERRORS=$((ERRORS + 1))
  fi

  if [ "$ERRORS" -gt 0 ]; then
    echo "==> FAIL: $ERRORS assertion(s) failed" >&2
    exit 1
  fi

  echo "==> PASS: all subscription review routing assertions passed"

)

# -----------------------------------------------------------------------------
# Consolidated feature coverage: review log isolation
# -----------------------------------------------------------------------------
(
  #
  # tests/test-review-log-isolation.sh — guard user review audit state from tests.

  set -euo pipefail

  TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  TEST_DIR="$(mktemp -d -t touchstone-test-review-log-isolation.XXXXXX)"
  trap 'rm -rf "$TEST_DIR"' EXIT

  ERRORS=0
  RELEVANT_TESTS="
tests/test-review-dry-run.sh
tests/test-migrate-review-config.sh
tests/test-events-json.sh
"

  fail() {
    echo "FAIL: $*" >&2
    ERRORS=$((ERRORS + 1))
  }

  run_relevant_suite() {
    local fake_home="$1"
    local mode="$2"
    local test_path output

    for test_path in $RELEVANT_TESTS; do
      output="$TEST_DIR/${mode}-$(basename "$test_path").out"
      if ! HOME="$fake_home" bash "$TOUCHSTONE_ROOT/$test_path" >"$output" 2>&1; then
        fail "$test_path failed under isolated HOME ($mode)"
        cat "$output" >&2
      fi
    done
  }

  echo "==> Test: review and merge fixture class declares isolated audit state"
  for test_path in "$TOUCHSTONE_ROOT"/tests/test-*.sh; do
    [ "$(basename "$test_path")" = "test-review-log-isolation.sh" ] && continue

    invokes_real_review=0
    if grep -qF 'cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh"' "$test_path" \
      || grep -qF 'bash "$TOUCHSTONE_ROOT/scripts/codex-review.sh"' "$test_path" \
      || grep -qF 'bash "$TOUCHSTONE_ROOT/scripts/conductor-review.sh"' "$test_path" \
      || grep -qF 'bash "$TOUCHSTONE_ROOT/hooks/codex-review.sh"' "$test_path" \
      || grep -qF 'bash "$TOUCHSTONE_ROOT/hooks/conductor-review.sh"' "$test_path" \
      || grep -qF 'bash "$TOUCHSTONE_ROOT/bin/touchstone" review' "$test_path" \
      || grep -qF 'bash "$TOUCHSTONE_BIN" review' "$test_path"; then
      invokes_real_review=1
    fi

    if [ "$invokes_real_review" -eq 1 ] \
      && ! grep -q 'TOUCHSTONE_REVIEW_LOG=' "$test_path" \
      && ! grep -q 'touchstone_isolate_review_log ' "$test_path"; then
      fail "$(basename "$test_path") invokes a real review/merge path without isolated audit state"
    fi
  done

  echo "==> Test: isolated suite cannot create the default user review log"
  EMPTY_HOME="$TEST_DIR/empty-home"
  mkdir -p "$EMPTY_HOME"
  run_relevant_suite "$EMPTY_HOME" empty
  if [ -e "$EMPTY_HOME/.touchstone-review-log" ]; then
    fail "relevant suite created the default review log in an empty HOME"
  fi

  echo "==> Test: isolated suite cannot change existing user review state"
  EXISTING_HOME="$TEST_DIR/existing-home"
  EXISTING_LOG="$EXISTING_HOME/.touchstone-review-log"
  mkdir -p "$EXISTING_HOME"
  printf 'production-review-evidence-must-survive\n' >"$EXISTING_LOG"
  before="$(shasum "$EXISTING_LOG" | awk '{print $1}')"
  run_relevant_suite "$EXISTING_HOME" existing
  after="$(shasum "$EXISTING_LOG" | awk '{print $1}')"
  if [ "$before" != "$after" ]; then
    fail "relevant suite changed the preexisting default review log"
  fi

  if [ "$ERRORS" -ne 0 ]; then
    echo "FAIL: $ERRORS review-log isolation assertion(s) failed" >&2
    exit 1
  fi

  echo "PASS: review tests cannot mutate default user review state"

)
