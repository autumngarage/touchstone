#!/usr/bin/env bash
#
# scripts/delivery-metrics.sh — observe delivery cost per merged pull request.
#
# Usage:
#   bash scripts/delivery-metrics.sh collect [--repo OWNER/NAME] [--limit N]
#   bash scripts/delivery-metrics.sh select --limit N [FILE]
#   bash scripts/delivery-metrics.sh report [FILE]
#
# collect reads GitHub and emits one TSV record per merged PR (network).
# select keeps the N most recently merged of those records (offline).
# report reads those records and summarizes them by change size (offline).
#
# select exists as its own command because the sampling rule is the part most
# likely to be silently wrong, and a rule that only runs inside a network call
# cannot be tested. It is the fix for a real defect: selecting by creation
# order dropped PRs opened long ago and merged recently, which is precisely
# the stalled case this tool exists to surface.
#
# This observes. It decides nothing, gates nothing, and writes to no
# repository. A delivery metric that can block delivery is a second
# adjudicator; this stays a reporter so it cannot become one.

set -euo pipefail

SCHEMA="touchstone.delivery-metrics/v1"

usage() {
  sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Field order is the versioned contract between collect and report. Epoch
# seconds are resolved during collect so report needs no `date` parsing, which
# differs between GNU and BSD userlands.
#
#   1 number  2 created_epoch  3 merged_epoch
#   4 lines_changed  5 files_changed  6 commits  7 reviews
#
# There is deliberately no working-time field. The obvious candidate -- the
# first commit's committedDate -- does not bound work: rebases rewrite
# committer dates and commits can predate the PR (observed in both directions:
# touchstone #703 first commit 2,705m after open, vesper #823 596m before).
# A clock that can be wrong in both directions is worse than no clock.

collect() {
  local repo="" limit=100
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || die "--repo requires OWNER/NAME"
        repo="$2"
        shift 2
        ;;
      --limit)
        [ "$#" -ge 2 ] || die "--limit requires a positive integer"
        limit="$2"
        shift 2
        ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  case "$limit" in '' | *[!0-9]* | 0) die "--limit must be a positive integer" ;; esac

  local owner name
  if [ -n "$repo" ]; then
    case "$repo" in */*) ;; *) die "--repo must be OWNER/NAME, got '$repo'" ;; esac
    owner="${repo%%/*}"
    name="${repo#*/}"
  else
    owner="$(gh repo view --json owner --jq .owner.login)" || die "could not resolve repository owner"
    name="$(gh repo view --json name --jq .name)" || die "could not resolve repository name"
  fi

  # `gh pr list --json commits` fetches every commit and its authors
  # connection for every PR, which exceeds GitHub's node budget past a few
  # dozen records. Only the first commit's date and the two totals are needed,
  # so ask for exactly that and let the page size bound the traversal.
  #
  # A PR missing a merge time or carrying no commits is dropped rather than
  # emitted as a zero, so a gap in the data never reads as an instant merge.
  gh api graphql --paginate \
    -F owner="$owner" -F name="$name" \
    -f query='
      query($owner: String!, $name: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequests(states: MERGED, first: 25,
                       orderBy: {field: CREATED_AT, direction: DESC},
                       after: $endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              number createdAt mergedAt additions deletions changedFiles
              commits(first: 1) { totalCount }
              reviews(first: 1) { totalCount }
            }
          }
        }
      }' \
    --jq '.data.repository.pullRequests.nodes[]
      | select(.mergedAt != null and .createdAt != null)
      | select(.commits.totalCount > 0)
      | [ .number,
          (.createdAt | fromdateiso8601),
          (.mergedAt | fromdateiso8601),
          (.additions + .deletions),
          .changedFiles,
          .commits.totalCount,
          .reviews.totalCount ]
      | @tsv' \
    | select_records "$limit"
  # The pipeline drains rather than closing early: `head` would SIGPIPE the
  # paginating `gh` and trip pipefail. --limit truncates the sample, it does
  # not bound the fetch.
}

# Sample the N most recently MERGED records. GitHub's pullRequests connection
# cannot order by merge time, so the ordering is applied here over the full
# fetched set. Sorting by creation time instead systematically under-samples
# stalls: a PR opened weeks ago and merged today sorts as old and falls off
# the end, and long-lived PRs are exactly the ones worth measuring.
select_records() {
  local limit="$1"
  sort -t "$(printf '\t')" -k3,3nr | awk -v n="$limit" 'NR <= n'
}

select_cmd() {
  local limit="" input=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit)
        [ "$#" -ge 2 ] || die "--limit requires a positive integer"
        limit="$2"
        shift 2
        ;;
      -*) die "unknown argument '$1'" ;;
      *)
        [ -z "$input" ] || die "select accepts at most one FILE"
        input="$1"
        shift
        ;;
    esac
  done
  [ -n "$limit" ] || die "select requires --limit"
  case "$limit" in '' | *[!0-9]* | 0) die "--limit must be a positive integer" ;; esac
  [ -z "$input" ] || [ -r "$input" ] || die "cannot read records: $input"
  if [ -n "$input" ]; then
    select_records "$limit" <"$input"
  else
    select_records "$limit"
  fi
}

