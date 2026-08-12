#!/usr/bin/env bash
#
# tests/test-review-binding-workflow.sh — static guardrails for the
# review-binding check-run workflow (.github/workflows/review-binding.yml,
# issue #726).
#
# WHAT THIS FILE IS, PLAINLY: static structural assertions over the workflow
# TEXT — greps plus awk passes over the YAML — plus parity tests for the
# PURE fragments the workflow marks for extraction between
# ">>> parity-tested:" fences (parse_trusted_review_authors,
# record_untrusted_creator, the untrusted_review_authors pair, the
# evidence_row_filters jq constants, and the reviews_channel_loop), which
# are extracted verbatim from the workflow text and executed against
# fixtures — the parser with lib/toml.sh itself as the oracle, the row
# filters with real jq. The last two sections additionally render the
# failure summary from the workflow's own verbatim coords/footer/summary
# lines to assert what the operator actually reads. Nothing here executes
# the workflow's API-driven bash, stubs its gh calls, or simulates GitHub
# events; the workflow's dynamic behavior — check-run publication and
# verdict correctness — is proven by its live runs in CI on real PRs, not
# by anything in this file.
#
# The workflow publishes the "review-binding" check-run that will eventually
# gate merges, so its safety properties are load-bearing:
#   - it must execute no PR-controlled code: no checkout, no third-party
#     actions at all, and no pull_request_target trigger;
#   - the trusted-author allowlist may never come from PR-controlled files:
#     the fallback default lives in the workflow env, and the live list is
#     read from the review config at the PR's current BASE oid with
#     lib/toml.sh-equivalent parsing (a divergent parser silently changes
#     the authorization policy);
#   - intent statuses must be creator-validated (statuses:write alone must
#     not bind a base) and evidence removal must re-evaluate — including
#     removal followed by an inspection failure, which is why a pending run
#     must neutralize the previous verdict before inspection begins;
#   - it must hold checks:write, and the only check-run named
#     "review-binding" must be the one it POSTs — a job or step of the same
#     name would publish a second, always-green run racing for what branch
#     protection reads;
#   - it must reference no secret beyond the built-in GITHUB_TOKEN.
#
# All grep assertions scan the workflow with comment lines stripped: the
# header prose explains the hazards and therefore necessarily names them.
# Scanning comments too would force the file to stop documenting its own
# threat model.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$TOUCHSTONE_ROOT/.github/workflows/review-binding.yml"

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}
ok() {
  printf '  OK: %s\n' "$*"
}

if [ ! -f "$WORKFLOW" ]; then
  echo "FAIL: workflow not found: $WORKFLOW" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Strip comment-only lines (YAML comments and the bash comments inside the
# run block) before scanning for dangerous strings.
STRIPPED="$(grep -v -E '^[[:space:]]*#' "$WORKFLOW")"
# All assertions grep a FILE, not a `printf | grep -q` pipeline: grep -q exits
# on first match, the producer takes SIGPIPE on a ~30 KB payload, and pipefail
# turns a FOUND marker into a reported failure — a scheduling-dependent flake
# on macOS (PR #753 review, round 9).
STRIPPED_FILE="$TMP_DIR/stripped-workflow.txt"
printf '%s\n' "$STRIPPED" >"$STRIPPED_FILE"

echo "==> No PR-controlled code can execute"
if grep -q -E '(^|[[:space:]])uses:' "$STRIPPED_FILE"; then
  fail "workflow must run zero actions (no 'uses:' steps — not even checkout)"
else
  ok "no 'uses:' steps: nothing is checked out, no third-party actions run"
fi
if grep -q 'pull_request_target' "$STRIPPED_FILE"; then
  fail "workflow must not trigger on pull_request_target"
else
  ok "no pull_request_target trigger"
fi

# `opened` is load-bearing for the shared-head guard: an already-green commit
# opened as a SECOND PR inherits the first PR's commit-level check unless the
# opened event re-evaluates it (PR #753 review, round 5). Mutation: removing
# `opened` from the types list must fail here.
if grep -qE 'types:[[:space:]]*\[opened,' "$STRIPPED_FILE"; then
  ok "pull_request trigger covers opened (shared-head guard reachable on sibling creation)"
else
  fail "pull_request types must include opened — without it a sibling PR at a green commit inherits the check"
fi

# One PR's evaluation failure must not strand the rest of a sweep with stale
# verdicts (set -e aborts the loop otherwise).
if grep -q 'sweep_failures' "$STRIPPED_FILE"; then
  ok "sweep isolates per-PR evaluation failures and fails the run afterward"
else
  fail "the base-push sweep must isolate per-PR failures — an early API error strands later heads on stale verdicts"
fi

# The isolation must not suppress errexit inside the evaluation: bash ignores
# set -e (including re-enables) throughout any if/||-tested context, so
# `if ! evaluate_pr` lets inner API failures fall through to a successful
# return. The run_isolated helper runs the subshell OUTSIDE any tested
# context (PR #753 review, round 6).
if grep -q 'run_isolated()' "$STRIPPED_FILE"; then
  ok "errexit-preserving isolation helper present"
else
  fail "isolation must preserve errexit (run_isolated); a tested-context call suppresses set -e inside evaluate_pr"
fi
if grep -qE 'if ! (evaluate_pr|publish_sweep_overflow)' "$STRIPPED_FILE"; then
  fail "evaluate_pr/publish_sweep_overflow must never be invoked in a tested context — that suppresses errexit through the whole function"
else
  ok "no tested-context invocations of the fallible sweep functions"
fi

# Sweep/status paths know the affected SHA before any fallible call; the
# previous verdict at that SHA must be neutralized FIRST, or a coordinate
# lookup failure leaves a stale green standing (PR #753 review, round 7).
if grep -q 'known_sha' "$STRIPPED_FILE" \
  && grep -q 'evaluate_pr "\$pr" "\$sweep_head"' "$STRIPPED_FILE" \
  && grep -q 'evaluate_pr "\$pr" "\$status_sha"' "$STRIPPED_FILE"; then
  ok "known-SHA callers neutralize the prior verdict before coordinate lookup"
else
  fail "sweep/status paths must pass their known SHA so pending publishes before the fallible PR lookup"
fi
# The status path must neutralize BEFORE its own discovery lookup too — the
# commits/<sha>/pulls call is fallible and precedes evaluate_pr entirely
# (PR #753 review, round 10). Assert the pending POST sits between the
# status_sha assignment and the pulls discovery, by file order.
if awk '/status_sha="\$\{STATUS_SHA/{a=NR} /check-runs/{if (a && !b) b=NR} /commits\/\$status_sha\/pulls/{c=NR} END{exit !(a && b && c && a<b && b<c)}' "$STRIPPED_FILE"; then
  ok "status path posts pending on STATUS_SHA before PR discovery"
else
  fail "the status fan-out must neutralize the prior verdict before its fallible discovery lookup"
fi
if grep -q 'PR_EVENT_HEAD_SHA' "$STRIPPED_FILE" \
  && grep -q 'evaluate_pr "\$PR_NUMBER" "\${PR_EVENT_HEAD_SHA:-}"' "$STRIPPED_FILE"; then
  ok "pull_request events pass the payload head — the known-SHA enumeration is closed by construction"
else
  fail "the generic path must pass the pull_request payload head as known_sha (retarget with unchanged head)"
fi

echo "==> Trusted-author allowlist is never PR-controlled"
if grep -q -F 'chatgpt-codex-connector,chatgpt-codex-connector[bot]' "$STRIPPED_FILE"; then
  ok "fallback allowlist hardcoded in env (merge-pr.sh's built-in default)"
else
  fail "fallback allowlist 'chatgpt-codex-connector,chatgpt-codex-connector[bot]' missing from workflow env"
fi
if grep -q -F '.touchstone-review.toml' "$STRIPPED_FILE"; then
  ok "live allowlist read from the review config at the PR's base oid (merge-pr.sh parity)"
else
  fail "workflow must load trusted_review_authors from .touchstone-review.toml at the PR's current base oid"
fi

echo "==> Permissions"
if grep -q -E '^[[:space:]]*checks:[[:space:]]*write$' "$STRIPPED_FILE"; then
  ok "checks: write present"
else
  fail "permissions must include 'checks: write' to publish the check-run"
fi

echo "==> Check-run identity"
if [ "$(grep -c -E '^name: review-binding$' "$STRIPPED_FILE")" -eq 1 ]; then
  ok "workflow is named review-binding"
else
  fail "expected exactly one top-level 'name: review-binding'"
fi
if grep -q -F -- '-f name=review-binding' "$STRIPPED_FILE"; then
  ok "POSTs a check-run named review-binding"
else
  fail "workflow must POST a check-run with '-f name=review-binding'"
fi
# GitHub names a job's own check-run after its name: property when present
# and after its KEY otherwise — so BOTH surfaces must be asserted. An earlier
# version of this check grepped only '^[[:space:]]+name: review-binding$';
# the mutation "rename the evaluate job key to review-binding" passed it,
# which is why the jobs: block is now parsed structurally instead of shape-
# matched. The key check is deliberately stricter than the naming rule needs
# (a review-binding KEY shadowed by a different name: property would be
# harmless today) because one deleted line must never be the only thing
# between a job's always-green check-run and branch protection.
JOB_KEYS="$(awk '
  /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
  /^[^[:space:]]/ { in_jobs = 0 }
  in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    key = $1
    sub(/:$/, "", key)
    print key
  }
