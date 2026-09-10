#!/usr/bin/env bash
#
# scripts/touchstone-usage.sh — see the pace of GitHub Actions usage, not the cliff.
#
# Usage: see usage() below, or `touchstone usage --help`.
#
# `check` is read-only. It reads the enterprise billing usage report with the
# current gh login, converts every Actions minute into included-minute
# equivalents, projects the month at its month-to-date rate, and ranks the
# consumers. GitHub's own notices arrive at 90% and 100% of the allowance,
# after it is gone; this check warns while there is still room to act.
#
# SKU weights are derived from GitHub's rows, never hard-coded: the allowance
# is applied to billing rows as a dollar discount at the included-minute
# price (the price of BASE_SKU below), so a minute of any SKU draws
# pricePerUnit / base price included minutes. Minutes in public repositories
# are free and never draw on the allowance, so they are reported, not counted.
#
# The billing rows carry no workflow or job. The workflow and job ranking
# comes from the Actions API over a bounded sample: the most recent
# --sample-runs completed runs of each of the --top repositories, one run
# list plus one job list per sampled run, so at most TOP x (1 + SAMPLE_RUNS)
# requests (job lists over 100 jobs paginate). The output says how many of
# the month's runs the sample covers.
#
# `install` renders a launchd agent that runs the installed touchstone's
# `usage check --notify` daily, so the check spends no Actions minutes, and
# `uninstall` removes it. Both are macOS-only.
#
# Exit status: 0 the projection is within the threshold; 1 it passes the
# threshold (the warning an agent acts on); 2 invalid input, or a read that
# could not complete — never reported as within the threshold.
set -euo pipefail

# GitHub Enterprise Cloud includes 50,000 Actions minutes a month, denominated
# in standard Linux minutes.
DEFAULT_ALLOWANCE_MINUTES=50000
BASE_SKU="Actions Linux"
# Warn at this share of the allowance, while there is still room to act.
DEFAULT_THRESHOLD_PERCENT=80
# Billing rows are daily aggregates, so a rate over less than a day is noise:
# the month-to-date rate never divides by fewer days than this.
MIN_RATE_DAYS=1
DEFAULT_TOP=5
DEFAULT_SAMPLE_RUNS=20
# The run list is read as one page, and a page holds at most 100 runs.
MAX_SAMPLE_RUNS=100
DEFAULT_HOUR=9
DEFAULT_MINUTE=0
LABEL_PREFIX="com.autumngarage.touchstone.usage"
NOTIFY_TITLE="Touchstone: Actions usage"

usage() {
  cat <<EOF
Usage:
  touchstone usage check --enterprise SLUG [--allowance MINUTES] [--threshold MINUTES]
                         [--as-of DATE] [--top N] [--sample-runs N] [--notify]
  touchstone usage install --enterprise SLUG [--allowance MINUTES] [--threshold MINUTES]
                           [--hour H] [--minute M] [--touchstone PATH] [--dry-run]
  touchstone usage uninstall --enterprise SLUG [--dry-run]

check      Read the enterprise's GitHub billing usage with the current gh login
           and print month-to-date usage in included-minute equivalents, the
           projection to month end at the month-to-date rate, and the top
           consumers by repository, workflow, and job. Read-only.
           --as-of DATE      report as of YYYY-MM-DD (00:00 UTC) or
                             YYYY-MM-DDTHH:MM:SSZ; default: now
           --top N           rows per ranking, and repositories sampled for the
                             workflow and job ranking (default $DEFAULT_TOP)
           --sample-runs N   most recent completed runs sampled per repository
                             (default $DEFAULT_SAMPLE_RUNS, at most $MAX_SAMPLE_RUNS; 0 skips the sample)
           --notify          raise a macOS notification on a warning or failure
install    Write a launchd agent that runs the installed touchstone's
           'usage check --notify' daily at --hour:--minute local time
           (default $DEFAULT_HOUR:$(printf '%02d' "$DEFAULT_MINUTE")), and load it. macOS only.
uninstall  Unload and remove that agent.

--allowance defaults to $DEFAULT_ALLOWANCE_MINUTES included minutes a month; --threshold
defaults to $DEFAULT_THRESHOLD_PERCENT% of the allowance.

Exit status: 0 the projection is within the threshold, 1 it passes the
threshold, 2 invalid input or a read that could not complete.
EOF
}

