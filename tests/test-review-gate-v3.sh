#!/usr/bin/env bash
# Behavioral fixtures for the review-gate gate behavior contract, version 3.
# One trusted, explicit verdict bound to the current head; only an unedited
# clean result succeeds. Fixtures are sanitized from the shapes observed in
# the 52-PR audit (audits/2026-09-01-exact-head-verdict.md): every scenario
# named by AUT-1132's Phase 1 list is exercised here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVALUATOR="$ROOT/.github/review-gate/evaluate-v3.jq"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}
ok() { echo "  OK: $*"; }

HEAD_SHA="1111111111111111111111111111111111111111"
OLD_SHA="9999999999999999999999999999999999999999"
BASE_SHA="2222222222222222222222222222222222222222"
CLEAN_BODY="Codex Review: Didn't find any major issues.\n\n**Reviewed commit:** \`1111111\`"
FINDINGS_BODY="\n### 💡 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** \`$HEAD_SHA\`"

# Base fixture: one review request, one findings review for the head, one
# later clean result for the head — the common answered-then-attested PR.
cat >"$TMP_DIR/base.json" <<EOF2
{"gateBehaviorContractVersion":3,"complete":true,
 "trustedAuthors":["chatgpt-codex-connector","chatgpt-codex-connector[bot]"],
 "pr":{"number":42,"state":"open","headSha":"$HEAD_SHA","baseRef":"main","baseSha":"$BASE_SHA","baseRetargetedAt":"","openHeadPulls":[42]},
 "issueComments":[
  {"id":100,"created_at":"2026-08-20T10:05:00Z","updated_at":"2026-08-20T10:05:00Z","user":{"login":"henry"},"body":"@codex review\n\n<!-- touchstone:pr-open head=$HEAD_SHA base=main base_sha=$BASE_SHA -->"},
  {"id":101,"created_at":"2026-08-20T10:40:00Z","updated_at":"2026-08-20T10:40:00Z","user":{"login":"chatgpt-codex-connector"},"body":"$CLEAN_BODY","resolved_review_sha":"$HEAD_SHA"}],
 "reviews":[
  {"id":900,"state":"COMMENTED","submitted_at":"2026-08-20T10:20:00Z","updated_at":"2026-08-20T10:20:00Z","commit_id":"$HEAD_SHA","user":{"login":"chatgpt-codex-connector"},"body":"$FINDINGS_BODY"}]}
EOF2

run_case() {
  local label="$1" filter="$2" expected_verdict="$3" reason_fragment="${4:-}" verdict
  jq "$filter" "$TMP_DIR/base.json" >"$TMP_DIR/case.json"
  verdict="$(jq -f "$EVALUATOR" "$TMP_DIR/case.json")" || {
    fail "$label: evaluator crashed"
    return
  }
  [ "$(jq -r .verdict <<<"$verdict")" = "$expected_verdict" ] || {
    fail "$label: expected verdict $expected_verdict, got $(jq -c '{verdict,state,reason}' <<<"$verdict")"
    return
  }
  local expected_conclusion="failure"
  [ "$expected_verdict" = "clean" ] && expected_conclusion="success"
  [ "$(jq -r .conclusion <<<"$verdict")" = "$expected_conclusion" ] || {
    fail "$label: expected conclusion $expected_conclusion, got $(jq -c '{verdict,conclusion}' <<<"$verdict")"
    return
  }
  if [ -n "$reason_fragment" ] && ! jq -e --arg r "$reason_fragment" '.reason | contains($r)' <<<"$verdict" >/dev/null; then
    fail "$label: missing reason fragment '$reason_fragment' in $(jq -c .reason <<<"$verdict")"
    return
  fi
  ok "$label"
}

# --- Phase 1 scenario matrix ---

run_case "clean current head" '.' clean

run_case "finding-bearing current head (no later clean)" \
  'del(.issueComments[1])' findings "answer and resolve them on their threads"

# Answering without a code change is invisible to the evaluator by design:
# the same head simply receives a later clean verdict after re-review.
run_case "finding answered without a code change, then clean re-review" \
  '.issueComments[1].created_at = "2026-08-20T11:00:00Z" | .issueComments[1].updated_at = "2026-08-20T11:00:00Z"' clean

# A fix pushed as a new head: the old findings review binds the old SHA and
# the clean re-review names the new head.
run_case "finding fixed by a new head and clean re-review" \
  ".reviews[0].commit_id = \"$OLD_SHA\"" clean

run_case "stale prior-head clean result" \
  '.issueComments[1].body = "Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `9999999`" | del(.reviews[0])' \
  waiting "no trusted completed verdict binds"

