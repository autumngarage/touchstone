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

gh_field_value() {
  local field_name="$1"
  shift
  local previous="" arg

  for arg in "$@"; do
    if [ "$previous" = "-f" ] && [[ "$arg" = "$field_name="* ]]; then
      printf '%s' "${arg#*=}"
      return 0
    fi
    previous="$arg"
  done
  return 0
}

case "${1:-} ${2:-}" in
  "repo view")
    echo "main"
    ;;
  "pr list")
    if [ "${GH_PR_LIST_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    if [ -n "${GH_EXISTING_PR_URL:-}" ]; then
      printf '%s\t%s\t%s\n' \
        "$GH_EXISTING_PR_URL" \
        "${GH_EXISTING_PR_BASE:-main}" \
        "${GH_EXISTING_PR_HEAD:-${GH_PR_HEAD_SHA:-$(git rev-parse HEAD)}}"
    fi
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
  "api user")
    echo "${GH_AUTHENTICATED_ACTOR:-henrymodisett}"
    ;;
  "api repos/"*)
    if [[ "${2:-}" = */collaborators/*/permission ]]; then
      status_creator="${2#*/collaborators/}"
      status_creator="${status_creator%/permission}"
      if [ "$status_creator" = "untrusted-app" ]; then
        echo "read"
      else
        echo "write"
      fi
    elif [[ "${2:-}" = */commits/* ]] && [[ "$*" = *".commit.committer.date"* ]]; then
      echo "${GH_HEAD_COMMIT_DATE:-2026-07-29T00:00:00Z}"
    else
      printf '%s\t%s\n' "${GH_PR_BASE_NAME:-main}" "${GH_PR_BASE_SHA:-base-oid}"
    fi
    ;;
  "api --paginate")
    if [ "${GH_API_FAIL:-0}" = "1" ]; then
      echo "mock durable request inspection failure" >&2
      exit 1
    fi
    if [[ "${3:-}" != repos/*/commits/*/statuses* ]]; then
      echo "unexpected paginated API target: $*" >&2
      exit 1
    fi
    if [[ "$*" != *"touchstone/review-request-intent"* ]] \
      || [[ "$*" != *"touchstone/review-request-complete"* ]] \
      || [[ "$*" != *'.state == "success"'* ]] \
      || [[ "$*" != *"creator.login"* ]]; then
      echo "request lookup must filter durable status records" >&2
      exit 1
    fi
    if [ -n "${GH_REQUEST_RECORDS:-}" ]; then
      printf '%s\n' "$GH_REQUEST_RECORDS"
    fi
    if [ -s "$GH_STATUS_RECORDS_FILE" ]; then
      query_head="${3#*/commits/}"
      query_head="${query_head%%/*}"
      while IFS="$(printf '\t')" read -r record_head context created_at creator description; do
        [ "$record_head" = "$query_head" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$context" "$created_at" "$creator" "$description"
      done <"$GH_STATUS_RECORDS_FILE"
    fi
    ;;
  "api -X")
    if [ "${3:-}" != "POST" ]; then
      echo "unexpected API mutation: $*" >&2
      exit 1
    fi
    case "${4:-}" in
      repos/*/issues/*/comments)
        printf '%s\n' "$(gh_field_value body "$@")" >>"$GH_COMMENT_FILE"
        printf '%s\n' "${GH_COMMENT_CREATED_AT:-${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}}"
        ;;
      repos/*/statuses/*)
        if [[ "$*" != *"context=touchstone/review-request"* ]] \
          || [[ "$*" != *"description=base="* ]]; then
          echo "unexpected durable review status: $*" >&2
          exit 1
        fi
        status_context="$(gh_field_value context "$@")"
        status_description="$(gh_field_value description "$@")"
        if [ "$status_context" = "touchstone/review-request-intent" ]; then
          status_created_at="${GH_STATUS_INTENT_CREATED_AT:-${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}}"
        else
          status_created_at="${GH_STATUS_COMPLETE_CREATED_AT:-${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}}"
        fi
        printf '%s\n' "$*" >>"$GH_STATUS_FILE"
        status_head="${4##*/}"
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$status_head" \
          "$status_context" \
          "$status_created_at" \
          "${GH_STATUS_CREATOR:-${GH_AUTHENTICATED_ACTOR:-henrymodisett}}" \
          "$status_description" >>"$GH_STATUS_RECORDS_FILE"
        printf '%s\n' "$status_created_at"
        ;;
      *)
        echo "unexpected API mutation target: $*" >&2
        exit 1
        ;;
    esac
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
if [ "\${1:-}" = "fetch" ]; then
  fetch_refspec="\${*: -1}"
  remote_ref="\${fetch_refspec#*:}"
  if [ "\${GIT_FETCH_FAIL:-0}" = "1" ]; then
    exit 1
  fi
  if [ -n "\${GIT_FETCH_BASE_SHA:-}" ]; then
    "$REAL_GIT" update-ref "\$remote_ref" "\$GIT_FETCH_BASE_SHA"
    echo "[mock] git \$*"
    exit 0
  fi
  if "$REAL_GIT" rev-parse --verify --quiet "\$remote_ref^{commit}" >/dev/null; then
    exit 0
  fi
  exit 1
