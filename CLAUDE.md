# Touchstone — Claude Code Instructions

## Who You Are on This Project

You are maintaining the standard baseline for a solo developer directing many agents across many projects. Touchstone ships two things, and both are the product: the **guidance prompts** an agent reads to know how to work, and the **push scripts** that make the agent use GitHub correctly. Quality matters doubly — a bug here is a bug in how every project ships.

Codex and other AGENTS.md-native tools read `AGENTS.md`; Gemini CLI reads `GEMINI.md`. Keep `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` aligned when workflow, architecture, or hard-won lessons change.

## Universal steering

The universal contract is `TOUCHSTONE.md`. `touchstone steering install` puts it in `~/.claude/CLAUDE.md`, so it is already loaded here on any machine with the install; this file does not import it a second time. If `/context` lists no Touchstone steering block under Memory files, read `TOUCHSTONE.md` before the first edit.

Codex and Gemini read the same block through the managed markers in `AGENTS.md` and `GEMINI.md`. **Edit `TOUCHSTONE.md`, then run `bash scripts/render-steering.sh`**; `tests/test-steering-render.sh` fails on drift.

## Touchstone-Specific Principles

- **A rule must live at the layer that can enforce it.** GitHub enforces (rulesets, required checks). Prose instructs. Scripts observe and sequence — they never adjudicate. Nothing may live at two layers at once. Re-deciding locally what GitHub decides at the merge button is what grew this repo to 49,000 lines; it is the specific mistake to not repeat.
- **Adoption must stay set-and-forget.** Consumer repositories carry declarations and narrow integration points, never copied Touchstone implementation. An adopted repository remains valid without routine rewrites; evolution is backward-compatible or an explicit reviewable upgrade. `docs/product-contract.md` is the canonical boundary.
- **Delete by default.** The burden of proof is on keeping. A deletion is recoverable from git history; a file kept on "it might be useful" accretes tests, findings, and dependents. A change earns its way in when a real failure demanded it — not because a review round suggested it.
- **Self-tests are mandatory.** Run focused deterministic tests for changed behavior before pushing. The protected hosted workflow owns the complete suite; do not repeat it locally as confirmation. If effective policy lacks that workflow, run the complete suite locally and track the rollout gap.
- **Downstream projects are frozen, deliberately.** anima, vesper, arpeggio, and convoy carry committed copies of the old scripts. Deleting the bootstrap means no stripped release can reach them: they keep working exactly as they did. Re-adoption is a separate, later decision — do not "fix" them from here.

## Key Files

| File | Purpose |
|------|---------|
| `scripts/respond-review.sh` (`touchstone pr answer`) | Reply to a review finding and resolve its thread in one step (GitHub needs four API calls) |
| `scripts/touchstone-tracker.sh` | Versioned tracker-neutral verified claim adapter |
| `scripts/touchstone-pr.sh` | Source entrypoint for the `open`/`status`/`merge` PR operations (`answer` lives in `respond-review.sh`) |
| `scripts/claim-issue.sh` | GitHub transport used by the tracker adapter |
| `hooks/branch-guard.sh` | Refuses `git commit` on the default branch at the Claude tool boundary |
| `tests/test-steering-size-caps.sh` | Steering size caps plus path integrity — every path the docs name must exist |

Release history lives in `git log` and `gh release list`; there is no `CHANGELOG.md`, deliberately (`principles/documentation-ownership.md`).

## Delivery

The installed CLI is the sequencer everywhere; raw `git` and `gh` are the
documented recovery path. In this source checkout,
`bash bin/touchstone pr open|status|merge|answer`
exercises the four bounded operations (`answer` replies to a finding, records
its disposition, resolves its thread, and — under gate behavior contract 3 —
posts the one idempotent attest request when the last thread resolves);
`docs/pr-cli-contract.md` records their stable schema and exact raw
equivalents. Pass `--expect-branch <branch>` to `open` with the branch name written out:
it acts on whatever branch the invoking directory has checked out, which
differs per worktree. Never derive it from `$(git branch --show-current)` —
that reads the same checkout the command reads, so it agrees with a wrong
worktree and binds nothing.

## Distribution

Releases are tag-driven and Homebrew-distributed; a release is a name for reviewed state, never a new state. The cut procedure, the non-Homebrew installer, and the hook-by-name rule for consumer settings live in `README.md` under Distribution. Homebrew upgrades the installed tool only and never mutates a repository. The tool version and the project-contract schema are separate lines; see `docs/product-contract.md`.
