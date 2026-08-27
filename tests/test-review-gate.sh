#!/usr/bin/env bash
# Behavioral fixtures for the review-gate evidence contract, version 3.
# The request is derived from the driver's own comments -- the pr-open marker,
# or a bare request posted after the head was pushed -- so the evaluator can
# run from a pinned required workflow with a read-only token.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVALUATOR="$ROOT/.github/review-gate/evaluate.jq"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}
ok() { echo "  OK: $*"; }
HEAD_SHA="1111111111111111111111111111111111111111"
BASE_SHA="2222222222222222222222222222222222222222"
cat >"$TMP_DIR/base.json" <<EOF2
{"contractVersion":3,"complete":true,"trustedAuthors":["chatgpt-codex-connector[bot]"],
 "authorPermissions":{"henry":"admin"},
 "pr":{"number":42,"state":"open","headSha":"$HEAD_SHA","baseRef":"main","baseSha":"$BASE_SHA","acceptableBaseShas":["$BASE_SHA"],"headCurrentSince":"2026-08-20T10:00:00Z","openHeadPulls":[42]},
 "issueComments":[
  {"id":100,"created_at":"2026-08-20T10:05:00Z","author_association":"NONE","user":{"login":"henry"},"body":"@codex review\n\n<!-- touchstone:pr-open head=$HEAD_SHA base=main base_sha=$BASE_SHA -->"},
  {"id":101,"created_at":"2026-08-20T10:20:00Z","author_association":"NONE","user":{"login":"chatgpt-codex-connector[bot]"},"body":"Codex Review: Didn't find any major issues.\n\n**Reviewed commit:** \`1111111111\`","resolved_review_sha":"$HEAD_SHA"}],
 "reviews":[],"reviewComments":[]}
EOF2
run_case() {
  local label="$1" filter="$2" expected="$3" reason="${4:-}" verdict
  jq "$filter" "$TMP_DIR/base.json" >"$TMP_DIR/case.json"
  verdict="$(jq -f "$EVALUATOR" "$TMP_DIR/case.json")" || {
    fail "$label: evaluator crashed"
    return
  }
  [ "$(jq -r .conclusion <<<"$verdict")" = "$expected" ] || {
    fail "$label: expected $expected, got $(jq -c '{conclusion,reasons}' <<<"$verdict")"
    return
  }
  if [ -n "$reason" ] && ! jq -e --arg r "$reason" '.reasons | any(contains($r))' <<<"$verdict" >/dev/null; then
    fail "$label: missing reason '$reason'"
    return
  fi
  ok "$label"
}
run_state_case() {
  local label="$1" filter="$2" expected_state="$3" verdict
  local expected_conclusion="failure"
  [ "$expected_state" = "success" ] && expected_conclusion="success"
  jq "$filter" "$TMP_DIR/base.json" >"$TMP_DIR/case.json"
  verdict="$(jq -f "$EVALUATOR" "$TMP_DIR/case.json")" || {
    fail "$label: evaluator crashed"
    return
  }
  [ "$(jq -r .state <<<"$verdict")" = "$expected_state" ] || {
    fail "$label: expected state $expected_state, got $(jq -c '{state,conclusion,reasons}' <<<"$verdict")"
    return
  }
  [ "$(jq -r .conclusion <<<"$verdict")" = "$expected_conclusion" ] || {
    fail "$label: expected conclusion $expected_conclusion, got $(jq -c '{state,conclusion,reasons}' <<<"$verdict")"
    return
  }
  ok "$label"
}
run_rejected_count_case() {
  local label="$1" filter="$2" expected="$3" expected_state="$4" verdict
  jq "$filter" "$TMP_DIR/base.json" >"$TMP_DIR/case.json"
  verdict="$(jq -f "$EVALUATOR" "$TMP_DIR/case.json")" || {
    fail "$label: evaluator crashed"
    return
  }
  [ "$(jq -r .counts.rejectedReviewEvidence <<<"$verdict")" = "$expected" ] || {
    fail "$label: expected $expected rejected review candidate(s), got $(jq -c '{state,conclusion,counts,reasons}' <<<"$verdict")"
    return
  }
  [ "$(jq -r .state <<<"$verdict")" = "$expected_state" ] || {
    fail "$label: expected state $expected_state, got $(jq -c '{state,conclusion,counts,reasons}' <<<"$verdict")"
    return
  }
  ok "$label"
}
echo "==> Requests come from the driver's comments"
run_case "org-only admin request + clean exact-head result passes" '.' success
run_state_case "a complete clean review is terminal success" '.' success
run_state_case "a PR opened before its request waits for the request" \
  '.issueComments = []' waiting-request
