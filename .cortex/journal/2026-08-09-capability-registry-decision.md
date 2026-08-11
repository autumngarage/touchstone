# Make the scope filter enforceable, and pay for its steering cost by routing memory hygiene out

**Date:** 2026-08-09
**Type:** decision
**Trigger:** T1.1
**Cites:** journal/2026-08-08-pr-merged-2155.md

> Every shipped file must declare which of Touchstone's three mission jobs it serves, checked deterministically; the mission moves from an issue into the steering block, funded by routing memory hygiene to `principles/`.

## Context

Touchstone's scope filter existed as prose in `TOUCHSTONE.md` — "does it constrain the agent, or merely serve it?" — with nothing behind it, and the actionable form of the test (the three jobs: constrain, make state legible, carry the contract) lived only in issue #694.

That gap produced measurable drift inside one release cycle. Auditing #694's cut list against `main` at v2.13.0 found **one of six cuts landed**: `lib/events.sh`, the lease-guarded resume in `open-pr.sh`, the 1,965-line `emergency-disclosure.sh`, and the doctor advisories all still ship. The release notes carry a "~44% smaller" claim against roughly 12%. Nothing failed, because nothing was checking.

The same audit surfaced a related failure: #593 was auto-closed by a `Closes` trailer that survived a revert inside its own PR (#680, commit 5 of 8), so a live bug read as fixed. Plans and claims were drifting from the tree in both directions.

## What we decided

**1. `capabilities.toml` is the scope ledger.** Every file under `bin/`, `bootstrap/`, `hooks/`, `lib/`, and `scripts/` declares a mission job plus a `why` that must say what the file does. Repo-only, deliberately not synced: it governs what Touchstone ships, and projects do not make Touchstone scope decisions.

**2. The check is deterministic and lives in an existing self-test.** Assertions were folded into `tests/test-steering-size-caps.sh` rather than a new file — the repo's review guide asks new assertions to join existing tests, and preflight already selects that test, so a governed-path change cannot skip the parity check. The surface is enumerated recursively so a file in a subdirectory or without a `.sh` suffix cannot ship undeclared.

**3. Condemned code is declared, not hidden.** A capability kept only until its removal lands is marked `cut` with a tracking issue, and its line count prints as scope debt on every run. Two entries could not be justified honestly on day one — `bootstrap/migrate-from-toolkit.sh` and `lib/codex-auth.sh` — and became #702 rather than being given a comfortable label.

**4. The mission moves into the steering block.** The three jobs now live in `TOUCHSTONE.md`, which every driver reads, instead of an issue that will eventually be closed.

**Alternatives weighed.** Per-subsystem *line budgets* were considered: they measure size, not justification, and a budget raise is a one-line diff that reads as routine. A *removal denylist* was considered: narrower, and it only catches regrowth of things already cut, not new arrivals. The registry was chosen because it forces the question at the moment of addition, which is the only moment the answer is cheap.

**Cost accepted.** `TOUCHSTONE.md` had 7 bytes of headroom under its 8 KiB cap. Rather than raise the cap — which would make cap-raising the normal response to wanting more steering — memory hygiene was routed to `principles/memory-hygiene.md` with a routing-table row. That is the remedy the cap test itself prescribes, and the trade is defensible: memory hygiene fires on a trigger, scope discipline fires on every decision to add something. Net 19 bytes smaller.

## Consequences / action items

- [x] `capabilities.toml` + assertions in `tests/test-steering-size-caps.sh` (PR #703)
- [x] Mission and three jobs in `TOUCHSTONE.md`, propagated to `AGENTS.md`, `GEMINI.md`, and both templates
- [x] #702 filed for the two unjustifiable capabilities
- [x] #593 reopened; the reverted-fix-closed-the-issue class recorded on #694
- [ ] Finish the five outstanding 2.13.0 cuts and let 2.14.0 carry the honest claim (#694)
- [ ] Nothing re-checks that a `Closes` trailer still describes the merged tree — no issue filed yet for that class
