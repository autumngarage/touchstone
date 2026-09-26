#!/usr/bin/env bash
#
# scripts/touchstone-ci.sh — see how changes flow through the merge queue and CI.
#
# Usage: see usage() below, or `touchstone ci --help`.
#
# `metrics` is read-only. It derives every number from GitHub's own records,
# read with the current gh login:
#
#   - the merge-queue timeline of each pull request updated in the window
#     (GraphQL: enqueue, removal with its reason and candidate commit, and
#     force-push events, plus the head commit), paged newest-updated first
#     and stopped at the window start;
#   - the window's merge_group runs (one REST page per 100 runs), and the
#     job list of each run a metric reads: the runs of every successful
#     candidate, and of every candidate whose ejection is counted;
#   - one page of workflow_dispatch runs on the default branch, for the
#     nightly.
#
# Pull-request runs are not read: no metric needs them, and a head's history
# comes from the timeline. Job lists of a completed run attempt never change,
# so they are cached on disk by run id and attempt; a repeated window reads
# only what is new.
#
# Every agent on a machine shares one GitHub quota. Before each phase the
# script reads `gh api rate_limit` (which costs nothing) and refuses, with
# exit 2, a read that would leave less than RESERVE_PERCENT of the REST or
# GraphQL limit; it never retries into a limit.
#
# The metric definitions are documented in README.md (CI flow metrics) and
# pinned by tests/test-ci-metrics.sh.
#
# Exit status: 0 the report printed; 2 invalid input, a refused window, or a
# read that could not complete — never a partial report.
set -euo pipefail

SCHEMA="touchstone.ci-metrics/v1"
DEFAULT_DAYS=1
DEFAULT_NIGHTLY_WORKFLOW="macOS"
# A shard's test step, by exact name: shard balance compares these steps, and
# one that fails after WATCHDOG_MINUTES is the test watchdog's signature.
TEST_STEP="Test"
WATCHDOG_MINUTES=45
# Share of each GitHub quota left untouched for the other agents on this machine.
RESERVE_PERCENT=10
PR_PAGE_SIZE=50
TIMELINE_PAGE_SIZE=100
RUN_PAGE_SIZE=100
# GitHub's run listing returns at most 1,000 results for a filtered query.
RUN_LIST_CAP=1000

usage() {
  cat <<EOF
Usage:
  touchstone ci metrics [--repo OWNER/NAME]... [--since DATE | --days N] [--until DATE]
                        [--nightly-workflow NAME] [--json]

metrics  Read each repository's merge-queue timeline and merge_group and
         workflow_dispatch runs with the current gh login, and report queue
         lead time, first-pass rate, ejections by cause, candidate build time
         by stage, shard balance, the nightly result and green streak, and
         throughput for the window. Read-only.
  --repo OWNER/NAME        repeatable; default: the current directory's repository
  --since DATE             window start: YYYY-MM-DD (00:00 UTC) or YYYY-MM-DDTHH:MM:SSZ
  --days N                 the N days before --until (default $DEFAULT_DAYS); not with --since
  --until DATE             window end, exclusive (default: now)
  --nightly-workflow NAME  the workflow whose workflow_dispatch runs on the default
                           branch are the nightly (default $DEFAULT_NIGHTLY_WORKFLOW)
  --json                   print the versioned JSON report ($SCHEMA)

Job lists of completed runs are cached under \${XDG_CACHE_HOME:-~/.cache}/touchstone/ci-metrics.
A window whose reads would leave less than $RESERVE_PERCENT% of the REST or GraphQL
quota is refused; narrow it or retry after the reset.

Exit status: 0 the report printed; 2 invalid input, a refused window, or a
read that could not complete.
EOF
}

die_usage() {
  echo "ERROR: $*" >&2
  echo "Run 'touchstone ci --help' for usage." >&2
  exit 2
}
die() {
  echo "ERROR: $*" >&2
  exit 2
}

ACTION="${1:-}"
[ "$#" -gt 0 ] && shift
case "$ACTION" in
  -h | --help | help)
    usage
    exit 0
    ;;
  metrics) ;;
  *) die_usage "unknown ci command '${ACTION:-<none>}'; available: metrics" ;;
esac

