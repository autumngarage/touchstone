# Delivery baseline — 2026-08-18

Baseline for AUT-310, captured before any AUT-309 proportionality work, so a
later claim that small changes got cheaper can be checked rather than asserted.

Source: `scripts/delivery-metrics.sh`, 60 most recent merged pull requests per
repository. Raw records are committed alongside this file.

```
TOUCHSTONE
touchstone.delivery-metrics/v1 — 60 merged pull requests

size                count        med        p90        max   reviews   commits
------------------- -----  ---------  ---------  ---------  --------  --------
tiny   (<10 lines)      2         3m         6m         6m         0         1
small  (10-49)          9        17m        29m        49m         2         2
medium (50-249)        16        46m       138m       281m         2         3
large  (250+)          33        70m       393m       574m         8         5

slowest merged changes
  #801       574m   6088 lines   7 commits  19 reviews
  #807       450m   1088 lines   4 commits   7 reviews
  #808       430m   1036 lines   3 commits   5 reviews
  #810       393m   8126 lines   2 commits  13 reviews
  #827       345m   1746 lines  23 commits  44 reviews

All times are first commit to merge. MERGED PULL REQUESTS ONLY:
changes still open, or closed unmerged, are excluded by construction
and are exactly where delivery pain concentrates. Read the tail, not
the median.

VESPER
touchstone.delivery-metrics/v1 — 60 merged pull requests

size                count        med        p90        max   reviews   commits
------------------- -----  ---------  ---------  ---------  --------  --------
tiny   (<10 lines)      2         4m         4m         4m         0         1
small  (10-49)         11         7m         8m       198m         0         1
medium (50-249)        13        11m        49m        69m         0         1
large  (250+)          34        46m       368m       737m         4         4

slowest merged changes
  #837       737m   2629 lines  26 commits  23 reviews
  #823       614m    350 lines   2 commits   2 reviews
  #877       546m   1105 lines   6 commits   7 reviews
  #746       368m   3842 lines  12 commits  40 reviews
  #885       237m    864 lines   3 commits   3 reviews

All times are first commit to merge. MERGED PULL REQUESTS ONLY:
changes still open, or closed unmerged, are excluded by construction
and are exactly where delivery pain concentrates. Read the tail, not
the median.
```

## What this changes about the plan

**The stated premise of AUT-309 is not what the data shows.** The claim was
that a small change pays the same toll as a large one. By median it does not,
in either repository — cost tracks size cleanly (touchstone 3m / 17m / 46m /
70m; vesper 4m / 7m / 11m / 46m).

**The real defect is variance, not disproportion.** Every bucket has a tail
several multiples above its median. A vesper change of 10–49 lines has a
median of 7 minutes and a maximum of 198. Touchstone's large bucket runs 70m
median against 574m worst. The system is not uniformly slow; it is
*unpredictable*, and an unpredictable pipeline cannot be planned around.

Two signatures are visible in the slowest rows:

- **Stalling** — vesper #823 took 614 minutes for 350 lines across 2 commits
  and 2 reviews. Almost no work happened; the time was spent waiting.
- **Review churn** — touchstone #827 accumulated 44 reviews across 23 commits,
  and vesper #746 40 reviews. These are changes the review loop kept reopening.

Those want different fixes. Stalls want the wait removed; churn wants scope
bounded. Neither is "scale the gate to the size of the change."

## Known limitation, and it is load-bearing

**Merged pull requests only.** A change that is still open, or was closed
unmerged, cannot appear here. The incidents that motivated this milestone —
the ~20-line fix that consumed five commits and three review rounds, and the
merge-gate wedge on PR #888 — are absent for exactly that reason: one is
still open and the other merged only after intervention.

So this baseline measures the survivors. It is the right instrument for
"did the typical change get cheaper" and the wrong one for "did we stop
getting stuck." A follow-up should count open-PR age and unmerged closures,
or the metric will report improvement while the pain is unchanged.
