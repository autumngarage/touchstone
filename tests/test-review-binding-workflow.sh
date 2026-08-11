#!/usr/bin/env bash
#
# tests/test-review-binding-workflow.sh — static guardrails for the
# review-binding check-run workflow (.github/workflows/review-binding.yml,
# issue #726).
#
# WHAT THIS FILE IS, PLAINLY: static structural assertions over the workflow
# TEXT — greps plus one awk pass over the YAML. It executes none of the
# workflow's bash, stubs none of its API calls, and simulates no GitHub
# events; it therefore proves textual invariants only (triggers subscribed,
# no code-execution surfaces, the safety markers present) and cannot prove
# the workflow computes correct verdicts. The workflow's dynamic behavior —
# check-run publication and verdict correctness — is proven by its live runs
# in CI on real PRs, not by anything in this file.
#
# The workflow publishes the "review-binding" check-run that will eventually
# gate merges, so its safety properties are load-bearing:
#   - it must execute no PR-controlled code: no checkout, no third-party
#     actions at all, and no pull_request_target trigger;
#   - the trusted-author allowlist may never come from PR-controlled files:
#     the fallback default lives in the workflow env, and the live list is
#     read from the review config at the PR's current BASE oid;
#   - intent statuses must be creator-validated (statuses:write alone must
#     not bind a base) and evidence removal must re-evaluate;
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

# Strip comment-only lines (YAML comments and the bash comments inside the
# run block) before scanning for dangerous strings.
STRIPPED="$(grep -v -E '^[[:space:]]*#' "$WORKFLOW")"

echo "==> No PR-controlled code can execute"
if printf '%s\n' "$STRIPPED" | grep -q -E '(^|[[:space:]])uses:'; then
  fail "workflow must run zero actions (no 'uses:' steps — not even checkout)"
else
  ok "no 'uses:' steps: nothing is checked out, no third-party actions run"
fi
if printf '%s\n' "$STRIPPED" | grep -q 'pull_request_target'; then
  fail "workflow must not trigger on pull_request_target"
else
  ok "no pull_request_target trigger"
fi

echo "==> Trusted-author allowlist is never PR-controlled"
if printf '%s\n' "$STRIPPED" | grep -q -F 'chatgpt-codex-connector,chatgpt-codex-connector[bot]'; then
  ok "fallback allowlist hardcoded in env (merge-pr.sh's built-in default)"
else
  fail "fallback allowlist 'chatgpt-codex-connector,chatgpt-codex-connector[bot]' missing from workflow env"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F '.touchstone-review.toml'; then
  ok "live allowlist read from the review config at the PR's base oid (merge-pr.sh parity)"
else
  fail "workflow must load trusted_review_authors from .touchstone-review.toml at the PR's current base oid"
fi

echo "==> Permissions"
if printf '%s\n' "$STRIPPED" | grep -q -E '^[[:space:]]*checks:[[:space:]]*write$'; then
  ok "checks: write present"
else
  fail "permissions must include 'checks: write' to publish the check-run"
fi

echo "==> Check-run identity"
if [ "$(printf '%s\n' "$STRIPPED" | grep -c -E '^name: review-binding$')" -eq 1 ]; then
  ok "workflow is named review-binding"
else
  fail "expected exactly one top-level 'name: review-binding'"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F -- '-f name=review-binding'; then
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
if printf '%s\n' "$STRIPPED" | grep -q -E '^[[:space:]]+name: review-binding$'; then
  fail "no job or step name: property may be review-binding — its own check-run would race the published verdict"
else
  ok "no job/step name: property review-binding (published verdict is the only run of that name)"
fi

echo "==> Binding evidence sources"
if printf '%s\n' "$STRIPPED" | grep -q -F 'touchstone/review-request-intent'; then
  ok "reads the touchstone/review-request-intent base binding"
else
  fail "workflow must read the 'touchstone/review-request-intent' commit status for base binding"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F 'collaborators/$login/permission'; then
  ok "intent-status creators resolved to collaborator permission (statuses:write alone cannot bind)"
else
  fail "workflow must resolve each intent-status creator via collaborators/<login>/permission (merge-pr.sh parity)"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F 'commits/$head_sha/pulls'; then
  ok "shared-head guard present (a head serving multiple open PRs fails closed)"
else
  fail "workflow must detect a head shared by multiple open PRs via commits/<sha>/pulls and fail closed"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F 'Reviewed commit:'; then
  ok "accepts the trusted result-comment channel (parity with merge-pr.sh)"
else
  fail "workflow must accept the trusted 'Reviewed commit:' comment channel merge-pr.sh accepts"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F 'earliest_matching_intent_at'; then
  ok "freshness anchored to the earliest base-bound request intent"
else
  fail "workflow must anchor evidence freshness to the earliest matching review-request intent (earliest_matching_intent_at)"
fi

echo "==> Publication discipline"
if printf '%s\n' "$STRIPPED" | grep -q -F 'live_head'; then
  ok "publish-time revalidation present (stale coordinates skip the POST)"
else
  fail "workflow must re-read live head/base before publishing so a stale evaluation cannot overwrite a newer verdict"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F 'publish_sweep_overflow'; then
  ok "sweep overflow fails closed (no PR past the cap keeps a stale verdict)"
else
  fail "PRs past MAX_BASE_SWEEP_PRS must get an explicit fail-closed check-run (publish_sweep_overflow)"
fi

echo "==> Triggers"
if printf '%s\n' "$STRIPPED" | grep -q -E '^[[:space:]]*pull_request_review:'; then
  ok "pull_request_review trigger present"
else
  fail "workflow must trigger on pull_request_review (formal review submission fires no issue_comment)"
fi
if printf '%s\n' "$STRIPPED" | grep -q -E '^[[:space:]]*push:'; then
  ok "push trigger present"
else
  fail "workflow must trigger on push (base-branch advance stales bindings with no PR-scoped event)"
fi
if printf '%s\n' "$STRIPPED" | grep -q -F 'MAX_BASE_SWEEP_PRS'; then
  ok "push fan-out bounded by MAX_BASE_SWEEP_PRS"
else
  fail "the push fan-out must be bounded by a named MAX_BASE_SWEEP_PRS cap"
fi
if printf '%s\n' "$STRIPPED" | grep -q -E '^[[:space:]]*issue_comment:'; then
  ok "issue_comment trigger present"
else
  fail "workflow must trigger on issue_comment (review completion is signalled by a PR comment)"
fi
if printf '%s\n' "$STRIPPED" | grep -A1 -E '^[[:space:]]*issue_comment:' | grep -q -E 'types:.*created.*edited.*deleted'; then
  ok "issue_comment covers created, edited, and deleted (evidence removal re-evaluates fail-closed)"
else
  fail "issue_comment types must include created, edited, and deleted — deleting/editing a result comment removes evidence and must re-evaluate"
fi
if printf '%s\n' "$STRIPPED" | grep -q -E '^[[:space:]]*pull_request:'; then
  ok "pull_request trigger present"
else
  fail "workflow must trigger on pull_request (synchronize makes every new head start red)"
fi
if printf '%s\n' "$STRIPPED" | grep -q 'synchronize'; then
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

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS review-binding workflow check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: review-binding workflow guardrails respected"
