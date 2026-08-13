#!/usr/bin/env bash
# Behavioral fixtures for the versioned review-binding evidence contract.
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVALUATOR="$TOUCHSTONE_ROOT/.github/review-binding/evaluate.jq"
WORKFLOW="$TOUCHSTONE_ROOT/.github/workflows/review-binding.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HEAD_SHA="1111111111111111111111111111111111111111"
BASE_SHA="2222222222222222222222222222222222222222"
REVIEWER="chatgpt-codex-connector[bot]"
ERRORS=0

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

ok() {
  echo "  OK: $*"
}

cat >"$TMP_DIR/base.json" <<EOF
{
  "contractVersion": 1,
  "complete": true,
  "trustedAuthors": ["$REVIEWER"],
  "pr": {
    "number": 42,
    "state": "open",
    "headSha": "$HEAD_SHA",
    "baseRef": "main",
    "baseRefHash": "88d050b1908057b53d38b42702ebc659e3d7f696",
    "baseSha": "$BASE_SHA",
    "openHeadPulls": [42]
  },
  "statuses": [{
    "context": "touchstone/review-request-v1",
    "state": "success",
    "description": "v1 p=42 r=88d050b1908057b53d38b42702ebc659e3d7f696 b=$BASE_SHA c=100",
    "creator": {"login": "github-actions[bot]"}
  }],
  "issueComments": [
    {
      "id": 100,
      "body": "@codex review",
      "created_at": "2026-08-13T10:00:00Z",
      "author_association": "MEMBER",
      "user": {"login": "driver"}
    },
    {
      "id": 101,
      "body": "Codex Review: Didn't find any major issues. Hooray!\n\n**Reviewed commit:** \`1111111111\`",
      "created_at": "2026-08-13T10:01:00Z",
      "author_association": "NONE",
      "user": {"login": "$REVIEWER"}
    }
  ],
  "reviews": [],
  "reviewComments": []
}
EOF

run_case() {
  local label="$1" filter="$2" expected="$3" reason="${4:-}"
  local fixture="$TMP_DIR/case.json" verdict
  jq "$filter" "$TMP_DIR/base.json" >"$fixture"
  if ! verdict="$(jq -f "$EVALUATOR" "$fixture")"; then
    fail "$label: evaluator crashed"
    return
  fi
  if [ "$(jq -r .conclusion <<<"$verdict")" != "$expected" ]; then
    fail "$label: expected $expected, got $(jq -c '{conclusion,reasons,counts}' <<<"$verdict")"
    return
  fi
  if [ -n "$reason" ] && ! jq -e --arg reason "$reason" '.reasons | any(contains($reason))' <<<"$verdict" >/dev/null; then
    fail "$label: missing reason '$reason': $(jq -c .reasons <<<"$verdict")"
    return
  fi
  ok "$label"
}

echo "==> Exact head and base binding"
run_case "clean exact-head result passes" '.' success
run_case "pre-review state fails" '.statuses = []' failure "no trusted review request"
run_case "moved head invalidates evidence" '.pr.headSha = "3333333333333333333333333333333333333333"' failure "no trusted exact-head"
run_case "moved base invalidates request" '.pr.baseSha = "3333333333333333333333333333333333333333"' failure "no trusted review request"
run_case "retargeted base ref invalidates request even at the same commit" '.pr.baseRef = "release" | .pr.baseRefHash = "3333333333333333333333333333333333333333"' failure "no trusted review request"
run_case "shared head fails closed" '.pr.openHeadPulls = [42, 43]' failure "not uniquely scoped"
run_case "untrusted request marker creator fails" '.statuses[0].creator.login = "attacker"' failure "no trusted review request"
run_case "edited-away request fails" '.issueComments[0].body = "never mind"' failure "no trusted review request"
run_case "untrusted result comment is not review evidence" '.issueComments[1].user.login = "attacker"' failure "no trusted exact-head"

echo "==> Provider and inspection failures"
run_case "incomplete API evidence fails closed" '.complete = false' failure "collection was incomplete"
run_case "unsupported contract fails closed" '.contractVersion = 2' failure "contract version"
run_case "quota response is explicit" '
  .issueComments = [
    .issueComments[0],
    {"id":102,"body":"You have reached your Codex usage limits. Please try again later.","created_at":"2026-08-13T10:01:00Z","author_association":"NONE","user":{"login":"chatgpt-codex-connector[bot]"}}
  ]' failure "quota or no-review"