die_usage() {
  echo "ERROR: $*" >&2
  echo "Run 'touchstone usage --help' for usage." >&2
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
  check | install | uninstall) ;;
  *) die_usage "unknown usage command '${ACTION:-<none>}'; available: check, install, uninstall" ;;
esac

ENTERPRISE=""
ALLOWANCE=""
THRESHOLD=""
AS_OF=""
TOP="$DEFAULT_TOP"
SAMPLE_RUNS="$DEFAULT_SAMPLE_RUNS"
NOTIFY=false
HOUR="$DEFAULT_HOUR"
MINUTE="$DEFAULT_MINUTE"
TOUCHSTONE_BIN=""
DRY_RUN=false

# A non-negative decimal integer, normalized so a leading zero is not octal.
count() {
  case "$2" in
    '' | *[!0-9]*) die_usage "$1 requires a non-negative whole number, got '$2'" ;;
  esac
  printf '%d' "$((10#$2))"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --notify)
      NOTIFY=true
      shift
      continue
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      continue
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --enterprise | --allowance | --threshold | --as-of | --top | --sample-runs | --hour | --minute | --touchstone)
      [ "$#" -ge 2 ] || die_usage "$1 requires a value"
      ;;
    *) die_usage "unknown option '$1' for 'usage $ACTION'" ;;
  esac
  case "$1" in
    --enterprise) ENTERPRISE="$2" ;;
    --allowance) ALLOWANCE="$(count "$1" "$2")" ;;
    --threshold) THRESHOLD="$(count "$1" "$2")" ;;
    --as-of) AS_OF="$2" ;;
    --top) TOP="$(count "$1" "$2")" ;;
    --sample-runs) SAMPLE_RUNS="$(count "$1" "$2")" ;;
    --hour) HOUR="$(count "$1" "$2")" ;;
    --minute) MINUTE="$(count "$1" "$2")" ;;
    --touchstone) TOUCHSTONE_BIN="$2" ;;
    *) die_usage "unknown option '$1' for 'usage $ACTION'" ;;
  esac
  shift 2
done

# The slug is interpolated into an API path, a launchd label, and file names.
case "$ENTERPRISE" in
  '') die_usage "--enterprise SLUG is required" ;;
  -* | *[!A-Za-z0-9-]*) die_usage "--enterprise must be a GitHub enterprise slug (letters, digits, hyphens), got '$ENTERPRISE'" ;;
esac
[ "$SAMPLE_RUNS" -le "$MAX_SAMPLE_RUNS" ] || die_usage "--sample-runs is at most $MAX_SAMPLE_RUNS (one page of runs), got $SAMPLE_RUNS"
[ "$HOUR" -le 23 ] || die_usage "--hour must be 0-23, got $HOUR"
[ "$MINUTE" -le 59 ] || die_usage "--minute must be 0-59, got $MINUTE"
[ -n "$ALLOWANCE" ] || ALLOWANCE="$DEFAULT_ALLOWANCE_MINUTES"
[ "$ALLOWANCE" -gt 0 ] || die_usage "--allowance must be greater than zero"

LABEL="$LABEL_PREFIX.$ENTERPRISE"

# --- install / uninstall ------------------------------------------------------

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

render_plist() {
  local arg
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$LABEL")</string>
  <key>ProgramArguments</key>
  <array>
EOF
  for arg in "$@"; do
    printf '    <string>%s</string>\n' "$(xml_escape "$arg")"
  done
  cat <<EOF
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "$AGENT_PATH")</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$LOG_PATH")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$LOG_PATH")</string>
</dict>
</plist>
EOF
}