' "$WORKFLOW")"
if [ -z "$JOB_KEYS" ]; then
  fail "could not parse any job keys out of the jobs: block (parser guard — a vacuous pass is a fail)"
else
  ok "job keys parsed structurally: $(printf '%s' "$JOB_KEYS" | tr '\n' ' ')"
fi
if printf '%s\n' "$JOB_KEYS" | grep -q -F -x 'review-binding'; then
  fail "no job KEY may be review-binding — the job's own check-run would race the published verdict"
else
  ok "no job key named review-binding"
fi
if grep -q -E '^[[:space:]]+name: review-binding$' "$STRIPPED_FILE"; then
  fail "no job or step name: property may be review-binding — its own check-run would race the published verdict"
else
  ok "no job/step name: property review-binding (published verdict is the only run of that name)"
fi

echo "==> Binding evidence sources"
if grep -q -E 'touchstone/review-request-intent($|[^A-Za-z0-9-])' "$STRIPPED_FILE"; then
  ok "reads the touchstone/review-request-intent base binding"
else
  fail "workflow must read the 'touchstone/review-request-intent' commit status for base binding"
fi
if grep -q -E 'touchstone/review-request-complete($|[^A-Za-z0-9-])' "$STRIPPED_FILE"; then
  ok "reads the touchstone/review-request-complete trigger record (merge-pr.sh parity)"
else
  fail "workflow must read the 'touchstone/review-request-complete' status: an intent-anchored freshness bar accepts in-flight reviews of the previous base"
fi
if grep -q -F 'collaborators/$login/permission' "$STRIPPED_FILE"; then
  ok "intent-status creators resolved to collaborator permission (statuses:write alone cannot bind)"
else
  fail "workflow must resolve each intent-status creator via collaborators/<login>/permission (merge-pr.sh parity)"
fi
if grep -q -F 'commits/$head_sha/pulls' "$STRIPPED_FILE"; then
  ok "shared-head guard present (a head serving multiple open PRs fails closed)"
else
  fail "workflow must detect a head shared by multiple open PRs via commits/<sha>/pulls and fail closed"
fi
if grep -q -F 'Reviewed commit:' "$STRIPPED_FILE"; then
  ok "accepts the trusted result-comment channel (parity with merge-pr.sh)"
else
  fail "workflow must accept the trusted 'Reviewed commit:' comment channel merge-pr.sh accepts"
fi
if grep -q -F 'earliest_matching_trigger_at' "$STRIPPED_FILE"; then
  ok "freshness anchored to the earliest completed request's trigger timestamp"
else
  fail "workflow must anchor evidence freshness to the earliest completed request's trigger (earliest_matching_trigger_at) — the intent timestamp accepts a review already in flight for the previous base"