run_case "evidence beyond a 100-item page remains visible" '
  .issueComments = [.issueComments[0]]
    + [range(0; 150) as $i | {id:(1000+$i),body:"noise",created_at:"2026-08-13T10:00:30Z",author_association:"NONE",user:{login:"reader"}}]
    + [.issueComments[1]]' success

echo "==> Inline findings require later driver answers"
# The JSON snippets are intentionally literal jq programs.
# shellcheck disable=SC2016
INLINE_REVIEW='{
  "id": 200,
  "body": "### 💡 Codex Review\n\nHere are some automated review suggestions.\n\n**Reviewed commit:** `1111111111`",
  "commit_id": "1111111111111111111111111111111111111111",
  "state": "COMMENTED",
  "submitted_at": "2026-08-13T10:01:00Z",
  "user": {"login": "chatgpt-codex-connector[bot]"}
}'
INLINE_FINDING='{
  "id": 300,
  "in_reply_to_id": null,
  "pull_request_review_id": 200,
  "body": "Fix the invariant",
  "created_at": "2026-08-13T10:01:00Z",
  "author_association": "NONE",
  "user": {"login": "chatgpt-codex-connector[bot]"}
}'
INLINE_ANSWER='{
  "id": 301,
  "in_reply_to_id": 300,
  "pull_request_review_id": 201,
  "body": "Fixed and tested",
  "created_at": "2026-08-13T10:02:00Z",
  "author_association": "MEMBER",
  "user": {"login": "driver"}
}'
run_case "resolved-but-unanswered finding fails" \
  ".issueComments = [.issueComments[0]] | .reviews = [$INLINE_REVIEW] | .reviewComments = [$INLINE_FINDING]" \
  failure "inline finding"
run_case "answered finding passes even while thread gate remains separate" \
  ".issueComments = [.issueComments[0]] | .reviews = [$INLINE_REVIEW] | .reviewComments = [$INLINE_FINDING, $INLINE_ANSWER]" \
  success
run_case "same-second reply does not answer a finding" \
  ".issueComments = [.issueComments[0]] | .reviews = [$INLINE_REVIEW] | .reviewComments = [$INLINE_FINDING, ($INLINE_ANSWER | .created_at = \"2026-08-13T10:01:00Z\")]" \
  failure "inline finding"
run_case "every finding needs its own answer" \
  ".issueComments = [.issueComments[0]] | .reviews = [$INLINE_REVIEW] | .reviewComments = [$INLINE_FINDING, ($INLINE_FINDING | .id = 302), $INLINE_ANSWER]" \
  failure "302"
run_case "changes-requested remains GitHub's independent decision" \
  '.pr.reviewDecision = "CHANGES_REQUESTED"' success
run_case "dismissed review is not evidence" \
  ".issueComments = [.issueComments[0]] | .reviews = [($INLINE_REVIEW | .state = \"DISMISSED\")]" \
  failure "no trusted exact-head"

echo "==> Body-only findings require an answer or re-review"
BODY_REVIEW='{
  "id": 400,
  "body": "The migration has no rollback path.",
  "commit_id": "1111111111111111111111111111111111111111",
  "state": "COMMENTED",
  "submitted_at": "2026-08-13T10:01:00Z",
  "user": {"login": "chatgpt-codex-connector[bot]"}
}'
BODY_ANSWER='{
  "id": 401,
  "body": "Added and exercised rollback. <!-- touchstone:review-answer id=400 -->",
  "created_at": "2026-08-13T10:02:00Z",
  "author_association": "MEMBER",
  "user": {"login": "driver"}
}'
REREVIEW='{
  "id": 402,
  "body": "",
  "commit_id": "1111111111111111111111111111111111111111",
  "state": "COMMENTED",
  "submitted_at": "2026-08-13T10:03:00Z",
  "user": {"login": "chatgpt-codex-connector[bot]"}
}'
run_case "body-only finding without answer fails" \
  ".issueComments = [.issueComments[0]] | .reviews = [$BODY_REVIEW]" failure "body-only"
run_case "body-only finding with later PR answer passes" \
  ".issueComments = [.issueComments[0], $BODY_ANSWER] | .reviews = [$BODY_REVIEW]" success
run_case "unmarked later PR chatter does not answer a body finding" \
  ".issueComments = [.issueComments[0], ($BODY_ANSWER | .body = \"Unrelated status update\")] | .reviews = [$BODY_REVIEW]" \
  failure "body-only"
run_case "body-only finding with later re-review passes" \
  ".issueComments = [.issueComments[0]] | .reviews = [$BODY_REVIEW, $REREVIEW]" success

