# Cold-start dogfooding, round 3 — 2026-08-21

First round against touchstone 3.2.1 (installed 12:37Z), scored with the
pass condition defined in [round 2](2026-08-21-cold-start-round-2.md): a
cell passes when (1) the ship sequence matches the contract and violates no
invariant, (2) `touchstone policy status` reads `applied`, and (3) the agent
quotes no contradiction between shipped documents or between a document and
the installed tool. The prompt was rewritten as a scored checklist (verdict
per criterion with evidence) instead of an open question.

## Scorecard

| Cell | (1) sequence | (2) enforcement | (3) contradictions | Pass |
| --- | --- | --- | --- | --- |
| Claude / arpeggio | PASS | PASS (`applied`) | FAIL — 4 quoted | no |
| Claude / vesper | PASS | PASS (`applied`) | FAIL — 5 quoted | no |
| Codex / arpeggio | PASS | FAIL — read-only `$TMPDIR` (AUT-421) | FAIL — 4 quoted | no |
| Codex / vesper | PASS | FAIL — read-only `$TMPDIR` (AUT-421) | FAIL — 4 quoted | no |

All four sequences were correct: branch, Linear claim (manual), commit with
the tier's pass, `touchstone pr open --expect-branch`, `pr answer`, `pr merge
--head`, fail-closed cleanup; none would push to `main`, hand-post a marker,
or record unrun validation. Criterion (1) is solved at the contract level.

## Contradictions, by owner

Touchstone (fixed in #969):

- `principles/git-workflow.md` enumerated an eight-step lifecycle against the
  steering's nine (no claim, no reconcile, an extra tree-check step).
- `git-workflow.md` "push each sub-task" vs the serious tier's pre-push pass
  and `local-review.md`'s one-batched-fix rule.
- `docs/pr-cli-contract.md` defined `applied` as requiring a merge queue; the
  tool accepts a queue-less consumer whose own policy declares none.
- The drive-by claim exception read as contradicting "claim before
  implementation"; it now covers only fixes with no tracker item.

Touchstone (routed): body-only findings have no executable re-request path
(`pr open` reuses the existing marker) — AUT-396.

arpeggio (fixed in arpeggio#52, AUT-406): the interim `validate.yml` and the
`.touchstone.toml` comment still said "once policy is applied"; CLAUDE.md
said checks "approve"; pre-commit comments named one hook type and called
pre-push "fast".

vesper (fixed in vesper#930): GEMINI.md's block lacked `--expect-head` and
the claim step while CLAUDE.md said they matched; GEMINI.md cited a
nonexistent AGENTS.md "Authoring Guide"; `setup.sh` advertised `touchstone
doctor`/`status`; settings wired the libexec hook path; script comments
described a merge queue. Routed (AUT-403): `worker.sh` records `--tier
normal` without classifying; `ship-pr.sh` binds merge before review exists.

## What this round settles

Criterion (1) passed in every cell for the first time. Criterion (2) passes
wherever the sandbox allows a temp file; AUT-421 is the only blocker for the
Codex cells. Criterion (3) failed everywhere, but every quoted contradiction
was either already fixed in flight or is fixed by the three PRs above; none
required a design change.

## Round 4

The confirmation run, after #969, arpeggio#52, and vesper#930 merge. Same
prompt, same four cells. Pass for the Claude cells requires (3) clean; the
Codex cells cannot pass (2) until AUT-421 lands and are scored on (1) and
(3). Round 4 is the last cold-start round for 3.2.x whatever the result; what
remains becomes tracked issues.
