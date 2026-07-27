#!/usr/bin/env bash
#
# tests/test-advisory-at-pr-open.sh — PR-open advisory review comment flow.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-advisory-pr-open.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
RUN_DIR="$TEST_DIR/run"
REPO_DIR="$TEST_DIR/repo"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$RUN_DIR/scripts" "$RUN_DIR/lib" "$REPO_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$RUN_DIR/scripts/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$RUN_DIR/scripts/issue-claim-check.sh"
cp "$TOUCHSTONE_ROOT/lib/review-comment.sh" "$RUN_DIR/lib/review-comment.sh"
cp "$TOUCHSTONE_ROOT/lib/preflight.sh" "$RUN_DIR/lib/preflight.sh"
cp "$TOUCHSTONE_ROOT/lib/preflight-scope.sh" "$RUN_DIR/lib/preflight-scope.sh"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$RUN_DIR/lib/toml.sh"
chmod +x "$RUN_DIR/scripts/open-pr.sh" "$RUN_DIR/scripts/issue-claim-check.sh"

cat >"$RUN_DIR/scripts/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'TOUCHSTONE_PREFLIGHT_ALREADY_RAN=%s\n' "${TOUCHSTONE_PREFLIGHT_ALREADY_RAN:-}"
  printf 'TOUCHSTONE_CONDUCTOR_WITH=%s\n' "${TOUCHSTONE_CONDUCTOR_WITH:-}"
} >"$CODEX_REVIEW_STUB_ENV_LOG"
printf '{"reviewer":"Conductor","provider":"claude","model":"claude-opus-4-1","peer_provider":"none","iterations":1,"mode":"%s","findings":%s,"exit_reason":"%s"}\n' \
  "${CODEX_REVIEW_MODE:-unknown}" "${CODEX_REVIEW_STUB_FINDINGS:-0}" "${CODEX_REVIEW_STUB_REASON:-clean}" > "$CODEX_REVIEW_SUMMARY_FILE"
if [ "${CODEX_REVIEW_STUB_EXIT:-0}" != "0" ]; then
  if [ -n "${CODEX_REVIEW_STUB_OUTPUT:-}" ]; then
    printf '%s\n' "$CODEX_REVIEW_STUB_OUTPUT"
  else
    printf -- '- blocking advisory finding\n'
  fi
  printf 'CODEX_REVIEW_BLOCKED\n'
  exit "$CODEX_REVIEW_STUB_EXIT"
fi
printf 'CODEX_REVIEW_CLEAN\n'
EOF
chmod +x "$RUN_DIR/scripts/codex-review.sh"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "repo view")
    echo "main"
    ;;
  "pr list")
    echo ""
    ;;
  "pr create")
    echo "https://example.test/touchstone/pull/456"
    ;;
  "pr view")
    printf '%s\n' "${GH_PR_HEAD_SHA:-$(git rev-parse HEAD)}"
    ;;
  "pr comment")
    if [ "${4:-}" != "--body" ]; then
      echo "unexpected gh pr comment args: $*" >&2
      exit 1
    fi
    printf '%s\n' "${5:-}" >> "$GH_COMMENT_FILE"
    ;;
  "api --paginate")
    if [ "${GH_API_FAIL:-0}" = "1" ]; then
      echo "mock comment inspection failure" >&2
      exit 1
    fi
    if [ -n "${GH_EXISTING_REQUEST_FILE:-}" ]; then
      cat "$GH_EXISTING_REQUEST_FILE"
    else
      printf '%s\n' "${GH_EXISTING_REQUEST_BODY:-}"
    fi
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

REAL_GIT="$(command -v git)"
cat >"$FAKE_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "push" ]; then
  echo "[mock] git push \$*"
  if [ "\${GIT_PUSH_CREATE_LOCAL_COMMIT:-0}" = "1" ]; then
    printf 'pre-push autofix\n' >> pre-push-autofix.txt
    "$REAL_GIT" add pre-push-autofix.txt
    "$REAL_GIT" commit -m "fix: simulated pre-push autofix" >/dev/null
  fi
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE_BIN/git"

