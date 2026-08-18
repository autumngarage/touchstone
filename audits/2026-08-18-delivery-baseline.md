# Delivery baseline — 2026-08-18

Baseline for AUT-310, captured before proportionality work, so a later claim
that delivery got cheaper can be checked rather than asserted.

Source: `scripts/delivery-metrics.sh`, the 60 most recently **merged** pull
requests per repository, selected by merge time. Raw records are committed
alongside this file.

```
TOUCHSTONE
touchstone.delivery-metrics/v1 — 60 merged pull requests

                                          open-to-merge
size                count       med      p90      max  reviews commits
------------------- -----  -------- -------- --------  ------- -------
tiny   (<10 lines)      2        3m       6m       6m        0       1
small  (10-49)          9       20m      47m      90m        2       2
medium (50-249)        15       47m     938m    1012m        2       3
large  (250+)          34      121m     519m    2935m        8       5

slowest merged changes, by time the pull request stayed open
  #703       2935m open   1101 lines   8 commits   49 reviews
  #707       1193m open    547 lines   5 commits   11 reviews
  #712       1012m open     59 lines   6 commits   15 reviews
  #715        983m open    766 lines  11 commits   38 reviews
  #915        938m open     58 lines   2 commits    2 reviews

open-to-merge is elapsed time; no working-time clock is reported
because commit dates do not bound work. MERGED PULL REQUESTS ONLY:
changes still open, or closed unmerged, are excluded by construction
and are exactly where delivery pain concentrates. Read the tail, not
the median.

VESPER
touchstone.delivery-metrics/v1 — 60 merged pull requests

                                          open-to-merge
size                count       med      p90      max  reviews commits
------------------- -----  -------- -------- --------  ------- -------
tiny   (<10 lines)      2        4m       4m       4m        0       1
small  (10-49)         11        7m       9m      33m        0       1
medium (50-249)        13       11m      53m      68m        0       1
large  (250+)          34       42m     346m     519m        4       4

slowest merged changes, by time the pull request stayed open
  #877        519m open   1105 lines   6 commits    7 reviews
  #746        368m open   3842 lines  12 commits   40 reviews
  #826        351m open   3658 lines   1 commits   77 reviews
  #837        346m open   2629 lines  26 commits   23 reviews
  #885        230m open    864 lines   3 commits    3 reviews

open-to-merge is elapsed time; no working-time clock is reported
because commit dates do not bound work. MERGED PULL REQUESTS ONLY:
changes still open, or closed unmerged, are excluded by construction
and are exactly where delivery pain concentrates. Read the tail, not
the median.
```

## What the baseline shows

**One clock, deliberately.** open-to-merge is elapsed time from PR creation to
merge. An earlier revision also reported first-commit-to-merge as "working
time"; review showed commit dates do not bound work — rebases rewrite
committer dates and commits can predate the PR (observed in both directions:
touchstone #703 first commit 2,705 minutes after open, vesper #823 596 minutes
before). A clock that can be wrong in both directions was deleted rather than
repaired. Conclusions drawn from it — including an earlier classification of
vesper #823 as a stall — are withdrawn.

**Medians are healthy and track size.** The defect is the tail: every bucket's
p90 runs several multiples above its median (touchstone large: 121m median,
2,935m max; vesper large: 42m median, 519m max). An unpredictable pipeline
cannot be planned around even when its typical case is fine.

**Review counts separate two tail shapes** without needing a second clock:
high-review rows (touchstone #703, 49 reviews) are churn — the review loop
reopening a change; low-review long-open rows are waiting. Which mechanism
dominates is for the exit check (AUT-309) to determine on post-change data,
not this baseline.

## Known limitation, and it is load-bearing

**Merged pull requests only.** Anything still open, or closed unmerged, cannot
appear here. So this measures the survivors: it answers "did the typical
merged change get cheaper" and cannot answer "did we stop getting stuck." The
exit check must also record open-PR age and overrides used, or the metric will
report improvement while the pain is unchanged.