fi

echo "==> Publication discipline"
if grep -q -F -- '-f status=in_progress' "$STRIPPED_FILE"; then
  ok "pending run posted before fallible inspection (a mid-inspection death cannot leave a stale success standing)"
else
  fail "workflow must POST an in_progress review-binding run before fallible inspection so an inspection failure invalidates the prior verdict"
fi
if grep -q -F -- '-X PATCH "repos/$REPO/check-runs/$run_id"' "$STRIPPED_FILE"; then
  ok "verdict completes the pending run in place (PATCH to completed)"
else
  fail "workflow must PATCH its pending check-run to completed with the verdict"
fi
if grep -q -F 'live_head' "$STRIPPED_FILE"; then
  ok "publish-time revalidation present (stale coordinates never publish a verdict)"
else
  fail "workflow must re-read live head/base before publishing so a stale evaluation cannot overwrite a newer verdict"
fi
if grep -q -F 'publish_sweep_overflow' "$STRIPPED_FILE"; then
  ok "sweep overflow fails closed (no PR past the cap keeps a stale verdict)"
else
  fail "PRs past MAX_BASE_SWEEP_PRS must get an explicit fail-closed check-run (publish_sweep_overflow)"
fi
# The overflow helper must revalidate live PR coordinates before publishing:
# a PR retargeted or advanced during the sweep already got a correct verdict
# from its own PR-scoped event, and a stale overflow failure would bury it.
# Extracted structurally (function start to its closing brace) so the
# assertion cannot pass on a mention elsewhere in the file.
OVERFLOW_BODY="$(awk '
  /^          publish_sweep_overflow\(\) \{/ { grab = 1 }
  grab { print }
  grab && /^          \}$/ { exit }
' "$WORKFLOW")"
if [ -z "$OVERFLOW_BODY" ]; then
  fail "could not extract publish_sweep_overflow() from the workflow (extraction guard — a vacuous pass is a fail)"
elif printf '%s\n' "$OVERFLOW_BODY" | grep -q -F 'pulls/$pr_number'; then
  ok "sweep-overflow revalidates live PR coordinates before publishing its fail-closed verdict"
else
  fail "publish_sweep_overflow must re-read the PR (pulls/<n>) and confirm it is still open at the listed head and pushed base before posting"
fi

# Discovery is the one fallible call preceding ANY per-head invalidation in
# the base-push sweep: a transient failure there would leave every pre-push
# green merge-eligible on a stale base OID with no pending run posted
# (PR #753 review, round 11). It must be retried, not single-shot.
if grep -q -F 'discovery_attempt' "$STRIPPED_FILE"; then
  ok "base-push PR discovery retries transient failures before giving up"
else
  fail "the sweep's open-PR discovery call must retry (discovery_attempt loop) — a single-shot failure preserves every stale green"
fi

echo "==> Triggers"
if grep -q -E '^[[:space:]]*pull_request_review:' "$STRIPPED_FILE"; then
  ok "pull_request_review trigger present"
else
  fail "workflow must trigger on pull_request_review (formal review submission fires no issue_comment)"
fi
if grep -q -E '^[[:space:]]*push:' "$STRIPPED_FILE"; then
  ok "push trigger present"
else
  fail "workflow must trigger on push (base-branch advance stales bindings with no PR-scoped event)"
fi
if grep -q -F 'MAX_BASE_SWEEP_PRS' "$STRIPPED_FILE"; then
  ok "push fan-out bounded by MAX_BASE_SWEEP_PRS"
else
  fail "the push fan-out must be bounded by a named MAX_BASE_SWEEP_PRS cap"
fi
if grep -q -E '^[[:space:]]*status:[[:space:]]*$' "$STRIPPED_FILE"; then
  ok "status trigger present (review-request status writes re-evaluate the head)"
else
  fail "workflow must trigger on status — adding a review-request status fires no PR-scoped event, leaving a prior green standing"
fi
if grep -q -E '^[[:space:]]*issue_comment:' "$STRIPPED_FILE"; then
  ok "issue_comment trigger present"
else
  fail "workflow must trigger on issue_comment (review completion is signalled by a PR comment)"
fi
if grep -A1 -E '^[[:space:]]*issue_comment:' "$STRIPPED_FILE" | grep -q -E 'types:.*created.*edited.*deleted'; then
  ok "issue_comment covers created, edited, and deleted (evidence removal re-evaluates fail-closed)"
else
  fail "issue_comment types must include created, edited, and deleted — deleting/editing a result comment removes evidence and must re-evaluate"
fi
if grep -q -E '^[[:space:]]*pull_request:' "$STRIPPED_FILE"; then
  ok "pull_request trigger present"
else
  fail "workflow must trigger on pull_request (synchronize makes every new head start red)"
fi
if grep -q 'synchronize' "$STRIPPED_FILE"; then
  ok "synchronize event covered"
else
  fail "pull_request types must include synchronize"
fi

echo "==> Secrets discipline"
OTHER_SECRETS="$(printf '%s\n' "$STRIPPED" \
  | grep -o -E 'secrets\.[A-Za-z_][A-Za-z0-9_]*' | sort -u \
  | grep -v -F -x 'secrets.GITHUB_TOKEN' || true)"
if [ -n "$OTHER_SECRETS" ]; then
  fail "workflow references secrets beyond GITHUB_TOKEN: $OTHER_SECRETS"
else
  ok "no secret referenced beyond the built-in GITHUB_TOKEN"
fi

# ---------------------------------------------------------------------------
# Extracted-function parity: the workflow marks its PURE fragments with
# ">>> parity-tested:" / "<<< parity-tested:" comment fences. They are
# extracted verbatim (so what runs here is byte-identical to what runs in
# CI) and executed against fixtures. The allowlist parser is proven against
# lib/toml.sh — the canonical parser merge-pr.sh uses — because a divergent
# parser silently changes the authorization policy: a single-quoted array
# a collaborator legitimately wrote would block every review, and quoted
# text in an inline comment would join the allowlist.
# ---------------------------------------------------------------------------
echo "==> Extracted-function parity"