fi
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
      local request_created_at="${GH_REQUEST_CREATED_AT:-1969-01-01T00:00:00Z}"
      PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        GH_COMMENT_FILE="$TEST_DIR/comments" \
        GH_STATUS_FILE="$TEST_DIR/statuses" \
        GH_STATUS_RECORDS_FILE="$TEST_DIR/status-records" \
        GH_API_FAIL="${GH_API_FAIL:-0}" \
        GH_REQUEST_RECORDS="${GH_REQUEST_RECORDS:-}" \
        GH_REQUEST_CREATED_AT="$request_created_at" \
        GH_STATUS_INTENT_CREATED_AT="${GH_STATUS_INTENT_CREATED_AT:-}" \
        GH_STATUS_COMPLETE_CREATED_AT="${GH_STATUS_COMPLETE_CREATED_AT:-}" \
        GH_COMMENT_CREATED_AT="${GH_COMMENT_CREATED_AT:-$request_created_at}" \
        GH_STATUS_CREATOR="${GH_STATUS_CREATOR:-henrymodisett}" \
        GH_AUTHENTICATED_ACTOR="${GH_AUTHENTICATED_ACTOR:-henrymodisett}" \
        GH_HEAD_COMMIT_DATE="${GH_HEAD_COMMIT_DATE:-2026-07-29T00:00:00Z}" \
        GH_EXISTING_REQUEST_BODY="${GH_EXISTING_REQUEST_BODY:-}" \
        GH_EXISTING_REQUEST_EDITED="${GH_EXISTING_REQUEST_EDITED:-0}" \
        GH_EXISTING_REQUEST_FILE="${GH_EXISTING_REQUEST_FILE:-}" \
        GH_EXISTING_PR_URL="${GH_EXISTING_PR_URL:-}" \
        GH_EXISTING_PR_BASE="${GH_EXISTING_PR_BASE:-}" \
        GH_EXISTING_PR_HEAD="${GH_EXISTING_PR_HEAD:-}" \
        GH_PR_LIST_FAIL="${GH_PR_LIST_FAIL:-0}" \
        GH_PR_HEAD_SHA="${GH_PR_HEAD_SHA:-}" \
        GH_PR_BASE_NAME="${GH_PR_BASE_NAME:-main}" \
        GH_PR_BASE_SHA="${GH_PR_BASE_SHA:-base-oid}" \
        GIT_FETCH_BASE_SHA="${GIT_FETCH_BASE_SHA:-}" \
        GIT_FETCH_FAIL="${GIT_FETCH_FAIL:-0}" \
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
  rm -f "$TEST_DIR/comments" "$TEST_DIR/review-env" "$TEST_DIR/statuses" "$TEST_DIR/status-records"
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

