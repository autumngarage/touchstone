#!/usr/bin/env bash
#
# tests/test-review-comment.sh — clean-review PR comment helper and merge wiring.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-review-comment.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: format_clean_review_comment produces one-line audit text"
# shellcheck source=../lib/review-comment.sh
source "$TOUCHSTONE_ROOT/lib/review-comment.sh"

echo "==> Test: review comment parser accepts alternate finding formats"
PARSER_OUTPUT=$'1. app/main.py:12 - numbered finding\n### Finding 2: lib/review.sh:44 - heading finding\nIssue: missing operator-visible fallback\n### Finding 4\nmulti-line heading detail\nCODEX_REVIEW_BLOCKED'
PARSER_FINDINGS="$(review_comment_findings_from_output "$PARSER_OUTPUT")"
EXPECTED_FINDINGS=$'- app/main.py:12 - numbered finding\n- Finding 2: lib/review.sh:44 - heading finding\n- Issue: missing operator-visible fallback\n- Finding 4 - multi-line heading detail'
if [ "$PARSER_FINDINGS" = "$EXPECTED_FINDINGS" ]; then
  echo "==> PASS: alternate finding formats normalize to canonical bullets"
else
  echo "FAIL: alternate finding parser output mismatch" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$EXPECTED_FINDINGS" "$PARSER_FINDINGS" >&2
  exit 1
fi

echo "==> Test: unparseable nonzero findings include raw transcript excerpt"
UNPARSEABLE_OUTPUT=$'Reviewer saw a problem but wrote prose only.\nCODEX_REVIEW_BLOCKED'
COMMENT="$(format_advisory_findings_comment '{"reviewer":"Conductor","provider":"openrouter","model":"gpt-5.3-codex","peer_provider":"none","iterations":1,"mode":"review-only","findings":1}' "$UNPARSEABLE_OUTPUT")"
if printf '%s\n' "$COMMENT" | grep -q 'no supported findings format was parsed' \
  && printf '%s\n' "$COMMENT" | grep -q 'Review transcript excerpt' \
  && printf '%s\n' "$COMMENT" | grep -q 'Reviewer saw a problem but wrote prose only'; then
  echo "==> PASS: advisory comment exposes raw unparseable reviewer output"
else
  echo "FAIL: unparseable advisory findings should include a raw transcript excerpt" >&2
  printf '%s\n' "$COMMENT" >&2
  exit 1
fi

COMMENT="$(format_clean_review_comment '{"reviewer":"Conductor","provider":"gemini","model":"gemini-2.5-pro","peer_provider":"none","iterations":1,"mode":"review-only","findings":0}')"
EXPECTED='Conductor review clean - provider: gemini, model: gemini-2.5-pro, peer: none, iterations: 1, mode: review-only, findings: 0'
if [ "$COMMENT" = "$EXPECTED" ]; then
  echo "==> PASS: formatter output matches"
else
  echo "FAIL: formatter output mismatch" >&2
  printf 'expected: %s\nactual:   %s\n' "$EXPECTED" "$COMMENT" >&2
  exit 1
fi

echo "==> Test: format_clean_review_comment surfaces fallback diagnostics"
COMMENT="$(format_clean_review_comment '{"reviewer":"Conductor","provider":"openrouter","model":"gpt-5.1","peer_provider":"none","iterations":1,"mode":"fix","findings":0,"fallback_attempted":true,"fallback_primary_provider":"codex","fallback_retry_provider":"openrouter","fallback_excluded_providers":"codex","fallback_reason":"reviewer exit 1","diagnostics_file":"/tmp/review-diagnostics.jsonl","diagnostics_events":1}')"
if printf '%s\n' "$COMMENT" | grep -q 'Fallback: `codex` -> `openrouter` (reviewer exit 1)' \
  && printf '%s\n' "$COMMENT" | grep -q 'Fallback excluded: `codex`' \
  && printf '%s\n' "$COMMENT" | grep -q 'Diagnostics: `/tmp/review-diagnostics.jsonl` (1 event(s))'; then
  echo "==> PASS: formatter includes fallback diagnostics"
else
  echo "FAIL: expected fallback diagnostics in clean review comment" >&2
  printf '%s\n' "$COMMENT" >&2
  exit 1
fi

