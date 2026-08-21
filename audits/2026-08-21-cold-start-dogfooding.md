# Cold-start dogfooding — 2026-08-21

Method (operator-directed): on each adopted repository, a fresh Claude Code
agent and a fresh Codex agent (`codex exec --sandbox read-only`), with no
session context, were given the same read-only prompt: read the driver file,
the installed steering and routed principles, `.touchstone.toml`,
`.touchstone-tracker.toml`, hooks and `scripts/`; then list the exact commands
to ship a small fix, say what GitHub enforces versus what is merely
instructed, name the tracker and closing grammar, quote anything ambiguous or
stale, and rate confidence. Findings are treated as evidence about the
contract first; project-local fixes only where the contract is right and the
project diverged.

Repositories: vesper (at PRs 927/928, policy not yet applied), arpeggio (at PR
51, policy not yet applied). Convoy follows its adoption (AUT-402).

## Results

| Agent | Repo | Confidence | Would it have shipped correctly? |
| --- | --- | --- | --- |
| Claude | vesper | medium | Yes, once it listed `scripts/` (CLAUDE.md at that head did not name `ship-pr.sh`); would have reinstalled steering on the check's advice |
| Codex | vesper | medium | Yes, via `ship-pr.sh --expect-branch --expect-head --return-on-findings`; refused to state enforcement it could not audit |
| Claude | arpeggio | medium | Yes, via `check.sh` → `touchstone pr open` → `pr merge --head`; PR body would have claimed a gate that is not there |
| Codex | arpeggio | medium | Yes; could not verify live policy and said so |

All four found the happy path and the exact-head binding; all four stopped at
the same wall: they could not learn, from the tool, what GitHub enforces.

## Findings, generalised

1. **Enforcement is not legible from the tool** (4/4). `adopt --check` says
   "remote policy: separate operation"; `pr status` does not enumerate rules.
   Agents ran four `gh api` calls and read a workflow comment to find that
   nothing protected `main`. Every agent named this as the single most
   valuable fix. → AUT-408 (`enforcement: applied | not applied` in
   `adopt --check` / `pr status`; `pr merge` fails closed on an unguarded
   base).
2. **`touchstone steering check` reported DRIFT on a current machine and
   prescribed a mutation** (2/2 Claude). The installed block predated the
   3.1 rename; nothing refreshes it after `brew upgrade`, and the message
   does not say that `install` rewrites only the managed block. One agent
   would have overwritten newer steering on the check's say-so. → AUT-409.
3. **The Linear claim the steering calls mandatory and race-safe does not
   exist** (4/4). `touchstone tracker claim AUT-n` always returns
   `unverifiable linear-transport-unavailable`; every agent then planned a
   manual MCP assign + re-read. Steering step 3 must say that for Linear, or
   the adapter must gain a transport. → AUT-410.
4. **`respond-review.sh` is shipped but unreachable** (3/4): not on PATH,
   not a subcommand, not named in the installed principles, so agents fall
   back to hand-assembled `gh api` + GraphQL. → AUT-411 (`touchstone pr
   answer`).
5. **Routed documents still describe the pre-3 layout** (4/4):
   `coderabbit review … -c principles/local-review-contract.md` (path is
   `~/.touchstone/principles/…` now); "`bash scripts/touchstone-tracker.sh
   claim`"; the squash-cleanup test `git diff --quiet main...<branch>` is
   wrong after a squash; `touchstone validate --help` says schema-v1;
   `tracker --help` prints a script path; `pr status` shows `merge state:
   UNKNOWN` on a merged PR; the abbreviated "`pr open --expect-branch
   <branch>`" omits the required `--title`/`--body-file`; docs mention only
   Codex where CodeRabbit also reviews. → AUT-412.
6. **Generated PR bodies assert evidence they did not observe** (2/4, vesper
   `ship-pr.sh`: "run by the required validate workflow", tier hardcoded to
   `serious`). → AUT-408 (rule) and AUT-403 (vesper fix; also scrapes every
   mentioned `AUT-n` into `Fixes`).
7. **"Read-only" commands need a temp file** (Codex sandbox, 2/2): `adopt
   --check`, `steering check`, `pr status` failed under a read-only
   filesystem. Low severity; folded into AUT-412.
8. Confirmed reproduction of the vesper session report: at #927,
   `CLAUDE.md` did not name the ship path; the general fix is the steering
   naming `touchstone pr open|merge` (AUT-407, #957), not per-repo prose.

## What stays project-local

- vesper: `ship-pr.sh` tier/evidence/`Fixes` scraping (AUT-403); the Swift
  suite not in the per-PR gate (AUT-313, deliberate).
- arpeggio: the interim `validate.yml` and its test (AUT-406).

## Next round

Repeat after AUT-408/409/410/411/412 land and after each consumer policy is
applied; include convoy on Windows Git Bash with Codex.