git -C "$REPO_DIR" init -b main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "base commit" >/dev/null 2>&1
git -C "$REPO_DIR" checkout -b feat/advisory >/dev/null 2>&1
printf 'change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test advisory" >/dev/null 2>&1

run_open_pr() {
  local output_file="$1"
  shift
  (
    cd "${OPEN_PR_WORKDIR:-$REPO_DIR}"
    invoke_open_pr() {
      PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        GH_COMMENT_FILE="$TEST_DIR/comments" \
        GH_API_FAIL="${GH_API_FAIL:-0}" \
        GH_EXISTING_REQUEST_BODY="${GH_EXISTING_REQUEST_BODY:-}" \
        GH_EXISTING_REQUEST_FILE="${GH_EXISTING_REQUEST_FILE:-}" \
        GH_PR_HEAD_SHA="${GH_PR_HEAD_SHA:-}" \
        GIT_PUSH_CREATE_LOCAL_COMMIT="${GIT_PUSH_CREATE_LOCAL_COMMIT:-0}" \
        TOUCHSTONE_PR_HEAD_CONVERGENCE_ATTEMPTS="${TOUCHSTONE_PR_HEAD_CONVERGENCE_ATTEMPTS:-1}" \
        CODEX_REVIEW_STUB_EXIT="${CODEX_REVIEW_STUB_EXIT:-0}" \
        CODEX_REVIEW_STUB_FINDINGS="${CODEX_REVIEW_STUB_FINDINGS:-0}" \
        CODEX_REVIEW_STUB_REASON="${CODEX_REVIEW_STUB_REASON:-clean}" \
        CODEX_REVIEW_STUB_OUTPUT="${CODEX_REVIEW_STUB_OUTPUT:-}" \
        CODEX_REVIEW_STUB_ENV_LOG="$TEST_DIR/review-env" \
        bash "$RUN_DIR/scripts/open-pr.sh" "$@"
    }
    if [ -n "${OPEN_PR_CONFIRM_DIRTY:-}" ]; then
      printf '%s\n' "$OPEN_PR_CONFIRM_DIRTY" | invoke_open_pr "$@"
    else
      invoke_open_pr "$@"
    fi
  ) >"$output_file" 2>&1
}

reset_case() {
  rm -f "$TEST_DIR/comments" "$TEST_DIR/review-env"
  unset CODEX_REVIEW_STUB_OUTPUT
}

echo "==> Case 1: clean advisory review posts clean summary"
reset_case
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "configure advisory review" >/dev/null 2>&1
OUT="$TEST_DIR/clean.out"
CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT"
if grep -q '^Conductor review clean - provider: claude, model: claude-opus-4-1, peer: none, iterations: 1, mode: review-only, findings: 0$' "$TEST_DIR/comments"; then
  echo "    PASS"
else
  echo "    FAIL: clean advisory comment missing" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 1b: advisory review is disabled by default"
reset_case
printf '[review]\npreflight_required = false\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "remove advisory setting" >/dev/null 2>&1
OUT="$TEST_DIR/default-disabled.out"
CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT"
if grep -q 'Advisory review at PR open disabled; merge-gate review still runs during auto-merge.' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: default advisory review should be disabled" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 2: findings advisory review is non-blocking and posts findings"
reset_case
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "re-enable advisory review" >/dev/null 2>&1
OUT="$TEST_DIR/findings.out"
CODEX_REVIEW_STUB_EXIT=1 CODEX_REVIEW_STUB_FINDINGS=1 CODEX_REVIEW_STUB_REASON=blocked run_open_pr "$OUT"
if grep -q 'advisory review found 1 finding(s)' "$TEST_DIR/comments" \
  && grep -q '^- blocking advisory finding$' "$TEST_DIR/comments" \
  && grep -q '^https://example.test/touchstone/pull/456$' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: findings advisory comment missing or PR open blocked" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 2b: unparseable advisory findings expose raw reviewer output"