REPOS=()
REPO_COUNT=0
SINCE=""
DAYS=""
UNTIL=""
NIGHTLY_WORKFLOW="$DEFAULT_NIGHTLY_WORKFLOW"
JSON=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON=true
      shift
      continue
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --repo | --since | --days | --until | --nightly-workflow)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "$1 requires a value"
      ;;
    *) die_usage "unknown option '$1' for 'ci metrics'" ;;
  esac
  case "$1" in
    --repo)
      # Interpolated into API paths and the cache path.
      printf '%s' "$2" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
        || die_usage "--repo must be OWNER/NAME, got '$2'"
      case "$2" in */. | */.. | ./* | ../*) die_usage "--repo must be OWNER/NAME, got '$2'" ;; esac
      REPOS+=("$2")
      REPO_COUNT=$((REPO_COUNT + 1))
      ;;
    --since) SINCE="$2" ;;
    --days)
      case "$2" in *[!0-9]* | 0*) die_usage "--days requires a positive whole number, got '$2'" ;; esac
      DAYS="$2"
      ;;
    --until) UNTIL="$2" ;;
    --nightly-workflow) NIGHTLY_WORKFLOW="$2" ;;
  esac
  shift 2
done
[ -z "$SINCE" ] || [ -z "$DAYS" ] || die_usage "--since and --days are alternatives; pass one"
[ -n "$DAYS" ] || DAYS="$DEFAULT_DAYS"

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

# All date math is jq's, so it is the same under BSD and GNU userlands.
DATE_JQ='
def instant($v): if ($v | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then $v + "T00:00:00Z"
  elif ($v | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) then $v
  else error("format") end
  | . as $iso | fromdateiso8601 | if todate != $iso then error("not a calendar date") else . end;'
parse_instant() {
  jq -rn --arg v "$2" "$DATE_JQ"'instant($v)' 2>/dev/null \
    || die_usage "$1 must be a UTC date YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, got '$2'"
}
if [ -n "$UNTIL" ]; then
  UNTIL_EPOCH="$(parse_instant --until "$UNTIL")"
else
  UNTIL_EPOCH="$(jq -n 'now | floor')"
fi
if [ -n "$SINCE" ]; then
  SINCE_EPOCH="$(parse_instant --since "$SINCE")"
else
  SINCE_EPOCH=$((UNTIL_EPOCH - DAYS * 86400))
fi
[ "$SINCE_EPOCH" -lt "$UNTIL_EPOCH" ] || die_usage "the window is empty: --since must be before --until"
SINCE_ISO="$(jq -rn --argjson t "$SINCE_EPOCH" '$t | todate')"
UNTIL_ISO="$(jq -rn --argjson t "$UNTIL_EPOCH" '$t | todate')"

if [ "$REPO_COUNT" -eq 0 ]; then
  REPOS=("$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null </dev/null)") \
    || die "could not resolve the current directory's repository; pass --repo OWNER/NAME"
  [ -n "${REPOS[0]}" ] || die "could not resolve the current directory's repository; pass --repo OWNER/NAME"
fi

CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:?HOME is not set}/.cache}/touchstone/ci-metrics"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-ci.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
gh_err() { head -c 400 "$TMP/err" | tr '\n' ' '; }

# require_quota RESOURCE NEEDED WHAT: refuse a read that would leave less than
# the reserve. rate_limit itself is free.
require_quota() {
  local resource="$1" needed="$2" what="$3" remaining limit reset reserve
  gh api rate_limit >"$TMP/rate.json" 2>"$TMP/err" </dev/null \
    || die "rate limit read failed: $(gh_err)"
  IFS=$'\t' read -r remaining limit reset < <(jq -r --arg r "$resource" \
    '.resources[$r] | [.remaining, .limit, (.reset | todate)] | @tsv' "$TMP/rate.json") \
    || die "rate limit read carried no $resource quota"
  reserve=$((limit * RESERVE_PERCENT / 100))
  if [ $((remaining - needed)) -lt "$reserve" ]; then
    die "$what needs $needed $resource request(s), but $remaining of $limit remain until $reset and $reserve ($RESERVE_PERCENT%) are left for the other agents on this machine; narrow the window (--days, --since) or retry after the reset"
  fi
}

REST_CALLS=0
# rest PATH OUT: one REST read, counted.
rest() {
  local path="$1" out="$2"
  REST_CALLS=$((REST_CALLS + 1))
  gh api "$path" >"$out" 2>"$TMP/err" </dev/null \
    || die "read failed for $REPO ($path): $(gh_err)"
}

EVENT_JQ='
def event: if .__typename == "AddedToMergeQueueEvent" then {type: "enqueued", at: .createdAt}
  elif .__typename == "RemovedFromMergeQueueEvent" then
    {type: "removed", at: .createdAt, reason: (.reason // "unspecified"), candidate: (.beforeCommit.oid // null)}
  elif .__typename == "HeadRefForcePushedEvent" then {type: "forcePushed", at: .createdAt}
  else empty end;'
EVENT_FIELDS='__typename
  ... on AddedToMergeQueueEvent { createdAt }
  ... on RemovedFromMergeQueueEvent { createdAt reason beforeCommit { oid } }
  ... on HeadRefForcePushedEvent { createdAt }'
EVENT_TYPES='[ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]'
PR_QUERY="query(\$owner: String!, \$name: String!, \$endCursor: String) {
  repository(owner: \$owner, name: \$name) {
    defaultBranchRef { name }
    pullRequests(first: $PR_PAGE_SIZE, after: \$endCursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number state updatedAt mergedAt headRefOid
        commits(last: 1) { nodes { commit { oid committedDate } } }
        timelineItems(first: $TIMELINE_PAGE_SIZE, itemTypes: $EVENT_TYPES) {
          pageInfo { hasNextPage }
          nodes { $EVENT_FIELDS }
        }
      }
    }
  }
}"
TIMELINE_QUERY="query(\$owner: String!, \$name: String!, \$number: Int!, \$endCursor: String) {
  repository(owner: \$owner, name: \$name) {
    pullRequest(number: \$number) {
      timelineItems(first: $TIMELINE_PAGE_SIZE, after: \$endCursor, itemTypes: $EVENT_TYPES) {
        pageInfo { hasNextPage endCursor }
        nodes { $EVENT_FIELDS }
      }
    }
  }
}"

# Pull requests updated in the window, newest first, with their queue events.
# Every event in the window updated its pull request, so paging stops at the
# first page that reaches back past the window start. A pull request updated
# while the pages are read moves to the front and can be read twice, never
# skipped; it is kept once.
fetch_pull_requests() {
  local cursor="" more last
  : >"$TMP/prs.jsonl"
  while :; do
    require_quota graphql 1 "reading the pull request timeline of $REPO"
    set -- -F owner="$OWNER" -F name="$NAME" -f query="$PR_QUERY"
    [ -z "$cursor" ] || set -- "$@" -f endCursor="$cursor"
    gh api graphql "$@" >"$TMP/page.json" 2>"$TMP/err" </dev/null \
      || die "pull request timeline read failed for $REPO: $(gh_err)"
    jq -e '.data.repository.pullRequests.nodes | type == "array"' "$TMP/page.json" >/dev/null 2>&1 \
      || die "pull request timeline read for $REPO returned no pull requests: $(head -c 400 "$TMP/page.json")"
    DEFAULT_BRANCH="$(jq -r '.data.repository.defaultBranchRef.name // empty' "$TMP/page.json")"
    [ -n "$DEFAULT_BRANCH" ] || die "$REPO has no default branch"
    jq -c --argjson since "$SINCE_EPOCH" "$EVENT_JQ"'
      .data.repository.pullRequests.nodes[]
      | select((.updatedAt | fromdateiso8601) >= $since)
      | (.commits.nodes[0].commit // {}) as $head
      | {number, state, mergedAt,
         headCommittedAt: (if $head.oid == .headRefOid then $head.committedDate else null end),
         moreTimeline: .timelineItems.pageInfo.hasNextPage,
         events: [.timelineItems.nodes[] | event]}' "$TMP/page.json" >>"$TMP/prs.jsonl"
    IFS=$'\t' read -r more cursor last < <(jq -r '.data.repository.pullRequests
      | [.pageInfo.hasNextPage, (.pageInfo.endCursor // ""), (.nodes[-1].updatedAt // "")] | @tsv' "$TMP/page.json")
    [ "$more" = true ] || break
    [ -n "$last" ] && [ "$(jq -rn --arg t "$last" '$t | fromdateiso8601')" -ge "$SINCE_EPOCH" ] || break
  done
  # A pull request with more queue events than one timeline page is read in
  # full, never truncated.
  : >"$TMP/timelines.jsonl"
  local number
  while IFS= read -r number; do
    require_quota graphql 2 "reading the full queue timeline of $REPO#$number"
    gh api graphql --paginate -F owner="$OWNER" -F name="$NAME" -F number="$number" \
      -f query="$TIMELINE_QUERY" --jq '.data.repository.pullRequest.timelineItems.nodes[]' \
      >"$TMP/timeline.jsonl" 2>"$TMP/err" </dev/null \
      || die "queue timeline read failed for $REPO#$number: $(gh_err)"
    jq -cs --argjson n "$number" "$EVENT_JQ"'{number: $n, events: map(event)}' "$TMP/timeline.jsonl" >>"$TMP/timelines.jsonl"
  done < <(jq -r 'select(.moreTimeline) | .number' "$TMP/prs.jsonl")
  jq -s --slurpfile full "$TMP/timelines.jsonl" '
    ($full | map({key: (.number | tostring), value: .events}) | from_entries) as $f
    | unique_by(.number) | map(.events = ($f[.number | tostring] // .events) | del(.moreTimeline))' \
    "$TMP/prs.jsonl" >"$TMP/prs.json"
}

RUN_FIELDS='{id, name, headSha: .head_sha, headBranch: .head_branch, attempt: .run_attempt,
  status, conclusion, createdAt: .created_at, updatedAt: .updated_at, url: .html_url}'

# The window's merge_group runs. The first page carries the total, so the cap
# and the quota are checked before the remaining pages are read.
fetch_merge_group_runs() {
  local base total pages page
  base="repos/$REPO/actions/runs?event=merge_group&created=$SINCE_ISO..$UNTIL_ISO&exclude_pull_requests=true&per_page=$RUN_PAGE_SIZE"
  require_quota core 2 "listing the merge_group runs of $REPO"
  rest "$base&page=1" "$TMP/runs-page.json"
  jq -c ".workflow_runs[] | $RUN_FIELDS" "$TMP/runs-page.json" >"$TMP/runs.jsonl"
  total="$(jq '.total_count // 0' "$TMP/runs-page.json")"
  [ "$total" -le "$RUN_LIST_CAP" ] \
    || die "$REPO has $total merge_group runs in the window, more than the $RUN_LIST_CAP GitHub lists for one query; narrow the window (--days, --since)"
  pages=$(((total + RUN_PAGE_SIZE - 1) / RUN_PAGE_SIZE))
  [ "$pages" -le 1 ] || require_quota core "$((pages - 1))" "listing the merge_group runs of $REPO"
  page=2
  while [ "$page" -le "$pages" ]; do
    rest "$base&page=$page" "$TMP/runs-page.json"
    jq -c ".workflow_runs[] | $RUN_FIELDS" "$TMP/runs-page.json" >>"$TMP/runs.jsonl"
    page=$((page + 1))
  done
  RUNS_LISTED="$total"
}

# An ejection whose candidate was built before the window still names its
# candidate; its runs are read by commit so its signatures are not lost.
fetch_ejection_candidates() {
  local sha count
  jq -r --argjson since "$SINCE_EPOCH" --argjson until "$UNTIL_EPOCH" --slurpfile runs <(jq -s . "$TMP/runs.jsonl") '
    ($runs[0] | map(.headSha)) as $known
    | [.[] | .events[] | select(.type == "removed" and .reason != "merged" and .candidate != null)
        | select((.at | fromdateiso8601) as $t | $t >= $since and $t < $until) | .candidate]
    | unique | map(select(. as $c | $known | index($c) | not)) | .[]' "$TMP/prs.json" >"$TMP/missing.txt"
  count="$(grep -c . "$TMP/missing.txt" || true)"
  [ "$count" -eq 0 ] || require_quota core "$count" "reading the candidates of $REPO's ejections"
  while IFS= read -r sha; do
    rest "repos/$REPO/actions/runs?event=merge_group&head_sha=$sha&exclude_pull_requests=true&per_page=$RUN_PAGE_SIZE" "$TMP/cand.json"
    jq -c ".workflow_runs[] | $RUN_FIELDS" "$TMP/cand.json" >>"$TMP/runs.jsonl"
  done <"$TMP/missing.txt"
  jq -s 'unique_by(.id)' "$TMP/runs.jsonl" >"$TMP/runs.json"
}

# The most recent page of workflow_dispatch runs on the default branch created
# up to the window end: the window's nightlies, and the streak before them.
fetch_dispatch_runs() {
  local branch
  branch="$(jq -rn --arg b "$DEFAULT_BRANCH" '$b | @uri')"
  require_quota core 1 "listing the workflow_dispatch runs of $REPO"
  rest "repos/$REPO/actions/runs?event=workflow_dispatch&branch=$branch&created=%3C%3D$UNTIL_ISO&exclude_pull_requests=true&per_page=$RUN_PAGE_SIZE" "$TMP/dispatch-page.json"
  jq ".workflow_runs | map($RUN_FIELDS)" "$TMP/dispatch-page.json" >"$TMP/dispatch.json"
  DISPATCH_FULL_PAGE="$(jq --argjson n "$RUN_PAGE_SIZE" '.workflow_runs | length >= $n' "$TMP/dispatch-page.json")"
  # A full page that does not reach back to the window start would drop the
  # window's earliest nightlies; refuse rather than report them missing.
  if [ "$DISPATCH_FULL_PAGE" = true ] && jq -e --argjson since "$SINCE_EPOCH" \
    'map(.createdAt | fromdateiso8601) | min >= $since' "$TMP/dispatch.json" >/dev/null; then
    die "$REPO has more than $RUN_PAGE_SIZE workflow_dispatch runs on $DEFAULT_BRANCH in the window; narrow the window (--days, --since)"
  fi
}

# Job lists for the runs a metric reads: every run of a successful candidate
# created in the window, and every run of an ejected candidate. Only completed
# runs; a completed attempt is immutable, so it is cached by id and attempt.
fetch_jobs() {
  local id attempt file count
  jq -r --argjson since "$SINCE_EPOCH" --argjson until "$UNTIL_EPOCH" --slurpfile prs "$TMP/prs.json" '
    def passing: . == "success" or . == "neutral" or . == "skipped";
    ([$prs[0][] | .events[] | select(.type == "removed" and .reason != "merged") | .candidate]) as $ejected
    | group_by(.headSha)
    | map(select(
        (all(.[]; .status == "completed" and (.conclusion | passing))
          and ((map(.createdAt | fromdateiso8601) | min) as $c | $c >= $since and $c < $until))
        or (.[0].headSha as $s | $ejected | index($s))))
    | .[][] | select(.status == "completed") | "\(.id) \(.attempt)"' "$TMP/runs.json" >"$TMP/needed.txt"
  CACHE_DIR="$CACHE_ROOT/jobs/$REPO"
  mkdir -p "$CACHE_DIR"
  : >"$TMP/uncached.txt"
  while read -r id attempt; do
    file="$CACHE_DIR/$id-$attempt.json"
    jq -e '.jobs | type == "array"' "$file" >/dev/null 2>&1 || echo "$id $attempt" >>"$TMP/uncached.txt"
  done <"$TMP/needed.txt"
  JOBS_NEEDED="$(grep -c . "$TMP/needed.txt" || true)"
  JOBS_FETCHED="$(grep -c . "$TMP/uncached.txt" || true)"
  count="$JOBS_FETCHED"
  [ "$count" -eq 0 ] || require_quota core "$count" "reading the job lists of $REPO's candidates ($count not cached)"
  # A run deleted after it was listed answers 404: its candidate is left out
  # of every metric and counted, never reported from the runs that remain.
  : >"$TMP/gone.txt"
  while read -r id attempt; do
    file="$CACHE_DIR/$id-$attempt.json"
    REST_CALLS=$((REST_CALLS + 1))
    if ! gh api --paginate "repos/$REPO/actions/runs/$id/attempts/$attempt/jobs?per_page=100" \
      --jq '.jobs[] | {name, status, conclusion, runner_name, created_at, started_at, completed_at,
        steps: [(.steps // [])[] | {name, conclusion, started_at, completed_at}]}' \
      >"$TMP/jobs.jsonl" 2>"$TMP/err" </dev/null; then
      grep -q 'HTTP 404' "$TMP/err" \
        || die "job list read failed for $REPO run $id attempt $attempt: $(gh_err)"
      echo "warning: $REPO run $id was deleted after it was listed; its candidate is left out" >&2
      echo "$id" >>"$TMP/gone.txt"
      continue
    fi
    jq -s '{jobs: .}' "$TMP/jobs.jsonl" >"$file.tmp.$$"
    mv -f "$file.tmp.$$" "$file"
  done <"$TMP/uncached.txt"
  while read -r id attempt; do
    grep -qx "$id" "$TMP/gone.txt" && continue
    jq -c --arg id "$id" '{key: $id, value: .jobs}' "$CACHE_DIR/$id-$attempt.json"
  done <"$TMP/needed.txt" | jq -s 'from_entries' >"$TMP/jobs.json"
  jq -R 'tonumber' "$TMP/gone.txt" | jq -s . >"$TMP/gone.json"
  jq --slurpfile gone "$TMP/gone.json" '
    ([.[] | select(.id as $i | $gone[0] | index($i)) | .headSha] | unique) as $lost
    | map(select(.headSha as $s | $lost | index($s) | not))' "$TMP/runs.json" >"$TMP/runs-kept.json"
  mv -f "$TMP/runs-kept.json" "$TMP/runs.json"
  RUNS_GONE="$(jq length "$TMP/gone.json")"
}

# The metric definitions. Every duration is whole seconds; every percentile is
# nearest-rank (the smallest value with at least p% of the values at or below
# it), the same rule scripts/delivery-metrics.sh reports.
METRICS_JQ='
def ts: if . == null then null else fromdateiso8601 end;
def inwin: . != null and . >= $since and . < $until;
def secs($a; $b): if $a == null or $b == null then null else ($b | ts) - ($a | ts) end;
def rank($p; $n): ((($p * $n) + 99) / 100 | floor) as $i | (if $i < 1 then 1 else $i end) - 1;
def dist: map(select(. != null)) | sort | length as $n
  | if $n == 0 then {count: 0, p50: null, p90: null, max: null}
    else {count: $n, p50: .[rank(50; $n)], p90: .[rank(90; $n)], max: .[$n - 1]} end;
def ratio($a; $b): if $b > 0 then ($a / $b * 1000 + 0.5 | floor) / 1000 else null end;
def passing: . == "success" or . == "neutral" or . == "skipped";
def outcome: if any(.[]; .status != "completed") then "incomplete"
  elif all(.[]; .conclusion | passing) then "success"
  elif all(.[]; (.conclusion | passing) or .conclusion == "cancelled") then "cancelled"
  else "failure" end;
# A step belongs to the first stage its name matches, in this order.
def stage: ascii_downcase
  | if test("checkout") then "checkout"
    elif test("restore|cache") then "restore"
    elif test("release") then "release"
    elif test("test") then "test"
    elif test("build") then "build"
    else null end;
def jobs_of($c): [$c.runs[] | ($jobs[.id | tostring] // [])[] | select(.conclusion != "skipped")];
def stage_secs($js; $name):
  [$js[] | [.steps[] | select((.name | stage) == $name) | secs(.started_at; .completed_at)]
    | map(select(. != null)) | select(length > 0) | add]
  | if length == 0 then null else max end;
def signatures($c): jobs_of($c) as $js
  | [ (if any($js[]; .conclusion == "timed_out") then "timed_out" else empty end),
      (if any($js[] | .steps[]; .name == $testStep and .conclusion == "failure"
            and (secs(.started_at; .completed_at) // 0) >= $watchdog) then "watchdog" else empty end),
      (if any($js[]; .conclusion == "failure"
            and ([.steps[] | select(.conclusion == "failure" or .conclusion == "cancelled"
                   or .conclusion == "timed_out")] | length) == 0) then "runner_lost" else empty end) ];

($runs | group_by(.headSha) | map(
    ([.[0].headBranch // "" | capture("^gh-readonly-queue/.+/pr-(?<pr>[0-9]+)-(?<base>[0-9a-f]{40})$")] | .[0]) as $b
    | {sha: .[0].headSha, base: ($b.base // null), runs: .,
       createdAt: (map(.createdAt | ts) | min), outcome: outcome})) as $candidates
| ($candidates | map({key: .sha, value: .}) | from_entries) as $bySha
| [$candidates[] | select(.createdAt | inwin)] as $windowed
| [$windowed[] | select(.outcome == "success") | . as $c | jobs_of($c) as $js
    | {runnerWait: ([$js[] | secs(.created_at; .started_at)] | map(select(. != null)) | max),
       checkout: stage_secs($js; "checkout"), restore: stage_secs($js; "restore"),
       build: stage_secs($js; "build"), test: stage_secs($js; "test"), release: stage_secs($js; "release"),
       wall: ((([$js[] | .completed_at | ts] | max) // ($c.runs | map(.updatedAt | ts) | max)) - $c.createdAt),
       shards: [$js[] | .steps[] | select(.name == $testStep) | secs(.started_at; .completed_at)
         | select(. != null)]}] as $clean
| [$prs[] | select(.mergedAt | ts | inwin)] as $merged
| [$merged[] | . as $pr | ($pr.mergedAt | ts) as $m
    | [$pr.events[] | select(.type == "enqueued" and (.at | ts) <= $m) | .at | ts] as $enq
    | {lead: (if ($enq | length) > 0 then $m - ($enq | min) else null end),
       ejections: ([$pr.events[] | select(.type == "removed" and .reason != "merged" and (.at | ts) <= $m)] | length)}
  ] as $landed
| [$landed[] | select(.lead != null)] as $queued
| [$prs[] | . as $pr | $pr.events[]
    | select(.type == "removed" and .reason != "merged" and (.at | ts | inwin))
    | (.at | ts) as $t | $bySha[.candidate // ""] as $cand
    | ($cand != null and $cand.base != null and ($bySha[$cand.base].outcome // null) == "failure") as $stacked
    | (if any($pr.events[]; .type == "forcePushed" and (.at | ts) > $t
            and ($pr.mergedAt == null or (.at | ts) <= ($pr.mergedAt | ts))) then true
       elif $pr.headCommittedAt == null then null
       else ($pr.headCommittedAt | ts) > $t end) as $changed
    | {pr: $pr.number, at, reason, candidate,
       cause: (if $stacked then "stacked" elif $changed == true then "defect"
               elif $changed == false and $pr.mergedAt != null then "flake" else "unknown" end),
       signatures: (if $cand != null then signatures($cand) else [] end),
       candidateRead: ($cand != null)}
  ] | sort_by(.at) as $ejections
| ($dispatch | map(select(.name == $nightly and (.createdAt | ts) < $until)) | sort_by(.createdAt) | reverse) as $nightlies
| [$nightlies[] | select(.status == "completed")] as $done
| ([range(0; $done | length) | select($done[.].conclusion != "success")] | .[0]) as $firstRed
| (($until - $since) / 86400) as $days
| {
    repository: $repo,
    defaultBranch: $branch,
    throughput: {
      merged: ($merged | length),
      perDay: (($merged | length) / $days * 100 + 0.5 | floor / 100),
      byDay: ([range($since / 86400 | floor; (($until - 1) / 86400 | floor) + 1) | . * 86400 | todate | .[0:10]]
        | map(. as $d | {key: $d, value: ([$merged[] | select(.mergedAt[0:10] == $d)] | length)}) | from_entries)
    },
    queue: {
      leadTimeSeconds: ($queued | map(.lead) | dist),
      mergedOutsideQueue: (($landed | length) - ($queued | length)),
      firstPass: (([$queued[] | select(.ejections == 0)] | length) as $p
        | {passed: $p, of: ($queued | length), rate: ratio($p; $queued | length)}),
      ejections: {
        total: ($ejections | length),
        byCause: (reduce $ejections[] as $e ({defect: 0, flake: 0, stacked: 0, unknown: 0}; .[$e.cause] += 1)),
        byReason: (reduce $ejections[] as $e ({}; .[$e.reason] += 1)),
        bySignature: (reduce ($ejections[] | .signatures[]) as $s ({timed_out: 0, watchdog: 0, runner_lost: 0}; .[$s] += 1)),
        items: $ejections
      }
    },
    candidates: (($windowed | map(.outcome)) as $o
      | ([$o[] | select(. == "success")] | length) as $ok
      | ([$o[] | select(. == "failure")] | length) as $bad
      | {
        total: ($o | length), succeeded: $ok, failed: $bad,
        cancelled: ([$o[] | select(. == "cancelled")] | length),
        incomplete: ([$o[] | select(. == "incomplete")] | length),
        passRate: ratio($ok; $ok + $bad),
        stageSeconds: {
          runnerWait: ($clean | map(.runnerWait) | dist), checkout: ($clean | map(.checkout) | dist),
          restore: ($clean | map(.restore) | dist), build: ($clean | map(.build) | dist),
          test: ($clean | map(.test) | dist), release: ($clean | map(.release) | dist),
          wall: ($clean | map(.wall) | dist)
        },
        shards: {
          testStepSeconds: ([$clean[] | .shards[]] | dist),
          spreadSeconds: ([$clean[] | select((.shards | length) >= 2) | (.shards | max) - (.shards | min)] | dist)
        }
      }),
    nightly: {
      workflow: $nightly,
      runs: [$nightlies[] | select(.createdAt | ts | inwin) | {id, createdAt, status, conclusion, url}] | reverse,
      greenStreak: ($firstRed // ($done | length)),
      greenStreakIsLowerBound: ($firstRed == null and $dispatchFull)
    },
    collection: $collection
  }'

compute_repository() {
  jq -n --arg repo "$REPO" --arg branch "$DEFAULT_BRANCH" --arg nightly "$NIGHTLY_WORKFLOW" \
    --arg testStep "$TEST_STEP" --argjson watchdog "$((WATCHDOG_MINUTES * 60))" \
    --argjson since "$SINCE_EPOCH" --argjson until "$UNTIL_EPOCH" \
    --argjson dispatchFull "$DISPATCH_FULL_PAGE" \
    --argjson collection "$(jq -n --argjson p "$(jq length "$TMP/prs.json")" --argjson r "$RUNS_LISTED" \
      --argjson n "$JOBS_NEEDED" --argjson f "$JOBS_FETCHED" --argjson c "$REST_CALLS" --argjson g "$RUNS_GONE" \
      '{pullRequestsRead: $p, mergeGroupRunsListed: $r, jobListsRead: $n, jobListsFetched: $f,
        runsDeletedWhileRead: $g, restRequests: $c}')" \
    --slurpfile prsIn "$TMP/prs.json" --slurpfile runsIn "$TMP/runs.json" \
    --slurpfile dispatchIn "$TMP/dispatch.json" --slurpfile jobsIn "$TMP/jobs.json" \
    '$prsIn[0] as $prs | $runsIn[0] as $runs | $dispatchIn[0] as $dispatch | $jobsIn[0] as $jobs | '"$METRICS_JQ"
}

: >"$TMP/report.jsonl"
for REPO in "${REPOS[@]}"; do
  OWNER="${REPO%%/*}"
  NAME="${REPO#*/}"
  REST_CALLS=0
  fetch_pull_requests
  fetch_merge_group_runs
  fetch_ejection_candidates
  fetch_dispatch_runs
  fetch_jobs
  compute_repository >>"$TMP/report.jsonl"