MERGE_DIR="$TEST_DIR/merge"
FAKE_BIN="$MERGE_DIR/bin"
mkdir -p "$MERGE_DIR/scripts" "$MERGE_DIR/lib" "$MERGE_DIR/repo" "$FAKE_BIN"
cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$MERGE_DIR/scripts/merge-pr.sh"
cp "$TOUCHSTONE_ROOT/lib/preflight.sh" "$MERGE_DIR/lib/preflight.sh"
cp "$TOUCHSTONE_ROOT/lib/review-comment.sh" "$MERGE_DIR/lib/review-comment.sh"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$MERGE_DIR/lib/toml.sh"
cat >"$MERGE_DIR/scripts/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
summary="${CODEX_REVIEW_STUB_SUMMARY:-}"
if [ -z "$summary" ]; then
  summary="$(printf '{"reviewer":"Conductor","provider":"claude","model":"claude-opus-4-1","peer_provider":"none","iterations":1,"mode":"%s","findings":0,"exit_reason":"clean"}' "${CODEX_REVIEW_MODE:-unknown}")"
fi
printf '%s\n' "$summary" > "$CODEX_REVIEW_SUMMARY_FILE"
printf 'review invoked\n' > "$CODEX_REVIEW_LOG"
if [ -n "${CODEX_REVIEW_STUB_OUTPUT:-}" ]; then
  printf '%s\n' "$CODEX_REVIEW_STUB_OUTPUT"
fi
exit "${CODEX_REVIEW_STUB_EXIT:-0}"
EOF
chmod +x "$MERGE_DIR/scripts/merge-pr.sh" "$MERGE_DIR/scripts/codex-review.sh"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "repo view")
    json_fields=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      fi
      prev="$arg"
    done
    case "$json_fields" in
      defaultBranchRef) echo "main" ;;
      nameWithOwner) echo "example/touchstone" ;;
      *) echo "unexpected gh repo view json: $json_fields" >&2; exit 1 ;;
    esac
    ;;
  "pr view")
    case "${5:-}" in
      state)
        if [ -f "${GH_MERGED_MARKER:-/dev/null/never}" ]; then echo "MERGED"; else echo "OPEN"; fi
        ;;
      headRefName) echo "feature/test" ;;
      headRefOid) echo "pr-head-oid" ;;
      isDraft) echo "false" ;;
      reviewDecision) echo "" ;;
      mergeStateStatus,mergeable) echo "CLEAN MERGEABLE" ;;
      mergedAt) echo "2026-05-07T15:00:00Z" ;;
      mergeCommit) echo "squash-oid" ;;
      *) echo "unexpected gh pr view args: $*" >&2; exit 1 ;;
    esac
    ;;
  "api graphql")
    echo ""
    ;;
  "pr checkout")
    echo checked-out > "$GH_CHECKOUT_FILE"
    ;;
  "pr comment")
    if [ "${4:-}" != "--body" ]; then
      echo "unexpected gh pr comment args: $*" >&2
      exit 1
    fi
    printf '%s\n' "${5:-}" >> "$GH_COMMENT_FILE"
    ;;
  "pr merge")
    echo "$7" > "$GH_MERGE_HEAD_FILE"
    [ -n "${GH_MERGED_MARKER:-}" ] && touch "$GH_MERGED_MARKER"
    if [ "${8:-}" = "--body" ]; then
      printf '%s\n' "${9:-}" > "$GH_MERGE_BODY_FILE"
    fi
    ;;
  *) echo "unexpected gh args: $*" >&2; exit 1 ;;
esac
EOF

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "rev-parse --show-toplevel") printf '%s\n' "$TEST_REPO_ROOT" ;;
  "rev-parse --abbrev-ref HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then echo "HEAD"; else echo "feature/test"; fi
    ;;
  "rev-parse HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then echo "pr-head-oid"; else echo "stale-local-oid"; fi
    ;;
  "rev-parse feature/test") echo "pr-head-oid" ;;
  "rev-parse --verify --quiet origin/main^{commit}") echo "base-oid" ;;
  "rev-parse --git-path touchstone/reviewer-clean") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/reviewer-clean" ;;
  "rev-parse --git-path touchstone/reviewer-findings-history") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/reviewer-findings-history" ;;
  "rev-parse --git-path touchstone/squash-map.jsonl") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/squash-map.jsonl" ;;
  rev-parse\ --git-path\ touchstone/review-summary-pr-123.json) printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/review-summary-pr-123.json" ;;
  "fetch origin +refs/heads/main:refs/remotes/origin/main") echo fetched ;;
  "cat-file -e pr-head-oid^{commit}") ;;
  "merge-base origin/main pr-head-oid") echo "base-oid" ;;
  "status --porcelain") ;;
  "diff --name-only origin/main...HEAD") ;;
  "diff --name-only --cached") ;;
  "diff --name-only") ;;
  "ls-files") ;;
  "worktree list --porcelain") ;;
  "checkout main") echo main > "$GIT_CHECKOUT_MAIN_FILE" ;;
  "pull --rebase") ;;
  "show-ref --verify --quiet refs/heads/feature/test") ;;
  "branch -D feature/test") ;;
  *) echo "unexpected git args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/git"