reset_case
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = true\n# parser fallback case\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "exercise unparseable advisory" >/dev/null 2>&1
OUT="$TEST_DIR/unparseable-findings.out"
CODEX_REVIEW_STUB_EXIT=1 \
  CODEX_REVIEW_STUB_FINDINGS=1 \
  CODEX_REVIEW_STUB_REASON=blocked \
  CODEX_REVIEW_STUB_OUTPUT=$'Reviewer wrote prose only about a real blocker.' \
  run_open_pr "$OUT"
if grep -q 'advisory review found 1 finding(s)' "$TEST_DIR/comments" \
  && grep -q 'Review transcript excerpt' "$TEST_DIR/comments" \
  && grep -q 'Reviewer wrote prose only about a real blocker' "$TEST_DIR/comments" \
  && grep -q '^https://example.test/touchstone/pull/456$' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: unparseable advisory findings should expose raw reviewer output" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 3: advisory_at_pr_open=false skips review and comment"
reset_case
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = false\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "disable advisory review" >/dev/null 2>&1
OUT="$TEST_DIR/disabled.out"
CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT"
if grep -q 'Advisory review at PR open disabled; merge-gate review still runs during auto-merge.' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: disabled advisory review still posted a comment" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 4: clean advisory preflight is passed through to review"
reset_case
git -C "$REPO_DIR" update-ref refs/remotes/origin/main main
printf '[review]\npreflight_required = true\nadvisory_at_pr_open = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "enable advisory preflight" >/dev/null 2>&1
OUT="$TEST_DIR/preflight.out"
(
  export TOUCHSTONE_CONDUCTOR_WITH="deepseek-reasoner"
  CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT"
)
if grep -q '^TOUCHSTONE_PREFLIGHT_ALREADY_RAN=true$' "$TEST_DIR/review-env" \
  && grep -q '^TOUCHSTONE_CONDUCTOR_WITH=deepseek-reasoner$' "$TEST_DIR/review-env" \
  && grep -q 'Deterministic preflight clean (cached=false' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: advisory review should know clean preflight already ran" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/review-env" ] && cat "$TEST_DIR/review-env" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 5: repeated advisory preflight reuses the exact clean marker"
reset_case
OUT="$TEST_DIR/preflight-cached.out"
(
  export TOUCHSTONE_CONDUCTOR_WITH="deepseek-reasoner"
  CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT"
)
if grep -q 'Deterministic preflight clean (cached=true' "$OUT" \
  && grep -q '^TOUCHSTONE_PREFLIGHT_ALREADY_RAN=true$' "$TEST_DIR/review-env"; then
  echo "    PASS"
else
  echo "    FAIL: repeated advisory preflight should reuse the clean marker" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/review-env" ] && cat "$TEST_DIR/review-env" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 6: nested open-pr warning lists root untracked files"
reset_case
mkdir -p "$REPO_DIR/nested"
printf 'root scratch\n' >"$REPO_DIR/root-untracked.txt"
OUT="$TEST_DIR/preflight-subdir-untracked-warning.out"
(
  export OPEN_PR_WORKDIR="$REPO_DIR/nested"
  export OPEN_PR_CONFIRM_DIRTY="y"
  CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT"
)
rm -f "$REPO_DIR/root-untracked.txt"
if grep -q 'WARNING: working tree has uncommitted changes' "$OUT" \
  && grep -q 'Untracked files detected:' "$OUT" \
  && grep -q 'root-untracked.txt' "$OUT" \
  && grep -q '^https://example.test/touchstone/pull/456$' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: nested open-pr warning should list root-level untracked files" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 7: request_on_push posts one head-bound GitHub Codex request"