extract_marked() {
  awk -v start="$1" -v stop="$2" '
    index($0, start) { grab = 1; next }
    index($0, stop) { grab = 0 }
    grab { print }
  ' "$WORKFLOW"
}

PARSER_SNIPPET="$(extract_marked '>>> parity-tested: parse_trusted_review_authors' '<<< parity-tested: parse_trusted_review_authors')"
if [ -z "$PARSER_SNIPPET" ] || ! printf '%s\n' "$PARSER_SNIPPET" | grep -q 'parse_trusted_review_authors()'; then
  fail "could not extract parse_trusted_review_authors between its parity markers (extraction guard — a vacuous pass is a fail)"
elif [ ! -f "$TOUCHSTONE_ROOT/lib/toml.sh" ]; then
  fail "lib/toml.sh not found; cannot prove allowlist-parser parity"
else
  printf '%s\n' "$PARSER_SNIPPET" >"$TMP_DIR/parser.sh"
  # shellcheck source=/dev/null
  . "$TMP_DIR/parser.sh"
  # shellcheck source=/dev/null
  . "$TOUCHSTONE_ROOT/lib/toml.sh"

  ORACLE_FOUND=0
  ORACLE_VALUE=""
  oracle_callback() {
    if [ "$1" = "review.pr_triggered" ] && [ "$2" = "trusted_review_authors" ]; then
      ORACLE_VALUE="$(toml_normalize_array "$3")"
      ORACLE_FOUND=1
    fi
  }

  parity_case() {
    local label="$1" fixture="$2" parser_out parser_status=0
    ORACLE_FOUND=0
    ORACLE_VALUE=""
    toml_parse "$fixture" oracle_callback
    parser_out="$(parse_trusted_review_authors <"$fixture")" || parser_status=$?
    if [ "$ORACLE_FOUND" -eq 0 ]; then
      if [ "$parser_status" -eq 3 ]; then
        ok "parity ($label): both parsers report the key absent"
      else
        fail "parity ($label): lib/toml.sh reports the key absent but the workflow parser exited $parser_status with output '$parser_out'"
      fi
      return 0
    fi
    if [ "$parser_status" -ne 0 ]; then
      fail "parity ($label): workflow parser exited $parser_status where lib/toml.sh found '$ORACLE_VALUE'"
      return 0
    fi
    if [ "$parser_out" = "$ORACLE_VALUE" ]; then
      ok "parity ($label): '$parser_out'"
    else
      fail "parity ($label): workflow parser -> '$parser_out', lib/toml.sh -> '$ORACLE_VALUE'"
    fi
  }

  cat >"$TMP_DIR/f-double.toml" <<'EOF'
[review]
preflight_required = true

[review.pr_triggered]
provider = "github-codex"
trusted_review_authors = ["alice", "bob[bot]"]
timeout_sec = 5
EOF
  parity_case "double-quoted array" "$TMP_DIR/f-double.toml"

  cat >"$TMP_DIR/f-single.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = ['custom-reviewer']
EOF
  parity_case "single-quoted array" "$TMP_DIR/f-single.toml"

  cat >"$TMP_DIR/f-comment.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = ["alice"] # later maybe add "mallory"
EOF
  parity_case "inline comment with quoted text" "$TMP_DIR/f-comment.toml"

  cat >"$TMP_DIR/f-multiline.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = [
  "alice", # primary
  'bob', # comment with "quotes"
]
EOF
  parity_case "multiline array with per-line comments" "$TMP_DIR/f-multiline.toml"

  cat >"$TMP_DIR/f-hash.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = ["a#b", "c"]
EOF
  parity_case "hash inside a quoted item" "$TMP_DIR/f-hash.toml"

  cat >"$TMP_DIR/f-bare.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = [alice, bob]
EOF
  parity_case "bare (unquoted) items" "$TMP_DIR/f-bare.toml"

  cat >"$TMP_DIR/f-empty.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = []
EOF
  parity_case "empty array (trusts nobody)" "$TMP_DIR/f-empty.toml"

  cat >"$TMP_DIR/f-lastwins.toml" <<'EOF'
[review.pr_triggered]
trusted_review_authors = ["first"]
trusted_review_authors = ["second"]
EOF
  parity_case "duplicate key (last wins)" "$TMP_DIR/f-lastwins.toml"

  cat >"$TMP_DIR/f-absent.toml" <<'EOF'
[review]
preflight_required = true
EOF
  parity_case "key absent (default retained)" "$TMP_DIR/f-absent.toml"

  cat >"$TMP_DIR/f-wrongsection.toml" <<'EOF'
[review]
trusted_review_authors = ["nope"]
EOF
  parity_case "key in the wrong section" "$TMP_DIR/f-wrongsection.toml"
fi

RECORDER_SNIPPET="$(extract_marked '>>> parity-tested: record_untrusted_creator' '<<< parity-tested: record_untrusted_creator')"
if [ -z "$RECORDER_SNIPPET" ] || ! printf '%s\n' "$RECORDER_SNIPPET" | grep -q 'record_untrusted_creator()'; then
  fail "could not extract record_untrusted_creator between its parity markers (extraction guard — a vacuous pass is a fail)"
else
  printf '%s\n' "$RECORDER_SNIPPET" >"$TMP_DIR/recorder.sh"
  # shellcheck source=/dev/null
  . "$TMP_DIR/recorder.sh"
  untrusted_request_creators=""
  record_untrusted_creator ""
  if [ "$untrusted_request_creators" = "<unknown>" ]; then
    ok "first empty-login creator recorded as <unknown> (regression: raw ',,' dedup silently dropped it)"
  else
    fail "the FIRST empty-login creator must be recorded as <unknown>; got '$untrusted_request_creators' — normalization must precede deduplication"
  fi
  record_untrusted_creator ""
  record_untrusted_creator "mallory"
  record_untrusted_creator "mallory"
  record_untrusted_creator ""
  if [ "$untrusted_request_creators" = "<unknown>,mallory" ]; then
    ok "labels deduplicate after normalization: '$untrusted_request_creators'"
  else
    fail "expected '<unknown>,mallory' after repeated records; got '$untrusted_request_creators'"
  fi