report() {
  local input="${1:-/dev/stdin}"
  [ "$#" -le 1 ] || die "report accepts at most one FILE"
  [ "$input" = /dev/stdin ] || [ -r "$input" ] || die "cannot read records: $input"

  awk -F '\t' -v schema="$SCHEMA" '
    function bucket_of(lines) {
      if (lines < 10) return 1
      if (lines < 50) return 2
      if (lines < 250) return 3
      return 4
    }
    # Insertion sort: portable across awk implementations (macOS awk has no
    # asort) and the record counts here are small by construction.
    function median(arr, n,   i, j, key, out) {
      if (n == 0) return -1
      for (i = 2; i <= n; i++) {
        key = arr[i]
        j = i - 1
        while (j > 0 && arr[j] > key) { arr[j + 1] = arr[j]; j-- }
        arr[j + 1] = key
      }
      if (n % 2) return arr[(n + 1) / 2]
      return int((arr[n / 2] + arr[n / 2 + 1]) / 2)
    }
    # Sorts in place, so callers must pass an array they no longer need
    # unsorted. Reported alongside the median because the median hides the
    # tail, and the tail is where delivery actually hurts.
    function pct(arr, n, p,   i, j, key, idx) {
      if (n == 0) return -1
      for (i = 2; i <= n; i++) {
        key = arr[i]
        j = i - 1
        while (j > 0 && arr[j] > key) { arr[j + 1] = arr[j]; j-- }
        arr[j + 1] = key
      }
      idx = int((p / 100) * n + 0.5)
      if (idx < 1) idx = 1
      if (idx > n) idx = n
      return arr[idx]
    }
    NF == 0 { next }
    NF != 7 {
      printf("ERROR: expected 7 fields, got %d on line %d\n", NF, NR) > "/dev/stderr"
      bad = 1
      next
    }
    {
      n++
      num[n] = $1; created[n] = $2; merged[n] = $3
      lines[n] = $4; files[n] = $5; commits[n] = $6; reviews[n] = $7
      b[n] = bucket_of($4)
      open_min[n] = int(($3 - $2) / 60)
    }
    END {
      if (bad) exit 1
      if (n == 0) { print "no records"; exit 0 }

      name[1] = "tiny   (<10 lines)"
      name[2] = "small  (10-49)"
      name[3] = "medium (50-249)"
      name[4] = "large  (250+)"

      printf("%s — %d merged pull requests\n\n", schema, n)
      printf("%-19s %5s  %28s\n", "", "", "open-to-merge")
      printf("%-19s %5s  %8s %8s %8s  %7s %7s\n", \
        "size", "count", "med", "p90", "max", "reviews", "commits")
      printf("%-19s %5s  %8s %8s %8s  %7s %7s\n", \
        "-------------------", "-----", "--------", "--------", "--------", \
        "-------", "-------")

      for (k = 1; k <= 4; k++) {
        c = 0
        for (i = 1; i <= n; i++) {
          if (b[i] != k) continue
          c++
          o[c] = open_min[i]; o2[c] = open_min[i]; o3[c] = open_min[i]
          r[c] = reviews[i]; m[c] = commits[i]
        }
        if (c == 0) { printf("%-19s %5d  %8s %8s %8s  %7s %7s\n", name[k], 0, "-", "-", "-", "-", "-"); continue }
        printf("%-19s %5d  %7dm %7dm %7dm  %7d %7d\n", \
          name[k], c, median(o, c), pct(o2, c, 90), pct(o3, c, 100), \
          median(r, c), median(m, c))
        delete o; delete o2; delete o3; delete r; delete m
      }

      # The slowest changes are the ones that cost real time; medians hide
      # them entirely. Sorted by first-commit-to-merge.
      printf("\nslowest merged changes, by time the pull request stayed open\n")
      for (i = 1; i <= n; i++) { ord[i] = i }
      for (i = 2; i <= n; i++) {
        key = ord[i]; j = i - 1
        while (j > 0 && open_min[ord[j]] < open_min[key]) { ord[j + 1] = ord[j]; j-- }
        ord[j + 1] = key
      }
      top = (n < 5) ? n : 5
      for (i = 1; i <= top; i++) {
        idx = ord[i]
        printf("  #%-6d %7dm open  %5d lines  %2d commits  %3d reviews\n", \
          num[idx], open_min[idx], lines[idx], commits[idx], reviews[idx])
      }

      # The premise under test: cost should track size. If the tiny and large
      # rows report similar totals, the toll is flat and the disproportion is
      # visible here rather than argued.
      printf("\nopen-to-merge is elapsed time; no working-time clock is reported\n")
      printf("because commit dates do not bound work. MERGED PULL REQUESTS ONLY:\n")
      printf("changes still open, or closed unmerged, are excluded by construction\n")
      printf("and are exactly where delivery pain concentrates. Read the tail, not\n")
      printf("the median.\n")
    }
  ' "$input"
}

ACTION="${1:-}"
[ -n "$ACTION" ] || usage
shift

case "$ACTION" in
  collect) collect "$@" ;;
  select) select_cmd "$@" ;;
  report) report "$@" ;;
  -h | --help) usage ;;
  *) die "unknown action '$ACTION'; expected 'collect', 'select', or 'report'" ;;
esac