reset_case
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = false\n\n[review.pr_triggered]\nprovider = "github-codex"\nrequest_on_push = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "request codex review on push" >/dev/null 2>&1
REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-on-push.out"
run_open_pr "$OUT"
if grep -q '^@codex review$' "$TEST_DIR/comments" \
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$REQUEST_HEAD -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $REQUEST_HEAD" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected one head-bound GitHub Codex request" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8: request_on_push is idempotent for the same head"
EXISTING_REQUEST_BODY="$(cat "$TEST_DIR/comments")"
reset_case
OUT="$TEST_DIR/request-idempotent.out"
GH_EXISTING_REQUEST_BODY="$EXISTING_REQUEST_BODY" run_open_pr "$OUT"
if grep -q "GitHub Codex review already requested for head $REQUEST_HEAD" "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: repeated request should not post another comment" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8b: large trailing comment text preserves request idempotency"
reset_case
LARGE_REQUEST_FILE="$TEST_DIR/large-existing-request"
printf '%s\n' "$EXISTING_REQUEST_BODY" >"$LARGE_REQUEST_FILE"
head -c 131072 /dev/zero | tr '\0' x >>"$LARGE_REQUEST_FILE"
OUT="$TEST_DIR/request-idempotent-large.out"
GH_EXISTING_REQUEST_FILE="$LARGE_REQUEST_FILE" run_open_pr "$OUT"
if grep -q "GitHub Codex review already requested for head $REQUEST_HEAD" "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: a large existing comment payload should not duplicate the request" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8c: request marker follows the selected push head when a hook advances local HEAD"
reset_case
SELECTED_REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-remote-head.out"
GH_PR_HEAD_SHA="$SELECTED_REQUEST_HEAD" GIT_PUSH_CREATE_LOCAL_COMMIT=1 run_open_pr "$OUT"
ADVANCED_LOCAL_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
if [ "$ADVANCED_LOCAL_HEAD" != "$SELECTED_REQUEST_HEAD" ] \
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$SELECTED_REQUEST_HEAD -->" "$TEST_DIR/comments" \
  && ! grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$ADVANCED_LOCAL_HEAD -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $SELECTED_REQUEST_HEAD" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: request marker should bind to the SHA selected before the pre-push hook" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8d: a newly opened draft PR still requests review for its pushed head"
reset_case
DRAFT_REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-draft.out"
run_open_pr "$OUT" --draft
if grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$DRAFT_REQUEST_HEAD -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $DRAFT_REQUEST_HEAD" "$OUT" \
  && grep -q 'Opened as draft' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: a draft PR should request review before returning" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9: request inspection failure stops before merge waiting"
reset_case
OUT="$TEST_DIR/request-inspection-failure.out"
if GH_API_FAIL=1 run_open_pr "$OUT"; then
  echo "    FAIL: request inspection failure should fail closed" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q 'failed to inspect prior GitHub Codex review requests' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: request inspection failure lacked actionable diagnostics" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 10: advisory preflight cache hashes relevant root worktree state from subdirs"
reset_case
printf '[review]\npreflight_required = true\nadvisory_at_pr_open = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "restore advisory preflight" >/dev/null 2>&1
mkdir -p "$REPO_DIR/nested"
printf 'change\nroot dirty one\n' >"$REPO_DIR/file.txt"
OUT="$TEST_DIR/preflight-subdir-first.out"
(
  export OPEN_PR_WORKDIR="$REPO_DIR/nested"
  export OPEN_PR_CONFIRM_DIRTY="y"
  CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT"
)
printf 'change\nroot dirty two\n' >"$REPO_DIR/file.txt"
OUT2="$TEST_DIR/preflight-subdir-second.out"
(
  export OPEN_PR_WORKDIR="$REPO_DIR/nested"
  export OPEN_PR_CONFIRM_DIRTY="y"
  CODEX_REVIEW_STUB_EXIT=0 CODEX_REVIEW_STUB_FINDINGS=0 CODEX_REVIEW_STUB_REASON=clean run_open_pr "$OUT2"
)
if grep -q 'Deterministic preflight clean (cached=false' "$OUT" \
  && grep -q 'Deterministic preflight clean (cached=false' "$OUT2" \
  && ! grep -q 'Deterministic preflight clean (cached=true' "$OUT2"; then
  echo "    PASS"
else
  echo "    FAIL: subdir-launched advisory preflight missed root worktree state" >&2
  cat "$OUT" >&2
  cat "$OUT2" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: advisory review at PR open is commented and non-blocking"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
