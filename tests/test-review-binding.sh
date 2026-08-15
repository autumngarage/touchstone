#!/usr/bin/env bash
# Behavioral fixtures for the versioned review-binding evidence contract.
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVALUATOR="$TOUCHSTONE_ROOT/.github/review-binding/evaluate.jq"
WORKFLOW="$TOUCHSTONE_ROOT/.github/workflows/review-binding.yml"
SIGNAL_WORKFLOW="$TOUCHSTONE_ROOT/.github/workflows/review-evidence-signal.yml"
SETUP="$TOUCHSTONE_ROOT/setup.sh"
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
      "resolved_review_sha": "$HEAD_SHA",
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
run_case "a second request after the prior result waits for new evidence" '
  .statuses += [{
    "context":"touchstone/review-request-v1",
    "state":"success",
    "description":"v1 p=42 r=88d050b1908057b53d38b42702ebc659e3d7f696 b=2222222222222222222222222222222222222222 c=102",
    "creator":{"login":"github-actions[bot]"}
  }]
  | .issueComments += [{
    "id":102,
    "body":"@codex review",
    "created_at":"2026-08-13T10:02:00Z",
    "author_association":"MEMBER",
    "user":{"login":"driver"}
  }]' failure "no trusted exact-head"
run_case "editing a raced replacement into an audit note restores the original binding" '
  .statuses += [{
    "context":"touchstone/review-request-v1",
    "state":"success",
    "description":"v1 p=42 r=88d050b1908057b53d38b42702ebc659e3d7f696 b=2222222222222222222222222222222222222222 c=102",
    "creator":{"login":"github-actions[bot]"}
  }]
  | .issueComments += [{
    "id":102,
    "body":"Recovery trigger withdrawn: original request completed during posting.",
    "created_at":"2026-08-13T10:02:00Z",
    "author_association":"MEMBER",
    "user":{"login":"driver"}
  }]' success
run_case "untrusted result comment is not review evidence" '.issueComments[1].user.login = "attacker"' failure "no trusted exact-head"
run_case "an unresolved abbreviated SHA is never prefix-matched" '.issueComments[1].resolved_review_sha = ""' failure "no trusted exact-head"
run_case "editing a clean result reopens it as a body finding" '.issueComments[1].updated_at = "2026-08-13T10:02:00Z"' failure "body-only"
run_case "body-only result binds through its full-SHA blob link" '
  .issueComments[1].body = "### 💡 Codex Review\n\nhttps://github.com/autumngarage/touchstone/blob/1111111111111111111111111111111111111111/path/file#L1\n\nFix this"' \
  failure "body-only"

echo "==> Provider and inspection failures"
run_case "incomplete API evidence fails closed" '.complete = false' failure "collection was incomplete"
run_case "unsupported contract fails closed" '.contractVersion = 2' failure "contract version"
run_case "quota notice stays provisional and non-evidence" '
  .issueComments = [
    .issueComments[0],
    {"id":102,"body":"You have reached your Codex usage limits. Please try again later.","created_at":"2026-08-13T10:01:00Z","author_association":"NONE","user":{"login":"chatgpt-codex-connector[bot]"}}
  ]' failure "quota notice is provisional"
run_case "terminal no-review retry response is not a quota notice" '
  .issueComments = [
    .issueComments[0],
    {"id":102,"body":"Could not review this pull request; please try again later.","created_at":"2026-08-13T10:01:00Z","author_association":"NONE","user":{"login":"chatgpt-codex-connector[bot]"}}
  ]' failure "no trusted exact-head review evidence"
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
  "updated_at": "2026-08-13T10:01:00Z",
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
run_case "editing an inline finding after its reply requires a new answer" \
  ".issueComments = [.issueComments[0]] | .reviews = [$INLINE_REVIEW] | .reviewComments = [($INLINE_FINDING | .updated_at = \"2026-08-13T10:03:00Z\"), $INLINE_ANSWER]" \
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
run_case "editing a formal review body invalidates its older marked answer" \
  ".issueComments = [.issueComments[0], $BODY_ANSWER] | .reviews = [($BODY_REVIEW | .updated_at = \"2026-08-13T10:02:30Z\")]" \
  failure "body-only"