echo "==> Case 7: trusted base request policy overrides a weakened feature config"
reset_case
git -C "$REPO_DIR" checkout main >/dev/null 2>&1
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = false\n\n[review.pr_triggered]\nprovider = "github-codex"\nrequest_on_push = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "require codex review requests" >/dev/null 2>&1
git -C "$REPO_DIR" update-ref refs/remotes/origin/main main
git -C "$REPO_DIR" checkout feat/advisory >/dev/null 2>&1
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = false\n\n[review.pr_triggered]\nprovider = "openrouter"\nrequest_on_push = false\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "attempt to weaken review requests" >/dev/null 2>&1
REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-on-push.out"
run_open_pr "$OUT"
if grep -q '^@codex review$' "$TEST_DIR/comments" \
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$REQUEST_HEAD base=base-oid -->" "$TEST_DIR/comments" \
  && grep -q 'context=touchstone/review-request-intent' "$TEST_DIR/statuses" \
  && grep -q 'context=touchstone/review-request-complete' "$TEST_DIR/statuses" \
  && grep -q 'description=base=base-oid' "$TEST_DIR/statuses" \
  && grep -q "Requested GitHub Codex review for head $REQUEST_HEAD at base base-oid" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: feature config disabled or redirected the trusted base request policy" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 7a: trusted base policy is refreshed before review is requested"
reset_case
git -C "$REPO_DIR" checkout main >/dev/null 2>&1
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = false\n\n[review.pr_triggered]\nprovider = "openrouter"\nrequest_on_push = false\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "temporarily disable review requests" >/dev/null 2>&1
git -C "$REPO_DIR" update-ref refs/remotes/origin/main main
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = false\n\n[review.pr_triggered]\nprovider = "github-codex"\nrequest_on_push = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "reenable remote review requests" >/dev/null 2>&1
FRESH_POLICY_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" checkout feat/advisory >/dev/null 2>&1
REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-refreshed-base.out"
GIT_FETCH_BASE_SHA="$FRESH_POLICY_SHA" run_open_pr "$OUT"
if grep -q '^@codex review$' "$TEST_DIR/comments" \
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$REQUEST_HEAD base=base-oid -->" "$TEST_DIR/comments" \
  && [ "$(git -C "$REPO_DIR" rev-parse refs/remotes/origin/main)" = "$FRESH_POLICY_SHA" ]; then
  echo "    PASS"
else
  echo "    FAIL: stale origin/main policy was not refreshed before requesting review" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 7aa: a published base policy fails closed when refresh fails"
reset_case
OUT="$TEST_DIR/request-base-refresh-failure.out"
if GIT_FETCH_FAIL=1 run_open_pr "$OUT"; then
  echo "    FAIL: published base refresh failure should stop PR creation" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q "Could not refresh trusted review request policy base 'main'" "$OUT" \
  && grep -q 'Refusing to use stale refs/remotes/origin/main' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: published base refresh failure lacked fail-closed diagnostics" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 7b: request_on_push defaults an omitted provider to GitHub Codex"
reset_case
git -C "$REPO_DIR" checkout main >/dev/null 2>&1
printf '[review]\npreflight_required = false\nadvisory_at_pr_open = false\n\n[review.pr_triggered]\nrequest_on_push = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "use default trusted review provider" >/dev/null 2>&1
git -C "$REPO_DIR" update-ref refs/remotes/origin/main main
git -C "$REPO_DIR" checkout feat/advisory >/dev/null 2>&1
REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-default-provider.out"
run_open_pr "$OUT"
if grep -q '^@codex review$' "$TEST_DIR/comments" \
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$REQUEST_HEAD base=base-oid -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $REQUEST_HEAD at base base-oid" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: an omitted provider should default to GitHub Codex" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8: request_on_push is idempotent for the same head"
EXISTING_REQUEST_RECORDS="$(cut -f2- "$TEST_DIR/status-records")"
reset_case
OUT="$TEST_DIR/request-idempotent.out"
GH_REQUEST_RECORDS="$EXISTING_REQUEST_RECORDS" run_open_pr "$OUT"
if grep -q "GitHub Codex review already requested for head $REQUEST_HEAD at base base-oid" "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: repeated request should not post another comment" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8a: durable matching request survives trigger-comment edits"
reset_case
OUT="$TEST_DIR/request-edited-matching.out"
if ! GH_REQUEST_RECORDS="$EXISTING_REQUEST_RECORDS" \
  run_open_pr "$OUT"; then
  echo "    FAIL: edited trigger comment erased durable matching request evidence" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q "GitHub Codex review already requested for head $REQUEST_HEAD at base base-oid" "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: durable status should make mutable trigger comments irrelevant" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8aa: durable conflicting-base request survives trigger-comment deletion"
