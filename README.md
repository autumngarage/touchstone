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
versioned CLI entrypoint, including read-only plan-first adoption; steering
ships with the tool itself (`touchstone steering install`), so adoption writes
declarations only. Homebrew distribution remains a separate replacement
capability; neither may restore background propagation.
The organization-required workflow remains pinned to an immutable Touchstone
revision outside the consumer PR and executes the same project contract.

Machine onboarding is one-time and keeps credentials out of review tools and
durable review state:

```bash
touchstone steering install
touchstone review setup
```

The second command securely saves a dedicated OpenRouter key in macOS Keychain.
`touchstone review check` validates the credential, local tools, and versioned
review policy without a provider request. `touchstone review run` sends only the
staged diff in one cost-bounded OpenRouter request, then reports the selected
model, tokens, cost, and findings. The policy asks OpenRouter Auto Router for
its low-cost tier under absolute price ceilings rather than naming one concrete
model. Serious and PR-visible reviews remain on their default Codex paths.

`scripts/touchstone-run.sh` is the declaration-only validation engine,
accepting schema 1 and schema 2; its contract lives in [docs/validation-contract.md](docs/validation-contract.md).
`scripts/touchstone-tracker.sh` owns the tracker-neutral verified claim boundary;
its versioned outcomes live in [docs/tracker-contract.md](docs/tracker-contract.md).
Drivers reconcile delivered work through the configured tracker's API or CLI.
`scripts/touchstone-pr.sh` owns the three bounded PR sequencing operations; its
versioned output and raw recovery equivalents live in
[docs/pr-cli-contract.md](docs/pr-cli-contract.md).
Current replacement scope and sequencing live in the [canonical Linear execution plan](https://linear.app/autumngarage/document/touchstone-execution-plan-post-strip-baseline-cac4c56e593e), not this durable overview.

The configured AI reviewer reports `COMMENTED`, not `APPROVED`, so GitHub approval count does not represent it. The required `review-gate` workflow instead binds trusted review evidence to the exact head and requires a later qualifying answer for every finding; GitHub independently requires every inline thread resolved.

## Delivery

Raw `git` and `gh` remain the active delivery workflow. Source contributors can
exercise the three bounded operations after the branch is pushed:

```bash
bash bin/touchstone pr open --title "fix: some change" --body-file /tmp/pr-body \
  --expect-branch fix/some-change
bash bin/touchstone pr status <n>
bash bin/touchstone pr merge <n> --head <reviewed-sha>
```

`open` acts on the branch the invoking directory has checked out, which
differs per worktree; `--expect-branch` states which one you meant, the way
`merge --head` states which commit was reviewed. Write the branch name out.
`$(git branch --show-current)` reads the same checkout the command reads, so
it agrees with a wrong worktree and binds nothing. Two pull requests were
opened for the wrong branch before this option existed.

The exact raw recovery path remains:

```bash
git checkout -b fix/some-slug
# ... edit, then stage explicit paths ...
git commit -m "fix: what changed"
git push -u origin HEAD
cp .github/pull_request_template.md /tmp/pr-body
# Fill every required section and Validation row; keep `Fixes AUT-123` in the body.
bash bin/touchstone pr open --title "fix: what changed" --body-file /tmp/pr-body \
  --expect-branch fix/some-slug   # creates the PR and posts the bound review request
# ... answer every finding, fix the high-severity ones, resolve every thread ...
gh pr merge <n> --squash --match-head-commit "$(gh pr view <n> --json headRefOid --jq .headRefOid)"
gh pr view <n> --json state,mergedAt      # confirm; the merge exit code lies in both directions
```

`principles/git-workflow.md` carries the full sequence, including thread resolution and the failure modes worth knowing about.

Answering inline review findings still uses the existing script because GitHub
needs four API calls to reply-and-resolve correctly:

```bash
bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file> --fix-commit <sha>
bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file> --no-code-change
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
declaration engine as local validation with no unrelated toolchain dependency.
The target repository carries no duplicate required workflow.

Lint is separate, at pre-commit: `shellcheck`, `shfmt`, `markdownlint`, `actionlint`.

## Contributing

Open a PR for improvements to principles, scripts, hooks, or skills. The same delivery workflow above applies here — Touchstone ships through its own gate.

Current replacement scope and sequencing live in the [canonical Linear execution plan](https://linear.app/autumngarage/document/touchstone-execution-plan-post-strip-baseline-cac4c56e593e), not this durable overview.