run_case "later re-review answers an edited formal review body" \
  ".issueComments = [.issueComments[0]] | .reviews = [($BODY_REVIEW | .updated_at = \"2026-08-13T10:02:30Z\"), $REREVIEW]" \
  success
RESULT_BODY_FINDING='{
  "id": 500,
  "body": "The rollback proof is incomplete. **Reviewed commit:** `1111111111`",
  "resolved_review_sha": "1111111111111111111111111111111111111111",
  "created_at": "2026-08-13T10:01:00Z",
  "updated_at": "2026-08-13T10:03:00Z",
  "author_association": "NONE",
  "user": {"login": "chatgpt-codex-connector[bot]"}
}'
RESULT_BODY_ANSWER='{
  "id": 501,
  "body": "Added the proof. <!-- touchstone:review-answer id=500 -->",
  "created_at": "2026-08-13T10:02:00Z",
  "author_association": "MEMBER",
  "user": {"login": "driver"}
}'
run_case "editing a result-comment finding invalidates its older answer" \
  ".issueComments = [.issueComments[0], $RESULT_BODY_FINDING, $RESULT_BODY_ANSWER]" \
  failure "body-only"
run_case "a new answer after the result-comment edit passes" \
  ".issueComments = [.issueComments[0], $RESULT_BODY_FINDING, ($RESULT_BODY_ANSWER | .created_at = \"2026-08-13T10:04:00Z\")]" \
  success
STANDARD_RESULT_EDIT='{
  "id": 502,
  "body": "### 💡 Codex Review\n\nThe newly edited result contains a finding.\n\n**Reviewed commit:** `1111111111`",
  "resolved_review_sha": "1111111111111111111111111111111111111111",
  "created_at": "2026-08-13T10:01:00Z",
  "updated_at": "2026-08-13T10:03:00Z",
  "author_association": "NONE",
  "user": {"login": "chatgpt-codex-connector[bot]"}
}'
run_case "editing a standard-format result comment creates a fresh finding" \
  ".issueComments = [.issueComments[0], $STANDARD_RESULT_EDIT]" \
  failure "body-only"
run_case "a later marked answer closes an edited standard-format result finding" \
  ".issueComments = [.issueComments[0], $STANDARD_RESULT_EDIT, ($RESULT_BODY_ANSWER | .body = \"Fixed. <!-- touchstone:review-answer id=502 -->\" | .created_at = \"2026-08-13T10:04:00Z\")]" \
  success

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
  'pull_request_target:' \
  'workflow_run:' \
  'workflows: [review evidence signal]' \
  'api_reviews' \
  'updatedAt' \
  'issue_comment:' \
  'types: [created, edited, deleted]' \
  'status=in_progress' \
  'PATCH "repos/$REPO/check-runs/$run_id"' \
  'contents/.github/review-binding/evaluate.jq?ref=$base' \
  'live_head' \
  'newest_run' \
  'GITHUB_EVENT_PATH' \
  'known_head'; do
  if grep -Fq "$required" "$WORKFLOW"; then
    ok "workflow contains: $required"
  else
    fail "workflow missing required guardrail: $required"
  fi
done
if grep -Fq 'BOOTSTRAP_BASE_SHA' "$WORKFLOW"; then
  fail "required review-binding workflow still carries its one-head bootstrap bypass"
else
  ok "one-head bootstrap bypass is absent from the required gate"
fi
if grep -Fq 'pull_request_review:' "$WORKFLOW" \
  || grep -Fq 'pull_request_review_comment:' "$WORKFLOW"; then
  fail "write-capable publisher must not run directly with read-only fork review tokens"