reset_case
OUT="$TEST_DIR/request-edited-conflicting.out"
if GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-07-29T00:00:00Z\thenrymodisett\tbase=old-base-oid' \
  run_open_pr "$OUT"; then
  echo "    FAIL: edited conflicting marker unexpectedly requested a review" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q "head $REQUEST_HEAD already has trusted review requests for another base revision" "$OUT" \
  && grep -q 'prior base(s): old-base-oid' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: durable conflicting request should require a new head" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8ab: orphaned intent retries and records completion"
reset_case
OUT="$TEST_DIR/request-orphan-intent.out"
GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-07-29T00:00:00Z\thenrymodisett\tbase=base-oid' \
  run_open_pr "$OUT"
if grep -q '^@codex review$' "$TEST_DIR/comments" \
  && grep -q 'context=touchstone/review-request-complete' "$TEST_DIR/statuses" \
  && ! grep -q 'context=touchstone/review-request-intent' "$TEST_DIR/statuses"; then
  echo "    PASS"
else
  echo "    FAIL: orphaned request intent should retry the trigger and complete" >&2
  cat "$OUT" >&2
  [ ! -f "$TEST_DIR/statuses" ] || cat "$TEST_DIR/statuses" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8ac: durable status survives driver handoff"
reset_case
OUT="$TEST_DIR/request-untrusted-status.out"
GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-07-29T00:00:00Z\tprior-driver\tbase=base-oid\ntouchstone/review-request-complete\t2026-07-29T00:00:01Z\tprior-driver\tbase=base-oid intent=2026-07-29T00:00:00Z trigger=2026-07-29T00:00:01Z' \
  run_open_pr "$OUT"
if grep -q "GitHub Codex review already requested for head $REQUEST_HEAD at base base-oid" "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ] \
  && [ ! -f "$TEST_DIR/statuses" ]; then
  echo "    PASS"
else
  echo "    FAIL: another driver should reuse append-only request evidence" >&2
  cat "$OUT" >&2
  [ ! -f "$TEST_DIR/statuses" ] || cat "$TEST_DIR/statuses" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8ad: non-writer status creator forces a fresh head"
reset_case
OUT="$TEST_DIR/request-untrusted-creator.out"
if GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-07-29T00:00:00Z\tuntrusted-app\tbase=base-oid\ntouchstone/review-request-complete\t2026-07-29T00:00:01Z\tuntrusted-app\tbase=base-oid intent=2026-07-29T00:00:00Z trigger=2026-07-29T00:00:01Z' \
  run_open_pr "$OUT"; then
  echo "    FAIL: non-writer status creator suppressed a review request" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q "review-request status from untrusted creator 'untrusted-app'" "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ] \
  && [ ! -f "$TEST_DIR/statuses" ]; then
  echo "    PASS"
else
  echo "    FAIL: non-writer status creator did not fail closed" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8b: a copied standalone marker does not suppress the real request"
reset_case
COPIED_MARKER="Diagnostic copy:

