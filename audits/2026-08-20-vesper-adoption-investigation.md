# Vesper → Touchstone 3: what a full update needs — 2026-08-20

Investigation for AUT-303 / AUT-311, requested by the operator: what vesper
needs to be fully on Touchstone 3, and what Touchstone itself must change so
that vesper — and every other project — is updated by `brew upgrade` and an
audited policy apply from then on, never by editing the repository again.

Sources: vesper checkout at `952bee44` (remote already `autumngarage/vesper`),
its `.touchstone-manifest`, GitHub state of `autumngarage/vesper`, Linear
AUT-303/311/313, touchstone main at the time of writing.

## 1. Where vesper is right now

| Fact | State |
| --- | --- |
| Repository | `autumngarage/vesper`, private, Team plan — merge queue is available |
| Reviewers | Codex and CodeRabbit review every PR already (account-level apps; the transfer changed nothing) |
| Ruleset | `Protect main delivery`: deletion, non-fast-forward, pull_request. **No required checks, no queue** |
| CI | Exactly one workflow, `issue-claim-check.yml`, not required. **Nothing compiles or tests the app in CI** (deliberate: #531 moved everything local) |
| Local gates | The vendored 2.x scripts: `open-pr.sh` (2,057 lines), `merge-pr.sh` (3,312), `lib/preflight.sh` (1,743) — review-request statuses, merge adjudication, the full Swift suite *at merge time* |
| Tool | 3.0.1 on this machine; the 2.x scripts work again via the `touchstone update` shim shipped today |
| Steering | Machine-level block installed today; vesper's `AGENTS.md`/`GEMINI.md` still carry the stale copied block, and `CLAUDE.md` `@`-imports a vendored `principles/` directory |
| Tracker | GitHub issues (no Linear prefix anywhere) |
| Deploy | Local only: codesign → notarytool → Sparkle appcast → Vercel Blob. No Actions secrets beyond `GITHUB_TOKEN`; the five Apple secrets on the repo are unused by any workflow |

Ownership, from `.touchstone-manifest` (36 managed paths): the delivery
scripts, seven `lib/*.sh`, ten `principles/*.md`, `TOUCHSTONE.md`,
`.claude/settings.json`, the claim-check workflow. Everything else under
`scripts/` is vesper's: release notes, site validation, release readiness,
terminal smoke, deploy, and — critically — `worker.sh` + `lib/worker-*.sh`.

## 2. The target state, concretely

A fully updated vesper carries **declarations and its own scripts, nothing of
Touchstone's**:

- `.touchstone.toml` (schema 2) declaring: `validate` = `bash
  scripts/validate-preflight.sh` (release-note rule + site checks; runs on
  ubuntu), and a `stage = "commit"` task for `scripts/release-notes.sh` —
  vesper is the case that created schema 2 (AUT-306: the per-commit rule
  could not be checked until push).
- `.touchstone-tracker.toml` (`type = "github"`).
- A pre-commit entry `touchstone validate --stage commit` and the machine-level
  steering; no `principles/`, no `TOUCHSTONE.md`, no managed blocks, no
  `.touchstone-config/-manifest/-version/-review.toml`, no `lib/`.
- GitHub policy applied from `policy/github/consumers/vesper.json`: PR-only,
  no force-push, required workflows `validate` + `review-gate` +
  `delivery-evidence` from `touchstone-workflows` (pinned), merge queue,
  thread resolution, `allow_auto_merge` on.
- `touchstone pr open|status|merge` and the installed `respond-review.sh` as
  the delivery commands; `worker.sh` and `deploy.sh` call them.

After that, a Touchstone change reaches vesper one of three ways, none of
which touch the repository: `brew upgrade` (tool + steering), a policy pin
bump applied through `github-policy.sh` (gates), or a new
`touchstone-workflows` SHA in that same policy (required workflows).

## 3. What Touchstone must change first (the gaps vesper exposes)

These are Touchstone's, found by trying to fit vesper; each is small and each
applies to every consumer.

1. **Unforgeable gates as required workflows (3.1, in flight).** `review-gate`
   is required on touchstone as of today; `delivery-evidence` follows #931;
   `review-binding` is then dropped. Without this a consumer would need a
   copy of a 500-line workflow — the drift the product contract forbids.
2. **Runner selection for `validate`.** The central `validate` workflow is
   `ubuntu-latest` only. vesper's declared `validate` runs there fine (bash +
   npm), but AUT-313's recommended per-PR deterministic check — *compile plus a
   fast unit subset* — needs macOS. Add `runner = "macos-15"` (optional,
   default ubuntu) to `[validation]` in the schema; `touchstone-workflows/
   validate.yml` gains a `plan` job that reads the declaration and a `validate`
   job with `runs-on: ${{ needs.plan.outputs.runner }}`. The required workflow
   is referenced by path, so the job name may change. Until this ships, vesper
   declares only the ubuntu-safe tasks.
3. **`allow_auto_merge` in the policy.** The queue entry uses auto-merge;
   `github-policy.sh apply`/`verify` must set and check the repository flag
   (one PATCH). Done by hand on touchstone today.
