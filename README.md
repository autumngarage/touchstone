# Touchstone

**The standard baseline for a solo developer directing many agents across many projects.**

One person cannot read everything many agents produce. Touchstone exists so that they do not have to. It ships two things, and both are the product:

1. **Guidance prompts** — the steering an agent reads to know how to work: branch first, one concern per commit, answer every finding, reconcile issues, never bypass the gate.
2. **Push tooling** — the small script surface that makes an agent use GitHub *correctly*.

The goal is that every Autumn Garage project gets the same dev flow by adopting Touchstone, and that the flow is industry-leading practice for GitHub and agent-driven delivery. Adoption is **set-and-forget**: an adopted repository must remain correct if Touchstone never rewrites it again. V1 serves one operator's portfolio through public-quality interfaces; it does not build a speculative third-party platform. The durable boundary is defined in `docs/product-contract.md`.

**What the second half ships today is narrower than that ambition.** The surviving scripts claim issues, answer review threads, and run a project's checks. **Nothing here opens a PR, binds a review to its head, or merges** — those are raw `git` and `gh`, documented below and in `principles/git-workflow.md`. Rebuilding that half as a thin CLI is the open work; until it lands, read "push tooling" as a goal, not an inventory.

## Purpose

**Humans approve plans. Agents write and ship code. GitHub reviews code.**

Everything here exists to hold one of those three lines. To hold them, Touchstone does exactly three things:

1. **Constrain** — you cannot commit to the default branch, merge on a red check, or merge with an unresolved thread. Reviewing the head you merge is required but unenforced; see the known gap below.
2. **Make state legible** — what happened lives in git, PRs, and issues, verifiable without trusting an agent's narration.
3. **Carry the contract** — the same rules reach every project and every agent.

The operating rule that keeps it honest: **a rule must live at the layer that can actually enforce it.** GitHub enforces (rulesets, required checks). Prose instructs. Scripts observe and sequence — they never adjudicate. Nothing may live at two layers at once.

## Current state — stripped, mid-rebuild

Touchstone had grown to roughly 49,000 lines, most of it re-implementing what GitHub already does. 43% of the two shipping scripts re-decided locally what GitHub decides at the merge button, and no line of the codebase ever read the server-side branch protection settings that already expressed the same rules.

That machinery has been deleted. What remains is the judgment layer plus a small script surface:

```
touchstone/
├── TOUCHSTONE.md   # Canonical steering router — the universal contract for all drivers
├── docs/           # Touchstone-specific product contract and project documentation
├── principles/     # The judgment layer, routed to from TOUCHSTONE.md
├── skills/         # User-scoped Claude Code skills
├── templates/      # Legacy transition inputs; nothing copies them
├── hooks/          # branch-guard.sh — PreToolUse hook wired in .claude/settings.json
├── scripts/        # claim-issue, issue-claim-check, respond-review, touchstone-run
├── audits/         # Dated drift/health reports
├── feedback/       # Dated dogfooding notes from downstream projects
└── tests/          # Self-tests
```

**There is no CLI, no bootstrap, and no auto-update right now.** They were deleted with the propagation channel, deliberately and first: cutting propagation is what froze the downstream projects safely in place on their existing committed copies. The replacement is a thin, Homebrew-distributed CLI and a full-SHA-pinned CI adapter around one versioned project contract. Project-type detection compiles an adoption proposal once; validation executes accepted declarations without guessing. Upgrading the installed tool never mutates repositories.

The surviving `scripts/touchstone-run.sh` and `templates/` still describe the frozen pre-strip consumer shape. They are historical inputs for the consumer audit, not the new architecture. Current replacement scope and sequencing live in the [canonical Linear execution plan](https://linear.app/autumngarage/document/touchstone-execution-plan-post-strip-baseline-cac4c56e593e), not this durable overview.

**Known gap:** an AI reviewer can never file an `APPROVED` review — GitHub reserves formal approval for real user accounts — so `required_approving_review_count` cannot express "this was reviewed." The check-run that could express it was deleted alongside the local mirror it duplicated. Until it is rebuilt as a small required status check, review enforcement is advisory. This is known and accepted, not overlooked.

## Delivery

There is no wrapper. Ship with `git` and `gh` directly:

```bash
git checkout -b fix/some-slug
# ... edit, then stage explicit paths ...
git commit -m "fix: what changed"
git push -u origin HEAD
gh pr create                      # put `Closes #123` in the PR BODY, not just the commit
gh pr comment <n> --body "@codex review"
# ... answer every finding, resolve every thread ...
gh pr merge <n> --squash --match-head-commit "$(gh pr view <n> --json headRefOid --jq .headRefOid)"
gh pr view <n> --json state,mergedAt      # confirm; the merge exit code lies in both directions
```

`principles/git-workflow.md` carries the full sequence, including thread resolution and the failure modes worth knowing about.

Answering review findings is the one place a script genuinely earns its keep, because GitHub needs four API calls to reply-and-resolve correctly:

```bash
bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file>
bash scripts/respond-review.sh <pr> --all-resolved-check
```

## Documentation

- **[TOUCHSTONE.md](TOUCHSTONE.md)** — the universal contract every driver reads
- **[git-workflow.md](principles/git-workflow.md)** — the full delivery sequence in raw `git` + `gh`
- **[engineering-principles.md](principles/engineering-principles.md)** — the principles every change is reviewed against
- **[product-contract.md](docs/product-contract.md)** — the durable product boundary, adoption/evolution contract, and anti-bloat admission test
- **[ai-delivery-architecture.md](principles/ai-delivery-architecture.md)** — the AI-authored change lifecycle
- **[pre-implementation-checklist.md](principles/pre-implementation-checklist.md)** — the gate before a non-trivial change
- **[agent-swarms.md](principles/agent-swarms.md)** — parallel agents, slice manifests, worktree isolation
- **[audit-weak-points.md](principles/audit-weak-points.md)** — auditing a bug class after fixing one instance
- **[documentation-ownership.md](principles/documentation-ownership.md)** — who owns which doc, and what not to duplicate
- **[file-upstream-bugs.md](principles/file-upstream-bugs.md)** — don't silently work around an upstream bug
- **[memory-hygiene.md](principles/memory-hygiene.md)** — agent memory is a cache, not truth

## Testing

```bash
for test in tests/test-*.sh; do
  echo "==> $test"
  bash "$test" || exit 1
done
```

The suite is deterministic, offline, and fetches nothing. `.github/workflows/validate.yml` runs the same loop as the required check with no third-party dependency of any kind — a required check that can go red because a package host had a bad minute is not a gate.

Lint is separate, at pre-commit: `shellcheck`, `shfmt`, `markdownlint`, `actionlint`.

## Contributing

Open a PR for improvements to principles, templates, scripts, hooks, or skills. The same delivery workflow above applies here — Touchstone ships through its own gate.
