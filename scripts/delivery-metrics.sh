#!/usr/bin/env bash
#
# scripts/delivery-metrics.sh — observe delivery cost per merged pull request.
#
# Usage:
#   bash scripts/delivery-metrics.sh collect [--repo OWNER/NAME] [--limit N]
#   bash scripts/delivery-metrics.sh report [FILE]
#
# collect reads GitHub and emits one TSV record per merged PR (network).
# report reads those records and summarizes them by change size (offline).
#
# This observes. It decides nothing, gates nothing, and writes to no
# repository. A delivery metric that can block delivery is a second
# adjudicator; this stays a reporter so it cannot become one.

set -euo pipefail

SCHEMA="touchstone.delivery-metrics/v1"

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//' >&2
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
#   1 number  2 created_epoch  3 merged_epoch  4 first_commit_epoch
#   5 lines_changed  6 files_changed  7 commits  8 reviews

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
              commits(first: 1) { totalCount nodes { commit { committedDate } } }
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
          (.commits.nodes[0].commit.committedDate | fromdateiso8601),
          (.additions + .deletions),
          .changedFiles,
          .commits.totalCount,
          .reviews.totalCount ]
      | @tsv' \
    | awk -v n="$limit" 'NR <= n'
  # awk drains the stream rather than closing it early: `head` would SIGPIPE
  # the paginating `gh` and trip pipefail. --limit truncates the report, it
  # does not bound the fetch.
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
    NF != 8 {
      printf("ERROR: expected 8 fields, got %d on line %d\n", NF, NR) > "/dev/stderr"
      bad = 1
      next
    }
    {
      n++
      num[n] = $1; created[n] = $2; merged[n] = $3; firstc[n] = $4
      lines[n] = $5; files[n] = $6; commits[n] = $7; reviews[n] = $8
      b[n] = bucket_of($5)
      open_min[n] = int(($3 - $2) / 60)
      total_min[n] = int(($3 - $4) / 60)
    }
    END {
      if (bad) exit 1
      if (n == 0) { print "no records"; exit 0 }

      name[1] = "tiny   (<10 lines)"
      name[2] = "small  (10-49)"
      name[3] = "medium (50-249)"
      name[4] = "large  (250+)"

      printf("%s — %d merged pull requests\n\n", schema, n)
      printf("%-19s %5s  %9s  %9s  %9s  %8s  %8s\n", \
        "size", "count", "med", "p90", "max", "reviews", "commits")
      printf("%-19s %5s  %9s  %9s  %9s  %8s  %8s\n", \
        "-------------------", "-----", "---------", "---------", "---------", "--------", "--------")

      for (k = 1; k <= 4; k++) {
        c = 0
        for (i = 1; i <= n; i++) {
          if (b[i] != k) continue
          c++
          t[c] = total_min[i]; t2[c] = total_min[i]; t3[c] = total_min[i]
          r[c] = reviews[i]; m[c] = commits[i]
        }
        if (c == 0) { printf("%-19s %5d  %9s  %9s  %9s  %8s  %8s\n", name[k], 0, "-", "-", "-", "-", "-"); continue }
        printf("%-19s %5d  %8dm  %8dm  %8dm  %8d  %8d\n", \
          name[k], c, median(t, c), pct(t2, c, 90), pct(t3, c, 100), median(r, c), median(m, c))
        delete t; delete t2; delete t3; delete r; delete m
      }

      # The slowest changes are the ones that cost real time; medians hide
      # them entirely. Sorted by first-commit-to-merge.
      printf("\nslowest merged changes\n")
      for (i = 1; i <= n; i++) { ord[i] = i }
      for (i = 2; i <= n; i++) {
        key = ord[i]; j = i - 1
        while (j > 0 && total_min[ord[j]] < total_min[key]) { ord[j + 1] = ord[j]; j-- }
        ord[j + 1] = key
      }
      top = (n < 5) ? n : 5
      for (i = 1; i <= top; i++) {
        idx = ord[i]
        printf("  #%-6d %6dm  %5d lines  %2d commits  %2d reviews\n", \
          num[idx], total_min[idx], lines[idx], commits[idx], reviews[idx])
      }

      # The premise under test: cost should track size. If the tiny and large
      # rows report similar totals, the toll is flat and the disproportion is
      # visible here rather than argued.
      printf("\nAll times are first commit to merge. MERGED PULL REQUESTS ONLY:\n")
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
  report) report "$@" ;;
  -h | --help) usage ;;
  *) die "unknown action '$ACTION'; expected 'collect' or 'report'" ;;
esac
