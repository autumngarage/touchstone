#!/usr/bin/env bash
#
# tests/test-review-binding-workflow.sh — static guardrails for the
# review-binding check-run workflow (.github/workflows/review-binding.yml,
# issue #726).
#
# The workflow publishes the "review-binding" check-run that will eventually
# gate merges, so its safety properties are load-bearing:
#   - it must execute no PR-controlled code: no checkout, no third-party
#     actions at all, and no pull_request_target trigger;
#   - the trusted-author allowlist must live inside the workflow definition
#     (the review surface of a public repo is internet-writable);
#   - it must hold checks:write, and the only check-run named
#     "review-binding" must be the one it POSTs — a job or step of the same
#     name would publish a second, always-green run racing for what branch
#     protection reads;
#   - it must reference no secret beyond the built-in GITHUB_TOKEN.
#
# All assertions scan the workflow with comment lines stripped: the header
# prose explains the hazards and therefore necessarily names them. Scanning
# comments too would force the file to stop documenting its own threat model.
#
# Cheap, deterministic, offline — fast tier. Live check-run publication can
# only be proven by the workflow running in CI on a real PR.
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

echo "==> Trusted-author allowlist is hardcoded in the workflow"
if printf '%s\n' "$STRIPPED" | grep -q -F 'chatgpt-codex-connector,chatgpt-codex-connector[bot]'; then
  ok "allowlist present: chatgpt-codex-connector,chatgpt-codex-connector[bot]"
else
  fail "trusted allowlist 'chatgpt-codex-connector,chatgpt-codex-connector[bot]' missing from workflow env"
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
if printf '%s\n' "$STRIPPED" | grep -q -E '^[[:space:]]+name: review-binding$'; then
  fail "no job or step may be named review-binding — its own check-run would race the published verdict"
else
  ok "no job/step named review-binding (published verdict is the only run of that name)"
fi

echo "==> Binding evidence sources"
if printf '%s\n' "$STRIPPED" | grep -q -F 'touchstone/review-request-intent'; then
  ok "reads the touchstone/review-request-intent base binding"
else
  fail "workflow must read the 'touchstone/review-request-intent' commit status for base binding"
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