fi

# ---------------------------------------------------------------------------
# Regression, issue #804: the untrusted-review failure must name the authors
# of the reviews FOUND at this head, never the trusted allowlist. Observed on
# PR #802: three reviews by `henrymodisett` were reported as
# "3 review(s) not on the allowlist: chatgpt-codex-connector,..." — the
# allowlist, printed again two lines down as `trusted authors:`. That tells
# the operator the trusted reviewer was rejected as untrusted and invites
# them to allowlist an author already on the list, pointing away from the
# real cause ("this head has not been reviewed yet").
#
# The assertion is ANCHORED to the untrusted clause, not to the summary: the
# allowlist legitimately appears in the summary's coordinates block, so a
# bare "summary must not contain chatgpt-codex-connector" would be false and
# a bare "summary must contain henrymodisett" would be satisfiable by text
# that is not the clause. The allowlist-hit count below is the standing
# proof that the anchoring is load-bearing rather than decorative.
# ---------------------------------------------------------------------------
echo "==> Untrusted-review failure names the authors found, not the allowlist (#804)"

UNTRUSTED_SNIPPET="$(extract_marked '>>> parity-tested: untrusted_review_authors' '<<< parity-tested: untrusted_review_authors')"
ADD_REASON_BODY="$(awk '
  /^          add_reason\(\) \{/ { grab = 1 }
  grab { print }
  grab && /^          \}$/ { exit }
' "$WORKFLOW")"
COORDS_LINE="$(grep -F 'coords=$' "$WORKFLOW" || true)"
FOOTER_LINE="$(grep -F 'footer=$' "$WORKFLOW" || true)"
SUMMARY_LINE="$(grep -F 'summary="This head+base pair' "$WORKFLOW" || true)"

RENDER_EXTRACTION_OK=true
# Extraction guards: every piece below is lifted verbatim out of the
# workflow, so a missing or ambiguous match must fail loudly rather than
# render a summary CI would never produce.
require_extract() {
  local label="$1" value="$2" want_lines="$3" got
  if [ -z "$value" ]; then
    fail "could not extract the $label from the workflow (extraction guard — a vacuous pass is a fail)"
    RENDER_EXTRACTION_OK=false
    return 0
  fi
  if [ "$want_lines" = "any" ]; then
    return 0
  fi
  printf '%s\n' "$value" >"$TMP_DIR/extract-lines.txt"
  got="$(wc -l <"$TMP_DIR/extract-lines.txt" | tr -d ' ')"
  if [ "$got" -ne "$want_lines" ]; then
    fail "the $label extraction matched $got workflow lines, expected $want_lines — the assembled summary would not be what CI renders"
    RENDER_EXTRACTION_OK=false
  fi
}
require_extract "untrusted_review_authors fence" "$UNTRUSTED_SNIPPET" any
require_extract "add_reason body" "$ADD_REASON_BODY" any
require_extract "coords line" "$COORDS_LINE" 1
require_extract "footer line" "$FOOTER_LINE" 1
require_extract "failure summary line" "$SUMMARY_LINE" 1
if [ "$RENDER_EXTRACTION_OK" = true ]; then
  printf '%s\n' "$UNTRUSTED_SNIPPET" >"$TMP_DIR/fence-check.txt"
  if ! grep -q 'untrusted_review_authors_reason()' "$TMP_DIR/fence-check.txt"; then
    fail "the untrusted_review_authors fence must define untrusted_review_authors_reason() (extraction guard — a vacuous pass is a fail)"
    RENDER_EXTRACTION_OK=false
  fi
fi

