#!/usr/bin/env bash
#
# tests/test-review-findings-checkpoint.sh — Issue #163: verify that a
# BLOCKED review persists its findings, and a subsequent review on a
# descendant HEAD prepends a verification-checkpoint block to the
# reviewer prompt instead of starting fresh. A CLEAN review removes the
# findings file. A force-push that orphans the recorded HEAD also
# removes the findings file (treated as blank slate).
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-review-findings.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

REPO="$TEST_DIR/repo"
FAKE_BIN="$TEST_DIR/bin"
PROMPT_LOG="$TEST_DIR/prompts.log"
mkdir -p "$REPO" "$FAKE_BIN"

# Fake conductor that:
#  - responds to `doctor` with the configured-true payload bootstrap expects
#  - on `review`/`exec`/`call`: appends the input prompt (read from stdin) to
#    PROMPT_LOG, then emits the verdict named by the env var
#    FAKE_CONDUCTOR_VERDICT (one of: BLOCKED, CLEAN). For BLOCKED it also
#    emits two synthetic finding lines so write_review_findings has data
#    to persist.
cat >"$FAKE_BIN/conductor" <<'CONDUCTOR_EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  doctor)
    printf '{"configured": true}\n'
    ;;
  review|exec|call)
    cat >> "$PROMPT_LOG"
    printf -- '--- end of prompt ---\n' >> "$PROMPT_LOG"
    case "${FAKE_CONDUCTOR_VERDICT:-BLOCKED}" in
      CLEAN)
        printf 'No blocking issues found.\n'
        printf 'CODEX_REVIEW_CLEAN\n'
        ;;
      BLOCKED)
        printf 'Blockers found:\n'
        printf -- '- src/foo.py:10 — boundary check missing\n'
        printf -- '- src/bar.py:42 — fail-open path swallows error\n'
        printf 'CODEX_REVIEW_BLOCKED\n'
        ;;
      *)
        echo "test bug: unknown FAKE_CONDUCTOR_VERDICT '$FAKE_CONDUCTOR_VERDICT'" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected conductor args: $*" >&2
    exit 1
    ;;
esac
CONDUCTOR_EOF
chmod +x "$FAKE_BIN/conductor"

# Set up a minimal repo with two commits so HEAD~1 is a real ref.
(
  cd "$REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Touchstone Test"
  mkdir -p lib
  cp -r "$TOUCHSTONE_ROOT/lib/"* lib/
  printf '[review]\nreviewer = "conductor"\nmode = "review-only"\n' >.codex-review.toml
  printf 'base\n' >example.txt
  git add .codex-review.toml example.txt
  git commit -q -m "base"
  printf 'change 1\n' >>example.txt
  git add example.txt
  git commit -q -m "change 1"
)

run_review() {
  local verdict="$1"
  (
    cd "$REPO" \
      && PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        PROMPT_LOG="$PROMPT_LOG" \
        FAKE_CONDUCTOR_VERDICT="$verdict" \
        CODEX_REVIEW_BASE=HEAD~1 \
        CODEX_REVIEW_BRANCH_NAME="feature/findings-checkpoint" \
        CODEX_REVIEW_DISABLE_CACHE=1 \
        TOUCHSTONE_REVIEW_LOG=/dev/null \
        bash "$TOUCHSTONE_ROOT/scripts/codex-review.sh" \
        >"$TEST_DIR/run-$verdict.out" 2>&1
  ) || true
}

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

