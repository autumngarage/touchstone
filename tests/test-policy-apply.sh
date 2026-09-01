#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RELEASE="$TMP/release"
PROJECT="$TMP/project"
STATE="$TMP/state"
mkdir -p "$RELEASE/bin" "$RELEASE/scripts" "$RELEASE/policy/github/consumers" "$PROJECT" "$STATE"
cp "$ROOT/bin/touchstone" "$RELEASE/bin/touchstone"
cp "$ROOT/scripts/touchstone-policy.sh" "$RELEASE/scripts/touchstone-policy.sh"
cp "$ROOT/policy/github/touchstone-main.json" "$RELEASE/policy/github/touchstone-main.json"
printf '9.9.9\n' >"$RELEASE/VERSION"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "  OK: $*"; }

cat >"$RELEASE/scripts/touchstone-pr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${TOUCHSTONE_POLICY_TEST_STATE:?}"
if [ -f "$state/status-fails" ]; then echo 'SECRET STATUS BODY' >&2; exit 1; fi
if [ -f "$state/oversized" ]; then
  dd if=/dev/zero bs=70000 count=1 2>/dev/null | tr '\0' x
  exit 0
fi
status=none
[ ! -f "$state/applied" ] || status=applied
host=github.com
[ ! -f "$state/enterprise-host" ] || host=github.example.test
policy=policy/github/touchstone-main.json
[ ! -f "$state/variation" ] || policy=policy/github/consumers/solo.json
[ ! -f "$state/invalid-host" ] || host='github.com/another'
jq -cn --arg status "$status" --arg host "$host" --arg policy "$policy" '{schema:"touchstone.pr/v2",operation:"policy-status",repository:"autumngarage/solo",repositoryHost:$host,baseRef:"main",policy:$policy,policyRevision:"v9.9.9",enforcement:{status:$status,missing:(if $status == "applied" then [] else ["delivery"] end)}}'
EOF

cat >"$RELEASE/scripts/derive-consumer-policy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = solo ]
jq --arg repo "$1" '.repository=$repo | .rollbackPrerequisites.repositoryFiles=[]' "$(dirname "$0")/../policy/github/touchstone-main.json"
EOF

cat >"$RELEASE/scripts/github-policy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${TOUCHSTONE_POLICY_TEST_STATE:?}"
[ "$1" = apply ] && [ -r "$2" ]
printf '%s\n' "${GH_HOST-unset}" >"$state/mutation-host"
if [ -f "$state/variation" ]; then
  jq -e '.testVariation == "retained"' "$2" >/dev/null
fi
[ ! -f "$state/apply-must-not-run" ] || { touch "$state/apply-was-called"; exit 99; }
printf 'SECRET PROVIDER BODY THAT MUST NEVER ESCAPE\n' >&2
if [ -f "$state/permission-denied" ]; then exit 1; fi
touch "$state/applied"
if [ -f "$state/lost-reply" ]; then exit 1; fi
printf 'mutation internals that must never escape\n'
EOF
jq '.repository = "solo" | .testVariation = "retained"' \
  "$RELEASE/policy/github/touchstone-main.json" >"$RELEASE/policy/github/consumers/solo.json"
chmod +x "$RELEASE/bin/touchstone" "$RELEASE/scripts/"*.sh

run() {
  TOUCHSTONE_POLICY_TEST_STATE="$STATE" bash "$RELEASE/bin/touchstone" policy apply \
    --project "$PROJECT" --base main --authorize-admin --json
}

if TOUCHSTONE_POLICY_TEST_STATE="$STATE" bash "$RELEASE/bin/touchstone" policy apply \
  --project "$PROJECT" --base main --json >"$TMP/no-auth.json"; then
  fail "apply accepted no administrator acknowledgement"
fi
jq -e '.schema == "touchstone.policy/v1" and .status == "action-required"' "$TMP/no-auth.json" >/dev/null \
  || fail "missing authorization did not use the versioned response"
ok "apply requires an explicit administrator acknowledgement"

if TOUCHSTONE_POLICY_TEST_STATE="$STATE" bash "$RELEASE/bin/touchstone" policy apply \
  --project --json --base main --authorize-admin --json >"$TMP/missing-value.json"; then
  fail "apply consumed an option as a project path"