echo "==> Rebuild is deterministic"
first="$(jq -S -f "$EVALUATOR" "$TMP_DIR/base.json")"
second="$(jq -S -f "$EVALUATOR" "$TMP_DIR/base.json")"
if [ "$first" = "$second" ]; then
  ok "unchanged evidence rebuilds the same verdict"
else
  fail "unchanged evidence produced different verdicts"
fi

echo "==> Workflow guardrails"
if grep -Eq '^[[:space:]]*uses:' "$WORKFLOW"; then
  fail "review-binding workflow must execute no checked-out or third-party action"
else
  ok "workflow executes no PR-controlled checkout or third-party action"
fi
# These literal workflow fragments must not expand in the test shell.
# shellcheck disable=SC2016
for required in \
  'name: review-binding' \
  'checks: write' \
  'gh api --paginate' \
  'pull_request_review_comment:' \
  'issue_comment:' \
  'types: [created, edited, deleted]' \
  'status=in_progress' \
  'PATCH "repos/$REPO/check-runs/$run_id"' \
  'contents/.github/review-binding/evaluate.jq?ref=$base' \
  'live_head' \
  'newest_run' \
  'BOOTSTRAP_BASE_SHA' \
  'GITHUB_EVENT_PATH' \
  'known_head'; do
  if grep -Fq "$required" "$WORKFLOW"; then
    ok "workflow contains: $required"
  else
    fail "workflow missing required guardrail: $required"
  fi
done
if grep -Fq 'EVENT_PATH: ${{ github.event_path }}' "$WORKFLOW"; then
  fail "workflow must use the runner-populated GITHUB_EVENT_PATH, not an empty context expression"
else
  ok "event payload reads use the runner-provided path"
fi
EVALUATE_BODY="$(awk '/^          evaluate_pr\(\) \{/{grab=1} grab{print} grab && /^          \}/{exit}' "$WORKFLOW")"
if [ -z "$EVALUATE_BODY" ]; then
  fail "could not extract evaluate_pr for pending-order guard"
elif awk '
  /create_pending .*known_head/ { pending = NR }
  /gh api "repos\/\$REPO\/pulls\/\$number"/ { lookup = NR; exit }
  END { exit !(pending && lookup && pending < lookup) }
' <<<"$EVALUATE_BODY"; then
  ok "known event heads publish pending before the fallible PR lookup"
else
  fail "evaluate_pr must neutralize a known head before reading live PR coordinates"
fi
if grep -Fq -- "[.number, .head.sha] | @tsv" "$WORKFLOW"; then
  ok "discovery paths carry each affected PR head into evaluation"
else
  fail "push/status discovery must preserve the affected head SHA"
fi
if grep -Fq 'base=$pushed_ref&' "$WORKFLOW"; then
  fail "push sweep must not interpolate a base ref into a query string"
elif grep -Fq -- '--method GET "repos/$REPO/pulls"' "$WORKFLOW" \
  && grep -Fq -- '-f "base=$pushed_ref"' "$WORKFLOW"; then
  ok "push sweep URL-encodes arbitrary valid base refs through gh fields"
else
  fail "push sweep must pass the base ref as an encoded GET field"
fi
MARKER='v1 p=18446744073709551615 r=1111111111111111111111111111111111111111 b=2222222222222222222222222222222222222222 c=18446744073709551615'
if [ "${#MARKER}" -le 140 ] \
  && grep -Fq 'git hash-object --stdin' "$WORKFLOW" \
  && ! grep -Fq 'r=$base_ref ' "$WORKFLOW"; then
  ok "request marker stays within GitHub's 140-character limit"
else
  fail "request marker must use a fixed-width base-ref digest within 140 characters"
fi
if grep -Eq '^[[:space:]]+(name: review-binding|review-binding:)$' "$WORKFLOW"; then
  fail "job/step must not publish a second review-binding check"
else
  ok "manual check-run is the only review-binding identity"
fi
if grep -Fq 'cancel-in-progress: false' "$WORKFLOW" \
  && grep -Fq 'newest_run' "$WORKFLOW"; then
  ok "superseded runs self-neutralize without a red cancelled Actions job"
else
  fail "stale-run safety must use the newer-run guard without force-cancelling jobs"
fi

if [ "$ERRORS" -ne 0 ]; then
  echo "$ERRORS review-binding test(s) failed" >&2
  exit 1
fi
echo "All review-binding tests passed."
