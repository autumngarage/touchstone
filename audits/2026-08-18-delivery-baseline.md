# Delivery baseline — 2026-08-18

Baseline for AUT-310, captured before any AUT-309 work, so a later claim that
delivery got cheaper can be checked rather than asserted.

Source: `scripts/delivery-metrics.sh`, the 60 most recently **merged** pull
requests per repository. Raw records are committed alongside this file.

```
TOUCHSTONE
touchstone.delivery-metrics/v1 — 60 merged pull requests

                                      commit-to-merge      open-to-merge
size                count       med      p90      max       med      max  reviews commits
------------------- -----  -------- -------- --------  -------- --------  ------- -------
tiny   (<10 lines)      2        3m       6m       6m        3m       6m        0       1
small  (10-49)          9       17m      29m      49m       20m      90m        2       2
medium (50-249)        15       41m     281m     944m       47m    1012m        2       3
large  (250+)          34       73m     393m     574m      121m    2935m        8       5

slowest merged changes, by time the pull request stayed open
  #703       2935m open     229m working   1101 lines   8 commits   49 reviews
  #707       1193m open     198m working    547 lines   5 commits   11 reviews
  #712       1012m open     222m working     59 lines   6 commits   15 reviews
  #715        983m open     197m working    766 lines  11 commits   38 reviews
  #915        938m open     944m working     58 lines   2 commits    2 reviews

commit-to-merge measures working time; open-to-merge measures elapsed
time and is where stalls appear. A large gap between them is a change
that sat rather than one that was hard. MERGED PULL REQUESTS ONLY:
changes still open, or closed unmerged, are excluded by construction
and are exactly where delivery pain concentrates. Read the tail, not
the median.

VESPER
touchstone.delivery-metrics/v1 — 60 merged pull requests

                                      commit-to-merge      open-to-merge
size                count       med      p90      max       med      max  reviews commits
------------------- -----  -------- -------- --------  -------- --------  ------- -------
tiny   (<10 lines)      2        4m       4m       4m        4m       4m        0       1
small  (10-49)         11        7m       8m     198m        7m      33m        0       1
medium (50-249)        13       11m      49m      69m       11m      68m        0       1
large  (250+)          34       46m     368m     737m       42m     519m        4       4

slowest merged changes, by time the pull request stayed open
  #877        519m open     546m working   1105 lines   6 commits    7 reviews
  #746        368m open     368m working   3842 lines  12 commits   40 reviews
  #826        351m open      12m working   3658 lines   1 commits   77 reviews
  #837        346m open     737m working   2629 lines  26 commits   23 reviews
  #885        230m open     237m working    864 lines   3 commits    3 reviews

commit-to-merge measures working time; open-to-merge measures elapsed
time and is where stalls appear. A large gap between them is a change
that sat rather than one that was hard. MERGED PULL REQUESTS ONLY:
changes still open, or closed unmerged, are excluded by construction
and are exactly where delivery pain concentrates. Read the tail, not
the median.
```

## What this changes about the plan

**The stated premise of AUT-309 needs restating.** The claim was that a small
change pays the same toll as a large one. By median that is false in both
repositories — commit-to-merge tracks size cleanly. But the premise is not
simply wrong either, and the median was hiding why.

**The defect is variance, and it lives on the elapsed clock.** Two clocks
matter and they say different things. `commit-to-merge` measures working time.
`open-to-merge` measures elapsed time, and that is where stalls appear. A large
gap between them is a change that sat, not a change that was hard.

Touchstone's large bucket runs 73m median working time against a 2,935-minute
worst elapsed — roughly 49 hours. Its medium bucket runs 41m median against
1,012m worst.

Two signatures, wanting opposite fixes:

- **Stalling** — #703 sat 2,935 minutes with 229 minutes of work in it. vesper
  #823 took 614 minutes for 350 lines across 2 commits and 2 reviews. Almost
  no activity; the time was waiting.
- **Review churn** — #703 accumulated 49 reviews, #715 38, vesper #746 40.
  The review loop kept reopening these changes.

**#712 is the case that justifies AUT-309 after all**: 59 lines, 15 reviews,
1,012 minutes open against 222 minutes of work. A small change paying a large
change's toll. It is invisible in the median and was invisible in the first
sample.

## Sampling correction

The first version of this baseline ordered by creation time and then truncated,
which systematically dropped pull requests opened long ago and merged recently
— precisely the stalled cases this tool exists to surface. Reported as a P1 on
PR #917 and fixed: selection is now by merge time, covered by a regression test
that fails on the old behaviour.

The correction changed the touchstone sample, pulling in #703 — the 49-review,
49-hour case that is now the worst row in the table. A metric that hides its
own worst case is worse than no metric, so the sampling rule is a separate,
separately tested command rather than a detail inside a network call.

## Known limitation, and it is load-bearing

**Merged pull requests only.** Anything still open, or closed unmerged, cannot
appear here. The ~20-line vesper fix that consumed five commits and three
review rounds is still open and therefore absent.

So this measures the survivors. It answers "did the typical change get
cheaper" and cannot answer "did we stop getting stuck." Counting open-PR age
and unmerged closures is the follow-up, or the metric will report improvement
while the pain is unchanged.