agent_paths() {
  [ -n "${HOME:-}" ] || die "HOME is not set; launchd agents live under \$HOME/Library/LaunchAgents"
  PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
  LOG_PATH="$HOME/Library/Logs/touchstone-usage-$ENTERPRISE.log"
  DOMAIN="gui/$(id -u)"
}

run_install() {
  local gh_bin jq_bin tmp_plist
  command -v launchctl >/dev/null 2>&1 \
    || die "install schedules a launchd agent, which needs macOS (launchctl not found)"
  agent_paths
  # The agent runs the installed tool, never this checkout: a source tree
  # moves with its branch, and a release is the reviewed state.
  if [ -z "$TOUCHSTONE_BIN" ]; then
    TOUCHSTONE_BIN="$(command -v touchstone || true)"
    [ -n "$TOUCHSTONE_BIN" ] \
      || die "no installed touchstone on PATH; install a release that has 'touchstone usage', or pass --touchstone PATH"
  fi
  case "$TOUCHSTONE_BIN" in
    /*) ;;
    *) die "--touchstone must be an absolute path, got '$TOUCHSTONE_BIN'" ;;
  esac
  [ -x "$TOUCHSTONE_BIN" ] || die "$TOUCHSTONE_BIN is not an executable touchstone"
  "$TOUCHSTONE_BIN" usage --help >/dev/null 2>&1 </dev/null \
    || die "$TOUCHSTONE_BIN has no 'usage' command (an older release); upgrade it (touchstone upgrade), then install again"
  gh_bin="$(command -v gh || true)"
  jq_bin="$(command -v jq || true)"
  [ -n "$gh_bin" ] && [ -n "$jq_bin" ] || die "the agent needs gh and jq on PATH; install them first"
  # launchd starts agents with a minimal PATH; carry the directories of the
  # tools the check runs, as resolved now.
  AGENT_PATH="$(dirname "$TOUCHSTONE_BIN"):$(dirname "$gh_bin"):$(dirname "$jq_bin"):/usr/bin:/bin:/usr/sbin:/sbin"
  # Carry only the limits given here, so a later release's defaults apply
  # to an agent that never overrode them.
  set -- "$TOUCHSTONE_BIN" usage check --enterprise "$ENTERPRISE" --notify
  [ -z "$ALLOWANCE_GIVEN" ] || set -- "$@" --allowance "$ALLOWANCE_GIVEN"
  [ -z "$THRESHOLD" ] || set -- "$@" --threshold "$THRESHOLD"
  if [ "$DRY_RUN" = true ]; then
    echo "# would write $PLIST_PATH:"
    render_plist "$@"
    echo "# would run: launchctl bootstrap $DOMAIN $PLIST_PATH"
    return 0
  fi
  mkdir -p "$(dirname "$PLIST_PATH")" "$(dirname "$LOG_PATH")"
  tmp_plist="$PLIST_PATH.tmp.$$"
  render_plist "$@" >"$tmp_plist"
  mv -f "$tmp_plist" "$PLIST_PATH"
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL" || die "could not unload the running agent $LABEL; the new plist is at $PLIST_PATH"
  fi
  launchctl bootstrap "$DOMAIN" "$PLIST_PATH" || die "launchctl bootstrap $DOMAIN $PLIST_PATH failed"
  printf 'installed %s: runs %s usage check --enterprise %s daily at %02d:%02d\n' \
    "$LABEL" "$TOUCHSTONE_BIN" "$ENTERPRISE" "$HOUR" "$MINUTE"
  echo "plist: $PLIST_PATH"
  echo "log:   $LOG_PATH"
}

run_uninstall() {
  local loaded=false
  command -v launchctl >/dev/null 2>&1 \
    || die "uninstall removes a launchd agent, which needs macOS (launchctl not found)"
  agent_paths
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && loaded=true
  if [ "$DRY_RUN" = true ]; then
    [ "$loaded" = false ] || echo "# would run: launchctl bootout $DOMAIN/$LABEL"
    [ ! -e "$PLIST_PATH" ] || echo "# would remove $PLIST_PATH"
    return 0
  fi
  if [ "$loaded" = true ]; then
    launchctl bootout "$DOMAIN/$LABEL" || die "could not unload $LABEL"
    echo "unloaded $LABEL"
  fi
  if [ -e "$PLIST_PATH" ]; then
    rm -f "$PLIST_PATH"
    echo "removed $PLIST_PATH"
  fi
  [ "$loaded" = true ] || [ -e "$PLIST_PATH" ] || echo "no $LABEL agent was installed"
}

ALLOWANCE_GIVEN=""
[ "$ALLOWANCE" = "$DEFAULT_ALLOWANCE_MINUTES" ] || ALLOWANCE_GIVEN="$ALLOWANCE"
case "$ACTION" in
  install)
    run_install
    exit 0
    ;;
  uninstall)
    run_uninstall
    exit 0
    ;;
esac

# --- check ------------------------------------------------------------------------

[ -n "$THRESHOLD" ] || THRESHOLD=$((ALLOWANCE * DEFAULT_THRESHOLD_PERCENT / 100))
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

notify() {
  [ "$NOTIFY" = true ] || return 0
  # Message and title travel as arguments, never inside the script text.
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' "$1" "$NOTIFY_TITLE" >/dev/null 2>&1 </dev/null \
    || echo "ERROR: osascript could not raise the notification: $1" >&2
}
fail_read() {
  echo "ERROR: $*" >&2
  notify "usage check for $ENTERPRISE could not complete: $*"
  exit 2
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-usage.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
gh_err() { head -c 400 "$TMP/err" | tr '\n' ' '; }

# The month is the as-of instant's UTC month; all date math is jq's, so it is
# the same under BSD and GNU userlands.
WINDOW_JQ='
  (if $asof == "" then now | floor
   elif ($asof | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then $asof + "T00:00:00Z" | fromdateiso8601
   elif ($asof | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) then $asof | fromdateiso8601
   else error("format") end) as $t
  | if $asof != "" and ($t | todate) != (if ($asof | length) == 10 then $asof + "T00:00:00Z" else $asof end)
    then error("not a calendar date") else . end
  | ($t | gmtime) as $g
  | ([$g[0], $g[1], 1, 0, 0, 0, 0, 0] | mktime) as $start
  | ((if $g[1] == 11 then [$g[0] + 1, 0] else [$g[0], $g[1] + 1] end) + [1, 0, 0, 0, 0, 0] | mktime) as $next
  | [$t, $g[0], $g[1] + 1, $start, ($next - $start) / 86400, ($t | todate), ($start | todate)] | @tsv'
WINDOW="$(jq -rn --arg asof "$AS_OF" "$WINDOW_JQ" 2>/dev/null)" \
  || die_usage "--as-of must be a UTC date YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, got '$AS_OF'"
IFS=$'\t' read -r ASOF_EPOCH YEAR MONTH START_EPOCH MONTH_DAYS ASOF_ISO START_ISO <<<"$WINDOW"

if ! gh api "enterprises/$ENTERPRISE/settings/billing/usage?year=$YEAR&month=$MONTH" \
  >"$TMP/usage.json" 2>"$TMP/err" </dev/null; then
  fail_read "billing usage read failed for enterprise $ENTERPRISE: $(gh_err)"
fi
jq -e '.usageItems | type == "array"' "$TMP/usage.json" >/dev/null 2>&1 \
  || fail_read "billing usage for enterprise $ENTERPRISE is not a {\"usageItems\": [...]} report"

# Public repositories never draw on the allowance. Visibility is not in the
# billing rows, so it is read once per organization that has minutes.
: >"$TMP/public.txt"
while IFS= read -r org; do
  [ -n "$org" ] || continue
  if ! gh api --paginate "orgs/$org/repos?type=public&per_page=100" >"$TMP/repos.json" 2>"$TMP/err" </dev/null; then
    fail_read "public repository list failed for organization $org: $(gh_err)"
  fi
  jq -r '.[].full_name' "$TMP/repos.json" >>"$TMP/public.txt"
done < <(jq -r '[.usageItems[] | select(.unitType == "Minutes") | .organizationName // empty] | unique[]' "$TMP/usage.json")

SUMMARY_JQ='
def rowtime: .date | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def eq($bp): .quantity * .pricePerUnit / $bp;
($public | map({key: ., value: true}) | from_entries) as $pub
| [.usageItems[] | select((rowtime) as $t | $t >= $start and $t < $asof)] as $window
| [$window[] | select(.product == "actions" and .unitType == "Minutes")
    | .repo = "\(.organizationName // "")/\(.repositoryName // "")"
    | .free = ($pub[.repo] // false)] as $minutes
| [$minutes[] | select(.free | not)] as $private
| [$minutes[] | select(.free)] as $free
| ([$minutes[] | select(.sku == $base)] | sort_by(.date) | last | .pricePerUnit) as $bp
| if ($private | length) > 0 and (($bp // 0) <= 0) then
    error("no priced \"\($base)\" row this month, so included minutes cannot be priced (a SKU weight is its price over the \($base) price)")
  else . end
| ($private | map(eq($bp)) | add // 0) as $mtd
| (($asof - $start) / 86400) as $elapsed
| ($mtd / ([$elapsed, $minrate] | max) * $days) as $projection
| {
    month: ($start | todate | .[0:7]),
    asof: ($asof | todate),
    elapsed: $elapsed,
    days: $days,
    base: $base,
    basePrice: $bp,
    skus: ($private | group_by(.sku)
      | map({sku: .[0].sku, minutes: (map(.quantity) | add),
             weight: ((map(.pricePerUnit) | max) / $bp), equivalents: (map(eq($bp)) | add)})
      | sort_by(-.equivalents)),
    families: (["Linux", "macOS", "Windows"]
      | map(. as $f | [$private[] | select(.sku | contains($f))] | group_by(.sku)
          | map({minutes: (map(.quantity) | add), weight: (.[0].pricePerUnit / $bp)})
          | max_by(.minutes) | if . then {key: $f, value: .weight} else empty end)
      | from_entries),
    monthToDate: $mtd,
    projection: $projection,
    allowance: $allowance,
    threshold: $threshold,
    warn: ($projection > $threshold),
    repos: ($private | group_by(.repo)
      | map({repo: .[0].repo, equivalents: (map(eq($bp)) | add)}) | sort_by(-.equivalents)),
    free: {minutes: ($free | map(.quantity) | add // 0), repos: ($free | map(.repo) | unique)},
    net: ($window | map(.netAmount // 0) | add // 0)
  }'
if ! jq --argjson public "$(jq -R . "$TMP/public.txt" | jq -s .)" \
  --argjson start "$START_EPOCH" --argjson asof "$ASOF_EPOCH" --argjson days "$MONTH_DAYS" \
  --argjson minrate "$MIN_RATE_DAYS" --argjson allowance "$ALLOWANCE" \
  --argjson threshold "$THRESHOLD" --arg base "$BASE_SKU" \
  "$SUMMARY_JQ" "$TMP/usage.json" >"$TMP/summary.json" 2>"$TMP/err"; then
  fail_read "$(sed 's/^jq: error ([^)]*): //' "$TMP/err" | head -c 400)"
fi

FORMAT_JQ='
def int: . + 0.5 | floor;
def group3: if length > 3 then (.[0:length - 3] | group3) + "," + .[length - 3:] else . end;
def n: int | tostring | group3;
def frac($digits): pow(10; $digits) as $scale | (. * $scale | int) as $c
  | "\(($c / $scale) | floor | tostring | group3)." + (($c % $scale) | tostring
    | if length < $digits then ("0" * ($digits - length)) + . else . end);
def lpad($w): tostring | if length < $w then (" " * ($w - length)) + . else . end;
def rpad($w): tostring | if length < $w then . + (" " * ($w - length)) else . end;
def pct($of): if $of > 0 then "\(. / $of * 100 | int)%" else "-" end;
'

render_summary() {
  jq -r --arg enterprise "$ENTERPRISE" "$FORMAT_JQ"'
    . as $s
    | "Actions usage for enterprise \($enterprise), \(.month), as of \(.asof) (day \(.elapsed | frac(1)) of \(.days))",
      "",
      (if (.skus | length) > 0 then
        "Included-minute equivalents (weight = SKU price / \(.base) price $\(.basePrice)):",
        (.skus[] | "  \(.sku | rpad(24)) \(.minutes | n | lpad(10)) min  x\(.weight | frac(2) | rpad(7)) \(.equivalents | n | lpad(10))")
       else "No private-repository Actions minutes this month." end),
      "",
      "Month to date  \(.monthToDate | n | lpad(10)) included minutes (\(.monthToDate | pct($s.allowance)) of the \(.allowance | n) allowance)",
      "Projection     \(.projection | n | lpad(10)) by month end at the month-to-date rate",
      "Threshold      \(.threshold | n | lpad(10))",
      (if .free.minutes > 0 then
        "Public repositories (free, not counted): \(.free.minutes | n) minutes in \(.free.repos | join(", "))"
       else empty end),
      "Net billed this month so far: $\(.net | frac(2))",
      (if (.repos | length) > 0 then
        "", "Top repositories by included minutes:",
        (.repos[:$top][] | "  \(.equivalents | n | lpad(10))  \(.equivalents | pct($s.monthToDate) | lpad(4))  \(.repo)")
       else empty end)
  ' --argjson top "$TOP" "$TMP/summary.json"
}

BREAKDOWN_ERROR=""
# Samples the most recent completed runs of each top repository and collects
# their jobs (every attempt, since every attempt is billed) into jobs.jsonl.
sample_jobs() {
  local repo id total
  RUNS_TOTAL=0
  RUNS_SAMPLED=0
  : >"$TMP/jobs.jsonl"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if ! gh api "repos/$repo/actions/runs?created=$START_ISO..$ASOF_ISO&status=completed&exclude_pull_requests=true&per_page=$SAMPLE_RUNS" \
      >"$TMP/runs.json" 2>"$TMP/err" </dev/null; then
      BREAKDOWN_ERROR="run list for $repo failed: $(gh_err)"
      return 1
    fi
    total="$(jq '.total_count // 0' "$TMP/runs.json")"
    RUNS_TOTAL=$((RUNS_TOTAL + total))
    while IFS= read -r id; do
      if ! gh api --paginate "repos/$repo/actions/runs/$id/jobs?filter=all&per_page=100" \
        >"$TMP/jobs.json" 2>"$TMP/err" </dev/null; then
        BREAKDOWN_ERROR="job list for $repo run $id failed: $(gh_err)"
        return 1
      fi
      jq -c --arg repo "$repo" '.jobs[]
        | {repo: $repo, workflow: (.workflow_name // "(unnamed workflow)"), name, labels, started_at, completed_at}' \
        "$TMP/jobs.json" >>"$TMP/jobs.jsonl"
      RUNS_SAMPLED=$((RUNS_SAMPLED + 1))
    done < <(jq -r --argjson n "$SAMPLE_RUNS" '.workflow_runs[:$n][].id' "$TMP/runs.json")
  done < <(jq -r --argjson top "$TOP" '.repos[:$top][].repo' "$TMP/summary.json")
}

# GitHub bills each job rounded up to the minute, at its runner's SKU; the
# runner family is read from the job's runs-on labels and weighted by the
# family's SKU in this month's rows. Self-hosted runners are not billed.
render_breakdown() {
  jq -rs --argjson families "$(jq -c .families "$TMP/summary.json")" --argjson top "$TOP" \
    --arg sampled "$RUNS_SAMPLED" --arg total "$RUNS_TOTAL" --arg per "$SAMPLE_RUNS" "$FORMAT_JQ"'
    def secs: fromdateiso8601;
    def family: (.labels // []) as $l
      | if any($l[]; . == "self-hosted") then "self-hosted"
        elif any($l[]; ascii_downcase | startswith("macos")) then "macOS"
        elif any($l[]; ascii_downcase | startswith("windows")) then "Windows"
        elif any($l[]; ascii_downcase | startswith("ubuntu")) then "Linux"
        else "unknown" end;
    def billed: if .started_at and .completed_at
      then ((.completed_at | secs) - (.started_at | secs)) as $s | if $s > 0 then $s / 60 | ceil else 0 end
      else 0 end;
    map(family as $f | . + {family: $f, minutes: billed,
      weight: (if $f == "self-hosted" then 0 else $families[$f] end)})
    | [.[] | select(.weight != null) | .equivalents = .minutes * .weight] as $priced
    | ([.[] | select(.weight == null) | .minutes] | add // 0) as $unpriced
    | ($priced | map(.equivalents) | add // 0) as $all
    | "",
      "Top workflows (jobs from the \($per) most recent completed runs of each top repository: \($sampled) of \($total | tonumber | n) runs this month):",
      ($priced | group_by([.repo, .workflow])
        | map({label: "\(.[0].repo)  \(.[0].workflow)", equivalents: (map(.equivalents) | add)})
        | sort_by(-.equivalents) | .[:$top][]
        | "  \(.equivalents | n | lpad(10))  \(.equivalents | pct($all) | lpad(4))  \(.label)"),
      "Top jobs:",
      ($priced | group_by([.repo, .workflow, .name])
        | map({label: "\(.[0].repo)  \(.[0].workflow) / \(.[0].name)", runs: length, equivalents: (map(.equivalents) | add)})
        | sort_by(-.equivalents) | .[:$top][]
        | "  \(.equivalents | n | lpad(10))  \(.equivalents | pct($all) | lpad(4))  \(.label) (\(.runs) job run\(if .runs == 1 then "" else "s" end))"),
      (if $unpriced > 0 then
        "\($unpriced | n) sampled job minutes ran on runners with no Actions SKU in this month'"'"'s rows and are not ranked."
       else empty end)
  ' "$TMP/jobs.jsonl"
}

render_summary

if [ "$SAMPLE_RUNS" -gt 0 ] && [ "$TOP" -gt 0 ]; then
  if sample_jobs; then
    render_breakdown
  else
    echo "ERROR: the workflow and job sample could not complete: $BREAKDOWN_ERROR" >&2
  fi
fi

echo
IFS=$'\t' read -r WARN PROJECTED LIMIT < <(jq -r "$FORMAT_JQ"'[.warn, (.projection | n), (.threshold | n)] | @tsv' "$TMP/summary.json")
if [ "$WARN" = true ]; then
  MESSAGE="Projected $PROJECTED included Actions minutes by month end passes the $LIMIT threshold ($ENTERPRISE, ${START_ISO:0:7})."
  echo "WARNING: $MESSAGE"
  notify "$MESSAGE"
  exit 1
fi
echo "OK: projected $PROJECTED included Actions minutes by month end is within the $LIMIT threshold."
if [ -n "$BREAKDOWN_ERROR" ]; then
  notify "usage check for $ENTERPRISE could not complete: $BREAKDOWN_ERROR"
  exit 2
fi
exit 0