findings_file() {
  # git rev-parse --git-path returns a path relative to the repo it ran
  # in; we resolve it against $REPO so the assertion can run from any cwd.
  local rel
  rel="$(cd "$REPO" && git rev-parse --git-path touchstone/reviewer-findings/feature_findings-checkpoint.findings)"
  case "$rel" in
    /*) printf '%s' "$rel" ;;
    *) printf '%s/%s' "$REPO" "$rel" ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 1: a BLOCKED review must persist its findings.
# ---------------------------------------------------------------------------
echo "==> Step 1: BLOCKED review writes findings file"
: >"$PROMPT_LOG"
run_review BLOCKED

FINDINGS_FILE="$(findings_file)"
if [ ! -f "$FINDINGS_FILE" ]; then
  fail "BLOCKED review did not write findings file at $FINDINGS_FILE"
fi
grep -q '^result=CODEX_REVIEW_BLOCKED$' "$FINDINGS_FILE" || fail "findings file missing result=CODEX_REVIEW_BLOCKED"
grep -q '^branch=feature/findings-checkpoint$' "$FINDINGS_FILE" || fail "findings file missing branch line"
grep -q '^head=' "$FINDINGS_FILE" || fail "findings file missing head line"
grep -q '^findings_count=2$' "$FINDINGS_FILE" || fail "findings_count should be 2"
grep -qF -- '- src/foo.py:10 — boundary check missing' "$FINDINGS_FILE" || fail "first finding missing"
grep -qF -- '- src/bar.py:42 — fail-open path swallows error' "$FINDINGS_FILE" || fail "second finding missing"

# Prompt for the first review must NOT contain the verification
# checkpoint (no prior file existed when it ran).
if grep -q 'Prior review findings' "$PROMPT_LOG"; then
  fail "first BLOCKED prompt unexpectedly contained a verification checkpoint"
fi

# ---------------------------------------------------------------------------
# Step 2: descendant HEAD + new BLOCKED review must include the verification
# checkpoint in the prompt and refresh the findings file.
# ---------------------------------------------------------------------------
echo "==> Step 2: descendant HEAD prepends verification checkpoint"
(cd "$REPO" && printf 'change 2\n' >>example.txt && git add example.txt && git commit -q -m "change 2")

: >"$PROMPT_LOG"
run_review BLOCKED

if ! grep -q 'Prior review findings — verify, do not restart' "$PROMPT_LOG"; then
  fail "second prompt missing verification-checkpoint header"
fi
if ! grep -qF -- '- src/foo.py:10 — boundary check missing' "$PROMPT_LOG"; then
  fail "second prompt missing first prior finding"
fi
if ! grep -q 'Directive for this iteration' "$PROMPT_LOG"; then
  fail "second prompt missing directive block"
fi

# Findings file should still exist (refreshed at new HEAD).
[ -f "$FINDINGS_FILE" ] || fail "findings file disappeared after second BLOCKED review"

# ---------------------------------------------------------------------------
# Step 3: a CLEAN review clears the findings file.
# ---------------------------------------------------------------------------
echo "==> Step 3: CLEAN review clears findings file"
(cd "$REPO" && printf 'change 3\n' >>example.txt && git add example.txt && git commit -q -m "change 3")

: >"$PROMPT_LOG"
run_review CLEAN
if [ -f "$FINDINGS_FILE" ]; then
  fail "CLEAN review did not clear findings file at $FINDINGS_FILE"
fi

# ---------------------------------------------------------------------------
# Step 4: stale recorded HEAD (force-push that orphans prior_head) → file
# is removed and no checkpoint appears in the next prompt.
# ---------------------------------------------------------------------------
echo "==> Step 4: orphaned prior HEAD is treated as blank slate"

# Re-record findings, then force-reset the branch so prior_head is no
# longer in the repo.
: >"$PROMPT_LOG"
run_review BLOCKED
[ -f "$FINDINGS_FILE" ] || fail "could not re-create findings file for step 4"

(
  cd "$REPO"
  git checkout -q -B feature/findings-checkpoint HEAD~3 2>/dev/null || true
  git gc --prune=now >/dev/null 2>&1 || true
)

: >"$PROMPT_LOG"
run_review BLOCKED
if grep -q 'Prior review findings — verify, do not restart' "$PROMPT_LOG"; then
  fail "blank-slate prompt unexpectedly contained a verification checkpoint after force-reset"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS assertion(s) failed" >&2
  echo "    last reviewer output:" >&2
  cat "$TEST_DIR"/run-*.out >&2
  exit 1
fi

echo "==> PASS: review findings persistence + verification checkpoint"