4. **Reopen after a new required workflow.** PR heads that predate an apply
   never get a run; `edited` does not trigger required workflows. The rollout
   step for every consumer: close/reopen its open PRs. (Recorded in memory
   today; belongs in `policy/github/README.md`.)
5. **Nothing ships for the worktree/branch helpers or the emergency hook** —
   by design. `spawn-worktree.sh`, `cleanup-worktrees.sh`,
   `cleanup-branches.sh` are "worktree convenience wrappers", an explicit
   non-goal; `emergency-disclosure.sh` (2,021 lines defeating obfuscated
   `--no-verify`) is made redundant by the ruleset: a direct or forced push to
   `main` is refused by GitHub regardless of local hooks. The claim-check
   workflow goes with AUT-302 (claim enforcement deleted). These are
   deletions in vesper, not ports.
6. **One fix to carry forward.** vesper's `merge-pr.sh:1218-1230` has a local
   hotfix (a thread with exactly one reply read as unanswered). The installed
   `respond-review.sh` reads replies per comment id, not per line, so the
   defect does not exist there — verified by reading, worth a fixture in
   `tests/test-review-binding.sh` before the 2.x copy is deleted.

## 4. What vesper must change (vesper PRs)

Ordered so each PR leaves vesper working.

**PR A — adopt and switch the commands (the core).**
- `touchstone adopt` (2 files). Add the `stage = "commit"` release-notes task.
- `scripts/validate-preflight.sh:67` stops calling the vendored
  `touchstone-run.sh`; the central workflow runs the declaration.
- `worker.sh` / `lib/worker-ship-job.sh` / `deploy.sh:234`: replace
  `bash scripts/open-pr.sh --auto-merge` with `touchstone pr open
  --expect-branch <branch>` followed by `touchstone pr merge <n> --head <sha>`
  (queue); `lib/worker-review-fix.sh:514-518,1093` replaces `lib/preflight.sh`
  with `touchstone validate`; `lib/codex-auth.sh` becomes vesper-owned (it is
  the local reviewer's auth, a vesper concern).
- `.pre-commit-config.yaml`: the pre-push `touchstone-run.sh validate` hook →
  `touchstone validate`; add the commit-stage hook.
- `.claude/settings.json` / `.codex/hooks.json`: `branch-guard.sh` →
  `$(brew --prefix)/opt/touchstone/libexec/hooks/branch-guard.sh`;
  drop the emergency-disclosure hook.
- Delete the 36 managed paths and the sync bookkeeping; remove the managed
  blocks from `AGENTS.md`/`GEMINI.md` and the `@principles/…` imports from
  `CLAUDE.md` (the machine block carries them); fix `GEMINI.md:106-107`
  outside the markers.
- **The Swift tests.** Nineteen test files exec the vendored scripts
  (`Tests/{OpenPRPreflightFailClosed,MergePRCodexReviewGate,
  IssueClaimCheckScript,TouchstonePreflightPolyglot,SitePreflight,
  AgentWorkerTab,…}Tests.swift`). They test Touchstone's scripts, not
  vesper's app; delete the ones that only do that, rewrite the worker-tab
  ones against the new commands. This is the largest single item.
- **The app dependency.** `TouchstoneWorkerClient.swift` invokes
  `scripts/worker.sh` in whatever repository the user opens; that file stays,
  vesper-owned, and keeps working because it now calls the installed CLI.

**PR B — owner references.** `site/lib/bugReportPolicy.js:343-344` falls back
to `henrymodisett/vesper` (set the Vercel env or change the default);
`README.md:28` + `Tests/ReadmeTests.swift:10` together; fixture URLs in two
tests. Re-issue the site's GitHub App installation for the org.

**PR C (optional, per AUT-313) — the fast macOS check.** After Touchstone
gap 2 ships: a second declared task (`swift build` + a fast unit subset) with
`runner = "macos-15"`, and the full suite stays in the release process.

**Policy.** `policy/github/consumers/vesper.json` (derived; #947 adds the
derivation) applied after PR A merges; `allow_auto_merge`; reopen open PRs.

## 5. Sequence and size

| Step | Where | Size |
| --- | --- | --- |
| 3.1: `delivery-evidence` pinned, `review-binding` dropped, tag | touchstone (in flight) | hours |
| `allow_auto_merge` + reopen note in the policy tool | touchstone | 1 PR |
| `runner` in schema + `validate.yml` plan job | touchstone + touchstone-workflows | 2 PRs, half a day |
| vesper PR A | vesper | the real work: ~1 day, mostly tests and `worker.sh` |
| vesper PR B | vesper | 1 PR |
| `vesper.json` apply + reopen | touchstone | minutes |
| vesper PR C | vesper | after the runner gap; 1 PR |

arpeggio and convoy are the same shape without the `worker.sh`/tests
burden (two-file adoptions, staged locally today); they go first and prove
the consumer path.

## 6. Risks accepted, stated

- Between PR A and PR C vesper has no per-PR compile; that is AUT-313's
  recorded trade (review is the bar, the suite runs at release), now with the
  fast check scheduled rather than indefinite.
- `worker.sh` remains a 3,851-line vesper-owned script calling Touchstone's
  CLI. Shrinking it is vesper's product work, not adoption.