elif grep -Fq 'pull_request_review:' "$SIGNAL_WORKFLOW" \
  && grep -Fq 'pull_request_review_comment:' "$SIGNAL_WORKFLOW" \
  && grep -Fq 'permissions: {}' "$SIGNAL_WORKFLOW" \
  && ! grep -Eq '^[[:space:]]*uses:' "$SIGNAL_WORKFLOW"; then
  ok "fork review events route through an inert default-branch workflow_run handoff"
else
  fail "review evidence signal must cover every review mutation without write access or actions"
fi
if grep -Fq 'EVENT_PATH: ${{ github.event_path }}' "$WORKFLOW"; then
  fail "workflow must use the runner-populated GITHUB_EVENT_PATH, not an empty context expression"
else
  ok "event payload reads use the runner-provided path"
fi
if grep -Fq 'base64 --decode' "$WORKFLOW" \
  && grep -Fq 'base64 -D' "$WORKFLOW" \
  && grep -Fq 'decode_base64' "$WORKFLOW"; then
  ok "base64 decoding selects GNU or BSD syntax explicitly"
else
  fail "evaluator download needs a GNU/BSD portable base64 decoder"
fi
if grep -Fq 'resolve_comment_heads' "$WORKFLOW" \
  && grep -Fq 'resolved_review_sha' "$EVALUATOR" \
  && ! grep -Fq 'startswith($reviewed)' "$EVALUATOR"; then
  ok "abbreviated result SHAs resolve to full commits before exact comparison"
else
  fail "result evidence must never prefix-match an abbreviated commit"
fi
if grep -Fq '{7,40}' "$WORKFLOW" \
  && grep -Fq '[ "${#abbreviated}" -eq 40 ]' "$WORKFLOW"; then
  ok "full reviewed commit SHAs bypass abbreviation lookup"
else
  fail "collector must accept full reviewed commit SHAs directly"
fi
if grep -Fq 'ignoring that item' "$WORKFLOW" \
  && grep -Fq 'resolved=""' "$WORKFLOW" \
  && ! grep -Fq 'commits/$abbreviated" --jq .sha)" || return 1' "$WORKFLOW"; then
  ok "one unresolvable historical abbreviation cannot poison newer evidence"
else
  fail "unresolvable historical abbreviations must invalidate only their own evidence item"
fi
PREINVALIDATE_LINE="$(grep -n 'preinvalidated_items=' "$WORKFLOW" | cut -d: -f1)"
EVALUATE_LOOP_LINE="$(grep -n 'evaluate_pr \"\$number\" \"\$known_head\" \"\$pending_id\"' "$WORKFLOW" | cut -d: -f1)"
if [ -n "$PREINVALIDATE_LINE" ] \
  && [ -n "$EVALUATE_LOOP_LINE" ] \
  && [ "$PREINVALIDATE_LINE" -lt "$EVALUATE_LOOP_LINE" ] \
  && grep -Fq 'no expensive evidence read starts until every known' "$WORKFLOW"; then
  ok "all known sweep heads are pre-invalidated before evidence evaluation"
else
  fail "sweeps need a complete pending-check pass before the evaluation pass"
fi
EVALUATE_BODY="$(awk '/^          evaluate_pr\(\) \{/{grab=1} grab{print} grab && /^          \}/{exit}' "$WORKFLOW")"
if [ -z "$EVALUATE_BODY" ]; then
  fail "could not extract evaluate_pr for pending-order guard"
elif awk '
  /reached evaluation without a precreated pending check/ { pending = NR }
  /gh api "repos\/\$REPO\/pulls\/\$number"/ { lookup = NR; exit }
  END { exit !(pending && lookup && pending < lookup) }
' <<<"$EVALUATE_BODY"; then
  ok "known event heads require a precreated pending check before the fallible PR lookup"
else
  fail "evaluate_pr must reject a known head without pre-invalidation before reading live PR coordinates"
fi
if grep -Fq -- "[.number, .head.sha] | @tsv" "$WORKFLOW"; then
  ok "discovery paths carry each affected PR head into evaluation"