if [ "$RENDER_EXTRACTION_OK" = true ]; then
  printf '%s\n%s\n' "$UNTRUSTED_SNIPPET" "$ADD_REASON_BODY" >"$TMP_DIR/untrusted.sh"
  # shellcheck source=/dev/null
  . "$TMP_DIR/untrusted.sh"

  # Three reviews, one distinct author — PR #802's exact shape.
  untrusted_review_authors=""
  record_untrusted_review_author "henrymodisett"
  record_untrusted_review_author "henrymodisett"
  record_untrusted_review_author "henrymodisett"
  if [ "$untrusted_review_authors" = "henrymodisett" ]; then
    ok "distinct authors deduplicate across repeated reviews: '$untrusted_review_authors'"
  else
    fail "expected 'henrymodisett' after three reviews by the same author; got '$untrusted_review_authors'"
  fi
  record_untrusted_review_author ""
  if [ "$untrusted_review_authors" = "henrymodisett,<unknown>" ]; then
    ok "an empty login normalizes to <unknown> before dedup"
  else
    fail "expected 'henrymodisett,<unknown>'; got '$untrusted_review_authors' — normalization must precede deduplication"
  fi

  # Assemble the failure summary exactly as evaluate_pr does, from the
  # workflow's own lines. The fixture variables below are read by those
  # sourced lines, not by this file, so shellcheck cannot see the use.
  # shellcheck disable=SC2034
  {
    head_sha="2258adf8b068d94ce873ff15c4563696f6a676e6"
    base_ref="main"
    base_oid="f7722cc9d0e1b2a3c4d5e6f708192a3b4c5d6e7f"
    TRUSTED_AUTHORS_EFFECTIVE="chatgpt-codex-connector,chatgpt-codex-connector[bot]"
    TRUSTED_AUTHORS_SOURCE="workflow default"
    untrusted_review_authors="henrymodisett"
    untrusted_reviews=3
    reasons=""
  }
  untrusted_reason="$(untrusted_review_authors_reason "$head_sha" "$untrusted_reviews" "$untrusted_review_authors")"
  add_reason "$untrusted_reason"
  printf '%s\n%s\n%s\n' "$COORDS_LINE" "$FOOTER_LINE" "$SUMMARY_LINE" >"$TMP_DIR/render.sh"
  # shellcheck source=/dev/null
  . "$TMP_DIR/render.sh"
  # $summary is assigned by the sourced workflow line above.
  # shellcheck disable=SC2154
  printf '%s\n' "$summary" >"$TMP_DIR/summary.txt"

  # ANCHOR: isolate the untrusted clause. Every content assertion below reads
  # this file, never the summary.
  grep -F 'is from untrusted author(s)' "$TMP_DIR/summary.txt" >"$TMP_DIR/untrusted-clause.txt" || true
  CLAUSE_LINES="$(wc -l <"$TMP_DIR/untrusted-clause.txt" | tr -d ' ')"
  if [ "$CLAUSE_LINES" -ne 1 ]; then
    fail "expected exactly one untrusted-author clause in the summary; found $CLAUSE_LINES (anchor guard — a vacuous pass is a fail)"
  else
    ok "untrusted clause isolated from the summary"
    if grep -q -F 'henrymodisett' "$TMP_DIR/untrusted-clause.txt"; then
      ok "the clause names the author of the reviews actually found"
    else
      fail "the untrusted-author clause must name the authors found at this head (expected 'henrymodisett'); got: $(cat "$TMP_DIR/untrusted-clause.txt")"
    fi
    if grep -q -F 'chatgpt-codex-connector' "$TMP_DIR/untrusted-clause.txt"; then
      fail "the untrusted-author clause names an ALLOWLISTED author (#804) — it is printing the trusted allowlist where it means the offending authors; got: $(cat "$TMP_DIR/untrusted-clause.txt")"
    else
      ok "the clause names no allowlisted author"
    fi
    if grep -q -F '3 review(s)' "$TMP_DIR/untrusted-clause.txt"; then
      ok "the clause keeps the review count"
    else
      fail "the untrusted-author clause must keep the review count ('3 review(s)'); got: $(cat "$TMP_DIR/untrusted-clause.txt")"
    fi
  fi

  # Standing proof that anchoring is required: the allowlist DOES appear in
  # the summary — once, in the coordinates block. If this ever reads 0 the
  # assertions above have gone vacuous (a naive assert_not_contains over the
  # whole summary would then pass for the wrong reason); if it reads 2 the
  # clause is echoing the allowlist again, which is the #804 defect.
  ALLOWLIST_HITS="$(grep -c -F 'chatgpt-codex-connector' "$TMP_DIR/summary.txt" || true)"
  if [ "$ALLOWLIST_HITS" -eq 1 ]; then
    ok "the allowlist appears exactly once in the summary (the 'trusted authors:' coordinate), so the clause assertion is anchored, not vacuous"
  else
    fail "expected the allowlist on exactly 1 summary line (the coordinates block); found $ALLOWLIST_HITS"
  fi
  if grep -q -F -- '- trusted authors: `chatgpt-codex-connector' "$TMP_DIR/summary.txt"; then
    ok "the coordinates block still echoes the trusted allowlist"
  else
    fail "the summary must still echo '- trusted authors:' in its coordinates block"
  fi
fi

# ---------------------------------------------------------------------------
# Regression, PR #808 review round 1: a formal review whose author ACCOUNT WAS
# DELETED (.user is null) must be counted and named <unknown>.
#
# Tab is IFS whitespace, so `read` collapses runs of tabs and drops leading
# ones. The old row filter emitted `(.user.login // "")` — an EMPTY leading
# field — so `IFS=$'\t' read -r author commit_oid review_state submitted_at`
# slid the commit oid into $author and the state into $commit_oid. The head
# comparison then dropped the row before record_untrusted_review_author ran,
# which made the <unknown> normalization added for #804 unreachable in
# production: the check reported "no trusted-author review evidence" for a
# head that had review evidence. Dropping a row can only REMOVE evidence, so
# the verdict stayed fail-closed — the defect is the MIS-STATED CAUSE, which
# is exactly what #804/#805 exist to fix.
#
# This runs real jq over the workflow's own hoisted filter and then feeds the
# result to the workflow's own verbatim loop, so it proves the jq->bash
# boundary end to end rather than asserting an exit code.
# ---------------------------------------------------------------------------
echo "==> A deleted-author review is counted and named <unknown> (PR #808 review, round 1)"

FILTERS_SNIPPET="$(extract_marked '>>> parity-tested: evidence_row_filters' '<<< parity-tested: evidence_row_filters')"
LOOP_SNIPPET="$(extract_marked '>>> parity-tested: reviews_channel_loop' '<<< parity-tested: reviews_channel_loop')"
TRUST_BODY="$(awk '
  /^          author_is_trusted\(\) \{/ { grab = 1 }
  grab { print }
  grab && /^          \}$/ { exit }
' "$WORKFLOW")"

NULL_AUTHOR_OK=true
# Extraction guard: a fence this test cannot find, or that no longer holds
# what it is named for, must FAIL — never pass vacuously.
guard_snippet() {
  local label="$1" value="$2" needle="$3"
  if [ -z "$value" ]; then
    fail "could not extract the $label from the workflow (extraction guard — a vacuous pass is a fail)"
    NULL_AUTHOR_OK=false
    return 0
  fi
  printf '%s\n' "$value" >"$TMP_DIR/guard-snippet.txt"
  if ! grep -q -F "$needle" "$TMP_DIR/guard-snippet.txt"; then
    fail "the $label extraction does not contain '$needle' (extraction guard — a vacuous pass is a fail)"
    NULL_AUTHOR_OK=false
  fi
}
guard_snippet "evidence_row_filters fence" "$FILTERS_SNIPPET" 'REVIEWS_ROW_JQ='
guard_snippet "evidence_row_filters fence" "$FILTERS_SNIPPET" 'COMMENTS_ROW_JQ='
guard_snippet "reviews_channel_loop fence" "$LOOP_SNIPPET" 'record_untrusted_review_author "$author"'
guard_snippet "author_is_trusted body" "$TRUST_BODY" 'author_is_trusted() {'
if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found; the row filters cannot be proven against real jq"
  NULL_AUTHOR_OK=false
fi

# Wiring guard: the hoisted filters are only meaningful if the gh calls
# actually use them. Without this, the fence could go stale as dead text
# while production kept an inline filter with the empty leading field.
if grep -q -F -- '--jq "$REVIEWS_ROW_JQ"' "$STRIPPED_FILE"; then
  ok "the reviews channel reads its rows through REVIEWS_ROW_JQ"