# A rewritten head inherits nothing: every prior verdict binds the old SHA.
run_case "current head rewritten after earlier review" \
  ".reviews[0].commit_id = \"$OLD_SHA\" | .issueComments[1].body = \"Codex Review: Didn't find any major issues.\n\n**Reviewed commit:** \`9999999\`\"" \
  waiting

run_case "clean result edited after posting" \
  '.issueComments[1].updated_at = "2026-08-20T10:45:00Z"' invalid "edited after posting"

# GitHub returns nothing for a deleted comment; absence of the positive
# artifact fails closed with no prior-snapshot reconstruction.
run_case "clean result deleted" \
  'del(.issueComments[1])
   | del(.reviews[0])' waiting

# Dismissal is not an answer and not a fresh clean verdict.
run_case "dismissed findings review still blocks success" \
  'del(.issueComments[1]) | .reviews[0].state = "DISMISSED"' findings

run_case "dismissal cannot resurrect an earlier clean result" \
  '.reviews[0].state = "DISMISSED" | .reviews[0].submitted_at = "2026-08-20T11:30:00Z"' findings

run_case "late finding after an apparent clean result" \
  '.reviews[0].submitted_at = "2026-08-20T11:30:00Z"' findings

run_case "multiple review requests for one head" \
  '.issueComments += [{"id":102,"created_at":"2026-08-20T10:30:00Z","updated_at":"2026-08-20T10:30:00Z","user":{"login":"henry"},"body":"@codex review"}]' clean

# The default branch advancing under the PR does not unmake a verdict.
run_case "base advancing without head mutation" \
  '.pr.baseSha = "3333333333333333333333333333333333333333"' clean

# A base retarget invalidates verdicts made against the old diff.
run_case "base retargeted after the clean verdict" \
  '.pr.baseRetargetedAt = "2026-08-20T11:00:00Z" | del(.reviews[0])' waiting

# Publication time is not proof of reviewed base: a verdict arriving after
# the retarget from an in-flight old-base review must not count. Only a
# verdict preceded by a review request posted after the retarget does.
run_case "verdict after retarget without a fresh request is not acceptable" \
  '.pr.baseRetargetedAt = "2026-08-20T10:10:00Z" | del(.reviews[0])' waiting

run_case "fresh request after retarget re-arms later verdicts" \
  '.pr.baseRetargetedAt = "2026-08-20T10:10:00Z" | del(.reviews[0])
   | .issueComments += [{"id":104,"created_at":"2026-08-20T10:15:00Z","updated_at":"2026-08-20T10:15:00Z","user":{"login":"henry"},"body":"@codex review"}]' clean

run_case "fresh request does not re-arm a verdict that precedes it" \
  '.pr.baseRetargetedAt = "2026-08-20T10:10:00Z" | del(.reviews[0])
   | .issueComments += [{"id":104,"created_at":"2026-08-20T10:45:00Z","updated_at":"2026-08-20T10:45:00Z","user":{"login":"henry"},"body":"@codex review"}]' waiting

# Absent retarget evidence is not proof that no retarget occurred.
run_case "missing base-retarget evidence fails closed" \
  'del(.pr.baseRetargetedAt)' invalid "base-retarget evidence"

run_case "malformed base-retarget evidence fails closed" \
  '.pr.baseRetargetedAt = "yesterday"' invalid "base-retarget evidence"

# The retarget cutoff must not silence evidence whose order cannot be proven.
run_case "retarget cannot drop a malformed event before the fail-closed check" \
  '.pr.baseRetargetedAt = "2026-08-20T10:30:00Z" | del(.reviews[0].submitted_at)' \
  invalid "malformed timestamps"

# Merge-group evaluation reads the same document; the workflow never waits
# there, so the open states below must be conclusion=failure (asserted by
# run_case for every non-clean verdict above).

# --- Adapter exclusions ---

run_case "mutable dashboard comment is never evidence" \
  'del(.reviews[0]) | .issueComments[1].body = "<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| 📝 Code Review | Completed | `1111111` |"' \
  waiting

run_case "quota notice is provisional, never evidence" \
  'del(.reviews[0]) | .issueComments[1].body = "Security review usage limit reached. **Reviewed commit:** `1111111`"' \
  waiting

run_case "trusted comment binding the head without a recognized verdict fails closed" \
  'del(.reviews[0]) | .issueComments[1].body = "Something unrecognized.\n\n**Reviewed commit:** `1111111`"' \
  invalid "not a recognized verdict"