else
  fail "push/status discovery must preserve the affected head SHA"
fi
if grep -Fq 'and .head.sha == $pr.head.sha' "$WORKFLOW"; then
  ok "shared-head uniqueness excludes descendant stacked PRs"
else
  fail "uniqueness must compare each associated PR's current head exactly"
fi
if grep -Fq "'.before'" "$WORKFLOW" \
  && grep -Fq 'previous_items=' "$WORKFLOW"; then
  ok "synchronize rebuilds PRs left on the event's previous shared head"
else
  fail "synchronize must fan out over open PRs associated with the previous head"
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
if grep -Fq 'updated_at: .updatedAt' "$WORKFLOW" \
  && grep -Fq '$finding.updated_at // $finding.submitted_at' "$EVALUATOR" \
  && ! grep -Fq 'touchstone/review-edit-v1' "$WORKFLOW" \
  && ! grep -Fq 'touchstone/review-edit-v1' "$EVALUATOR"; then
  ok "formal review edits use GitHub's authoritative updatedAt"
else
  fail "formal review edit freshness must come from authoritative review data"
fi
REQUEST_BODY="$(awk '/^          establish_request_marker\(\) \{/{grab=1} grab{print} grab && /^          \}/{exit}' "$WORKFLOW")"
if awk '
  /create_pending/ { pending = NR }
  /statuses\/\$head/ { marker = NR; exit }
  END { exit !(pending && marker && pending < marker) }
' <<<"$REQUEST_BODY" \
  && grep -Fq 'work_items="$EVENT_PENDING_PR"' "$WORKFLOW"; then
  ok "new review requests publish and retain pending before recording the marker"
else
  fail "request marker writes must never precede their invalidating pending check"
fi
if grep -Fq 'live_base_ref="$(jq -r .base.ref' "$WORKFLOW" \
  && grep -Fq '"$live_base_ref" != "$base_ref"' "$WORKFLOW"; then
  ok "publication revalidates base ref as well as base SHA"
else
  fail "same-SHA base retargeting must cancel a stale evaluation"
fi
if grep -Fq 'brew_install_if_missing "jq" "jq"' "$SETUP"; then
  ok "jq is declared by local setup for the review fixtures"
else
  fail "review fixtures require jq through local setup"
fi

if [ "$ERRORS" -ne 0 ]; then
  echo "$ERRORS review-binding test(s) failed" >&2
  exit 1
fi
echo "All review-binding tests passed."

