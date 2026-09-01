# Touchstone

**The standard baseline for a solo developer directing many agents across many projects.**

One person cannot read everything many agents produce. Touchstone exists so that they do not have to. It ships two things, and both are the product:

1. **Guidance prompts** — the steering an agent reads to know how to work: branch first, one concern per commit, answer every finding, reconcile issues, never bypass the gate.
2. **Push tooling** — the small CLI surface that makes an agent use GitHub *correctly*.

The goal is that every Autumn Garage project gets the same dev flow by adopting Touchstone, and that the flow is industry-leading practice for GitHub and agent-driven delivery. Adoption is **set-and-forget**: an adopted repository must remain correct if Touchstone never rewrites it again. V1 serves one operator's portfolio through public-quality interfaces; it does not build a speculative third-party platform. The durable boundary is defined in `docs/product-contract.md`.

**The second half is deliberately narrow.** The CLI validates declared project
checks, verifies tracker claims, applies and verifies the audited GitHub
policy, and exposes four bounded PR operations (`open`, `status`, `merge`,
`answer`). GitHub remains the review, findings, and merge surface; drivers
reconcile delivered work through the configured tracker API or CLI.
It does not stage, commit, or push code, and it never replaces GitHub's merge
verdict. Every operation retains a documented raw `git`/`gh` recovery path.

## Purpose

**Humans approve plans. Agents write and ship code. GitHub reviews code.**

Everything here exists to hold one of those three lines. To hold them, Touchstone does exactly three things:

1. **Constrain** — GitHub rejects direct, forced, unvalidated, unreviewed, stale-head, and unresolved delivery to the default branch.
2. **Make state legible** — what happened lives in git, PRs, and issues, verifiable without trusting an agent's narration.
3. **Carry the contract** — the same rules reach every project and every agent.

The operating rule that keeps it honest: **a rule must live at the layer that can actually enforce it.** GitHub enforces (rulesets, required checks). Prose instructs. Scripts observe and sequence — they never adjudicate. Nothing may live at two layers at once. (Touchstone once grew to ~49,000 lines re-deciding locally what GitHub decides at the merge button; that machinery was deleted, and this rule is why it stays deleted.)

## The merge gate — one exact-head verdict

Every adopted repository is protected by an audited organization ruleset:
PR-only delivery, no force pushes or deletions, required status checks, a
merge queue validating the prospective merged result, and two required
workflows pinned to an immutable revision of
`autumngarage/touchstone-workflows` that no target PR can edit:

- **validate** runs the repository's own `.touchstone.toml` declaration
  through the pinned validation engine — deterministic, offline, no
  third-party dependency.
- **review-gate** (gate behavior contract 3) derives one normalized
  reviewer verdict for the exact current PR head — `waiting`, `findings`,
  `clean`, or `invalid` — and succeeds only on a trusted, unedited,
  explicit **clean** result bound to that head. It never adjudicates
  whether historical findings were answered: threads belong to GitHub's
  native conversation-resolution rule, and the merged result to the merge
  queue. Evidence collection is O(pages of current surfaces), independent
  of how much review history a PR carries; anything ambiguous, edited,
  stale, or unresolvable fails closed.

The configured AI reviewer reports `COMMENTED`, not `APPROVED`, so GitHub
approval count does not represent it. Answering every finding and resolving
every thread remain mandatory driver duties — the gate simply no longer
replays that history; it asks for one fresh clean verdict instead.

## Distribution

```bash
brew install autumngarage/touchstone/touchstone   # macOS
touchstone upgrade                                # later upgrades (any platform)
```

Where Homebrew does not run (Windows Git Bash, Linux), `install.sh` from a
release tag installs the same reviewed release under `~/.touchstone/`,
verifying the tarball against the tap formula's recorded digest. A release is
a name for reviewed state, never a new state; `touchstone version` reports the
tool line, and the project-contract schema is versioned separately
(`docs/product-contract.md`).

Machine onboarding is one-time and keeps credentials out of review tools and
durable review state:

```bash
touchstone steering install   # user-scoped skills + steering surfaces
touchstone review setup       # dedicated OpenRouter key into macOS Keychain
```

`touchstone review check` validates the credential, local tools, and
versioned review policy without a provider request. `touchstone review run`
sends only the staged diff in one cost-bounded OpenRouter request, then
reports the selected model, tokens, cost, and findings. Serious and
PR-visible reviews remain on their default Codex paths.

