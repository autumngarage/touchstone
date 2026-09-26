#!/usr/bin/env bash
# tests/test-ci-metrics.sh — `touchstone ci metrics` derives merge-queue and CI
# flow metrics from GitHub's own records, with pinned definitions.
#
# Offline and date-independent: a fake gh serves tests/fixtures/ci-metrics-2026-09.json,
# a scenario expanded here into GitHub's GraphQL timeline and REST run and job
# shapes, and every run pins --since and --until. Expected values are computed
# by hand from the scenario; the fixture's comment says how to read it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/ci-metrics-2026-09.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-ci-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ERRORS=0
ok() { echo "  OK: $*"; }
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

STATE="$TMP/state"
mkdir -p "$TMP/bin" "$STATE"

# expand: the scenario spec -> the shapes GitHub returns.
jq '
def sha($t): ($t + ("0" * 40))[0:40];
def t: fromdateiso8601;
def job($created): . as $j | ($created + ($j.after // 10)) as $c | ($c + ($j.wait // 0)) as $s
  | (reduce ($j.steps // [])[] as $st ({at: $s, out: []};
      .out += [{name: $st[0], status: "completed", conclusion: ($st[2] // "success"), number: ((.out | length) + 1),
                started_at: (.at | todate), completed_at: ((.at + $st[1]) | todate)}] | .at += $st[1])) as $r
  | {id: 0, name: $j.name, status: "completed", conclusion: ($j.conclusion // "success"), runner_name: "runner-1",
     labels: ["self-hosted"], created_at: ($c | todate), started_at: ($s | todate), completed_at: ($r.at | todate), steps: $r.out};
def clean($w; $t1; $t2): [
  {name: "Build and test (1)", wait: $w, steps: [["Checkout prospective merge", 20], ["Restore SwiftPM build", 30], ["Build", 200], ["Test", $t1]]},
  {name: "Build and test (2)", wait: 10, steps: [["Checkout prospective merge", 20], ["Restore SwiftPM build", 30], ["Build", 200], ["Test", $t2]]}];
. as $s
| {repository, defaultBranch,
   prs: [.pullRequests[] | . as $p | sha("f\($p.number)") as $head
     | {number, state, updatedAt, mergedAt: ($p.mergedAt // null), headRefOid: $head,
        commits: {nodes: [{commit: {oid: $head, committedDate: $p.headCommittedAt}}]},
        split: ($p.splitTimeline // false),
        events: [$p.events[] | if .[0] == "enqueued" then {__typename: "AddedToMergeQueueEvent", createdAt: .[1]}
          elif .[0] == "removed" then {__typename: "RemovedFromMergeQueueEvent", createdAt: .[1], reason: .[2],
            beforeCommit: (if .[3] then {oid: sha(.[3])} else null end)}
          else {__typename: "HeadRefForcePushedEvent", createdAt: .[1]} end]}],
   runs: [.runs[] | . as $r | ($r.created | t) as $c | ($r.status // "completed") as $status
     | ((if $r.clean then clean($r.clean[0]; $r.clean[1]; $r.clean[2]) else $r.jobs end) | map(job($c))) as $jobs
     | {id: $r.id, event: "merge_group", name: $r.name, head_sha: sha($r.candidate),
        head_branch: "gh-readonly-queue/main/pr-\($r.pr)-\(sha($r.base))", run_attempt: ($r.attempt // 1),
        status: $status, conclusion: (if $status == "completed" then $r.conclusion else null end),
        created_at: $r.created, run_started_at: $r.created,
        updated_at: ((([$jobs[].completed_at | t] | max) // $c) + 5 | todate),
        html_url: "https://github.com/\($s.repository)/actions/runs/\($r.id)", jobs: $jobs}],
   dispatch: [.dispatch[] | {id, name, event: "workflow_dispatch", head_branch: "main",
     status: (.status // "completed"), conclusion: (.conclusion // null), created_at: .created,
     updated_at: .created, html_url: "https://github.com/example-org/app/actions/runs/\(.id)"}]}' \
  "$FIXTURE" >"$STATE/scenario.json"

cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
S="$GH_FAKE_STATE"
if [ "$1 $2" = "repo view" ]; then
  jq -r .repository "$S/scenario.json"
  exit 0
fi
[ "$1" = api ] || { echo "unhandled fake gh call: $*" >&2; exit 1; }
shift
path="" jqexpr="" number="" cursor="" paginate=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true; shift ;;
    --jq) jqexpr="$2"; shift 2 ;;
    -F | -f)
      case "$2" in number=*) number="${2#number=}" ;; endCursor=*) cursor="${2#endCursor=}" ;; esac
      shift 2
      ;;
    *) path="$1"; shift ;;
  esac
done
printf '%s number=%s cursor=%s paginate=%s\n' "$path" "$number" "$cursor" "$paginate" >>"$S/calls"
out() { if [ -n "$jqexpr" ]; then jq -c "$jqexpr"; else cat; fi; }
case "$path" in
  rate_limit) cat "$S/rate.json" ;;
  graphql)
    [ -f "$S/graphql-down" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    if [ -n "$number" ]; then
      jq --argjson n "$number" '{data: {repository: {pullRequest: {timelineItems: {
          pageInfo: {hasNextPage: false, endCursor: null},
          nodes: (.prs[] | select(.number == $n) | .events)}}}}}' "$S/scenario.json" | out
    else
      # Three pull requests a page, newest-updated first; the cursor is an
      # offset. With page-overlap, each later page starts one early, as when a
      # pull request is updated while the pages are read.
      at="${cursor:-0}"
      [ -f "$S/page-overlap" ] && [ "$at" -gt 0 ] && at=$((at - 1))
      jq --argjson at "$at" '(.prs | sort_by(.updatedAt) | reverse) as $all
        | {data: {repository: {defaultBranchRef: {name: .defaultBranch}, pullRequests: {
            pageInfo: {hasNextPage: (($at + 3) < ($all | length)), endCursor: (($at + 3) | tostring)},
            nodes: [$all[$at:$at + 3][] | {number, state, updatedAt, mergedAt, headRefOid, commits,
              timelineItems: {pageInfo: {hasNextPage: .split},
                nodes: (if .split then .events[0:2] else .events end)}}]}}}}' "$S/scenario.json" | out
    fi
    ;;
  repos/*/actions/runs/*/attempts/*/jobs\?*)
    id="${path#*/actions/runs/}"
    id="${id%%/*}"
    [ -f "$S/jobs-down-$id" ] && { echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; }
    [ -f "$S/gone-$id" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq --argjson id "$id" '.runs[] | select(.id == $id) | {total_count: (.jobs | length), jobs: .jobs}' "$S/scenario.json" | out
    ;;
  repos/*/actions/runs\?*)
    jq --arg path "$path" --slurpfile over <(cat "$S/total-override" 2>/dev/null || echo null) '
      ($path | ltrimstr("repos/") | split("/actions/")[0]) as $repo
      | ($path | split("?")[1] | split("&") | map(index("=") as $i
          | {key: .[0:$i], value: (.[$i + 1:] | gsub("%3C"; "<") | gsub("%3D"; "="))}) | from_entries) as $q
      | (if $q.event == "workflow_dispatch" then .dispatch else .runs end)
      | map(select(.event == $q.event and (.repo // "example-org/app") == $repo) | del(.jobs, .repo))
      | (if $q.created == null then .
         elif ($q.created | startswith("<=")) then ($q.created[2:]) as $u | map(select(.created_at <= $u))
         else ($q.created | split("..")) as $r | map(select(.created_at >= $r[0] and .created_at <= $r[1])) end)
      | (if $q.head_sha then map(select(.head_sha == $q.head_sha)) else . end)
      | (if $q.branch then map(select(.head_branch == $q.branch)) else . end)
      | sort_by(.created_at) | reverse
      | ($q.per_page | tonumber) as $pp | (($q.page // "1") | tonumber) as $pg
      | {total_count: ($over[0] // length), workflow_runs: .[($pg - 1) * $pp:$pg * $pp]}' "$S/scenario.json" | out
    ;;
  *) echo "unhandled fake gh call: api $path" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_FAKE_STATE="$STATE" XDG_CACHE_HOME="$TMP/cache"

rate() {
  jq -n --argjson core "$1" --argjson graphql "$2" \
    '{resources: {core: {limit: 5000, remaining: $core, reset: 1790500000},
                  graphql: {limit: 5000, remaining: $graphql, reset: 1790500000}}}' >"$STATE/rate.json"
}
rate 4000 4000
WINDOW=(--since 2026-09-25 --until 2026-09-27)
metrics() {
  : >"$STATE/calls"
  set +e
  bash "$ROOT/bin/touchstone" ci metrics "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  set -e
}
# field JQ: one value of the first repository's report.
field() { jq -c ".repositories[0] | $1" "$TMP/out"; }
expect() {
  local got
  got="$(field "$1")"
  [ "$got" = "$2" ] && ok "$3" || fail "$3: $1 is $got, expected $2"
}

echo "==> typical window: every metric, from the scenario"
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 0 ] && ok "exit 0" || fail "exit $RC: $(cat "$TMP/err")"
cp "$TMP/out" "$TMP/first.json"
[ "$(jq -r .schema "$TMP/out")" = touchstone.ci-metrics/v1 ] && ok "versioned schema" || fail "schema: $(jq -c .schema "$TMP/out")"
[ "$(jq -c 'keys' "$TMP/out")" = '["definitions","generatedAt","repositories","schema","window"]' ] \
  && [ "$(field keys)" = '["candidates","collection","defaultBranch","nightly","queue","repository","throughput"]' ] \
  && ok "the report's shape is exactly the documented one" || fail "shape: $(jq -c 'keys, (.repositories[0] | keys)' "$TMP/out")"
[ "$(jq -c .window "$TMP/out")" = '{"since":"2026-09-25T00:00:00Z","until":"2026-09-27T00:00:00Z","days":2}' ] \
  && ok "window" || fail "window: $(jq -c .window "$TMP/out")"
[ "$(jq -c .definitions "$TMP/out")" = '{"percentile":"nearest-rank","testStep":"Test","watchdogSeconds":2700,"nightlyWorkflow":"macOS"}' ] \
  && ok "definitions travel with the numbers" || fail "definitions: $(jq -c .definitions "$TMP/out")"

expect .throughput '{"merged":8,"perDay":4,"byDay":{"2026-09-25":7,"2026-09-26":1}}' \
  "throughput: merges in the window, per day, every UTC day of the window"
# Seven PRs merged through the queue: 1800 5400 5400 6000 6240 7200 7200.
# #109 was first enqueued before the window and still counts from that enqueue.
expect .queue.leadTimeSeconds '{"count":7,"p50":6000,"p90":7200,"max":7200}' \
  "queue lead time is first enqueue to merge, nearest-rank p50/p90"
expect .queue.mergedOutsideQueue 1 "a merge that never entered the queue is counted, not timed"
expect .queue.firstPass '{"passed":2,"of":7,"rate":0.286}' "first pass: merged with no ejection"

echo "==> ejections by cause: the pinned definitions"
cause() { field ".queue.ejections.items[] | select(.pr == $1) | .cause"; }
[ "$(cause 102)" = '"flake"' ] && ok "#102 ejected, then merged at the same head: flake" || fail "#102 is $(cause 102)"
[ "$(cause 111)" = '"flake"' ] && ok "#111 ejected in the window from a candidate built before it: flake" || fail "#111 is $(cause 111)"
[ "$(cause 103)" = '"defect"' ] && ok "#103's head changed (a new commit) before it merged: defect" || fail "#103 is $(cause 103)"
[ "$(cause 104)" = '"defect"' ] \
  && ok "#104 was force-pushed after its ejection: defect (its timeline spans two pages, read in full)" \
  || fail "#104 is $(cause 104); a flake here means the second timeline page was not read"
[ "$(cause 105)" = '"stacked"' ] && ok "#105's candidate was built on #104's failed candidate: stacked" || fail "#105 is $(cause 105)"
[ "$(cause 106)" = '"unknown"' ] && ok "#106 is still open at the same head: unknown" || fail "#106 is $(cause 106)"
[ "$(cause 110)" = '"defect"' ] && ok "#110 changed head after a merge conflict: defect" || fail "#110 is $(cause 110)"
[ "$(field '[.queue.ejections.items[] | select(.pr == 107 or .pr == 101 or .pr == 109)] | length')" = 0 ] \
  && ok "merged removals and ejections outside the window are not ejections" || fail "ejections: $(field .queue.ejections.items)"
expect '.queue.ejections | del(.items)' \
  '{"total":7,"byCause":{"defect":3,"flake":2,"stacked":1,"unknown":1},"byReason":{"failed_checks":5,"checks_timed_out":1,"merge_conflict":1},"bySignature":{"timed_out":2,"watchdog":1,"runner_lost":1}}' \
  "ejection totals by cause, by GitHub's removal reason, and by signature"
sigs() { field ".queue.ejections.items[] | select(.pr == $1) | .signatures"; }
[ "$(sigs 102)" = '["watchdog"]' ] && ok "a Test step that fails after 45 minutes is the watchdog" || fail "#102 signatures $(sigs 102)"
[ "$(sigs 103)" = '[]' ] && ok "a Test step that fails quickly has no signature" || fail "#103 signatures $(sigs 103)"
[ "$(sigs 104)" = '["timed_out"]' ] && ok "a timed_out job is its own signature, not the watchdog" || fail "#104 signatures $(sigs 104)"
[ "$(sigs 106)" = '["runner_lost"]' ] && ok "a job that failed with no failed step lost its runner" || fail "#106 signatures $(sigs 106)"
[ "$(sigs 111)" = '["timed_out"]' ] && ok "the pre-window candidate was read by commit for its signature" || fail "#111 signatures $(sigs 111)"
[ "$(field '.queue.ejections.items[] | select(.pr == 110) | [.candidate, .candidateRead]')" = '[null,false]' ] \
  && ok "an ejection with no candidate says so" || fail "#110: $(field '.queue.ejections.items[] | select(.pr == 110)')"
[ "$(field '[.queue.ejections.items[].at] == ([.queue.ejections.items[].at] | sort)')" = true ] \
  && ok "items are in time order" || fail "items unordered"

echo "==> candidates: outcome, stage times, shard balance"
expect '.candidates | del(.stageSeconds, .shards)' \
  '{"total":13,"succeeded":6,"failed":5,"cancelled":1,"incomplete":1,"passRate":0.545}' \
  "candidates created in the window by outcome; the pass rate excludes cancelled and incomplete"
expect .candidates.stageSeconds.runnerWait '{"count":6,"p50":45,"p90":600,"max":600}' "runner wait: a candidate's longest job created-to-started"
expect .candidates.stageSeconds.checkout '{"count":6,"p50":20,"p90":30,"max":30}' "checkout"
expect .candidates.stageSeconds.restore '{"count":6,"p50":30,"p90":60,"max":60}' "restore"
expect .candidates.stageSeconds.build '{"count":6,"p50":200,"p90":300,"max":300}' "build"
expect .candidates.stageSeconds.test '{"count":6,"p50":500,"p90":700,"max":700}' "test: a job's test steps summed, the slowest job counted"
expect .candidates.stageSeconds.release '{"count":1,"p50":120,"p90":120,"max":120}' \
  "release: 'Build the Release bundle' is release, and candidates without the stage are not zeros"
expect .candidates.stageSeconds.wall '{"count":6,"p50":770,"p90":1265,"max":1265}' \
  "wall: first run created to last job completed, across every workflow of the candidate"
expect .candidates.shards.testStepSeconds '{"count":12,"p50":400,"p90":600,"max":700}' "every shard's Test step"
expect .candidates.shards.spreadSeconds '{"count":6,"p50":100,"p90":400,"max":400}' "shard spread: max minus min Test step per candidate"

echo "==> nightly and collection"
expect .nightly '{"workflow":"macOS","runs":[{"id":9003,"createdAt":"2026-09-25T10:00:07Z","status":"completed","conclusion":"success","url":"https://github.com/example-org/app/actions/runs/9003"},{"id":9005,"createdAt":"2026-09-26T10:00:07Z","status":"completed","conclusion":"success","url":"https://github.com/example-org/app/actions/runs/9005"},{"id":9006,"createdAt":"2026-09-26T23:00:00Z","status":"in_progress","conclusion":null,"url":"https://github.com/example-org/app/actions/runs/9006"}],"greenStreak":3,"greenStreakIsLowerBound":false}' \
  "nightly: the named workflow's runs in the window; the streak counts back past the window, to the window end"
expect .collection '{"pullRequestsRead":10,"mergeGroupRunsListed":14,"jobListsRead":13,"jobListsFetched":13,"runsDeletedWhileRead":0,"restRequests":16}' \
  "collection states what was read"
[ "$(grep -c '^graphql number= ' "$STATE/calls")" -eq 4 ] \
  && ok "pull request paging stops at the first page that reaches past the window start" \
  || fail "graphql pages: $(grep '^graphql' "$STATE/calls")"
[ "$(grep -c '^graphql number=104 ' "$STATE/calls")" -eq 1 ] && ok "only the split timeline is re-read" \
  || fail "timeline reads: $(grep '^graphql' "$STATE/calls")"
! grep -q 'runs/1071/' "$STATE/calls" && ok "an incomplete run's jobs are not read" || fail "read an in-progress run's jobs"
! grep -q 'runs/1081/' "$STATE/calls" && ok "a cancelled candidate's jobs are not read" || fail "read a cancelled candidate's jobs"
! grep -q 'event=pull_request' "$STATE/calls" && ok "pull request runs are never listed" || fail "listed pull_request runs"
[ -f "$XDG_CACHE_HOME/touchstone/ci-metrics/jobs/example-org/app/1001-1.json" ] \
  && ok "job lists are cached by run id and attempt" || fail "no cache file: $(find "$XDG_CACHE_HOME" -type f | head -3)"

echo "==> repeat: completed runs come from the cache, and the numbers do not move"
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 0 ] && ! grep -q '/jobs?' "$STATE/calls" \
  && ok "a repeated window reads no job list" || fail "repeat (rc=$RC): $(grep '/jobs?' "$STATE/calls" | head -3)"
expect '.collection | [.jobListsFetched, .restRequests]' '[0,3]' "the repeat costs three REST requests"
[ "$(jq -S 'del(.generatedAt, .repositories[].collection)' "$TMP/out")" = "$(jq -S 'del(.generatedAt, .repositories[].collection)' "$TMP/first.json")" ] \
  && ok "the cached report equals the fetched one" || fail "the report changed on repeat"
echo 'not json' >"$XDG_CACHE_HOME/touchstone/ci-metrics/jobs/example-org/app/1001-1.json"
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 0 ] && [ "$(grep -c '/jobs?' "$STATE/calls")" -eq 1 ] && grep -q 'runs/1001/attempts/1/jobs' "$STATE/calls" \
  && ok "an unreadable cache entry is read again, not trusted" || fail "corrupt cache (rc=$RC): $(grep '/jobs?' "$STATE/calls")"

echo "==> the table"
metrics --repo example-org/app "${WINDOW[@]}"
[ "$RC" -eq 0 ] || fail "table exit $RC: $(cat "$TMP/err")"
for line in \
  'example-org/app  2026-09-25T00:00:00Z .. 2026-09-27T00:00:00Z (2 days)' \
  '  merged              8 (4/day); 1 outside the queue' \
  '  queue lead time     p50 1.7h  p90 2.0h  max 2.0h' \
  '  first pass          2 of 7 (29%)' \
  '  ejections           7: 3 defect, 2 flake, 1 stacked, 1 unknown' \
  '    by reason         5 failed_checks, 1 checks_timed_out, 1 merge_conflict' \
  '    signatures        2 timed_out, 1 watchdog, 1 runner_lost' \
  '  candidates          6 of 11 passed (55%); 1 cancelled, 1 incomplete' \
  '    runner wait           0.8m   10.0m   10.0m  (6)' \
  '    wall                 12.8m   21.1m   21.1m  (6)' \
  '    shard spread          1.7m    6.7m    6.7m  (6)' \
  '  nightly macOS       2026-09-25 success, 2026-09-26 success, 2026-09-26 in_progress; green streak 3'; do
  grep -qxF -- "$line" "$TMP/out" && ok "table: ${line#"${line%%[! ]*}"}" || fail "table lacks '$line': $(cat "$TMP/out")"
done

echo "==> small: an empty window is zeros and nulls, not an error"
metrics --repo example-org/app --since 2026-09-21 --until 2026-09-22 --json
[ "$RC" -eq 0 ] && ok "exit 0" || fail "empty window exit $RC: $(cat "$TMP/err")"
expect '[.throughput.merged, .queue.leadTimeSeconds, .queue.firstPass.rate, .queue.ejections.total, .candidates.total, .candidates.passRate, .candidates.stageSeconds.wall.p50, .nightly.runs, .nightly.greenStreak]' \
  '[0,{"count":0,"p50":null,"p90":null,"max":null},null,0,0,null,null,[],0]' "empty window"

echo "==> large: run lists past one page, and more than one repository"
jq '.runs += [range(0; 150) as $i | {repo: "example-org/big", id: (5000 + $i), event: "merge_group", name: "macOS",
    head_sha: ("e" + (1000 + $i | tostring) + ("0" * 40))[0:40], head_branch: "gh-readonly-queue/main/pr-900-\("0" * 40)",
    run_attempt: 1, status: "completed", conclusion: "cancelled", created_at: "2026-09-26T22:00:00Z",
    run_started_at: "2026-09-26T22:00:00Z", updated_at: "2026-09-26T22:05:00Z", html_url: "x", jobs: []}]' \
  "$STATE/scenario.json" >"$STATE/large.json"
cp "$STATE/scenario.json" "$STATE/typical.json"
cp "$STATE/large.json" "$STATE/scenario.json"
metrics --repo example-org/big --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 0 ] && ok "exit 0" || fail "large exit $RC: $(cat "$TMP/err")"
[ "$(grep -c 'event=merge_group&created=.*&page=2' "$STATE/calls")" -eq 1 ] \
  && ok "150 runs are read as two pages" || fail "run pages: $(grep 'event=merge_group&created' "$STATE/calls")"
[ "$(jq -c '[.repositories[] | [.repository, .candidates.total, .candidates.cancelled, .collection.mergeGroupRunsListed]]' "$TMP/out")" \
  = '[["example-org/big",150,150,150],["example-org/app",13,1,14]]' ] \
  && ok "each repository counts only its own runs" || fail "large counts: $(jq -c '[.repositories[].candidates]' "$TMP/out")"
cp "$STATE/typical.json" "$STATE/scenario.json"

echo "==> the default repository is the current directory's"
metrics "${WINDOW[@]}" --json
[ "$RC" -eq 0 ] && [ "$(field .repository)" = '"example-org/app"' ] && ok "gh repo view names it" || fail "default repo (rc=$RC): $(cat "$TMP/err")"

echo "==> a pull request read on two pages counts once"
touch "$STATE/page-overlap"
metrics --repo example-org/app "${WINDOW[@]}" --json
rm -f "$STATE/page-overlap"
[ "$RC" -eq 0 ] && [ "$(jq -S 'del(.generatedAt, .repositories[].collection)' "$TMP/out")" = "$(jq -S 'del(.generatedAt, .repositories[].collection)' "$TMP/first.json")" ] \
  && [ "$(field .collection.pullRequestsRead)" = 10 ] \
  && ok "overlapping pages give the same report" || fail "overlap (rc=$RC): $(field '[.throughput, .collection]')"

echo "==> the nightly of a past window is read up to that window's end"
metrics --repo example-org/app --since 2026-09-23 --until 2026-09-24T12:00:00Z --json
[ "$(field '[[.nightly.runs[] | [.id, .conclusion]], .nightly.greenStreak]')" = '[[[9001,"failure"],[9002,"success"]],1]' ] \
  && grep -q 'event=workflow_dispatch&branch=main&created=%3C%3D2026-09-24T12:00:00Z' "$STATE/calls" \
  && ok "past window: its own nightlies and the streak as of its end" \
  || fail "past nightly: $(field .nightly) $(grep workflow_dispatch "$STATE/calls")"
jq '.dispatch += [range(0; 100) as $i | {id: (8000 + $i), name: "macOS", event: "workflow_dispatch", head_branch: "main",
    status: "completed", conclusion: "success", created_at: "2026-09-26T12:00:00Z", updated_at: "2026-09-26T12:00:00Z", html_url: "x"}]' \
  "$STATE/typical.json" >"$STATE/scenario.json"
metrics --repo example-org/app "${WINDOW[@]}" --json
cp "$STATE/typical.json" "$STATE/scenario.json"
[ "$RC" -eq 2 ] && grep -q 'more than 100 workflow_dispatch runs on main in the window' "$TMP/err" \
  && ok "a window with more nightlies than one page is refused, not truncated" || fail "dispatch cap (rc=$RC): $(cat "$TMP/err")"

echo "==> quota: a window that would drain the shared quota is refused before it reads"
rm -rf "$XDG_CACHE_HOME"
rate 505 4000
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 2 ] && grep -q 'needs 13 core request(s), but 505 of 5000 remain until .* and 500 (10%) are left for the other agents' "$TMP/err" \
  && ! grep -q '/jobs?' "$STATE/calls" && [ ! -s "$TMP/out" ] \
  && ok "refused with the arithmetic, no job list read, no report" || fail "core refusal (rc=$RC): $(cat "$TMP/err")"
rate 4000 500
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 2 ] && grep -q 'graphql request(s), but 500 of 5000 remain' "$TMP/err" && ! grep -q '^graphql' "$STATE/calls" \
  && ok "the GraphQL quota is guarded the same way" || fail "graphql refusal (rc=$RC): $(cat "$TMP/err")"
rate 4000 4000
echo 1500 >"$STATE/total-override"
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 2 ] && grep -q '1500 merge_group runs in the window, more than the 1000' "$TMP/err" \
  && ok "a window past GitHub's 1,000-run listing cap is refused, not truncated" || fail "cap (rc=$RC): $(cat "$TMP/err")"
rm -f "$STATE/total-override"

echo "==> partial failure: a failed read is exit 2 and no report; a deleted run is left out"
touch "$STATE/jobs-down-1032"
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 2 ] && grep -q 'job list read failed for example-org/app run 1032.*HTTP 502' "$TMP/err" && [ ! -s "$TMP/out" ] \
  && ok "a failed job list read fails the report" || fail "jobs down (rc=$RC): $(cat "$TMP/err")"
rm -f "$STATE/jobs-down-1032"
touch "$STATE/graphql-down"
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 2 ] && grep -q 'pull request timeline read failed' "$TMP/err" && ok "a failed timeline read fails the report" \
  || fail "graphql down (rc=$RC): $(cat "$TMP/err")"
rm -f "$STATE/graphql-down"
rm -rf "$XDG_CACHE_HOME"
touch "$STATE/gone-1002"
metrics --repo example-org/app "${WINDOW[@]}" --json
[ "$RC" -eq 0 ] && grep -q 'run 1002 was deleted after it was listed' "$TMP/err" \
  && [ "$(field '[.candidates.total, .candidates.succeeded, .candidates.stageSeconds.release.count, .collection.runsDeletedWhileRead]')" = '[12,5,0,1]' ] \
  && ok "a run deleted mid-read drops its whole candidate, visibly" || fail "deleted run (rc=$RC): $(cat "$TMP/err") $(field .candidates)"
rm -f "$STATE/gone-1002"

echo "==> invalid input is refused"
for bad in "--since 2026-09-25 --days 2" "--since 2026-02-30" "--until yesterday" "--days 0" "--days x" \
  "--since 2026-09-27 --until 2026-09-25" "--repo app" "--repo ../x" "--repo example-org/app/x" "--frobnicate"; do
  # shellcheck disable=SC2086 # each case is deliberately several words
  metrics $bad
  [ "$RC" -eq 2 ] && ok "refused: $bad" || fail "accepted $bad (rc=$RC)"
done
set +e
bash "$ROOT/bin/touchstone" ci >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "an action is required" || fail "bare 'ci' was accepted"
bash "$ROOT/bin/touchstone" ci --help >"$TMP/help" 2>&1
[ "$?" -eq 0 ] && grep -q 'touchstone ci metrics \[--repo OWNER/NAME\]' "$TMP/help" \
  && ok "--help documents the command" || fail "--help: $(cat "$TMP/help")"
set -e
bash "$ROOT/bin/touchstone" help | grep -q '^  touchstone ci metrics ' \
  && ok "the CLI usage lists it" || fail "bin/touchstone usage() omits ci metrics"

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS failure(s)" >&2
  exit 1
fi
echo "all ci-metrics checks passed"
