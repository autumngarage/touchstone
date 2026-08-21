# Touchstone — Claude Code Instructions

## Who You Are on This Project

You are maintaining the standard baseline for a solo developer directing many agents across many projects. Touchstone ships two things, and both are the product: the **guidance prompts** an agent reads to know how to work, and the **push scripts** that make the agent use GitHub correctly. Quality matters doubly — a bug here is a bug in how every project ships.

Codex and other AGENTS.md-native tools read `AGENTS.md`; Gemini CLI reads `GEMINI.md`. Keep `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` aligned when workflow, architecture, or hard-won lessons change.

## Universal steering

@TOUCHSTONE.md

The block above is the canonical universal contract: agent roles, the engineering principles, the never-commit-on-main rule, the required delivery workflow, and a routing table that points to deeper docs rather than inlining them. Codex and Gemini agents read the same content via the `<!-- touchstone:steering -->` managed block in `AGENTS.md` / `GEMINI.md`.

**Edit `TOUCHSTONE.md`, then run `bash scripts/render-steering.sh`.** It rewrites the managed block in `AGENTS.md` and `GEMINI.md` from the canonical file, leaving content outside the markers untouched. `tests/test-steering-render.sh` fails if any block drifts, so a forgotten render is caught before it ships rather than becoming divergent contracts.

## Touchstone-Specific Principles

- **A rule must live at the layer that can enforce it.** GitHub enforces (rulesets, required checks). Prose instructs. Scripts observe and sequence — they never adjudicate. Nothing may live at two layers at once. Re-deciding locally what GitHub decides at the merge button is what grew this repo to 49,000 lines; it is the specific mistake to not repeat.
- **Adoption must stay set-and-forget.** Consumer repositories carry declarations and narrow integration points, never copied Touchstone implementation. An adopted repository remains valid without routine rewrites; evolution is backward-compatible or an explicit reviewable upgrade. `docs/product-contract.md` is the canonical boundary.
- **Delete by default.** The burden of proof is on keeping. A deletion is recoverable from git history; a file kept on "it might be useful" accretes tests, findings, and dependents. A change earns its way in when a real failure demanded it — not because a review round suggested it.
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
├── hooks/          # branch-guard.sh — the PreToolUse hook wired in .claude/settings.json
├── scripts/        # The surviving script surface: claim-issue, respond-review,
│                   #   touchstone-run
├── audits/         # Dated drift/health reports (never auto-modified)
├── feedback/       # Dated dogfooding notes from downstream projects
└── tests/          # Self-tests
```

## Key Files

| File | Purpose |
|------|---------|
| `TOUCHSTONE.md` | Canonical steering router — drives CLAUDE.md (@-import) and the AGENTS.md/GEMINI.md managed block |
| `principles/git-workflow.md` | The full delivery sequence in raw `git` + `gh`, including thread resolution |
| `scripts/respond-review.sh` (`touchstone pr answer`) | Reply to a review finding and resolve its thread in one step (GitHub needs four API calls) |
| `scripts/touchstone-tracker.sh` | Versioned tracker-neutral verified claim adapter |
| `scripts/touchstone-pr.sh` | Source entrypoint for three bounded PR operations |
| `scripts/claim-issue.sh` | GitHub transport used by the tracker adapter |
| `hooks/branch-guard.sh` | Refuses `git commit` on the default branch at the Claude tool boundary |
| `tests/test-steering-size-caps.sh` | Steering size caps plus path integrity — every path the docs name must exist |

Release history lives in `git log` and `gh release list` — there is no `CHANGELOG.md`. Duplicating release history in a markdown file was a documentation-ownership violation (see `principles/documentation-ownership.md`).

## Delivery

Raw `git` and `gh` remain the active delivery workflow until distribution
lands. In this source checkout, `bash bin/touchstone pr open|status|merge`
exercises the three bounded operations; `docs/pr-cli-contract.md` records their stable
schema and exact raw equivalents. Pass `--expect-branch <branch>` to `open` with the branch name written out:
it acts on whatever branch the invoking directory has checked out, which
differs per worktree. Never derive it from `$(git branch --show-current)` —
that reads the same checkout the command reads, so it agrees with a wrong
worktree and binds nothing.

## Distribution — Homebrew, tag-driven

Touchstone is distributed through `autumngarage/homebrew-touchstone`. A release is a name for reviewed state, never a new state: bump `VERSION` through an ordinary PR, then

```bash
git tag -a vX.Y.Z -m "touchstone X.Y.Z" <reviewed main sha>
git push origin vX.Y.Z
gh release create vX.Y.Z --verify-tag --generate-notes
```

`.github/workflows/release.yml` reacts to the published release and rewrites the tap formula's `url` and `sha256` through the shared `homebrew-bump` workflow; `brew upgrade touchstone` sees it about a minute later. Homebrew upgrades the installed tool only — it never mutates a repository.

Where Homebrew does not run — Windows Git Bash (Codex on convoy), Linux — `install.sh` installs the same reviewed release: it reads the tap formula as the one record of the release's tarball URL and sha256, verifies the download, and unpacks it under `~/.touchstone/` with a `bin/touchstone` wrapper (fetch `install.sh` from the release tag — `curl -fsSL -o install.sh https://raw.githubusercontent.com/autumngarage/touchstone/vX.Y.Z/install.sh` — and run the saved file; never pipe a moving branch into bash). `touchstone upgrade` re-runs it there and delegates to `brew upgrade` on a Homebrew install. Consumers reference hooks by name — `touchstone hook branch-guard` — so their settings never encode where the tool lives; settings that still point at the Homebrew libexec path (vesper, arpeggio, and the 2026-08-20 adoption audit) keep working on macOS and are migrated to the named form as each consumer is next touched. Touchstone does not write hook settings; the named form is what a consumer's own settings file should carry. `tests/test-project-root.sh` exercises the installer offline against a locally built archive and formula. Adoption compiles project facts into an explicit versioned contract, and already-correct consumers remain valid without routine sync. The tool version (`VERSION`, `touchstone version`) and the project-contract schema are separate lines; see `docs/product-contract.md`.

The configured AI reviewer reports `COMMENTED`, not `APPROVED`, so GitHub approval count does not represent it. The required `review-gate` workflow binds trusted review evidence to the exact head and requires a later qualifying answer for every finding; GitHub independently requires every inline thread resolved.