else
  fail "the reviews gh call must use \"\$REVIEWS_ROW_JQ\" — otherwise the parity-tested filter is dead text and production keeps its own"
fi
if grep -q -F -- '--jq "$COMMENTS_ROW_JQ"' "$STRIPPED_FILE"; then
  ok "the result-comment channel reads its rows through COMMENTS_ROW_JQ"
else
  fail "the comments gh call must use \"\$COMMENTS_ROW_JQ\" — otherwise the parity-tested filter is dead text and production keeps its own"
fi
# The old shape, byte-exact: `[(.user.login // ""),` opens the array with an
# unsentinelled login. The new filter wraps it (`[((.user.login // "") | if`),
# so this pattern matches the buggy form and nothing else.
if grep -q -F '[(.user.login // "")' "$STRIPPED_FILE"; then
  fail "an evidence row filter still opens with an unsentinelled '(.user.login // \"\")' — a null .user emits an empty leading TSV field and read shifts every field after it"
else
  ok "no evidence row filter opens with an unsentinelled login field"
fi

if [ "$NULL_AUTHOR_OK" = true ]; then
  printf '%s\n%s\n%s\n' "$FILTERS_SNIPPET" "$TRUST_BODY" "$UNTRUSTED_SNIPPET" \
    >"$TMP_DIR/null-author-defs.sh"
  # shellcheck source=/dev/null
  . "$TMP_DIR/null-author-defs.sh"
  printf '%s\n' "$LOOP_SNIPPET" >"$TMP_DIR/reviews-loop.sh"

  NULL_HEAD="2258adf8b068d94ce873ff15c4563696f6a676e6"
  cat >"$TMP_DIR/reviews-null-author.json" <<EOF
[
  {
    "user": null,
    "commit_id": "$NULL_HEAD",
    "state": "COMMENTED",
    "submitted_at": "2026-08-12T10:00:00Z"
  }
]
EOF
  # \$REVIEWS_ROW_JQ / \$COMMENTS_ROW_JQ are assigned by the sourced fence.
  # shellcheck disable=SC2154
  jq -r "$REVIEWS_ROW_JQ" "$TMP_DIR/reviews-null-author.json" \
    >"$TMP_DIR/reviews-null-author.tsv"

  # (1) Field alignment across the jq->bash boundary. This is the assertion
  # that fails on the old filter: with `// ""` the row begins with a tab,
  # read discards it, and $author holds the commit oid.
  NA_AUTHOR=""
  NA_COMMIT=""
  NA_STATE=""
  NA_TS=""
  IFS=$'\t' read -r NA_AUTHOR NA_COMMIT NA_STATE NA_TS \
    <"$TMP_DIR/reviews-null-author.tsv" || true
  if [ "$NA_AUTHOR" = "<unknown>" ] && [ "$NA_COMMIT" = "$NULL_HEAD" ] \
    && [ "$NA_STATE" = "COMMENTED" ] && [ "$NA_TS" = "2026-08-12T10:00:00Z" ]; then
    ok "a null .user row parses with its fields aligned: author='<unknown>', commit_oid=head"
  else
    fail "the reviews row filter must emit a NONEMPTY author field: a deleted account's null .user makes jq emit an empty leading field, which IFS=\$'\\t' read discards — shifting the commit oid into \$author. Parsed author='$NA_AUTHOR' commit_oid='$NA_COMMIT' state='$NA_STATE' submitted_at='$NA_TS' (expected '<unknown>' / '$NULL_HEAD' / 'COMMENTED' / '2026-08-12T10:00:00Z')"
  fi

  # (2) The workflow's own loop, verbatim, over that row: counted and named.
  # TRUSTED_AUTHORS_EFFECTIVE and reviews_tsv are the loop's INPUTS, read by
  # the sourced workflow lines below rather than by this file, so shellcheck
  # cannot see the use.
  # shellcheck disable=SC2034
  {
    head_sha="$NULL_HEAD"
    TRUSTED_AUTHORS_EFFECTIVE="chatgpt-codex-connector,chatgpt-codex-connector[bot]"
    evidence=""
    untrusted_reviews=0
    untrusted_review_authors=""
    reviews_tsv="$(cat "$TMP_DIR/reviews-null-author.tsv")"
  }
  # shellcheck source=/dev/null
  . "$TMP_DIR/reviews-loop.sh"
  if [ "$untrusted_reviews" -eq 1 ]; then
    ok "the deleted-author review at the head is COUNTED (untrusted_reviews=1)"
  else
    fail "a review at the head whose .user is null must be counted as untrusted evidence; untrusted_reviews=$untrusted_reviews — 0 means the field shift dropped the row at the head comparison and the check would report that no review evidence exists"
  fi
  if [ "$untrusted_review_authors" = "<unknown>" ]; then
    ok "the deleted-author review is NAMED (untrusted_review_authors='<unknown>')"
  else
    fail "expected untrusted_review_authors='<unknown>' for a deleted-account review; got '$untrusted_review_authors' — the <unknown> normalization must be reachable, not just present"
  fi
  if [ -z "$evidence" ]; then
    ok "a deleted-author review never enters the trusted evidence list"
  else
    fail "a null-author review must never count as trusted evidence; got '$evidence'"
  fi
  if author_is_trusted "<unknown>"; then
    fail "the <unknown> placeholder must never satisfy author_is_trusted — the sentinel would then launder a deleted account into trusted evidence"
  else
    ok "the <unknown> placeholder is not a trusted author"
  fi

  # (3) The operator-visible clause names <unknown>, anchored to the clause
  # (the allowlist legitimately appears in the coordinates block).
  if [ "$RENDER_EXTRACTION_OK" = true ]; then
    # Read by the sourced coords/summary workflow lines, not by this file.
    # shellcheck disable=SC2034
    {
      base_ref="main"
      base_oid="f7722cc9d0e1b2a3c4d5e6f708192a3b4c5d6e7f"
      TRUSTED_AUTHORS_SOURCE="workflow default"
      reasons=""
    }
    printf '%s\n' "$ADD_REASON_BODY" >"$TMP_DIR/null-author-reason.sh"
    # shellcheck source=/dev/null
    . "$TMP_DIR/null-author-reason.sh"
    add_reason "$(untrusted_review_authors_reason \
      "$head_sha" "$untrusted_reviews" "$untrusted_review_authors")"
    printf '%s\n%s\n%s\n' "$COORDS_LINE" "$FOOTER_LINE" "$SUMMARY_LINE" \
      >"$TMP_DIR/null-author-render.sh"
    # shellcheck source=/dev/null
    . "$TMP_DIR/null-author-render.sh"
    # $summary is assigned by the sourced workflow line above.
    # shellcheck disable=SC2154
    printf '%s\n' "$summary" >"$TMP_DIR/null-author-summary.txt"
    grep -F 'is from untrusted author(s)' "$TMP_DIR/null-author-summary.txt" \
      >"$TMP_DIR/null-author-clause.txt" || true
    NA_CLAUSE_LINES="$(wc -l <"$TMP_DIR/null-author-clause.txt" | tr -d ' ')"
    if [ "$NA_CLAUSE_LINES" -ne 1 ]; then
      fail "expected exactly one untrusted-author clause for the deleted-author case; found $NA_CLAUSE_LINES (anchor guard — a vacuous pass is a fail)"
    else
      # Count AND name in ONE assertion, deliberately: untrusted_review_authors_reason
      # renders `${authors:-<unknown>}`, so a clause reading "<unknown>" alone is
      # ALSO what the fallback prints for an EMPTY author list — i.e. for the very
      # bug this section exists to catch. Only "1 review(s) from `<unknown>`" is
      # unique to the intended path: the count proves the row survived the
      # jq->bash boundary, the name proves the normalization was reached.
      if grep -q -F '1 review(s) from `<unknown>`' "$TMP_DIR/null-author-clause.txt"; then
        ok "the clause counts the deleted-author review AND names it <unknown>"
      else
        fail "the untrusted-author clause must read '1 review(s) from \`<unknown>\`' — '0 review(s) from \`<unknown>\`' is the empty-list FALLBACK firing, not the row being recorded; got: $(cat "$TMP_DIR/null-author-clause.txt")"
      fi
      if grep -q -F 'chatgpt-codex-connector' "$TMP_DIR/null-author-clause.txt"; then
        fail "the clause names an allowlisted author instead of the observed one (#804); got: $(cat "$TMP_DIR/null-author-clause.txt")"
      else
        ok "the clause names no allowlisted author"
      fi
      # Standing proof that the clause anchor above is load-bearing: <unknown>
      # appears in the summary exactly once, inside the clause. A 0 would mean
      # the assertion went vacuous; a 2 would mean some other slot started
      # printing the placeholder and a whole-summary grep would pass wrongly.
      NA_UNKNOWN_HITS="$(grep -c -F '<unknown>' "$TMP_DIR/null-author-summary.txt" || true)"
      if [ "$NA_UNKNOWN_HITS" -eq 1 ]; then
        ok "<unknown> appears on exactly one summary line (the clause), so the clause assertion is anchored, not vacuous"
      else
        fail "expected '<unknown>' on exactly 1 summary line (the untrusted clause); found $NA_UNKNOWN_HITS"
      fi
    fi
  fi

  # (4) The result-comment channel carries the identical shape: its leading
  # field is the same nullable login. Its created_at is deliberately NOT
  # sentinel-filled — it is an evidence timestamp, and "<none>" sorts above
  # every real ISO-8601 value, so a sentinel there would clear the freshness
  # bar instead of failing it.
  cat >"$TMP_DIR/comments-null-author.json" <<'EOF'