reset_fixture() {
  rm -f "$TEST_DIR"/comments "$TEST_DIR"/merge-head "$TEST_DIR"/merge-body \
    "$TEST_DIR"/review.log "$TEST_DIR"/review-audit.log "$TEST_DIR"/merged \
    "$TEST_DIR"/checkout "$TEST_DIR"/git-checkout-main
  rm -rf "$MERGE_DIR/repo/.git"
  mkdir -p "$MERGE_DIR/repo/.git"
  unset CODEX_REVIEW_STUB_EXIT CODEX_REVIEW_STUB_OUTPUT CODEX_REVIEW_STUB_SUMMARY
}

run_merge() {
  local output_file="$1"
  shift
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TEST_REPO_ROOT="$MERGE_DIR/repo" \
    GH_COMMENT_FILE="$TEST_DIR/comments" \
    GH_MERGE_HEAD_FILE="$TEST_DIR/merge-head" \
    GH_MERGE_BODY_FILE="$TEST_DIR/merge-body" \
    GH_MERGED_MARKER="$TEST_DIR/merged" \
    GH_CHECKOUT_FILE="$TEST_DIR/checkout" \
    GIT_CHECKOUT_MAIN_FILE="$TEST_DIR/git-checkout-main" \
    CODEX_REVIEW_LOG="$TEST_DIR/review.log" \
    CODEX_REVIEW_STUB_EXIT="${CODEX_REVIEW_STUB_EXIT:-0}" \
    CODEX_REVIEW_STUB_OUTPUT="${CODEX_REVIEW_STUB_OUTPUT:-}" \
    CODEX_REVIEW_STUB_SUMMARY="${CODEX_REVIEW_STUB_SUMMARY:-}" \
    TOUCHSTONE_REVIEW_LOG="$TEST_DIR/review-audit.log" \
    TOUCHSTONE_NO_PREFLIGHT=1 \
    bash "$MERGE_DIR/scripts/merge-pr.sh" "$@" >"$output_file" 2>&1
}

echo "==> Test: clean merge review posts a one-line PR comment"
reset_fixture
printf '[review]\ncomment_on_clean = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
run_merge "$TEST_DIR/merge-clean.txt" 123
if grep -q '^Conductor review clean - provider: claude, model: claude-opus-4-1, peer: none, iterations: 1, mode: fix, findings: 0$' "$TEST_DIR/comments" \
  && grep -q '==> Posted clean-review PR comment\.' "$TEST_DIR/merge-clean.txt"; then
  echo "==> PASS: clean review comment posted"
else
  echo "FAIL: clean review comment was not posted as expected" >&2
  cat "$TEST_DIR/merge-clean.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi

echo "==> Test: cached clean merge review posts a clean PR comment"
reset_fixture
printf '[review]\ncomment_on_clean = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
CODEX_REVIEW_STUB_SUMMARY='{"reviewer":"Conductor","provider":"claude","model":"claude-opus-4-1","peer_provider":"none","iterations":1,"mode":"fix","findings":0,"exit_reason":"cache-hit"}' \
  run_merge "$TEST_DIR/merge-cache-hit.txt" 123
if grep -q '^Conductor review clean - provider: claude, model: claude-opus-4-1, peer: none, iterations: 1, mode: fix, findings: 0$' "$TEST_DIR/comments" \
  && grep -q '==> Posted clean-review PR comment\.' "$TEST_DIR/merge-cache-hit.txt"; then
  echo "==> PASS: cached clean review comment posted"
else
  echo "FAIL: cached clean review comment was not posted as expected" >&2
  cat "$TEST_DIR/merge-cache-hit.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi

