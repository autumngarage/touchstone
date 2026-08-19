# Touchstone

**The standard baseline for a solo developer directing many agents across many projects.**

One person cannot read everything many agents produce. Touchstone exists so that they do not have to. It ships two things, and both are the product:

1. **Guidance prompts** — the steering an agent reads to know how to work: branch first, one concern per commit, answer every finding, reconcile issues, never bypass the gate.
2. **Push tooling** — the small script surface that makes an agent use GitHub *correctly*.

The goal is that every Autumn Garage project gets the same dev flow by adopting Touchstone, and that the flow is industry-leading practice for GitHub and agent-driven delivery. Adoption is **set-and-forget**: an adopted repository must remain correct if Touchstone never rewrites it again. V1 serves one operator's portfolio through public-quality interfaces; it does not build a speculative third-party platform. The durable boundary is defined in `docs/product-contract.md`.

**The second half is deliberately narrow.** The CLI validates declared project
checks, verifies tracker claims, and exposes three bounded source-only PR
operations. GitHub remains the review, findings, and merge surface; drivers
reconcile delivered work through the configured tracker API or CLI.
It does not stage, commit, or push code, and it never replaces GitHub's merge
verdict. Every operation retains a documented raw `git`/`gh` recovery path.

## Purpose

**Humans approve plans. Agents write and ship code. GitHub reviews code.**

Everything here exists to hold one of those three lines. To hold them, Touchstone does exactly three things:

1. **Constrain** — GitHub rejects direct, forced, unvalidated, unreviewed, unanswered, stale-head, and unresolved delivery to the default branch.
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
├── policy/         # Audited desired GitHub policy and rollback baseline
├── scripts/        # Issue, review, validation, compatibility, and policy operations
├── audits/         # Dated drift/health reports
├── feedback/       # Dated dogfooding notes from downstream projects
└── tests/          # Self-tests
```

The broad legacy CLI, bootstrap, and auto-update machinery was deleted with the
propagation channel: cutting propagation froze downstream projects safely on
their existing committed copies. The repository now contains the narrow
versioned CLI entrypoint, including read-only plan-first adoption and explicit
upgrade planning. Homebrew distribution remains a separate replacement
capability; neither may restore background propagation.
The organization-required workflow remains pinned to an immutable Touchstone
revision outside the consumer PR and executes the same project contract.

The surviving `templates/` describe the frozen pre-strip consumer shape and are
historical inputs for compatibility audits, not the new architecture.
`scripts/touchstone-run.sh` is the declaration-only schema-v1 validation
engine; its contract lives in [docs/validation-contract.md](docs/validation-contract.md).
`scripts/touchstone-tracker.sh` owns the tracker-neutral verified claim boundary;
its versioned outcomes live in [docs/tracker-contract.md](docs/tracker-contract.md).
Drivers reconcile delivered work through the configured tracker's API or CLI.
`scripts/touchstone-pr.sh` owns the three bounded PR sequencing operations; its
versioned output and raw recovery equivalents live in
[docs/pr-cli-contract.md](docs/pr-cli-contract.md).
Current replacement scope and sequencing live in the [canonical Linear execution plan](https://linear.app/autumngarage/document/touchstone-execution-plan-post-strip-baseline-cac4c56e593e), not this durable overview.

The configured AI reviewer reports `COMMENTED`, not `APPROVED`, so GitHub approval count does not represent it. The required `review-binding` check instead binds trusted review evidence to the exact head and requires a later qualifying answer for every finding; GitHub independently requires every inline thread resolved.

## Delivery

Raw `git` and `gh` remain the active delivery workflow. Source contributors can
exercise the three bounded operations after the branch is pushed:

```bash
bash bin/touchstone pr open --title "fix: some change" --body-file /tmp/pr-body
bash bin/touchstone pr status <n>
bash bin/touchstone pr merge <n> --head <reviewed-sha>
```

The exact raw recovery path remains:

```bash
git checkout -b fix/some-slug
# ... edit, then stage explicit paths ...
git commit -m "fix: what changed"
git push -u origin HEAD
gh pr create                      # put `Fixes AUT-123` (or `Closes #123`) in the PR body
gh pr comment <n> --body "@codex review"
# ... answer every finding, resolve every thread ...
gh pr merge <n> --squash --match-head-commit "$(gh pr view <n> --json headRefOid --jq .headRefOid)"
gh pr view <n> --json state,mergedAt      # confirm; the merge exit code lies in both directions
```

`principles/git-workflow.md` carries the full sequence, including thread resolution and the failure modes worth knowing about.

Answering inline review findings still uses the existing script because GitHub
needs four API calls to reply-and-resolve correctly:

```bash
bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file>
bash scripts/respond-review.sh <pr> --all-resolved-check
```

## Documentation

- **[TOUCHSTONE.md](TOUCHSTONE.md)** — the universal contract every driver reads
- **[git-workflow.md](principles/git-workflow.md)** — the full delivery sequence in raw `git` + `gh`
- **[engineering-principles.md](principles/engineering-principles.md)** — the principles every change is reviewed against
- **[product-contract.md](docs/product-contract.md)** — the durable product boundary, adoption/evolution contract, and anti-bloat admission test
- **[fresh-consumer-harness.md](docs/fresh-consumer-harness.md)** — scratch-repository adoption, compatibility, policy, and mutation proofs
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

The suite is deterministic, offline, and fetches nothing. The protected,
immutable workflow pinned by `policy/github/touchstone-main.json` runs the same
schema-v1 engine as local validation with no unrelated toolchain dependency.
The target repository carries no duplicate required workflow.

Lint is separate, at pre-commit: `shellcheck`, `shfmt`, `markdownlint`, `actionlint`.

## Contributing

Open a PR for improvements to principles, templates, scripts, hooks, or skills. The same delivery workflow above applies here — Touchstone ships through its own gate.