[
  {
    "user": null,
    "created_at": "2026-08-12T11:00:00Z",
    "body": "Reviewed commit: `2258adf8b0`"
  }
]
EOF
  # shellcheck disable=SC2154
  jq -r "$COMMENTS_ROW_JQ" "$TMP_DIR/comments-null-author.json" \
    >"$TMP_DIR/comments-null-author.tsv"
  NC_AUTHOR=""
  NC_CREATED=""
  NC_BODY=""
  IFS=$'\t' read -r NC_AUTHOR NC_CREATED NC_BODY \
    <"$TMP_DIR/comments-null-author.tsv" || true
  if [ "$NC_AUTHOR" = "<unknown>" ] && [ "$NC_CREATED" = "2026-08-12T11:00:00Z" ] \
    && [ "$NC_BODY" = 'Reviewed commit: `2258adf8b0`' ]; then
    ok "a null .user comment row parses with its fields aligned: author='<unknown>', created_at and body intact"
  else
    fail "the comments row filter must emit a NONEMPTY author field: parsed author='$NC_AUTHOR' created_at='$NC_CREATED' body='$NC_BODY' (expected '<unknown>' / '2026-08-12T11:00:00Z' / 'Reviewed commit: \`2258adf8b0\`')"
  fi
  printf '%s\n' "$COMMENTS_ROW_JQ" >"$TMP_DIR/comments-filter.txt"
  if grep -q -F '(.created_at // "")' "$TMP_DIR/comments-filter.txt"; then
    ok "created_at stays empty-able: emptiness must remain a rejection signal, never a sentinel that outranks real timestamps"
  else
    fail "COMMENTS_ROW_JQ must leave created_at as '(.created_at // \"\")' — a nonempty sentinel in an evidence-timestamp slot sorts above every ISO-8601 value and would CLEAR the freshness bar"
  fi
  printf '%s\n' "$REVIEWS_ROW_JQ" >"$TMP_DIR/reviews-filter.txt"
  if grep -q -F '(.submitted_at // "")' "$TMP_DIR/reviews-filter.txt"; then
    ok "submitted_at stays empty-able: it is the last field, and emptiness is what rejects an unsubmitted PENDING review"
  else
    fail "REVIEWS_ROW_JQ must leave submitted_at as '(.submitted_at // \"\")' — it is last (no shift possible) and '[ -n \"\$submitted_at\" ]' is what keeps a PENDING review out of the evidence list"
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS review-binding workflow check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: review-binding workflow guardrails respected"
