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
echo status >>"$state/status-calls"
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
echo apply >>"$state/engine-calls"
[ "$1" = apply ] && [ -r "$2" ]
printf '%s\n' "${GH_HOST-unset}" >"$state/mutation-host"
if [ -f "$state/variation" ]; then
  jq -e '.testVariation == "retained"' "$2" >/dev/null
fi
[ ! -f "$state/apply-must-not-run" ] || { touch "$state/apply-was-called"; exit 99; }
printf 'SECRET PROVIDER BODY THAT MUST NEVER ESCAPE\n' >&2
printf 'SECRET PROVIDER STDOUT THAT MUST NEVER ESCAPE\n'
if [ -f "$state/permission-denied" ]; then exit 1; fi
touch "$state/applied"
if [ -f "$state/interrupted" ]; then kill -TERM "$$"; fi
if [ -f "$state/safe-report" ]; then
  if [ "${TOUCHSTONE_POLICY_SAFE_FACTS:-}" = 1 ]; then
    { cat "$state/safe-report" >&3; } 2>/dev/null || :
  fi
  exit "$(cat "$state/engine-status")"
fi
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

# Exercise both render branches before reporting an old-source failure.
bad=0
for mode in json human; do
  rm -f "$STATE/applied" "$STATE/status-calls" "$STATE/engine-calls"
  jq -cnS '{version:1,kind:"refresh-incomplete",installed:true,phase:"pr-refresh",
    targets:2,failures:1,first:{phase:"reopen",pr:42,head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' >"$STATE/safe-report"
  echo 7 >"$STATE/engine-status"
  status=0
  if [ "$mode" = json ]; then
    run >"$TMP/partial-$mode" 2>"$TMP/partial-$mode.err" || status=$?
  else
    TOUCHSTONE_POLICY_TEST_STATE="$STATE" bash "$RELEASE/bin/touchstone" policy apply \
      --project "$PROJECT" --base main --authorize-admin \
      >"$TMP/partial-$mode" 2>"$TMP/partial-$mode.err" || status=$?
  fi
  if [ "$status" -ne 7 ]; then
    echo "FAIL: $mode lost child exit7 (got $status)"
    bad=1
  fi
  for fact in 'installed' 'incomplete' '1 of 2' 'FIRST RECORDED' 'reopen' '#42' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
    if ! grep -q "$fact" "$TMP/partial-$mode"; then
      echo "FAIL: $mode lost safe fact: $fact"
      bad=1
    fi
  done
  if grep -Eiq 'SECRET|administrator|authentication' "$TMP/partial-$mode" "$TMP/partial-$mode.err"; then
    echo "FAIL: $mode exposed provider text or inferred authentication"
    bad=1
  fi
  [ "$(wc -l <"$STATE/status-calls" | tr -d ' ')" = 1 ] || fail "read status after engine failure"
  [ "$(wc -l <"$STATE/engine-calls" | tr -d ' ')" = 1 ] || fail "retried engine failure"
done
[ "$bad" = 0 ] || fail "partial refresh contract failed in JSON/human modes"
rm -f "$STATE/applied" "$STATE/safe-report" "$STATE/engine-status"
ok "safe incomplete refresh facts and exact exit survive both render modes"

report_failure() {
  local expected="$1" result=0
  rm -f "$STATE/applied" "$STATE/status-calls" "$STATE/engine-calls"
  echo 7 >"$STATE/engine-status"
  run >"$TMP/report.json" 2>"$TMP/report.err" || result=$?
  [ "$result" = 7 ] || fail "report changed child status"
  jq -e --arg expected "$expected" '.status=="action-required" and (.detail | contains($expected))' \
    "$TMP/report.json" >/dev/null || fail "wrong safe report disposition: $expected"
  if grep -Eiq 'SECRET|administrator|authentication' "$TMP/report.json" "$TMP/report.err"; then
    fail "report crossed the provider boundary"
  fi
  [ "$(wc -l <"$STATE/status-calls" | tr -d ' ')" = 1 ] || fail "report failure read status"
  [ "$(wc -l <"$STATE/engine-calls" | tr -d ' ')" = 1 ] || fail "report failure retried"
}
jq -cnS '{version:1,kind:"refresh-incomplete",installed:true,phase:"pr-refresh",
  targets:1,failures:1,first:{phase:"reopen",pr:1,head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' >"$TMP/min-report"
cp "$TMP/min-report" "$STATE/safe-report"
report_failure '1 of 1'
jq -cS '.targets=2147483647 | .failures=2147483647 | .first.pr=2147483647
  | .first.phase="after-reopen-coordinates"' "$TMP/min-report" >"$TMP/max-report"
[ "$(wc -c <"$TMP/max-report" | tr -d ' ')" = 234 ] || fail "canonical domain bound changed"
cp "$TMP/max-report" "$STATE/safe-report"
report_failure '2147483647 of 2147483647'
jq -cS '.phase="enumeration" | .targets=null | .failures=null | .first=null' \
  "$TMP/min-report" >"$TMP/enumeration-report"
cp "$TMP/enumeration-report" "$STATE/safe-report"
report_failure 'enumeration'
jq -cS '.phase="opt-out" | .first=null' "$TMP/min-report" >"$STATE/safe-report"
report_failure 'SKIPPED 1'
jq -cS '.first=null' "$TMP/min-report" >"$STATE/safe-report"
report_failure 'No safe per-PR sample'

for change in '.version=2' '.installed=false' '.kind="unknown"' '.phase="unknown"' \
  'del(.targets)' '.extra="SECRET"' '.targets=0' '.targets=2147483648' '.targets=1.5' \
  '.failures=0' '.failures=2' '.first.pr=0' '.first.pr=2147483648' \
  '.first.head="SECRET"' '.first.phase="unknown"' '.first.extra="SECRET"' \
  '.phase="enumeration"' '.phase="opt-out"'; do
  jq -cS "$change" "$TMP/min-report" >"$STATE/safe-report"
  report_failure 'Policy apply failed'
done
cat "$TMP/enumeration-report" "$TMP/enumeration-report" >"$STATE/safe-report"
report_failure 'Policy apply failed'
{
  printf '{}\n'
  cat "$TMP/enumeration-report"
} >"$STATE/safe-report"
[ "$(wc -c <"$STATE/safe-report" | tr -d ' ')" -le 234 ] || fail "mixed record fixture missed parser"
report_failure 'Policy apply failed'
sed 's/"version":1/"version":1,"version":1/' "$TMP/min-report" >"$STATE/safe-report"
report_failure 'Policy apply failed'
jq . "$TMP/min-report" >"$STATE/safe-report"
report_failure 'Policy apply failed'
printf '%s' "$(cat "$TMP/min-report")" >"$STATE/safe-report"
report_failure 'Policy apply failed'
cp "$TMP/min-report" "$STATE/safe-report"
printf '\n' >>"$STATE/safe-report"
report_failure 'Policy apply failed'
cp "$TMP/max-report" "$STATE/safe-report"
printf ' ' >>"$STATE/safe-report"
report_failure 'Policy apply failed'
printf 'SECRET malformed report\n' >"$STATE/safe-report"
report_failure 'Policy apply failed'

# Report validity cannot turn a successful engine into a failed invocation.
rm -f "$STATE/applied"
echo 0 >"$STATE/engine-status"
run >"$TMP/success-with-invalid-report.json"
jq -e '.status=="applied"' "$TMP/success-with-invalid-report.json" >/dev/null \
  || fail "invalid diagnostic changed engine success"
rm -f "$STATE/applied" "$STATE/safe-report" "$STATE/engine-status"
ok "single canonical bounded facts fail neutral without changing engine status"

mkdir -p "$TMP/tools"
TOUCHSTONE_POLICY_TEST_MKTEMP="$(command -v mktemp)"
export TOUCHSTONE_POLICY_TEST_MKTEMP
cat >"$TMP/tools/mktemp" <<'EOF'
#!/usr/bin/env bash
directory="$("$TOUCHSTONE_POLICY_TEST_MKTEMP" "$@")" || exit $?
mkdir "$directory/safe-facts.json"
printf '%s\n' "$directory"
EOF
chmod +x "$TMP/tools/mktemp"
cp "$TMP/min-report" "$STATE/safe-report"
PATH="$TMP/tools:$PATH" report_failure 'Policy apply failed'
rm -f "$STATE/applied" "$STATE/safe-report" "$STATE/engine-status"
ok "descriptor setup failure still invokes the engine and preserves its status"

touch "$STATE/interrupted"
rm -f "$STATE/applied" "$STATE/status-calls" "$STATE/engine-calls"
status=0
run >"$TMP/interrupted.json" 2>"$TMP/interrupted.err" || status=$?
[ "$status" = 143 ] || fail "interrupted engine status was masked"
jq -e '.status=="action-required" and (.detail | contains("Policy apply failed"))' \
  "$TMP/interrupted.json" >/dev/null || fail "interruption invented terminal refresh facts"
[ ! -s "$TMP/interrupted.err" ] || fail "engine termination diagnostics escaped"
[ "$(wc -l <"$STATE/status-calls" | tr -d ' ')" = 1 ] || fail "interrupted engine read status"
rm -f "$STATE/interrupted" "$STATE/applied"
ok "interrupted engine is a private neutral failure with its original status"

touch "$STATE/permission-denied"
if run >"$TMP/denied.json"; then fail "permission failure reported success"; fi
jq -e '.status == "action-required" and (.detail | contains("Policy apply failed"))' "$TMP/denied.json" >/dev/null \
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