\`\`\`
<!-- touchstone:pr-review-request provider=github-codex head=$REQUEST_HEAD -->
\`\`\`"
OUT="$TEST_DIR/request-copied-marker.out"
GH_EXISTING_REQUEST_BODY="$COPIED_MARKER" run_open_pr "$OUT"
if grep -q '^@codex review$' "$TEST_DIR/comments" \
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$REQUEST_HEAD base=base-oid -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $REQUEST_HEAD at base base-oid" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: a copied marker without the request command should not be idempotent" >&2
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
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$SELECTED_REQUEST_HEAD base=base-oid -->" "$TEST_DIR/comments" \
  && ! grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$ADVANCED_LOCAL_HEAD base=base-oid -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $SELECTED_REQUEST_HEAD at base base-oid" "$OUT"; then
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
if grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$DRAFT_REQUEST_HEAD base=base-oid -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $DRAFT_REQUEST_HEAD at base base-oid" "$OUT" \
  && grep -q 'Opened as draft' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: a draft PR should request review before returning" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8e: one head cannot request reviews for multiple bases"
reset_case
OUT="$TEST_DIR/request-conflicting-base.out"
GH_REQUEST_RECORDS=$'touchstone/review-request-intent\t2026-07-29T00:00:00Z\thenrymodisett\tbase=old-base-oid' \
  run_open_pr "$OUT" && {
  echo "    FAIL: conflicting base request unexpectedly succeeded" >&2
  ERRORS=$((ERRORS + 1))
}
if grep -q "head $DRAFT_REQUEST_HEAD already has trusted review requests for another base revision" "$OUT" \
  && grep -q 'current base:  base-oid' "$OUT" \
  && grep -q 'prior base(s): old-base-oid' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: a reused head should not request review against a second base" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8f: legacy head-only requests require a fresh PR head"
reset_case
OUT="$TEST_DIR/request-legacy-unbound.out"
GH_EXISTING_PR_URL="https://example.test/touchstone/pull/456" \
  GH_EXISTING_PR_BASE="main" \
  GH_EXISTING_PR_HEAD="$DRAFT_REQUEST_HEAD" \
  run_open_pr "$OUT" && {
  echo "    FAIL: legacy unbound request unexpectedly authorized a base-bound request" >&2
  ERRORS=$((ERRORS + 1))
}
if grep -q "head $DRAFT_REQUEST_HEAD has no durable review-request evidence" "$OUT" \
  && grep -q 'This invocation did not create or advance the PR head' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: legacy head-only request did not require a fresh PR head" >&2
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

echo "==> Case 9a: existing auto-merge PR request failure reports orphan recovery"
reset_case
OUT="$TEST_DIR/request-existing-orphan-risk.out"
if GH_API_FAIL=1 \
  GH_EXISTING_PR_URL="https://example.test/touchstone/pull/789" \
  GH_EXISTING_PR_BASE="main" \
  run_open_pr "$OUT" --auto-merge; then
  echo "    FAIL: existing PR request inspection failure should fail closed" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q 'failed to inspect prior GitHub Codex review requests' "$OUT" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/789' "$OUT" \
  && grep -q 'gh pr merge 789 --squash --delete-branch' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: existing PR request failure omitted orphan recovery guidance" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9b: stacked PR policy prefers origin/base over a divergent local base"
reset_case
git -C "$REPO_DIR" checkout -b feat/review-policy-parent main >/dev/null 2>&1
printf '[review]\n\n[review.pr_triggered]\nprovider = "openrouter"\nrequest_on_push = false\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "remote stack policy disables requests" >/dev/null 2>&1
git -C "$REPO_DIR" update-ref refs/remotes/origin/feat/review-policy-parent HEAD
printf '[review]\n\n[review.pr_triggered]\nprovider = "github-codex"\nrequest_on_push = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "local stack policy enables requests" >/dev/null 2>&1
git -C "$REPO_DIR" checkout feat/advisory >/dev/null 2>&1
OUT="$TEST_DIR/request-stacked-remote-policy.out"
run_open_pr "$OUT" --base feat/review-policy-parent
if [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: stacked PR ignored origin/base policy in favor of local or feature config" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9c: stacked PR policy falls back to the local base branch"
reset_case
git -C "$REPO_DIR" update-ref -d refs/remotes/origin/feat/review-policy-parent
STACK_REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-stacked-local-policy.out"
GH_PR_BASE_NAME="feat/review-policy-parent" \
  GH_PR_BASE_SHA="stack-base-oid" \
  run_open_pr "$OUT" --base feat/review-policy-parent
if grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$STACK_REQUEST_HEAD base=stack-base-oid -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $STACK_REQUEST_HEAD at base stack-base-oid" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: stacked PR did not use the local base policy fallback" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9d: existing stacked PR updates trust their actual base and pushed head"
reset_case
git -C "$REPO_DIR" checkout main >/dev/null 2>&1
printf '[review]\n\n[review.pr_triggered]\nprovider = "github-codex"\nrequest_on_push = false\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "disable default-branch requests" >/dev/null 2>&1
git -C "$REPO_DIR" update-ref refs/remotes/origin/main main
git -C "$REPO_DIR" checkout -b feat/existing-policy-parent main >/dev/null 2>&1
printf '[review]\n\n[review.pr_triggered]\nprovider = "github-codex"\nrequest_on_push = true\n' >"$REPO_DIR/.codex-review.toml"
git -C "$REPO_DIR" add .codex-review.toml
git -C "$REPO_DIR" commit -m "enable stacked-base requests" >/dev/null 2>&1
git -C "$REPO_DIR" update-ref refs/remotes/origin/feat/existing-policy-parent HEAD
git -C "$REPO_DIR" checkout feat/advisory >/dev/null 2>&1
EXISTING_REQUEST_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OUT="$TEST_DIR/request-existing-stacked-policy.out"
GH_EXISTING_PR_URL="https://example.test/touchstone/pull/789" \
  GH_EXISTING_PR_BASE="feat/existing-policy-parent" \
  GH_EXISTING_PR_HEAD="old-existing-head" \
  GH_PR_HEAD_SHA="$EXISTING_REQUEST_HEAD" \
  GH_PR_BASE_NAME="feat/existing-policy-parent" \
  GH_PR_BASE_SHA="existing-stack-base-oid" \
  GIT_PUSH_CREATE_LOCAL_COMMIT=1 \
  run_open_pr "$OUT"
ADVANCED_EXISTING_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
if [ "$ADVANCED_EXISTING_HEAD" != "$EXISTING_REQUEST_HEAD" ] \
  && grep -q 'PR already open for feat/advisory: https://example.test/touchstone/pull/789' "$OUT" \
  && grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$EXISTING_REQUEST_HEAD base=existing-stack-base-oid -->" "$TEST_DIR/comments" \
  && ! grep -q "<!-- touchstone:pr-review-request provider=github-codex head=$ADVANCED_EXISTING_HEAD base=existing-stack-base-oid -->" "$TEST_DIR/comments" \
  && grep -q "Requested GitHub Codex review for head $EXISTING_REQUEST_HEAD at base existing-stack-base-oid" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: existing stacked PR update ignored its actual base or selected push head" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9e: existing PR discovery failure stops before policy selection"
reset_case
OUT="$TEST_DIR/request-existing-discovery-failure.out"
if GH_PR_LIST_FAIL=1 run_open_pr "$OUT"; then
  echo "    FAIL: existing PR discovery failure should fail closed" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q "Failed to inspect existing PR metadata for branch 'feat/advisory'" "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: existing PR discovery failure lacked fail-closed diagnostics" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9f: --base cannot silently override an existing PR's actual base"
reset_case
OUT="$TEST_DIR/request-existing-base-mismatch.out"
if GH_EXISTING_PR_URL="https://example.test/touchstone/pull/789" \
  GH_EXISTING_PR_BASE="feat/existing-policy-parent" \
  run_open_pr "$OUT" --base main; then
  echo "    FAIL: mismatched --base should stop before policy selection" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q "does not match existing PR #789 base 'feat/existing-policy-parent'" "$OUT" \
  && grep -q "gh pr edit 789 --base 'main'" "$OUT" \
  && grep -q "rerun without --base to use the PR's current base" "$OUT" \
  && ! grep -q '\[mock\] git push' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: existing PR base mismatch lacked fail-closed diagnostics" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9g: review request rejects a base retarget after policy selection"
reset_case
OUT="$TEST_DIR/request-retargeted-before-comment.out"
if GH_EXISTING_PR_URL="https://example.test/touchstone/pull/789" \
  GH_EXISTING_PR_BASE="feat/existing-policy-parent" \
  GH_PR_BASE_NAME="main" \
  GH_PR_BASE_SHA="retargeted-base-oid" \
  run_open_pr "$OUT"; then
  echo "    FAIL: a retargeted PR should stop before requesting review" >&2
  ERRORS=$((ERRORS + 1))
elif grep -q 'PR #789 base changed before review was requested' "$OUT" \
  && grep -q 'expected: feat/existing-policy-parent' "$OUT" \
  && grep -q 'actual:   main' "$OUT" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "    PASS"
else
  echo "    FAIL: retargeted PR review request lacked fail-closed diagnostics" >&2
  cat "$OUT" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
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