## Delivery

The installed CLI is the sequencer everywhere; raw `git`/`gh` is the
documented recovery path, never the routine one.

```bash
git checkout -b fix/some-slug
# ... edit, stage explicit paths, commit ...
git push -u origin HEAD
touchstone pr open --expect-branch fix/some-slug \
  --title "fix: what changed" --body-file /tmp/pr-body
touchstone pr status <n>
touchstone pr merge <n> --head <reviewed-sha>
```

`open` creates or reuses the PR, posts the bound review request, and confirms
the exact head and base binding; re-run it after any later push. It acts on
the branch the invoking directory has checked out, which differs per
worktree; `--expect-branch` states which one you meant, the way
`merge --head` states which commit was reviewed. Write the branch name out —
`$(git branch --show-current)` reads the same checkout the command reads, so
it agrees with a wrong worktree and binds nothing.

Answering an inline finding replies, records a versioned disposition marker,
and resolves the thread in one audited step (GitHub needs four API calls to
do this correctly):

```bash
touchstone pr answer <n> --comment-id <id> --body-file <file> --fix-commit <sha>
touchstone pr answer <n> --comment-id <id> --body-file <file> --no-code-change
touchstone pr answer <n> --all-resolved-check
```

Under gate behavior contract 3, answering the last open thread also posts the
one fresh review request the clean exact-head verdict requires — idempotently,
so retries never post a second one.

The exact raw recovery path (CLI unavailable) remains:

```bash
cp .github/pull_request_template.md /tmp/pr-body
# Fill every required section and Validation row; keep `Fixes AUT-123` in the body.
gh pr create --title "fix: what changed" --body-file /tmp/pr-body
# ... post `@codex review`, answer findings, resolve threads ...
gh pr merge <n> --squash --match-head-commit "$(gh pr view <n> --json headRefOid --jq .headRefOid)"
gh pr view <n> --json state,mergedAt   # confirm; the merge exit code lies in both directions
```

`principles/git-workflow.md` carries the full sequence, including thread resolution and the failure modes worth knowing about.

## Adoption and policy

```bash
touchstone adopt --dry-run                 # plan-first, declarations only
touchstone policy status --project <dir>
touchstone policy apply --project <dir> --base main --authorize-admin
```

Adoption compiles project facts into an explicit versioned contract; an
adopted repository carries declarations and narrow integration points, never
copied Touchstone implementation. `policy apply` installs or updates the
audited ruleset and verifies the effective rules before returning; rollback
restores captured protection first, so neither direction leaves an
unprotected interval. Consumers reference hooks by name
(`touchstone hook branch-guard`), so settings never encode where the tool
lives.

## Architecture

```text
touchstone/
├── TOUCHSTONE.md   # Canonical steering router — the universal contract for all drivers
├── docs/           # Product contract, CLI/validation/tracker contracts
├── principles/     # The judgment layer, routed to from TOUCHSTONE.md
├── skills/         # User-scoped Claude Code skills
├── hooks/          # branch-guard.sh — PreToolUse hook wired in .claude/settings.json
├── policy/         # Audited desired GitHub policy, workflow pins, rollback baseline
├── scripts/        # Issue, review, validation, policy, and PR-sequencing operations
├── audits/         # Dated drift/health reports
├── feedback/       # Dated dogfooding notes from downstream projects
└── tests/          # Self-tests
```

`scripts/touchstone-run.sh` is the declaration-only validation engine,
accepting schema 1 and schema 2; its contract lives in [docs/validation-contract.md](docs/validation-contract.md).
`scripts/touchstone-tracker.sh` owns the tracker-neutral verified claim boundary;
its versioned outcomes live in [docs/tracker-contract.md](docs/tracker-contract.md).
`scripts/touchstone-pr.sh` owns the four bounded PR sequencing operations; its
versioned output and raw recovery equivalents live in
[docs/pr-cli-contract.md](docs/pr-cli-contract.md).

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

Open a PR for improvements to principles, scripts, hooks, or skills. The same delivery workflow above applies here — Touchstone ships through its own gate, including the exact-head verdict contract this repository was the canary for.

Current replacement scope and sequencing live in the [canonical Linear execution plan](https://linear.app/autumngarage/document/touchstone-execution-plan-post-strip-baseline-cac4c56e593e), not this durable overview.
