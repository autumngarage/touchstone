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
 "authorPermissions":{"henry":"admin","chatgpt-codex-connector[bot]":"none"},
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
echo "==> Requests come from the driver's comments"
run_case "org-only admin request + clean exact-head result passes" '.' success
run_case "write permission can request" '.authorPermissions.henry = "write"' success
run_case "maintain permission can request" '.authorPermissions.henry = "maintain"' success
run_case "direct collaborator with write permission can request" '.authorPermissions.henry = "write" | .issueComments[0].author_association = "COLLABORATOR"' success
run_case "bare request after the head was pushed binds it" '.issueComments[0].body = "@codex review"' success
run_case "bare request before the head was pushed does not" '.issueComments[0].body = "@codex review" | .issueComments[0].created_at = "2026-08-20T09:00:00Z"' failure "no trusted review request"
run_case "bare request before a base retarget does not bind" '.issueComments[0].body = "@codex review" | .pr.baseRetargetedAt = "2026-08-20T10:10:00Z"' failure "no trusted review request"
run_case "bare request after a base retarget binds" '.issueComments[0].body = "@codex review" | .pr.baseRetargetedAt = "2026-08-20T10:01:00Z"' success
run_case "marker for another head does not bind" '.issueComments[0].body |= sub("head=1111111111111111111111111111111111111111"; "head=3333333333333333333333333333333333333333")' failure "no trusted review request"
run_case "marker base must be the tip or an ancestor" '.pr.acceptableBaseShas = ["3333333333333333333333333333333333333333"]' failure "no trusted review request"
run_case "an advanced base keeps the request" '.pr.baseSha = "3333333333333333333333333333333333333333" | .pr.acceptableBaseShas = ["3333333333333333333333333333333333333333", "'"$BASE_SHA"'"]' success
run_case "retargeted base ref invalidates the marker" '.pr.baseRef = "release"' failure "no trusted review request"
run_case "an edited request counts from its edit, not its creation" '.issueComments[0].updated_at = "2026-08-20T10:30:00Z"' failure "no trusted exact-head"
run_case "bare request before the SHA was restored by force-push does not bind" '.issueComments[0].body = "@codex review" | .pr.headCurrentSince = "2026-08-20T10:10:00Z"' failure "no trusted review request"
run_case "a malformed sequencer marker is not a bare request" '.issueComments[0].body = "@codex review\n\n<!-- touchstone:pr-open head=1111 base=main -->"' failure "no trusted review request"
run_case "read permission cannot request" '.authorPermissions.henry = "read"' failure "no trusted review request"
run_case "triage permission cannot request" '.authorPermissions.henry = "triage"' failure "no trusted review request"
run_case "no repository permission cannot request" '.authorPermissions.henry = "none"' failure "no trusted review request"
run_case "unknown permission cannot request" '.authorPermissions.henry = "owner"' failure "no trusted review request"
run_case "missing permission fails closed" 'del(.authorPermissions.henry)' failure "permission evidence is missing"
run_case "author association is not an authorization fast path" 'del(.authorPermissions.henry) | .issueComments[0].author_association = "OWNER"' failure "permission evidence is missing"
run_case "the result must postdate the request" '.issueComments[1].created_at = "2026-08-20T10:01:00Z"' failure "no trusted exact-head"
run_case "moved head invalidates evidence" '.pr.headSha = "3333333333333333333333333333333333333333"' failure "no trusted exact-head"
run_case "contract version is enforced" '.contractVersion = 2' failure "contract version"
echo "==> Findings still need answers"
run_case "an unanswered inline finding blocks" '
  .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"}]' failure "inline finding"
run_case "an answered inline finding passes" '
  .reviews = [{"id":7,"body":"","state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"'"$HEAD_SHA"'","user":{"login":"chatgpt-codex-connector[bot]"}}]
  | .reviewComments = [{"id":9,"pull_request_review_id":7,"in_reply_to_id":null,"created_at":"2026-08-20T10:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"},"body":"P1 finding"},
                       {"id":10,"in_reply_to_id":9,"created_at":"2026-08-20T10:30:00Z","author_association":"NONE","user":{"login":"henry"},"body":"Fixed."}]' success
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
[ "$ERRORS" -eq 0 ] || {
  echo "==> FAIL: $ERRORS review-gate assertion(s) failed" >&2
  exit 1
}
echo "==> PASS: review-gate binds requests from driver comments and answers to findings"
