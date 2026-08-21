# Cold-start dogfooding, round 2 — 2026-08-21

Same method as [round 1](2026-08-21-cold-start-dogfooding.md): fresh Claude
Code and Codex (`codex exec --sandbox read-only`) agents, no session context,
one read-only prompt per repository, after the round-1 fixes (AUT-407, 408, 409, 412; AUT-410 and 411 still open)
shipped in touchstone 3.2.0 and the consumer policies were applied to vesper
and arpeggio. Convoy is still pending adoption (AUT-402).

Observed state at run time (~08:00–09:30Z): vesper and arpeggio both report
`enforcement: applied` (queue-less, AUT-413) from `touchstone policy status`
run by the operator; the agents in the read-only sandbox could not run it
(see finding 3).

## Results

| Agent | Repo | Confidence | Would it have shipped correctly? |
| --- | --- | --- | --- |
| Claude | arpeggio | medium | Yes: `check.sh` → `touchstone pr open --expect-branch` → `pr merge --head`; named the Linear claim as manual |
| Claude | vesper | low–medium | Not on the first try: the required `validate` check failed on every PR (engine pin, then merge-commit reads) and the generated body failed `delivery-evidence` |
| Codex | vesper | low | Mechanically yes via `ship-pr.sh`; refused to claim a Linear assignment it could not make; would hand-assemble reply/resolve |
| Codex | arpeggio | low | Same blocker: "no Linear MCP in this session is a genuine blocker, not an ambiguity I would work around" |

Round 1 found the happy path and stopped at enforcement legibility. Round 2
found the happy path *and* the policy read, and stopped at two walls: the
Linear claim has no transport, and the required check was red — first for a
reason no driver could fix from inside the repository (the central engine
pin, finding 1), then for a consumer-local defect that only the merge-ref
checkout exposed (vesper's validator, finding 2, fixed in vesper#929).

## Findings, generalised

1. **The required `validate` workflow failed every schema-2 consumer.** The
   pinned `validate.yml` fetched `touchstone-run.sh` at a schema-1 revision
   eight days stale. Fixed: touchstone-workflows#7 re-pins to v3.2.0;
   #965 moves the policy pins; policies re-applied to all three repositories.
   Structural fix (make the engine revision move with the release) stays
   open as AUT-417 — a pin that must be bumped by hand will go stale again.
2. **The required workflow checks out `refs/pull/N/merge`, and a per-commit
   history walk reads that merge commit as a product commit.** vesper's
   release-note validator used `git diff-tree <commit>`, which prints nothing
   for a merge, so every PR failed while the same command passed locally. The
   obvious fix, `-m --first-parent`, is also wrong (`-m` diffs against every
   parent; Codex caught it on #965). Correct form: `git diff-tree <c>^1 <c>`.
   Generalised into `docs/validation-contract.md`; vesper#929 carries the
   implementation with a divergent-parent regression test.
3. **Read-only commands are not operationally read-only** (2/2 Codex,
   repeat of round 1 finding 7). `steering check` and `policy status` need
   a writable `$TMPDIR`; in a read-only sandbox the exact command the
   steering prescribes for "inspect the effective rules" fails. Still open;
   it is the reason both Codex runs could not confirm `applied`.
4. **The Linear claim remains the top blocker** (2/2 Codex, 2/2 Claude
   noted it). Steering step 3 now says the claim is manual for Linear, which
   the agents read correctly — and then stopped, because a mandatory manual
   step with no tool is a stop for an autonomous agent. AUT-410: a transport
   behind `touchstone tracker claim AUT-n` that assigns and re-reads.
5. **`touchstone pr answer` was documented before it was installed** (2/2
   Codex): 3.2.0 on the machine had no `answer`. #960 ships it; 3.2.1 is the
   release. Review of #960 added three hardenings worth recording as a class:
   every printed "next step" that names a SHA must name the *captured* one,
   and every mutation must capture its coordinates before it runs and
   re-read them after.
6. **`touchstone upgrade --help` ran `brew upgrade`** (Codex arpeggio). A
   help probe must never mutate. Fixed in #960 with a fake-brew regression.
7. **Generated evidence, second pass** (Codex vesper): the body still said
   "serious" for every change and "run by the required validate workflow"
   for tests that only run at release. vesper#929: `--tier` is required from
   the caller, the generator runs `touchstone validate` itself and binds the
   result, the intent, and the push to one captured SHA, and says what it
   did not run.
8. **Stale prose, second sweep**: `ai-delivery-architecture.md` (`gh pr
   create` twice), `local-review.md` (`.touchstone-review.toml`), the
   stacked-PR opener. #966.
9. **Per-commit release-note fragments + agent commits**: three of my own
   vesper commits were silently eaten by the commit-stage fragment check
   (the hook fails, nothing is committed, the push goes out with the old
   head). Project-local and deliberate, but the failure mode — a local hook
   that rejects the commit while the driver believes it landed — is now
   tracked as AUT-419 (make the refusal unmissable; say "verify `git log
   -1` after every commit" explicitly in the steering).

## What changed between the rounds

Round 1 → round 2, all four agents moved past "cannot learn what GitHub
enforces": the read now exists. The two Codex runs then hit "the read-only
sandbox will not let me run it" (finding 3); the two Claude runs ran it and
stopped at the Linear claim and, on vesper, the red required check. That is
progress on the contract plus one narrower tooling defect.

## Next round

After 3.2.1 is installed (`pr answer`, `upgrade --help`), vesper#929 and
touchstone #965/#966 are merged, and AUT-410 has a transport or an explicit "claim via
the Linear MCP tool, here is the call" step in the steering. Include convoy
on Windows Git Bash with Codex once AUT-402 lands.