echo "==> Test: non-clean summary never posts clean-review comment"
reset_fixture
printf '[review]\ncomment_on_clean = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
CODEX_REVIEW_STUB_EXIT=0 \
  CODEX_REVIEW_STUB_SUMMARY='{"reviewer":"Conductor","provider":"unknown","model":"unknown","peer_provider":"none","iterations":1,"mode":"fix","findings":0,"exit_reason":"timeout"}' \
  run_merge "$TEST_DIR/merge-non-clean-summary.txt" 123
if grep -q 'merge review failed before a trusted clean verdict' "$TEST_DIR/comments" \
  && grep -q 'exit: timeout' "$TEST_DIR/comments" \
  && ! grep -q 'review clean' "$TEST_DIR/comments"; then
  echo "==> PASS: non-clean summary posted failure comment instead of clean"
else
  echo "FAIL: non-clean summary should not post clean-review comment" >&2
  cat "$TEST_DIR/merge-non-clean-summary.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi

echo "==> Test: failed merge review posts provider failure comment"
reset_fixture
printf '[review]\ncomment_on_clean = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
set +e
CODEX_REVIEW_STUB_EXIT=1 \
  CODEX_REVIEW_STUB_OUTPUT=$'provider timed out\nno sentinel emitted' \
  CODEX_REVIEW_STUB_SUMMARY='{"reviewer":"Conductor","provider":"gemini","model":"unknown","peer_provider":"none","iterations":1,"mode":"fix","findings":0,"fallback_attempted":true,"fallback_primary_provider":"gemini","fallback_retry_provider":"unknown","fallback_excluded_providers":"gemini","fallback_reason":"timeout after 60s","diagnostics_file":"/tmp/review-diagnostics.jsonl","diagnostics_events":2,"exit_reason":"timeout"}' \
  run_merge "$TEST_DIR/merge-provider-failure.txt" 123
FAILURE_COMMENT_EXIT=$?
set -e
if [ "$FAILURE_COMMENT_EXIT" -ne 0 ] \
  && grep -q 'merge review failed before a trusted clean verdict' "$TEST_DIR/comments" \
  && grep -q 'Failed/stalled provider(s): `gemini`' "$TEST_DIR/comments" \
  && grep -q 'Diagnostics: `/tmp/review-diagnostics.jsonl` (2 event(s))' "$TEST_DIR/comments" \
  && grep -q 'Retry: `TOUCHSTONE_CONDUCTOR_WITH=openrouter bash scripts/merge-pr.sh 123`' "$TEST_DIR/comments" \
  && ! grep -q 'review clean' "$TEST_DIR/comments"; then
  echo "==> PASS: provider failure comment posted with retry guidance"
else
  echo "FAIL: provider failure should post durable retry guidance" >&2
  echo "exit code: $FAILURE_COMMENT_EXIT" >&2
  cat "$TEST_DIR/merge-provider-failure.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi

echo "==> Test: comment_on_clean=false skips clean-review comment"
reset_fixture
printf '[review]\ncomment_on_clean = false\n' >"$MERGE_DIR/repo/.codex-review.toml"
run_merge "$TEST_DIR/merge-disabled.txt" 123
if grep -q 'Clean-review PR comment disabled' "$TEST_DIR/merge-disabled.txt" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "==> PASS: config disables clean-review comment"
else
  echo "FAIL: comment_on_clean=false did not skip comment" >&2
  cat "$TEST_DIR/merge-disabled.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi

echo "==> Test: bypass path posts audited disclosure without clean comment"
reset_fixture
printf '[review]\ncomment_on_clean = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
mkdir -p "$MERGE_DIR/repo/.git/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=base-oid\n' >"$MERGE_DIR/repo/.git/touchstone/reviewer-clean/feature_test.clean"
run_merge "$TEST_DIR/merge-bypass.txt" 123 --bypass-with-disclosure="reviewer wedged after clean marker"
if grep -q 'Reviewer bypassed via `--bypass-with-disclosure`. Marker: clean-review. Reason: reviewer wedged after clean marker' "$TEST_DIR/comments" \
  && grep -q $'\treview-bypass\t' "$TEST_DIR/review-audit.log" \
  && grep -q 'marker=clean-review' "$TEST_DIR/review-audit.log" \
  && ! grep -q 'review clean' "$TEST_DIR/comments"; then
  echo "==> PASS: bypass disclosure audited and no clean comment posted"
else
  echo "FAIL: bypass disclosure path regressed" >&2
  cat "$TEST_DIR/merge-bypass.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi
