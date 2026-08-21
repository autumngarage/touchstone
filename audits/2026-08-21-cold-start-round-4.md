# Cold-start dogfooding, round 4 (final for 3.2.x) — 2026-08-21

Confirmation run against touchstone 3.2.2 (installed 13:52Z, carrying the
round-3 fixes #966/#969), after arpeggio#52 and vesper#930 merged. Same
scored prompt as [round 3](2026-08-21-cold-start-round-3.md), with the
known-open tracked items disclosed so they are not re-counted (AUT-410,
AUT-421, AUT-396, AUT-403, AUT-423).

## Scorecard

| Cell | (1) sequence | (2) enforcement | (3) contradictions | Pass |
| --- | --- | --- | --- | --- |
| Claude / arpeggio | PASS | PASS (`applied`) | FAIL — 1 + 1 borderline | no |
| Claude / vesper | PASS | PASS (`applied`) | FAIL — 1 | no |
| Codex / arpeggio | PASS | FAIL — read-only `$TMPDIR` (AUT-421) | FAIL — 1 | no |
| Codex / vesper | PASS | FAIL — read-only `$TMPDIR` (AUT-421) | **PASS — none** | (2) only |

Round 3 → round 4: contradictions per cell went from 4–5 to 0–1 confirmed
(plus one borderline in Claude/arpeggio), and the first cell with none
arrived (Codex on vesper). Criterion (1) has now passed
in eight consecutive cells across two rounds: a fresh agent of either driver
reads the installed contract and produces the correct ship sequence.

## The four remaining items, and where each went

- `principles/git-workflow.md` "Before trusting any merge" still listed "the
  merge queue" as part of `applied` (Claude/arpeggio, borderline) — #972.
- `principles/ai-delivery-architecture.md` "feature-branch push … without
  running full test suites" vs arpeggio's deliberate full-suite pre-push
  (Codex/arpeggio) — #972: the default is stated as a default, a declared
  per-project cost is named as such, GitHub's checks are the gate either way.
- arpeggio `.pre-commit-config.yaml` "merge-queue commit" (Claude/arpeggio;
  my miss in #52) — arpeggio#53.
- vesper `.cursor/rules/conductor-delegation.mdc`, conductor-managed, names
  `conductor ask --kind review` (Claude/vesper) — AUT-424, a decision for
  the owner, not an agent deletion. vesper#931 drops a duplicated line #930
  left.

## Closing the loop

This is the last cold-start round for 3.2.x, as round 3 set out. What the
rounds bought: the contract's ship sequence is learnable cold (eight of
eight), enforcement is readable wherever a temp file can be written, and the
routed documents, once #972 lands, no longer contradict each other or the
tool on anything an agent quoted; at this head the two #972 quotations are
still open. What they did not buy, and no further round would: a Linear
claim transport (AUT-410), read-only observation commands (AUT-421), a
re-request path for body-only findings (AUT-396), a permission-based trust
check in the gate (AUT-422). Those are tool changes with issues; the next
cold start runs once, after the release that carries them, against the same
three criteria.

## Method note

The scored prompt (verdict per criterion, with evidence; preferences in an
unscored section; known-open items disclosed) produced four comparable,
terminating answers per round. The open-ended round-1/2 prompt produced
five-page essays that had to be mined. Keep the scored form.
