#!/usr/bin/env bash
# tests/test-actions-usage.sh — `touchstone usage` sees the pace of Actions
# usage, not the cliff, and its launchd agent surfaces the warning.
#
# Offline and date-independent: a fake gh serves a synthetic billing report
# (tests/fixtures/actions-usage-2026-08.json, shaped like GitHub's rows) and
# every check pins --as-of. Fake launchctl and osascript record their calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/actions-usage-2026-08.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-usage-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ERRORS=0
ok() { echo "  OK: $*"; }
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

STATE="$TMP/state"
mkdir -p "$TMP/bin" "$STATE" "$TMP/home"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_FAKE_STATE/calls"
[ "$1" = api ] || { echo "unhandled fake gh call: $*" >&2; exit 1; }
shift
[ "$1" = --paginate ] && shift
path="$1"
case "$path" in
  enterprises/*/settings/billing/usage\?*)
    [ -f "$GH_FAKE_STATE/billing-down" ] && { echo "gh: HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    cat "$GH_FAKE_STATE/usage.json"
    ;;
  orgs/*/repos\?type=public*)
    org="${path#orgs/}"
    org="${org%%/*}"
    jq -R --arg org "$org" '{full_name: ($org + "/" + .)}' "$GH_FAKE_STATE/public" | jq -s .
    ;;
  repos/*/actions/runs/*/jobs\?*)
    [ -f "$GH_FAKE_STATE/jobs-down" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    id="${path#*/actions/runs/}"
    cat "$GH_FAKE_STATE/jobs-${id%%/*}.json"
    ;;
  repos/*/actions/runs\?*)
    repo="${path#repos/}"
    repo="${repo%%/actions/*}"
    runs="$GH_FAKE_STATE/runs-${repo//\//_}.json"
    if [ -f "$runs" ]; then cat "$runs"; else echo '{"total_count":0,"workflow_runs":[]}'; fi
    ;;
  *) echo "unhandled fake gh call: $*" >&2; exit 1 ;;
esac
FAKE
cat >"$TMP/bin/osascript" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_FAKE_STATE/notifications"
FAKE
cat >"$TMP/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_FAKE_STATE/launchctl"
case "$1" in
  print) [ -f "$GH_FAKE_STATE/loaded" ] ;;
  bootstrap) touch "$GH_FAKE_STATE/loaded" ;;
  bootout) rm -f "$GH_FAKE_STATE/loaded" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/gh" "$TMP/bin/osascript" "$TMP/bin/launchctl"
export PATH="$TMP/bin:$PATH" GH_FAKE_STATE="$STATE"
echo "open-source-lib" >"$STATE/public"

# scale FACTOR: the fixture with every quantity and amount scaled. Decisions
# read quantity and pricePerUnit only; amounts scale with them so each row
# still satisfies grossAmount = quantity x pricePerUnit.
scale() {
  jq --argjson f "$1" '.usageItems |= map(.quantity *= $f | .grossAmount *= $f
    | .discountAmount *= $f | .netAmount *= $f)' "$FIXTURE" >"$STATE/usage.json"
}
check() {
  set +e
  bash "$ROOT/bin/touchstone" usage check --enterprise example-enterprise "$@" >"$TMP/out" 2>&1
  RC=$?
  set -e
}
# replay: run the daily check as of 00:00 UTC on each day of August and
# print "day<TAB>exit" for each.
replay() {
  local d
  for d in $(seq -w 1 31); do
    check --as-of "2026-08-$d" --sample-runs 0
    printf '2026-08-%s\t%s\n' "$d" "$RC"
  done
}
first_warning() { awk -F'\t' '$2 == 1 { print $1; exit }' "$1"; }

echo "==> the fixture is shaped like GitHub's rows and its spend first passes \$40 on Aug 27"
KEYS="$(jq -c '[.usageItems[] | keys] | unique' "$FIXTURE")"
[ "$KEYS" = '[["date","discountAmount","grossAmount","netAmount","organizationName","pricePerUnit","product","quantity","repositoryName","sku","unitType"]]' ] \
  && ok "every row carries exactly GitHub's keys" || fail "fixture keys drifted: $KEYS"
FORTY_DAY="$(jq -r '[.usageItems | group_by(.date[0:10])[] | {day: .[0].date[0:10], net: (map(.netAmount) | add)}]
  | reduce .[] as $d ({sum: 0, day: null}; .sum += $d.net | if .day == null and .sum > 40 then .day = $d.day else . end) | .day' "$FIXTURE")"
[ "$FORTY_DAY" = 2026-08-27 ] && ok "net spend first passes \$40 on $FORTY_DAY" || fail "net spend first passes \$40 on $FORTY_DAY, not 2026-08-27"

echo "==> typical month: the pace warns by Aug 27, and not while the base pace holds"
scale 1
replay >"$TMP/typical"
awk -F'\t' '$2 != 0 && $2 != 1 { bad = 1 } END { exit bad }' "$TMP/typical" \
  && ok "every day's check exits 0 or 1" || fail "a replayed check failed: $(tr '\n' ' ' <"$TMP/typical")"
WARN_DAY="$(first_warning "$TMP/typical")"
if [ -n "$WARN_DAY" ] && [[ ! "$WARN_DAY" > "$FORTY_DAY" ]]; then
  ok "first warning on $WARN_DAY, by the day spend passed \$40 ($FORTY_DAY)"
else
  fail "first warning on '${WARN_DAY:-never}', after spend passed \$40 on $FORTY_DAY"
fi
# The surge starts on the 22nd; the 00:00 check on the 23rd has seen one day
# of it. Counting the public repository's free minutes would warn from the
# first week, so this also proves they are excluded.
[ "$WARN_DAY" = 2026-08-24 ] && ok "the check on the 24th is the first to warn" \
  || fail "first warning on '${WARN_DAY:-never}', expected 2026-08-24"
awk -F'\t' '$1 >= "2026-08-24" && $2 != 1 { bad = 1 } END { exit bad }' "$TMP/typical" \
  && ok "it keeps warning through month end" || fail "the warning lapsed: $(tr '\n' ' ' <"$TMP/typical")"

echo "==> small and large months"
scale 0.25
replay >"$TMP/small"
[ -z "$(first_warning "$TMP/small")" ] && awk -F'\t' '$2 != 0 { bad = 1 } END { exit bad }' "$TMP/small" \
  && ok "a quarter-scale month never warns" || fail "small month: $(tr '\n' ' ' <"$TMP/small")"
scale 4
replay >"$TMP/large"
[ "$(awk -F'\t' '$1 == "2026-08-01" { print $2 }' "$TMP/large")" = 0 ] \
  && ok "no data yet on the 1st: within threshold" || fail "large month warned before any usage"
[ "$(first_warning "$TMP/large")" = 2026-08-02 ] \
  && ok "a four-times month warns on the first day with data" || fail "large month: $(tr '\n' ' ' <"$TMP/large")"

echo "==> the report: weights from prices, month to date, projection, free minutes"
scale 1
check --as-of 2026-08-24 --sample-runs 0
grep -q 'as of 2026-08-24T00:00:00Z (day 23.0 of 31)' "$TMP/out" && ok "window" || fail "window: $(cat "$TMP/out")"
grep -Eq 'Actions macOS 3-core +1,720 min +x10\.33 +17,773$' "$TMP/out" \
  && grep -Eq 'Actions Windows +460 min +x1\.67 +767$' "$TMP/out" \
  && grep -Eq 'Actions Linux +14,030 min +x1\.00 +14,030$' "$TMP/out" \
  && ok "each SKU weighted by its price over the Linux price" || fail "SKU weights: $(cat "$TMP/out")"
grep -Eq '^Month to date +32,570 included minutes \(65% of the 50,000 allowance\)' "$TMP/out" \
  && grep -Eq '^Projection +43,899 by month end' "$TMP/out" \
  && grep -Eq '^Threshold +40,000$' "$TMP/out" \
  && ok "32,570 to date projects to 43,899 against the 40,000 default threshold" || fail "totals: $(cat "$TMP/out")"
grep -q 'Public repositories (free, not counted): 5,750 minutes in example-org/open-source-lib' "$TMP/out" \
  && ok "public minutes are reported, not counted" || fail "public minutes: $(cat "$TMP/out")"
grep -Eq '^ +21,223 +65% +example-org/desktop-app$' "$TMP/out" \
  && ok "top repository by included minutes" || fail "repositories: $(cat "$TMP/out")"
grep -q '^WARNING: Projected 43,899 included Actions minutes by month end passes the 40,000 threshold' "$TMP/out" \
  && [ "$RC" -eq 1 ] && ok "warning line and exit 1" || fail "verdict (rc=$RC): $(cat "$TMP/out")"

jq '.usageItems |= map(if .sku == "Actions macOS 3-core" then .pricePerUnit = 0.012 | .grossAmount = .quantity * 0.012 else . end)' \
  "$FIXTURE" >"$STATE/usage.json"
check --as-of 2026-08-24 --sample-runs 0
grep -Eq 'Actions macOS 3-core +1,720 min +x2\.00 +3,440$' "$TMP/out" \
  && ok "a different macOS price is a different weight: nothing is hard-coded" || fail "repriced weight: $(cat "$TMP/out")"

echo "==> limits come from flags"
scale 1
check --as-of 2026-08-24 --sample-runs 0 --allowance 100000
[ "$RC" -eq 0 ] && grep -Eq '^Threshold +80,000$' "$TMP/out" \
  && ok "the default threshold is a share of the allowance" || fail "--allowance (rc=$RC): $(cat "$TMP/out")"
check --as-of 2026-08-23 --sample-runs 0 --threshold 30000
[ "$RC" -eq 1 ] && ok "--threshold overrides it" || fail "--threshold (rc=$RC): $(cat "$TMP/out")"

echo "==> failures are exit 2, never a pass"
jq '.usageItems |= map(select(.sku != "Actions Linux"))' "$FIXTURE" >"$STATE/usage.json"
check --as-of 2026-08-24 --sample-runs 0
[ "$RC" -eq 2 ] && grep -q 'no priced "Actions Linux" row' "$TMP/out" \
  && ok "no base price: refused, not guessed" || fail "missing base SKU (rc=$RC): $(cat "$TMP/out")"
scale 1
touch "$STATE/billing-down"
rm -f "$STATE/notifications"
check --as-of 2026-08-24 --sample-runs 0 --notify
[ "$RC" -eq 2 ] && grep -q 'billing usage read failed.*HTTP 403' "$TMP/out" \
  && grep -q 'could not complete' "$STATE/notifications" \
  && ok "a failed billing read exits 2 and notifies" || fail "billing down (rc=$RC): $(cat "$TMP/out")"
rm -f "$STATE/billing-down"
for bad in "--as-of 2026-02-30" "--as-of yesterday" "--sample-runs 101" "--top x" "--enterprise ../x"; do
  # shellcheck disable=SC2086 # each case is deliberately several words
  check $bad
  [ "$RC" -eq 2 ] && ok "refused: $bad" || fail "accepted $bad (rc=$RC)"
done
set +e
bash "$ROOT/bin/touchstone" usage check >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "--enterprise is required" || fail "check without --enterprise was accepted"
bash "$ROOT/bin/touchstone" usage >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "an action is required" || fail "bare 'usage' was accepted"
bash "$ROOT/bin/touchstone" usage --help >"$TMP/help" 2>&1
[ "$?" -eq 0 ] && grep -q 'touchstone usage check --enterprise SLUG' "$TMP/help" \
  && ok "--help documents the command" || fail "--help: $(cat "$TMP/help")"
set -e
bash "$ROOT/bin/touchstone" help | grep -q '^  touchstone usage check|install|uninstall' \
  && ok "the CLI usage lists it" || fail "bin/touchstone usage() omits the usage command"

echo "==> warning notifies"
rm -f "$STATE/notifications"
check --as-of 2026-08-24 --sample-runs 0 --notify
[ "$RC" -eq 1 ] && grep -q 'passes the 40,000 threshold (example-enterprise, 2026-08)' "$STATE/notifications" \
  && ok "the warning raises a notification" || fail "warning notification (rc=$RC): $(cat "$STATE/notifications" 2>/dev/null)"
rm -f "$STATE/notifications"
check --as-of 2026-08-20 --sample-runs 0 --notify
[ "$RC" -eq 0 ] && [ ! -f "$STATE/notifications" ] && ok "a pass is silent" || fail "a pass notified (rc=$RC)"

echo "==> workflow and job ranking from a bounded sample of runs"
cat >"$STATE/runs-example-org_desktop-app.json" <<'JSON'
{"total_count": 57, "workflow_runs": [{"id": 101}, {"id": 102}, {"id": 103}]}
JSON
cat >"$STATE/runs-example-org_api-service.json" <<'JSON'
{"total_count": 12, "workflow_runs": [{"id": 201}]}
JSON
cat >"$STATE/jobs-101.json" <<'JSON'
{"total_count": 2, "jobs": [
 {"workflow_name": "ci", "name": "build", "labels": ["macos-15"], "started_at": "2026-08-23T10:00:00Z", "completed_at": "2026-08-23T10:20:30Z"},
 {"workflow_name": "ci", "name": "lint", "labels": ["ubuntu-latest"], "started_at": "2026-08-23T10:00:00Z", "completed_at": "2026-08-23T10:02:00Z"}]}
JSON
cat >"$STATE/jobs-102.json" <<'JSON'
{"total_count": 4, "jobs": [
 {"workflow_name": "release", "name": "build", "labels": ["macos-15"], "started_at": "2026-08-23T11:00:00Z", "completed_at": "2026-08-23T11:30:00Z"},
 {"workflow_name": "release", "name": "sign", "labels": ["self-hosted", "macOS"], "started_at": "2026-08-23T11:30:00Z", "completed_at": "2026-08-23T12:30:00Z"},
 {"workflow_name": "release", "name": "notify", "labels": ["ubuntu-latest"], "started_at": "2026-08-23T12:30:05Z", "completed_at": "2026-08-23T12:30:04Z"},
 {"workflow_name": "release", "name": "gpu", "labels": ["gpu-large"], "started_at": "2026-08-23T11:00:00Z", "completed_at": "2026-08-23T11:05:00Z"}]}
JSON
cat >"$STATE/jobs-201.json" <<'JSON'
{"total_count": 1, "jobs": [
 {"workflow_name": "ci", "name": "test", "labels": ["ubuntu-24.04"], "started_at": "2026-08-23T09:00:00Z", "completed_at": "2026-08-23T09:09:01Z"}]}
JSON
: >"$STATE/calls"
check --as-of 2026-08-24 --top 2 --sample-runs 2
grep -q 'Top workflows (jobs from the 2 most recent completed runs of each top repository: 3 of 69 runs this month):' "$TMP/out" \
  && ok "the sample states its coverage" || fail "coverage: $(cat "$TMP/out")"
grep -Eq '^ +310 +58% +example-org/desktop-app  release$' "$TMP/out" \
  && grep -Eq '^ +219 +41% +example-org/desktop-app  ci$' "$TMP/out" \
  && grep -Eq '^ +310 +58% +example-org/desktop-app  release / build \(1 job run\)$' "$TMP/out" \
  && grep -Eq '^ +217 +40% +example-org/desktop-app  ci / build \(1 job run\)$' "$TMP/out" \
  && ok "jobs are billed per started minute at their runner's weight; self-hosted is free" || fail "ranking: $(cat "$TMP/out")"
grep -q '^5 sampled job minutes ran on runners with no Actions SKU' "$TMP/out" \
  && ok "unpriced runners are reported, not guessed" || fail "unpriced: $(cat "$TMP/out")"
JOB_CALLS="$(grep -c '/jobs?' "$STATE/calls" || true)"
[ "$JOB_CALLS" -eq 3 ] && ! grep -q 'runs/103/jobs' "$STATE/calls" \
  && ok "at most --sample-runs job lists per repository ($JOB_CALLS for --top 2 --sample-runs 2)" || fail "job reads: $(cat "$STATE/calls")"
grep -q 'created=2026-08-01T00:00:00Z..2026-08-24T00:00:00Z&status=completed&exclude_pull_requests=true&per_page=2' "$STATE/calls" \
  && ok "runs are read for this month, up to the as-of instant, one page of --sample-runs" || fail "run query: $(cat "$STATE/calls")"
[ "$RC" -eq 1 ] && ok "the verdict still comes from billing" || fail "verdict with sample (rc=$RC)"
touch "$STATE/jobs-down"
check --as-of 2026-08-24 --top 2 --sample-runs 2
[ "$RC" -eq 1 ] && grep -q 'sample could not complete' "$TMP/out" \
  && ok "a failed sample never hides the warning" || fail "sample down, over threshold (rc=$RC)"
check --as-of 2026-08-20 --top 2 --sample-runs 2
[ "$RC" -eq 2 ] && ok "a failed sample under threshold exits 2, not 0" || fail "sample down, under threshold (rc=$RC)"
rm -f "$STATE/jobs-down"

echo "==> install renders a daily launchd agent for the installed touchstone"
export HOME="$TMP/home"
LABEL="com.autumngarage.touchstone.usage.example-enterprise"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
: >"$STATE/launchctl"
set +e
bash "$ROOT/bin/touchstone" usage install --enterprise example-enterprise --touchstone "$ROOT/bin/touchstone" --dry-run >"$TMP/out" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] && [ ! -e "$PLIST" ] && [ ! -s "$STATE/launchctl" ] \
  && grep -q '<string>--notify</string>' "$TMP/out" && grep -q "would run: launchctl bootstrap gui/$(id -u) $PLIST" "$TMP/out" \
  && ok "--dry-run prints the plist and loads nothing" || fail "dry run (rc=$RC): $(cat "$TMP/out")"
set +e
bash "$ROOT/bin/touchstone" usage install --enterprise example-enterprise --touchstone "$ROOT/bin/touchstone" \
  --hour 7 --minute 5 --threshold 30000 >"$TMP/out" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] && [ -f "$PLIST" ] && ok "installed ($PLIST)" || fail "install (rc=$RC): $(cat "$TMP/out")"
UID_NOW="$(id -u)"
grep -qx "bootstrap gui/$UID_NOW $PLIST" "$STATE/launchctl" && ok "loaded with launchctl bootstrap" || fail "launchctl calls: $(cat "$STATE/launchctl")"
tr -d ' \n' <"$PLIST" | grep -q "<key>Hour</key><integer>7</integer><key>Minute</key><integer>5</integer>" \
  && ok "daily at 07:05" || fail "schedule: $(cat "$PLIST")"
ARGS="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$PLIST" | sed -n 's|^ *<string>\(.*\)</string>$|\1|p' | tr '\n' ' ')"
[ "$ARGS" = "$ROOT/bin/touchstone usage check --enterprise example-enterprise --notify --threshold 30000 " ] \
  && ok "runs the installed touchstone's check with --notify and only the limits given" || fail "ProgramArguments: $ARGS"
AGENT_PATH="$(sed -n '/<key>PATH<\/key>/{n;s|^ *<string>\(.*\)</string>$|\1|p;}' "$PLIST")"
case ":$AGENT_PATH:" in
  *":$TMP/bin:"*) ok "the agent's PATH carries gh's directory" ;;
  *) fail "agent PATH lacks gh: $AGENT_PATH" ;;
esac
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST" >/dev/null && ok "plutil accepts the plist" || fail "plutil rejects $PLIST"
fi

echo "==> the agent's command surfaces the warning"
# Run ProgramArguments the way launchd does, with the agent's PATH; --as-of
# pins the date the test replays.
ARGV=()
while IFS= read -r arg; do ARGV+=("$arg"); done < <(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$PLIST" | sed -n 's|^ *<string>\(.*\)</string>$|\1|p')
rm -f "$STATE/notifications"
set +e
env PATH="$AGENT_PATH" "${ARGV[@]}" --as-of 2026-08-23 --sample-runs 0 >"$TMP/out" 2>&1
RC=$?
set -e
[ "$RC" -eq 1 ] && grep -q 'passes the 30,000 threshold' "$STATE/notifications" \
  && ok "the scheduled command exits 1 and notifies" || fail "agent run (rc=$RC): $(cat "$TMP/out")"

echo "==> reinstall replaces, an old touchstone is refused, uninstall removes"
: >"$STATE/launchctl"
bash "$ROOT/bin/touchstone" usage install --enterprise example-enterprise --touchstone "$ROOT/bin/touchstone" >/dev/null 2>&1
[ "$(grep -E '^(bootout|bootstrap) ' "$STATE/launchctl" | tr '\n' '|')" = "bootout gui/$UID_NOW/$LABEL|bootstrap gui/$UID_NOW $PLIST|" ] \
  && ok "a loaded agent is booted out before the new one loads" || fail "reinstall: $(cat "$STATE/launchctl")"
cat >"$TMP/old-touchstone" <<'OLD'
#!/usr/bin/env bash
echo "ERROR: unknown command '$1'" >&2
exit 2
OLD
chmod +x "$TMP/old-touchstone"
cp "$PLIST" "$TMP/plist.before"
set +e
bash "$ROOT/bin/touchstone" usage install --enterprise example-enterprise --touchstone "$TMP/old-touchstone" >"$TMP/out" 2>&1
RC=$?
set -e
[ "$RC" -eq 2 ] && grep -q "has no 'usage' command" "$TMP/out" && cmp -s "$PLIST" "$TMP/plist.before" \
  && ok "a touchstone without the command is refused and the agent is untouched" || fail "old touchstone (rc=$RC): $(cat "$TMP/out")"
set +e
bash "$ROOT/bin/touchstone" usage install --enterprise example-enterprise --touchstone bin/touchstone >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "a relative --touchstone is refused" || fail "relative --touchstone accepted"
set -e
: >"$STATE/launchctl"
bash "$ROOT/bin/touchstone" usage uninstall --enterprise example-enterprise >"$TMP/out" 2>&1
grep -qx "bootout gui/$UID_NOW/$LABEL" "$STATE/launchctl" && [ ! -e "$PLIST" ] \
  && ok "uninstall unloads and removes the agent" || fail "uninstall: $(cat "$TMP/out")"
bash "$ROOT/bin/touchstone" usage uninstall --enterprise example-enterprise >"$TMP/out" 2>&1
grep -q "no $LABEL agent was installed" "$TMP/out" && ok "uninstall is idempotent" || fail "second uninstall: $(cat "$TMP/out")"

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS failure(s)" >&2
  exit 1
fi
echo "all actions-usage checks passed"