fi
jq -e '.status == "action-required"' "$TMP/missing-value.json" >/dev/null \
  || fail "option-shaped input did not use the versioned refusal"
ok "option-shaped values are refused before project resolution"

run >"$TMP/applied.json"
jq -e '.operation == "policy-apply" and .repository == "autumngarage/solo" and .baseRef == "main" and .status == "applied"' "$TMP/applied.json" >/dev/null \
  || fail "new policy was not applied and verified"
[ "$(wc -c <"$TMP/applied.json" | tr -d ' ')" -le 1024 ] || fail "success response is not bounded"
ok "a new policy is applied through one bounded versioned response"
[ "$(cat "$STATE/mutation-host")" = github.com ] || fail "mutation was not pinned to the resolved GitHub host"

rm -f "$STATE/applied"
touch "$STATE/enterprise-host"
run >"$TMP/enterprise.json"
[ "$(cat "$STATE/mutation-host")" = github.example.test ] || fail "enterprise mutation drifted from the resolved host"
ok "mutation is bound to the hostname selected by repository resolution"
rm -f "$STATE/applied" "$STATE/enterprise-host"

touch "$STATE/variation"
run >"$TMP/variation.json"
jq -e '.status == "applied"' "$TMP/variation.json" >/dev/null \
  || fail "checked-in consumer variation was not applied"
ok "checked-in consumer policy variations remain authoritative"
rm -f "$STATE/applied" "$STATE/variation"

touch "$STATE/invalid-host" "$STATE/apply-must-not-run"
if run >"$TMP/invalid-host.json"; then fail "invalid repository hostname reported success"; fi
jq -e '.status == "action-required"' "$TMP/invalid-host.json" >/dev/null \
  || fail "invalid repository hostname did not fail through the versioned schema"
[ ! -e "$STATE/apply-was-called" ] || fail "invalid repository hostname reached mutation"
ok "unsupported repository host identities fail before mutation"
rm -f "$STATE/invalid-host" "$STATE/apply-must-not-run"

: >"$STATE/applied"
: >"$STATE/apply-must-not-run"
run >"$TMP/already.json"
jq -e '.status == "already-applied"' "$TMP/already.json" >/dev/null \
  || fail "an applied policy was not recognized before mutation"
[ ! -e "$STATE/apply-was-called" ] || fail "already-applied invoked the mutation engine"
ok "already-applied is an idempotent read"
rm -f "$STATE/apply-must-not-run" "$STATE/applied"

touch "$STATE/permission-denied"
if run >"$TMP/denied.json"; then fail "permission failure reported success"; fi
jq -e '.status == "action-required" and (.detail | contains("administrator"))' "$TMP/denied.json" >/dev/null \
  || fail "permission failure was not actionable"
grep -q 'SECRET' "$TMP/denied.json" && fail "provider diagnostics escaped the policy API"
ok "permission failure is bounded and does not echo provider output"
rm -f "$STATE/permission-denied"

touch "$STATE/lost-reply"
if run >"$TMP/lost.json"; then fail "lost reply reported first-attempt success"; fi
jq -e '.status == "action-required"' "$TMP/lost.json" >/dev/null || fail "lost reply was not recoverable"
rm -f "$STATE/lost-reply"
run >"$TMP/converged.json"
jq -e '.status == "already-applied"' "$TMP/converged.json" >/dev/null \
  || fail "retry after a lost reply did not converge"
ok "a lost reply converges on the next idempotent call"
rm -f "$STATE/applied"

touch "$STATE/status-fails"
if run >"$TMP/status-fails.json"; then fail "unreadable status reported success"; fi
grep -q 'SECRET' "$TMP/status-fails.json" && fail "status diagnostics escaped the policy API"
rm -f "$STATE/status-fails"
touch "$STATE/oversized"
if run >"$TMP/oversized.json"; then fail "oversized status reported success"; fi
jq -e '.status == "action-required"' "$TMP/oversized.json" >/dev/null \
  || fail "oversized status did not fail through the bounded schema"
ok "unreadable and oversized status responses fail closed"

echo "All policy apply tests passed."