run_state_case "a bound request waits for exact-head review evidence" \
  '.issueComments = [.issueComments[0]]' waiting-review
run_state_case "a provisional quota notice keeps waiting for review" \
  '.issueComments = [.issueComments[0], {"id":101,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"Security review usage limit reached"}]' waiting-review
run_state_case "a current-head quota notice still keeps waiting for review" \
  '.issueComments = [.issueComments[0], {"id":101,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"Security review quota reached","resolved_review_sha":"'"$HEAD_SHA"'"}]' waiting-review
run_state_case "a cutoff before the request observes no request" \
  '.evidenceCutoffAt = "2026-08-20T10:04:59Z"' waiting-request
run_state_case "a cutoff after the request but before review waits for review" \
  '.evidenceCutoffAt = "2026-08-20T10:10:00Z"' waiting-review
run_state_case "evidence exactly at the cutoff is accepted" \
  '.evidenceCutoffAt = "2026-08-20T10:20:00Z"' success
run_state_case "a result edited after the cutoff remains blocking evidence" \
  '.evidenceCutoffAt = "2026-08-20T10:20:00Z" | .issueComments[1].updated_at = "2026-08-20T10:20:01Z"' failure
run_state_case "a later edited result cannot hide behind an earlier clean result" '
  .evidenceCutoffAt = "2026-08-20T10:25:00Z"
  | .issueComments += [{"id":102,"created_at":"2026-08-20T10:21:00Z","updated_at":"2026-08-20T10:30:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"Codex Review: P1 edited result finding\n\n**Reviewed commit:** `1111111111`","resolved_review_sha":"1111111111111111111111111111111111111111"}]' failure
run_state_case "an edited quota notice remains provisional at the cutoff" '
  .evidenceCutoffAt = "2026-08-20T10:25:00Z"
  | .issueComments = [.issueComments[0], {"id":102,"created_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:30:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"Security review quota reached"}]' waiting-review
run_state_case "an invalid evidence cutoff fails closed" \
  '.evidenceCutoffAt = "2026-08-20 10:20:00"' failure
run_state_case "a non-string evidence cutoff fails closed" \
  '.evidenceCutoffAt = false' failure
run_state_case "an impossible evidence cutoff fails closed" \
  '.evidenceCutoffAt = "2026-99-99T99:99:99Z"' failure
run_state_case "a normalized calendar-invalid cutoff fails closed" \
  '.evidenceCutoffAt = "2026-09-31T00:00:00Z"' failure
run_state_case "a pre-cutoff finding edited later remains blocking evidence" '
  .evidenceCutoffAt = "2026-08-20T10:25:00Z"
  | .issueComments = [.issueComments[0]]
  | .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:30:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 edited finding"}]' failure
run_state_case "a pre-cutoff formal finding cleared later remains blocking evidence" '
  .evidenceCutoffAt = "2026-08-20T10:25:00Z"
  | .issueComments = [.issueComments[0]]
  | .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:30:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]' failure
run_state_case "a quota-related review finding remains terminal evidence" \
  '.issueComments[1].body = "Codex Review: [P1] Fix quota accounting\n\n**Reviewed commit:** `1111111111`"' failure
run_state_case "invalid evidence never becomes a waiting state" \
  'del(.complete) | .issueComments = []' failure
run_case "write permission can request" '.authorPermissions.henry = "write"' success
run_case "maintain permission can request" '.authorPermissions.henry = "maintain"' success
run_case "direct collaborator with write permission can request" '.authorPermissions.henry = "write" | .issueComments[0].author_association = "COLLABORATOR"' success
run_case "bare request after the head was pushed binds it" '.issueComments[0].body = "@codex review"' success
run_case "bare request before the head was pushed does not" '.issueComments[0].body = "@codex review" | .issueComments[0].created_at = "2026-08-20T09:00:00Z"' failure "no trusted review request"
run_state_case "a stale authorized bare request is terminal failure" \
  '.issueComments[0].body = "@codex review" | .issueComments[0].created_at = "2026-08-20T09:00:00Z"' failure
run_case "bare request before a base retarget does not bind" '.issueComments[0].body = "@codex review" | .pr.baseRetargetedAt = "2026-08-20T10:10:00Z"' failure "no trusted review request"
run_case "bare request after a base retarget binds" '.issueComments[0].body = "@codex review" | .pr.baseRetargetedAt = "2026-08-20T10:01:00Z"' success
run_case "marker for another head does not bind" '.issueComments[0].body |= sub("head=1111111111111111111111111111111111111111"; "head=3333333333333333333333333333333333333333")' failure "no trusted review request"
run_state_case "a request marker for another head is terminal failure" \
  '.issueComments[0].body |= sub("head=1111111111111111111111111111111111111111"; "head=3333333333333333333333333333333333333333")' failure
run_case "marker base must be the tip or an ancestor" '.pr.acceptableBaseShas = ["3333333333333333333333333333333333333333"]' failure "no trusted review request"
run_case "an advanced base keeps the request" '.pr.baseSha = "3333333333333333333333333333333333333333" | .pr.acceptableBaseShas = ["3333333333333333333333333333333333333333", "'"$BASE_SHA"'"]' success
run_case "retargeted base ref invalidates the marker" '.pr.baseRef = "release"' failure "no trusted review request"
run_case "an edited request counts from its edit, not its creation" '.issueComments[0].updated_at = "2026-08-20T10:30:00Z"' failure "no trusted exact-head"
run_case "bare request before the SHA was restored by force-push does not bind" '.issueComments[0].body = "@codex review" | .pr.headCurrentSince = "2026-08-20T10:10:00Z"' failure "no trusted review request"
run_case "a malformed sequencer marker is not a bare request" '.issueComments[0].body = "@codex review\n\n<!-- touchstone:pr-open head=1111 base=main -->"' failure "no trusted review request"
run_state_case "a malformed sequencer marker is terminal failure" \
  '.issueComments[0].body = "@codex review\n\n<!-- touchstone:pr-open head=1111 base=main -->"' failure
run_state_case "read permission is a terminal request failure" '.authorPermissions.henry = "read"' failure
run_state_case "triage permission is a terminal request failure" '.authorPermissions.henry = "triage"' failure
run_state_case "no repository permission is a terminal request failure" '.authorPermissions.henry = "none"' failure
run_state_case "unknown permission is a terminal request failure" '.authorPermissions.henry = "owner"' failure
run_case "missing permission fails closed" 'del(.authorPermissions.henry)' failure "permission evidence is missing"
run_case "author association is not an authorization fast path" 'del(.authorPermissions.henry) | .issueComments[0].author_association = "OWNER"' failure "permission evidence is missing"
run_case "unrelated commenters need no permission lookup" '
  .issueComments += [{"id":102,"created_at":"2026-08-20T10:25:00Z","user":{"login":"reader"},"body":"Unrelated discussion"}]
  | .reviewComments += [{"id":11,"in_reply_to_id":null,"created_at":"2026-08-20T10:25:00Z","user":{"login":"reviewer"},"body":"Unrelated top-level comment"}]' success
run_case "every potential reply author needs permission evidence" '
  .reviewComments += [{"id":11,"in_reply_to_id":9,"created_at":"2026-08-20T10:25:00Z","user":{"login":"reader"},"body":"A possible answer"}]' failure "permission evidence is missing"
run_case "the result must postdate the request" '.issueComments[1].created_at = "2026-08-20T10:01:00Z"' failure "no trusted exact-head"
run_state_case "an older result still means the current request is waiting" \
  '.issueComments[1].created_at = "2026-08-20T10:01:00Z"' waiting-review
run_state_case "a post-request result for another head is terminal failure" \
  '.issueComments[1].resolved_review_sha = "3333333333333333333333333333333333333333"' failure
run_rejected_count_case "mixed accepted and stale results report the rejected evidence" '
  .issueComments += [{"id":102,"created_at":"2026-08-20T10:21:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"Codex Review: stale result","resolved_review_sha":"3333333333333333333333333333333333333333"}]' 1 success
run_state_case "a stale post-request result identified by a blob URL is terminal failure" \
  '.issueComments[1].resolved_review_sha = "" | .issueComments[1].body = "Review result: https://github.com/autumngarage/touchstone/blob/3333333333333333333333333333333333333333/file"' failure
run_state_case "a malformed post-request result is terminal failure" \
  '.issueComments[1].resolved_review_sha = "" | .issueComments[1].body = "Codex Review: completed\n\n**Reviewed commit:** `not-a-sha`"' failure
run_state_case "a post-request formal review for another head is terminal failure" '
  .issueComments = [.issueComments[0]]
  | .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"3333333333333333333333333333333333333333","user":{"login":"chatgpt-codex-connector[bot]"}}]' failure
run_case "moved head invalidates evidence" '.pr.headSha = "3333333333333333333333333333333333333333"' failure "no trusted exact-head"
run_case "contract version is enforced" '.contractVersion = 2' failure "contract version"
echo "==> Findings still need answers"
run_case "an unanswered inline finding blocks" '
  .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"}]' failure "inline finding"
run_state_case "an unanswered inline finding is terminal failure" '
  .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"}]' failure
run_case "an answered inline finding passes" '
  .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"},
                       {"id":10,"in_reply_to_id":9,"created_at":"2026-08-20T10:30:00Z","author_association":"NONE","user":{"login":"henry"},"body":"Fixed."}]' success
run_case "same-head recovery cannot erase an earlier unanswered inline finding" '
  .issueComments = [
    .issueComments[0],
    {"id":102,"created_at":"2026-08-20T10:25:00Z","user":{"login":"henry"},"body":"@codex review"},
    {"id":103,"created_at":"2026-08-20T10:40:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"Codex Review: Did not find any major issues.\n\n**Reviewed commit:** `1111111111`","resolved_review_sha":"'"$HEAD_SHA"'"}
  ]
  | .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"}]' failure "inline finding"
run_case "read permission cannot answer an inline finding" '
  .authorPermissions.henry = "read"
  | .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"},
                       {"id":10,"in_reply_to_id":9,"created_at":"2026-08-20T10:30:00Z","author_association":"OWNER","user":{"login":"henry"},"body":"Fixed."}]' failure "inline finding"
echo "==> A review body stamped by GitHub's inline attachment is not a finding; any later edit is"
STANDARD_BODY="### 💡 Codex Review\\n\\nHere are some automated review suggestions for this pull request.\\n\\n**Reviewed commit:** \`1111111111\`"
run_case "the attachment stamp (updated_at equals the last inline comment) passes" '
  .reviews = [{"id":7,"body":"'"$STANDARD_BODY"'","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:01Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:01Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"},
                       {"id":10,"in_reply_to_id":9,"created_at":"2026-08-20T10:30:00Z","author_association":"NONE","user":{"login":"henry"},"body":"Fixed."}]' success
run_case "a standard review body edited two seconds after its last attachment is a body finding" '
  .reviews = [{"id":7,"body":"'"$STANDARD_BODY"'","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:03Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"},
                       {"id":10,"in_reply_to_id":9,"created_at":"2026-08-20T10:30:00Z","author_association":"NONE","user":{"login":"henry"},"body":"Fixed."}]' failure "body-only finding"
for permission in write maintain admin; do
  run_case "$permission permission can answer a review-body finding" '
    .authorPermissions.henry = "'"$permission"'"
    | .reviews = [{"id":7,"body":"P1 body finding","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
    | .issueComments += [{"id":102,"created_at":"2026-08-20T10:30:00Z","author_association":"NONE","user":{"login":"henry"},"body":"Fixed. <!-- touchstone:review-answer id=7 -->"}]' success
done
run_case "read permission cannot answer a review-body finding" '
  .authorPermissions.henry = "read"
  | .reviews = [{"id":7,"body":"P1 body finding","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .issueComments += [{"id":102,"created_at":"2026-08-20T10:30:00Z","author_association":"OWNER","user":{"login":"henry"},"body":"Fixed. <!-- touchstone:review-answer id=7 -->"}]' failure "body-only finding"
for permission in write maintain admin; do
  run_case "$permission permission can answer a result-comment finding" '
    .authorPermissions.henry = "'"$permission"'"
    | .issueComments[1].body = "Codex Review: P1 result finding\n\n**Reviewed commit:** `1111111111`"
    | .issueComments += [{"id":102,"created_at":"2026-08-20T10:30:00Z","author_association":"NONE","user":{"login":"henry"},"body":"Fixed. <!-- touchstone:review-answer id=101 -->"}]' success
done
run_case "read permission cannot answer a result-comment finding" '
  .authorPermissions.henry = "read"
  | .issueComments[1].body = "Codex Review: P1 result finding\n\n**Reviewed commit:** `1111111111`"
  | .issueComments += [{"id":102,"created_at":"2026-08-20T10:30:00Z","author_association":"OWNER","user":{"login":"henry"},"body":"Fixed. <!-- touchstone:review-answer id=101 -->"}]' failure "body-only finding"
[ "$ERRORS" -eq 0 ] || {
  echo "==> FAIL: $ERRORS review-gate assertion(s) failed" >&2
  exit 1
}
echo "==> PASS: review-gate binds requests from driver comments and answers to findings"