(
  # tests/test-pr-cli.sh — deterministic PR lifecycle boundary tests.

  set -euo pipefail

  ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
  TMP="$(mktemp -d -t touchstone-pr.XXXXXX)"
  trap '[ "${KEEP_TMP:-false}" = true ] || rm -rf "$TMP"' EXIT
  ERRORS=0

  fail() {
    echo "FAIL: $*" >&2
    ERRORS=$((ERRORS + 1))
  }
  assert_has() { grep -qF -- "$2" "$1" || fail "expected $1 to contain: $2"; }
  assert_not_has() { grep -qF -- "$2" "$1" && fail "expected $1 not to contain: $2" || true; }
  assert_rc() { [ "$1" -eq "$2" ] || fail "expected rc $2, got $1"; }

  mkdir -p "$TMP/bin" "$TMP/project" "$TMP/origin.git" "$TMP/state"
  git -C "$TMP/origin.git" init -q --bare
  git -C "$TMP/project" init -q -b main
  git -C "$TMP/project" config user.name test
  git -C "$TMP/project" config user.email test@example.com
  printf 'fixture\n' >"$TMP/project/README.md"
  printf '%s\n' 'schema = 1' '' '[validation]' 'runtime = "bash"' \
    '' '[[validation.targets]]' 'name = "root"' 'path = "."' \
    '' '[[validation.tasks]]' 'name = "test"' 'target = "root"' \
    'command = "true"' 'required = true' >"$TMP/project/.touchstone.toml"
  printf '%s\n' 'schema = 1' 'type = "github"' >"$TMP/project/.touchstone-tracker.toml"
  git -C "$TMP/project" add README.md .touchstone.toml .touchstone-tracker.toml
  git -C "$TMP/project" commit -qm fixture
  git -C "$TMP/project" remote add origin "$TMP/origin.git"
  git -C "$TMP/project" push -qu origin main
  git -C "$TMP/project" remote set-head origin main
  MAIN_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
  git -C "$TMP/project" switch -qc feat/test
  printf 'change\n' >>"$TMP/project/README.md"
  git -C "$TMP/project" add README.md
  git -C "$TMP/project" commit -qm change
  git -C "$TMP/project" push -qu origin HEAD
  HEAD_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
  printf '%s\n' 'Change summary.' '' 'Closes #42' >"$TMP/body"
  printf '%s\n' 'Handled the finding.' >"$TMP/reply"

  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"
has() { local needle="$1"; shift; printf '%s\n' "$*" | grep -qF -- "$needle"; }
value_after() {
  local wanted="$1"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$wanted" ]; then
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done
  return 1
}

case "$1 ${2:-}" in
  "auth status")
    [ "${GH_MODE:-ok}" != auth_fail ]
    [ "${GH_MODE:-ok}" != auth_unrelated ] || has '--hostname' "$@"
    ;;
  "repo view")
    [ "${GH_MODE:-ok}" != success_stderr ] || printf 'repo debug detail\n' >&2
    if [ -n "${GH_REPO:-}" ]; then
      printf '%s\thttps://%s/%s\tmain\n' "$GH_REPO" "${GH_REPO_HOST:-github.com}" "$GH_REPO"
    else
      printf 'autumngarage/current\thttps://%s/autumngarage/current\tmain\n' "${GH_REPO_HOST:-github.com}"
    fi
    ;;
  "pr list")
    if [ -f "$GH_STATE/pr-exists" ]; then
      printf '7\thttps://example.test/pr/7\t%s\t%s\t%s\n' \
        "$GH_HEAD" "${GH_BASE_REF:-main}" "${GH_BASE_SHA:-base-sha}"
    fi
    ;;
  "pr create")
    case "${GH_MODE:-ok}" in
      create_missing) exit 1 ;;
      create_lied)
        touch "$GH_STATE/pr-exists"
        cp "$(value_after --body-file "$@")" "$GH_STATE/pr-body"
        echo 'gateway error' >&2
        exit 1
        ;;
      *)
        touch "$GH_STATE/pr-exists"
        cp "$(value_after --body-file "$@")" "$GH_STATE/pr-body"
        printf '%s\n' https://example.test/pr/7
        ;;
    esac
    ;;
  "pr comment")
    [ "${GH_MODE:-ok}" != comment_success_stderr ] || printf 'comment debug detail\n' >&2
    [ "${GH_MODE:-ok}" = comment_unverified ] ||
      printf '%s %s %s\n' "$GH_HEAD" "$GH_BASE_REF" "$GH_BASE_SHA" >"$GH_STATE/review-request"
    [ "${GH_MODE:-ok}" != comment_lied ] || exit 1
    printf '%s\n' https://example.test/pr/7#issuecomment-1
    ;;
  "pr view")
    [ "${GH_MODE:-ok}" != success_stderr ] || printf 'view debug detail\n' >&2
    if [ "${GH_MODE:-ok}" = read_retry ] && [ ! -f "$GH_STATE/retried" ]; then
      touch "$GH_STATE/retried"
      exit 1
    fi
    if has '--json headRefOid,baseRefName,baseRefOid' "$@"; then
      if [ "${GH_MODE:-ok}" = binding_moved ]; then
        printf 'moved-head\t%s\t%s\n' "$GH_BASE_REF" "$GH_BASE_SHA"
      else
        printf '%s\t%s\t%s\n' "$GH_HEAD" "$GH_BASE_REF" "$GH_BASE_SHA"
      fi
    elif has '--json body' "$@"; then
      if [ -f "$GH_STATE/pr-body" ]; then
        cat "$GH_STATE/pr-body"
      else
        printf '%s\n' 'Change summary.' '' 'Closes #42'
      fi
    elif has '--json state,url' "$@"; then
      if [ -f "$GH_STATE/merged" ]; then printf 'MERGED\thttps://example.test/pr/7\n'; else printf 'OPEN\thttps://example.test/pr/7\n'; fi
    elif [ -f "$GH_STATE/merged" ]; then
      printf '7\tMERGED\thttps://example.test/pr/7\t%s\tmain\tbase-sha\tUNKNOWN\tfalse\n' "$GH_HEAD"
    else
      printf '7\tOPEN\thttps://example.test/pr/7\t%s\tmain\tbase-sha\tCLEAN\tfalse\n' "$GH_HEAD"
    fi
    ;;
  "pr merge")
    if [ "${GH_MODE:-ok}" = merge_failed ]; then exit 1; fi
    case "${GH_MODE:-ok}" in merge_queue | auto_merge) exit 0 ;; esac
    touch "$GH_STATE/merged"
    [ "${GH_MODE:-ok}" != merge_lied ] || exit 1
    ;;
  "issue view")
    if [ -f "$GH_STATE/merged" ]; then printf 'CLOSED\tCOMPLETED\n'; else printf 'OPEN\t\n'; fi
    ;;
  "api user") printf '%s\n' alice ;;
  "api graphql")
    if has 'mergeQueueEntry' "$@"; then
      if [ -f "$GH_STATE/merged" ]; then
        printf 'MERGED\thttps://example.test/pr/7\tfalse\t\n'
      elif [ "${GH_MODE:-ok}" = merge_queue ]; then
        printf 'OPEN\thttps://example.test/pr/7\tfalse\tQUEUED\n'
      elif [ "${GH_MODE:-ok}" = auto_merge ]; then
        printf 'OPEN\thttps://example.test/pr/7\ttrue\t\n'
      else
        printf 'OPEN\thttps://example.test/pr/7\tfalse\t\n'
      fi
    elif has 'resolveReviewThread' "$@"; then
      printf '%s\n' true
    elif has 'node(id:' "$@"; then
      printf '%s\n' true
    elif has 'threadId:.id' "$@"; then
      printf '%s\n' '[{"threadId":"T1","resolved":false,"commentId":51,"path":"app.js","body":"fix it","url":"https://example.test/thread"}]'
    elif has 'select(.comments.nodes[0].databaseId' "$@"; then
      printf '%s\n' T1
    elif has 'select(.isResolved == false)' "$@"; then
      [ "${GH_MODE:-ok}" != unresolved ] || printf 'T1\t51\tapp.js\n'
    else
      printf '%s\n' '  thread 51 [resolved=false] app.js'
    fi
    ;;
  "api --paginate")
    if has "/commits/$GH_HEAD/statuses?per_page=100" "$@"; then
      [ "${GH_MODE:-ok}" = marker_missing ] || printf '%s\n' 81
    elif has '/issues/7/comments' "$@"; then
      if [ "${GH_MODE:-ok}" = many_requests ]; then
        for index in $(awk 'BEGIN { for (i = 1; i <= 4000; i++) print i }'); do
          printf 'https://example.test/pr/7#issuecomment-%s\talice\t%s\n' "$index" \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        done
      elif [ "${GH_MODE:-ok}" = spoofed_request ]; then
        printf '%s\tmallory\t%s\n' 'https://example.test/pr/7#issuecomment-spoofed' \
          "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        if [ -f "$GH_STATE/review-request" ]; then
          printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        fi
      elif [ "${GH_MODE:-ok}" = marker_only ]; then
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-marker' \
          "<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        if [ -f "$GH_STATE/review-request" ]; then
          printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        fi
      elif [ -f "$GH_STATE/review-request" ]; then
        read -r saved_head saved_base saved_base_sha <"$GH_STATE/review-request"
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
          "@codex review\\n\\n<!-- touchstone:pr-open head=$saved_head base=$saved_base base_sha=$saved_base_sha -->"
      fi
    elif has '/reviews?per_page=100' "$@"; then
      if has 'reviewId:.id' "$@"; then
        printf '%s\n' '[{"reviewId":61,"state":"COMMENTED","body":"body finding","url":"https://example.test/review","commit":"old-head"}]'
      else
        printf '%s\n' '  review 61 [COMMENTED] at old-head'
      fi
    elif has '/pulls/7/comments' "$@"; then
      if [ -f "$GH_STATE/reply" ]; then printf '%s\n' '<!-- touchstone:respond-review comment=51 -->'; fi
    fi
    ;;
  "api repos/autumngarage/current/pulls/7/comments/51/replies")
    touch "$GH_STATE/reply"
    printf '%s\n' 71
    ;;
  api*)
    if has '/issues/comments/1' "$@"; then
      [ "${GH_MODE:-ok}" = live_comment_invalid ] || printf '%s\n' 1
    elif has '/issues/7/comments' "$@"; then
      if [ -f "$GH_STATE/review-request" ]; then printf '%s\n' https://example.test/pr/7#issuecomment-1; fi
    elif has '/commits/' "$@" && has '/status' "$@"; then
      if [ -f "$GH_STATE/review-request" ]; then printf '%s\n' https://example.test/pr/7#issuecomment-1; fi
    elif has 'check-runs?check_name=review-binding' "$@"; then
      [ "${GH_MODE:-ok}" = binding_missing ] || printf 'completed\tsuccess\n'
    fi
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" GH_CALLS="$TMP/calls" GH_STATE="$TMP/state" GH_HEAD="$HEAD_SHA"
  export GH_BASE_REF=main GH_BASE_SHA=base-sha
  export TOUCHSTONE_READ_ATTEMPTS=2 TOUCHSTONE_REQUEST_ATTEMPTS=2 TOUCHSTONE_RETRY_DELAY=0

  run_pr() {
    local output="$1"
    shift
    : >"$GH_CALLS"
    set +e
    bash "$ROOT/bin/touchstone" pr "$@" --project "$TMP/project" >"$output" 2>&1
    RUN_RC=$?
    set -e
  }

  echo "==> status is versioned, read-only, and retries bounded transport failures"
  touch "$TMP/state/pr-exists"
  GH_MODE=read_retry run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"schema":"touchstone.pr/v1"'
  assert_has "$TMP/out" '"status":"observed"'
  assert_has "$TMP/out" "\"head\":\"$HEAD_SHA\""
  [ "$(grep -c '^pr view' "$GH_CALLS")" -eq 2 ] || fail "status did not retry exactly once"
  GH_REPO_HOST=github.enterprise.example run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr view 7 --repo github.enterprise.example/autumngarage/current'
  GH_REPO=ambient/wrong run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr view 7 --repo github.com/autumngarage/current'
  assert_not_has "$GH_CALLS" 'ambient/wrong'
  GH_MODE=success_stderr run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"head\":\"$HEAD_SHA\""
  assert_not_has "$TMP/out" 'debug detail'
  run_pr "$TMP/out" status 7 --title invalid
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not accept mutation options'
  run_pr "$TMP/out" status 7 --project '' --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'missing value for --project'
  GH_MODE=auth_fail run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_not_has "$TMP/out" '"status":"observed"'
  GH_MODE=auth_unrelated run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'auth status --hostname github.com'

  echo "==> open refuses head drift and reconciles a lying creation response"
  rm -f "$TMP/state/pr-exists" "$TMP/state/review-request"
  git -C "$TMP/project" switch -q main
  GH_HEAD="$MAIN_SHA" run_pr "$TMP/out" open --title 'Default branch' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'cannot open a pull request from the default branch'
  GH_HEAD="$MAIN_SHA" GH_BASE_REF=release run_pr "$TMP/out" open --title 'Default branch' \
    --body-file "$TMP/body" --base release --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'cannot open a pull request from the default branch'
  git -C "$TMP/project" switch -q feat/test
  touch "$TMP/state/pr-exists"
  GH_HEAD=wrong run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not match local/remote head'
  GH_HEAD="$HEAD_SHA"
  rm -f "$TMP/state/pr-exists"
  caller_directory="$PWD"
  canonical_body="$(cd "$TMP" && pwd -P)/body"
  cd "$TMP"
  GH_MODE=create_lied run_pr "$TMP/out" open --title 'Test PR' --body-file body --json
  cd "$caller_directory"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"opened"'
  assert_has "$TMP/out" '"reviewRequest":"posted:'
  assert_has "$GH_CALLS" "pr create --repo github.com/autumngarage/current --head feat/test --base main --title Test PR --body-file $canonical_body"
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "open did not post one review request"
  rm -f "$TMP/state/review-request"
  GH_MODE=comment_lied run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'could not post the review request'
  rm -f "$TMP/state/review-request"
  GH_MODE=comment_unverified run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'was not verified'
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"existing"'
  assert_has "$TMP/out" '"reviewRequest":"posted:'
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "recovery did not post exactly one review request"
  rm -f "$TMP/state/review-request"
  GH_MODE=comment_success_stderr run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewRequest":"posted:https://example.test/pr/7#issuecomment-1"'
  assert_not_has "$TMP/out" 'comment debug detail'
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewRequest":"existing:'
  [ "$(grep -c '^pr comment' "$GH_CALLS" || true)" -eq 0 ] || fail "rerun duplicated the review request"
  assert_has "$GH_CALLS" "/commits/$HEAD_SHA/statuses?per_page=100"
  assert_has "$GH_CALLS" 'touchstone/review-request-v1'
  GH_MODE=marker_missing run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'has no matching server binding'
  GH_MODE=binding_moved run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'PR coordinates moved before the review request was bound'
  GH_MODE=live_comment_invalid run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'is no longer a valid driver request'
  rm -f "$TMP/state/review-request"
  GH_MODE=spoofed_request run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "spoofed marker suppressed the real review request"
  rm -f "$TMP/state/review-request"
  GH_MODE=marker_only run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "marker without trigger suppressed the real review request"
  GH_MODE=many_requests run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewRequest":"existing:https://example.test/pr/7#issuecomment-1"'

  printf '%s\n' 'Local draft without a closer.' >"$TMP/local-draft"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/local-draft" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"existing"'

  printf '%s\n' 'Live body without a locally parsed closer.' >"$TMP/state/pr-body"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  cp "$TMP/body" "$TMP/state/pr-body"

  GH_BASE_REF=release GH_BASE_SHA=release-sha \
    run_pr "$TMP/out" open --title 'Retargeted PR' --body-file "$TMP/body" \
    --base release --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'already has a review request for different base coordinates'
  rm -f "$TMP/state/review-request"
  GH_BASE_REF=release GH_BASE_SHA=release-sha \
    run_pr "$TMP/out" open --title 'Retargeted PR' --body-file "$TMP/body" \
    --base release --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" "touchstone:pr-open head=$HEAD_SHA base=release base_sha=release-sha"
  GH_BASE_REF=main
  GH_BASE_SHA=base-sha

  echo "==> review findings and responses stay on the canonical GitHub surface"
  run_pr "$TMP/out" findings 7 --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'touchstone pr open'
  run_pr "$TMP/out" respond 7 --comment-id 51 --body-file "$TMP/reply" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'touchstone pr open'

  echo "==> merge remains on the exact raw GitHub boundary"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'touchstone pr open'

  if [ "$ERRORS" -gt 0 ]; then
    echo "==> FAIL: $ERRORS PR CLI assertion(s) failed" >&2
    exit 1
  fi
  echo "==> PASS: PR open/status preserve exact-head and idempotency invariants"
)
