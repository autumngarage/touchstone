# Touchstone — Claude Code Instructions

## Who You Are on This Project

You are maintaining the standard baseline for a solo developer directing many agents across many projects. Touchstone ships two things, and both are the product: the **guidance prompts** an agent reads to know how to work, and the **push scripts** that make the agent use GitHub correctly. Quality matters doubly — a bug here is a bug in how every project ships.

Codex and other AGENTS.md-native tools read `AGENTS.md`; Gemini CLI reads `GEMINI.md`. Keep `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` aligned when workflow, architecture, or hard-won lessons change.

## Universal steering

@TOUCHSTONE.md

The block above is the canonical universal contract: agent roles, the engineering principles, the never-commit-on-main rule, the required delivery workflow, and a routing table that points to deeper docs rather than inlining them. Codex and Gemini agents read the same content via the `<!-- touchstone:steering -->` managed block in `AGENTS.md` / `GEMINI.md`.

**That block is currently hand-maintained in four files.** The renderer that generated it (lib/touchstone-block.sh) went out with the strip. Edit `TOUCHSTONE.md` first, then mirror the change into the managed block of `AGENTS.md`, `GEMINI.md`, `templates/AGENTS.md`, and `templates/GEMINI.md`. Making `AGENTS.md` canonical and retiring the duplication is tracked in #733.

## Touchstone-Specific Principles

- **A rule must live at the layer that can enforce it.** GitHub enforces (rulesets, required checks). Prose instructs. Scripts observe and sequence — they never adjudicate. Nothing may live at two layers at once. Re-deciding locally what GitHub decides at the merge button is what grew this repo to 49,000 lines; it is the specific mistake to not repeat.
- **Adoption must stay set-and-forget.** Consumer repositories carry declarations and narrow integration points, never copied Touchstone implementation. An adopted repository remains valid without routine rewrites; evolution is backward-compatible or an explicit reviewable upgrade. `docs/product-contract.md` is the canonical boundary.
- **Delete by default.** The burden of proof is on keeping. A deletion is recoverable from git history; a file kept on "it might be useful" accretes tests, findings, and dependents. A change earns its way in when a real failure demanded it — not because a review round suggested it.
- **Templates are legacy transition inputs, not the future contract.** Nothing currently copies them. They describe the frozen downstream shape and remain available for the consumer audit; do not extend their detection, setup, or vendored-runner model. `docs/product-contract.md` defines the replacement boundary.
- **Self-tests are mandatory.** Run every `tests/test-*.sh` before pushing. The suite must stay deterministic, offline, and free of live model/provider quota.
- **Downstream projects are frozen, deliberately.** anima, vesper, arpeggio, and convoy carry committed copies of the old scripts. Deleting the bootstrap means no stripped release can reach them: they keep working exactly as they did. Re-adoption is a separate, later decision — do not "fix" them from here.

## Testing

```bash
# Before any push
for test in tests/test-*.sh; do
  echo "==> $test"
  bash "$test" || exit 1
done
```

The suite is the "is this safe to push" gate — deterministic, offline, and fetching nothing. The protected workflow pinned by `policy/github/touchstone-main.json` runs the same loop as the required check, with no third-party dependency of any kind. The target repository carries no duplicate validation workflow. That is deliberate: a required check that can go red because a package host had a bad minute is not a gate (#742, #803, #808).

Lint is not part of the test suite. It runs at pre-commit and via `pre-commit run --all-files`: `shellcheck`, `shfmt`, `markdownlint`, and `actionlint`. `.pre-commit-config.yaml` and `.markdownlint.json` are the canonical config.

## Architecture

```
touchstone/
├── TOUCHSTONE.md   # Canonical steering router — the universal contract for all drivers
├── docs/           # Touchstone-specific product contract and project documentation
├── principles/     # The judgment layer — universal docs routed to from TOUCHSTONE.md
├── skills/         # User-scoped Claude Code skills
├── templates/      # Legacy transition inputs (nothing copies them today)
├── hooks/          # branch-guard.sh — the PreToolUse hook wired in .claude/settings.json
├── scripts/        # The surviving script surface: claim-issue, issue-claim-check,
│                   #   respond-review, touchstone-run
├── audits/         # Dated drift/health reports (never auto-modified)
├── feedback/       # Dated dogfooding notes from downstream projects
└── tests/          # Self-tests
```

## Key Files

| File | Purpose |
|------|---------|
| `TOUCHSTONE.md` | Canonical steering router — drives CLAUDE.md (@-import) and the AGENTS.md/GEMINI.md managed block |
| `principles/git-workflow.md` | The full delivery sequence in raw `git` + `gh`, including thread resolution |
| `scripts/respond-review.sh` | Reply to a review finding and resolve its thread in one step (GitHub needs four API calls) |
| `scripts/touchstone-tracker.sh` | Versioned tracker-neutral verified claim adapter |
| `scripts/touchstone-pr.sh` | Three versioned, bounded PR sequencing operations |
| `scripts/claim-issue.sh` | GitHub transport used by the tracker adapter |
| `hooks/branch-guard.sh` | Refuses `git commit` on the default branch at the Claude tool boundary |
| `tests/test-steering-size-caps.sh` | Steering size caps plus path integrity — every path the docs name must exist |

Release history lives in `git log` and `gh release list` — there is no `CHANGELOG.md`. Duplicating release history in a markdown file was a documentation-ownership violation (see `principles/documentation-ownership.md`).

## Delivery

Use `touchstone pr open|status|merge` for the bounded delivery
operations. `docs/pr-cli-contract.md` records their stable schema and exact raw
`git`/`gh` equivalents; those raw commands remain the recovery path and the
portable contract shared with drivers that have not installed the CLI.

## Distribution — currently absent

The `touchstone` CLI, the bootstrap, the auto-update path, and the Homebrew release automation were all deleted. Nothing distributes Touchstone right now, and nothing needs to: the projects that use it are frozen on their committed copies.

The rebuild is Homebrew-distributed and deliberately thin — it observes and sequences, never adjudicates. Homebrew upgrades the installed tool only; it never mutates repositories. Adoption compiles project facts into an explicit versioned contract, and already-correct consumers remain valid without routine sync. Restoring the tap-bump workflow is part of that work, not of this state.

The configured AI reviewer reports `COMMENTED`, not `APPROVED`, so GitHub approval count does not represent it. The required `review-binding` check binds trusted review evidence to the exact head and requires a later qualifying answer for every finding; GitHub independently requires every inline thread resolved.