run_case "simultaneous conflicting verdicts fail closed" \
  '.reviews[0].submitted_at = "2026-08-20T10:40:00Z"' invalid "simultaneous and conflicting"

run_case "untrusted clean result is not evidence" \
  'del(.reviews[0]) | .issueComments[1].user.login = "impostor"' waiting

# A prefix alone is a candidate, never a binding: the workflow must resolve
# it, and a resolution naming another commit is a stale prefix collision.
run_case "abbreviated clean without workflow resolution fails closed" \
  'del(.reviews[0]) | del(.issueComments[1].resolved_review_sha)' invalid "did not resolve"

run_case "abbreviated clean resolving to another commit is stale" \
  "del(.reviews[0]) | .issueComments[1].resolved_review_sha = \"$OLD_SHA\"" waiting

# Every event sharing the latest timestamp must agree, not just the last two.
run_case "simultaneous findings among tied clean results fails closed" \
  '.reviews[0].submitted_at = "2026-08-20T10:40:00Z"
   | .issueComments += [{"id":103,"created_at":"2026-08-20T10:40:00Z","updated_at":"2026-08-20T10:40:00Z","user":{"login":"chatgpt-codex-connector"},"body":"Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `1111111`","resolved_review_sha":"1111111111111111111111111111111111111111"}]' \
  invalid "simultaneous and conflicting"

# Evidence whose order or edit state cannot be proven poisons the evaluation.
run_case "clean result with a missing timestamp fails closed" \
  'del(.reviews[0]) | del(.issueComments[1].updated_at)' invalid "malformed timestamps"

run_case "findings review with a missing timestamp fails closed" \
  'del(.reviews[0].submitted_at)' invalid "malformed timestamps"

run_case "clean result whose update precedes its creation fails closed" \
  'del(.reviews[0])
   | .issueComments[1].created_at = "2026-08-20T10:40:00Z"
   | .issueComments[1].updated_at = "2026-08-20T10:39:00Z"' \
  invalid "malformed timestamps"

# Shape alone is not validity: an impossible instant must fail closed too.
run_case "clean result with an impossible timestamp fails closed" \
  'del(.reviews[0])
   | .issueComments[1].created_at = "2026-99-99T99:99:99Z"
   | .issueComments[1].updated_at = "2026-99-99T99:99:99Z"' \
  invalid "malformed timestamps"

run_case "impossible base-retarget instant fails closed" \
  '.pr.baseRetargetedAt = "2026-99-99T99:99:99Z"' invalid "base-retarget evidence"

run_case "full-length reviewed commit binds" \
  '.issueComments[1].body = "Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `'"$HEAD_SHA"'`"' clean

# --- Invariants: incomplete or out-of-contract input fails closed ---

run_case "unsupported contract version" '.gateBehaviorContractVersion = 4' invalid "contract version"
run_case "incomplete evidence collection" '.complete = false' invalid "incomplete"
run_case "missing issue-comment evidence" 'del(.issueComments)' invalid "issue-comment evidence is missing"
run_case "missing review evidence" '.reviews = "not-an-array"' invalid "review evidence is missing"
run_case "closed pull request" '.pr.state = "closed"' invalid "not open"
run_case "invalid head SHA" '.pr.headSha = "abc123"' invalid "head SHA"
run_case "empty trusted allowlist" '.trustedAuthors = []' invalid "allowlist is empty"
run_case "head shared with another open pull request" '.pr.openHeadPulls = [42, 43]' invalid "uniquely scoped"

# --- Workflow state mapping ---

check_state() {
  local label="$1" filter="$2" expected="$3" got
  got="$(jq "$filter" "$TMP_DIR/base.json" | jq -f "$EVALUATOR" | jq -r .state)"
  [ "$got" = "$expected" ] || {
    fail "$label: expected state $expected, got $got"
    return
  }
  ok "$label"
}
check_state "clean maps to success" '.' success
check_state "findings maps to waiting-review" 'del(.issueComments[1])' waiting-review
check_state "no evidence with a request maps to waiting-review" 'del(.issueComments[1]) | del(.reviews[0])' waiting-review
check_state "no evidence and no request maps to waiting-request" 'del(.issueComments[1]) | del(.reviews[0]) | .issueComments[0].body = "opening note"' waiting-request
check_state "invalid maps to failure" '.issueComments[1].updated_at = "2026-08-20T10:45:00Z"' failure

if [ "$ERRORS" -gt 0 ]; then
  echo "test-review-gate-v3: $ERRORS failure(s)" >&2
  exit 1
fi
echo "test-review-gate-v3: all cases passed"