done

jq -s --arg schema "$SCHEMA" --argjson since "$SINCE_EPOCH" --argjson until "$UNTIL_EPOCH" \
  --arg nightly "$NIGHTLY_WORKFLOW" --arg testStep "$TEST_STEP" --argjson watchdog "$((WATCHDOG_MINUTES * 60))" '
  {schema: $schema, generatedAt: (now | floor | todate),
   window: {since: ($since | todate), until: ($until | todate), days: (($until - $since) / 86400 * 100 + 0.5 | floor / 100)},
   definitions: {percentile: "nearest-rank", testStep: $testStep, watchdogSeconds: $watchdog, nightlyWorkflow: $nightly},
   repositories: .}' "$TMP/report.jsonl" >"$TMP/report.json"

if [ "$JSON" = true ]; then
  cat "$TMP/report.json"
  exit 0
fi

jq -r '
def lpad($w): tostring | if length < $w then (" " * ($w - length)) + . else . end;
def rpad($w): tostring | if length < $w then . + (" " * ($w - length)) else . end;
def tenths: (. * 10 + 0.5 | floor) as $t | "\($t / 10 | floor).\($t % 10)";
def dur: if . == null then "-" elif . < 3600 then "\(. / 60 | tenths)m" else "\(. / 3600 | tenths)h" end;
def pct: if . == null then "-" else "\(. * 100 + 0.5 | floor)%" end;
def counts: to_entries | map("\(.value) \(.key)") | join(", ");
def row($label; $d): "    \($label | rpad(18)) \($d.p50 | dur | lpad(7)) \($d.p90 | dur | lpad(7)) \($d.max | dur | lpad(7))  (\($d.count))";
.window as $w
| .repositories[]
| "\(.repository)  \($w.since) .. \($w.until) (\($w.days) days)",
  "  merged              \(.throughput.merged) (\(.throughput.perDay)/day); \(.queue.mergedOutsideQueue) outside the queue",
  "  queue lead time     p50 \(.queue.leadTimeSeconds.p50 | dur)  p90 \(.queue.leadTimeSeconds.p90 | dur)  max \(.queue.leadTimeSeconds.max | dur)",
  "  first pass          \(.queue.firstPass.passed) of \(.queue.firstPass.of) (\(.queue.firstPass.rate | pct))",
  "  ejections           \(.queue.ejections.total): \(.queue.ejections.byCause | counts)",
  (if .queue.ejections.total > 0 then
    "    by reason         \(.queue.ejections.byReason | counts)",
    "    signatures        \(.queue.ejections.bySignature | counts)"
   else empty end),
  "  candidates          \(.candidates.succeeded) of \(.candidates.succeeded + .candidates.failed) passed (\(.candidates.passRate | pct)); \(.candidates.cancelled) cancelled, \(.candidates.incomplete) incomplete",
  "  successful candidates     p50     p90     max",
  row("runner wait"; .candidates.stageSeconds.runnerWait),
  row("checkout"; .candidates.stageSeconds.checkout),
  row("restore"; .candidates.stageSeconds.restore),
  row("build"; .candidates.stageSeconds.build),
  row("test"; .candidates.stageSeconds.test),
  row("release"; .candidates.stageSeconds.release),
  row("wall"; .candidates.stageSeconds.wall),
  row("shard test step"; .candidates.shards.testStepSeconds),
  row("shard spread"; .candidates.shards.spreadSeconds),
  "  nightly \(.nightly.workflow | rpad(11)) \(if (.nightly.runs | length) == 0 then "no runs in the window" else (.nightly.runs | map("\(.createdAt[0:10]) \(.conclusion // .status)") | join(", ")) end); green streak \(.nightly.greenStreak)\(if .nightly.greenStreakIsLowerBound then "+" else "" end)",
  ""' "$TMP/report.json"
