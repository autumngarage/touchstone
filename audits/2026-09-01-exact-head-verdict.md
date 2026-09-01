# Exact-head verdict contract: Phase 1 evidence audit (AUT-1132)

Date: 2026-09-01. Read-only audit of 52 pull requests across
`autumngarage/vesper` (35 merged + open incident PRs #1112 and #1113) and
`autumngarage/touchstone` (15 merged). Each PR's complete review surface was
snapshotted once: PR coordinates, all issue comments, all inline review
comments, all formal reviews (GraphQL, with commit binding), and timeline
force-push / base-retarget / dismissal events. Categories covered: fix (27),
feat (8), release-prep (6), test (4), chore (2), docs (2), refactor (2),
perf (1); 10 PRs had force-pushed (rewritten) heads; 4 PRs carried
`no-code-change` dispositions. No sampled PR had a base retarget or a review
dismissal; those scenarios are covered by fixtures instead of field data.

## Complete trusted-reviewer output shape classification

Every artifact authored by the trusted reviewer (`chatgpt-codex-connector`)
across all 52 PRs falls into exactly four shapes:

| Shape | Count | Identification | Verdict meaning |
|---|---|---|---|
| Findings formal review | 49 | Formal PR review, body has `### 💡 Codex Review` + `Reviewed commit:` | findings for GitHub's `commit_id` |
| Findings formal review, no `Reviewed commit:` line | 1 | Formal PR review, body has header only (vesper#1099: one P2 body finding) | findings for GitHub's `commit_id` |
| Clean result comment | 50 | Issue comment: `Didn't find any major issues` + `Reviewed commit:` naming an abbreviated SHA | clean for the named SHA |
| Status dashboard | 52 (1/PR) | Issue comment starting `<!-- codex-pull-request-review-summary -->`, edited in place | none — mutable, no verdict |

Zero other shapes. Zero clean formal reviews; zero finding-bearing issue
comments. Quota notices did not occur in this sample but are excluded by the
same rule contract 4 already used.

**Ambiguity proof.** The clean and findings shapes are disjoint by
construction: a clean verdict is an issue comment with an explicit sentence
and an explicit reviewed SHA; a findings verdict is a formal review bound by
GitHub itself to a commit. Across all 52 PRs, zero heads carried both a clean
and a findings verdict without a strict timestamp order, zero clean results
were ever edited, and zero trusted artifacts were unclassifiable. The one
prose anomaly (the missing `Reviewed commit:` line) is irrelevant because the
adapter binds formal reviews through `commit_id`, never prose. The connector
therefore does expose a stable positive-attestation boundary; no CheckRun
reviewer change is required.

**Binding with O(1) resolution.** A clean comment's abbreviated SHA that is
a prefix of the 40-hex current head is a candidate, and the collector
resolves only those candidates to full commit IDs (in this sample: exactly
one per clean-ending PR). This replaces contract 4's resolution of *every*
abbreviated result comment: stale verdicts differ from the current head in
their first hexes and are discarded without any request, and a mined prefix
collision resolves to its true commit and is discarded as stale. An
unresolved candidate fails closed.

## Verdict distribution and cost

Applying the adapter to each PR's final head: 41/52 clean, 11/52 findings
(10 merged, plus open #1112), 0 waiting, 0 invalid.

- 99 review requests were posted across the 52 PRs; 34 PRs (65%) were clean
  on their first review. Median hosted requests for a clean-first PR: 1.
- Finding rounds per PR: 0×34, 1×8, 2×4, 3×3, 5×1, 8×1, 12×1 (that last is
  incident PR #1112 — drivers already re-request repeatedly after fixes, so
  a final clean verdict frequently replaces an existing round rather than
  adding one; #1113 already ended with a clean current-head verdict).
- **Incremental model cost of the clean-only policy:** the 10 merged
  findings-final PRs would each have needed exactly one more review round —
  an upper bound of +0.2 hosted requests per PR (+10 per 50), consistent
  with the earlier 30-PR sample's +8. Those PRs merged on marker
  adjudication, so their would-be attest rounds are the price of deleting
  that machinery; nothing else in the sample pays anything.

**What the contract-4 gate pays today** (request-cost model taken from the
shipped collector: fixed baseline + permission lookups + abbreviated-SHA
resolutions + request-base comparisons + fix-reachability comparisons):
incident PR #1112 costs 23 REST requests and #1113 costs 22 — both above the
original 20-request ceiling that made them unmergeable (AUT-1106), and both
still O(review history) under the raised 44 ceiling. The version 3 collector
is O(pages): the same two PRs cost 4 REST requests plus 1 GraphQL page each
(their 60- and 55-event timelines and 17 issue comments each fit one page),
plus one resolution request per head-prefix clean candidate — one for a
clean-ending PR, zero for these two.

## Contract decision

**Policy 1 — only `clean` succeeds — is adopted.** The fallback
(findings succeed when every current-head finding has an authorized, still
present, resolved disposition) is rejected: it is contract 4. Its
deletion/edit safety proof *is* the cutoff/prior-snapshot/permission/
reachability machinery this task exists to delete, and no bounded
mutation-safe replacement was found that does not persist a ledger. The
clean-only policy needs no such proof: success requires a positive, current,
unedited artifact naming the exact head, so deletion removes evidence
(fails closed to waiting), edits fail closed to invalid, and a rewritten
head binds nothing.

The evaluator is `.github/review-gate/evaluate-v3.jq` (gate behavior
contract version 3); its sanitized frozen fixtures are
`tests/test-review-gate-v3.sh`, covering every Phase 1 scenario named in
AUT-1132 plus the fail-closed invariants.

## Side-by-side: version 3 offline vs. live version 2

The version 3 evaluator ran offline against all 52 raw snapshots
(normalized; `state`/`openHeadPulls` patched to their at-merge-time values).
The live gate's recorded outcomes are the version 2 side: every merged PR
passed it.

| Population | v2 (live) | v3 (offline) | Divergence explained |
|---|---|---|---|
| 40 merged, clean final head | success | clean/success | agree |
| 10 merged, findings final head | success via marker adjudication | findings | deliberate policy change: one attest round now required |
| #1112 (open, findings head) | capacity failure at ceiling 20; evaluable only after raising to 44 | findings → answer + re-request | v3 removes the capacity class entirely |
| #1113 (open, clean head) | 22-request evaluation | clean/success at 5 requests | agree, at O(pages) cost |

Zero unsafe divergences: no snapshot produced `clean` from stale, edited,
untrusted, or ambiguous evidence (`invalid`/`waiting` occurred zero times on
final heads, and the fixtures pin every such path).

The serious-tier local review of the evaluator surfaced four fail-closed
gaps — prefix collisions on abbreviated SHAs, dismissed findings dropping
out of the verdict order, same-second ties checked only pairwise, and
missing timestamps defaulting to "unedited" — all fixed before push, each
with a regression fixture; the side-by-side distribution was unchanged by
the hardening.

## Compatibility, rollout, rollback

Version 2 remains the live gate until the pinned workflow revision changes;
`evaluate-v3.jq` and its tests are inert in this repository (owner:
AUT-1132; removal condition for the version 2 files: the canary checkpoint
below). Rollout follows AUT-1132 Phase 4: (1) land the version 3 collector
in `touchstone-workflows` pinning this repository's merged revision,
(2) one Touchstone canary PR, (3) five representative Vesper PRs including
one finding-bearing and one rewritten-head, (4) Arpeggio/Convoy after the
Vesper checkpoint, each step a separately reviewed policy repin
(`gateBehaviorContractVersion` 2 → 3). Rollback is a repin to the prior
revision. Open PRs are not stranded: a head that already has a clean result
passes immediately; a head that passed v2 marker adjudication needs one
review request. After the canary, delete: fix-reachability collection,
permission collection, abbreviated-SHA resolution, request-base comparison,
cutoff/prior-snapshot machinery, `evaluate.jq` (contract 4) and its tests —
then AUT-785 and AUT-793 close as superseded, and AUT-1106 closes because
evaluation cost no longer depends on history size.

## Rollout observations (live, 2026-09-01)

Shapes observed during the Phase 4 rollout that the 52-PR sample did not
contain, none of which required an adapter change:

- A clean result with appended prose — `Didn't find any major issues. Keep
  it up!` — matched by the substring rule as designed.
- A transient empty-body formal review bound to the head while the
  reviewer's dashboard still said Running, with body and inline comments
  attached minutes later. The adapter reads the shell as `findings` (the
  safe direction) and supersession settles it when content arrives.
- The behavior-v3 attest flow (answer resolves the last thread → one
  idempotent fresh request) shipped in the sequencer ahead of the repin
  (#1086) after hosted review caught the gap.

## Reproduction

Snapshots were collected with `gh api` (REST + GraphQL, paginated,
read-only) into per-PR JSON documents; classification and the side-by-side
used `jq` against those documents and this repository's evaluators. The raw
snapshots contain full PR prose and are deliberately not committed; the
sanitized fixtures in `tests/test-review-gate-v3.sh` are the durable
artifacts.
