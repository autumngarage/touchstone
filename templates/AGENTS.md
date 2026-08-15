# AGENTS.md — AI Agent Instructions for {{PROJECT_NAME}}

This file steers Codex and other AGENTS.md-native coding agents. Claude Code reads `CLAUDE.md`; Gemini CLI reads `GEMINI.md`. Keep these files aligned when project-level workflow changes.

When coding, follow the authoring guide. When explicitly reviewing a PR or running the AI review hook, use the review guide.

## Authoring Guide

### Who You Are on This Project

{{PROJECT_DESCRIPTION — describe the project's purpose, your role, and what "good" looks like for this codebase. Be specific about the domain.}}

<!-- touchstone:steering:start -->

<!-- This block is a hand-maintained copy of TOUCHSTONE.md. The renderer that
     generated it (lib/touchstone-block.sh) was deleted; edit TOUCHSTONE.md first,
     then mirror the change here. Edit content OUTSIDE the markers freely. -->

## Touchstone — Shared Agent Steering

You are an AI agent (Claude Code, Codex, or another driving CLI) working in a Touchstone-bootstrapped project. This block is the universal contract: rules that apply on every turn, plus a routing table to deeper docs you should consult when specific triggers fire. Project-specific guidance lives outside this block in your driver's steering doc (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`).

## Purpose

**Humans approve plans. Agents write and ship code. GitHub reviews code.**

That division is the entire product; everything Touchstone ships exists to hold one of those three lines in place. No human reads a diff as a merge precondition, so machines are the whole quality bar.

**GitHub's effective repository policy is the enforcement authority.** Where the Touchstone policy has been installed and verified, the protected validation workflow and required `review-binding` check must pass, every finding must be answered, every thread must be resolved, and native rules reject direct and force pushes and branch deletion. Do not infer adoption from this document: inspect the repository's effective rules.

**Review is always required.** The configured AI reviewer reports `COMMENTED`, not `APPROVED`, so approval count does not represent it. Where `review-binding` is required, GitHub binds trusted review evidence and answers to the exact head. Until that gate is installed and verified, exact-head review remains mandatory driver procedure and the missing enforcement is a rollout gap, not permission to skip it.

**A security-review quota notice is never a blocker.** It is provisional acceptance, not review evidence. Keep watching through the completion deadline, then use bounded stalled-request recovery.

Local hooks are fast feedback; configured GitHub policy is the real boundary. An adopted policy limits emergency admin bypass to pull requests, where GitHub records it. A repository without that enforcement still does not authorize a driver to push directly.

To hold those lines, Touchstone does three things and nothing else:

1. **Constrain** — adopted GitHub policy blocks unsafe delivery; before adoption, the driver follows the same delivery contract and treats missing enforcement as a tracked gap.
2. **Make state legible** — what happened lives in git, PRs, and issues, verifiable without trusting your narration.
3. **Carry the contract** — the same rules reach every project and every agent, automatically.

Before adding anything here, name which of the three it serves; if you cannot, it does not belong. "Is it useful?" is not the test: **does it constrain the agent, or merely serve it?** Automating what you can already do (retrying a push, recovering a moved base) belongs in the project, not here: you are the recovery mechanism.

## Agent Roles And Fallbacks

- **Driving CLI** — Claude Code, Codex, or Gemini CLI. Owns file edits, git state, tests, commits, PR creation, PR comment triage, fix commits, approval tracking, and merge. Drivers are interchangeable; driver fallback is shared-contract fallback — if one is unavailable, another reads the same files and continues.
- **PR-visible reviewer** — GitHub-hosted review runs asynchronously against the exact pushed head. It reports findings on the PR; it never owns local files, git state, validation, or merge authority.

## Engineering principles (always in mind)

Non-negotiable. Every code change is reviewed against them. Full rationale lives in `principles/engineering-principles.md`.

- **No band-aids** — fix the root cause; if patching a symptom, say so explicitly and name the root cause.
- **Keep interfaces narrow** — expose the smallest stable contract; don't leak storage shape, vendor SDKs, or workflow sequencing.
- **Derive limits from domain** — thresholds and sizes come from input/config/named constants; test at small, typical, and large scales.
- **Derive, don't persist** — compute from the source of truth; persist derived state only with documented invalidation + rebuild path.
- **No silent failures** — every exception is re-raised or logged with debug context. No `except: pass`, no swallowed errors.
- **Every fix gets a test** — bug fix includes a regression test that runs in CI and fails on the old code.
- **Think in invariants** — name and assert at least one invariant for nontrivial logic.
- **One code path** — share business logic across modes; confine mode-specific differences to adapters, config, or the I/O boundary.
- **Version your data boundaries** — when a model/algorithm/source change affects decisions, version the boundary; don't aggregate across.
- **Separate behavior changes from tidying** — never mix functional changes with broad renames, formatting sweeps, or unrelated refactors.
- **Make irreversible actions recoverable** — destructive operations need dry-run, backup, idempotency, rollback, or forward-fix plan before they run.
- **Preserve compatibility at boundaries** — public API/config/schema/CLI/hook/template changes need a compatibility or migration plan.
- **Audit weak-point classes** — find a structural bug → audit the class + add a guardrail. Use the `touchstone-audit-weak-points` skill (Claude) or read `principles/audit-weak-points.md` (other drivers).
- **Isolate file-writing subagents** — parallel agents use dedicated worktrees and disjoint file ownership by default.
- **File issues for bugs** — open a GitHub issue when you find a bug, in this project or in an autumngarage tool. Don't silently work around it.
- **Escalate delivery friction upstream** — if Touchstone or the configured PR reviewer causes workflow drag (excessive latency, weak parallelization, brittle review/merge behavior, or other delivery inefficiency), file an actionable upstream issue with repro steps and impact instead of normalizing the pain.

## Never commit on the default branch

Before the first edit of a tracked file in a session, run `git branch --show-current`. If it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<slug>` where `<type>` is `feat | fix | chore | refactor | docs`. Your unstaged changes carry over — there's no cost to switching now and a real cost to discovering at commit time. Recovery steps when it happens anyway live in `principles/git-workflow.md`.

## Required Delivery Workflow

Drive this lifecycle automatically; do not ask the user for permission at each step.

1. **Pull.** `git pull --rebase` on the default branch.
2. **Branch.** Before any edit that might become a commit.
3. **Claim issues before implementation.** Use the configured tracker's race-safe claim, verification, and dispatch sequence before editing. Claim every issue in a bundle; never assume a repository-local helper exists.
4. **Change + commit.** Stage explicit file paths. Concise message. One concern per commit.
5. **Reconcile issues.** Before opening the PR, list every GitHub issue found, claimed, fixed, partially fixed, or made stale by the work. Fully fixed issues get closing trailers (`Closes-issue: #123` or `Closes #123`) so merge auto-closes them; partial/stale issues get a comment explaining the evidence or remaining gap. Do not leave fixed issues open silently.
6. **Ship.** `git push -u origin HEAD`, then `gh pr create`. Put the closing reference (`Closes #123`) in the **PR body** — squash-merge reads the body, not the commit. Request review by commenting `@codex review` on the PR.
7. **Answer every piece of PR feedback before merging.** Whoever reviews (hosted AI, bot, or colleague), reply to each comment and resolve the thread; unresolved threads and `CHANGES_REQUESTED` block the merge. `bash scripts/respond-review.sh <pr> --comment-id <id> --body-file <file>` replies and resolves in one step; `--all-resolved-check` proves none remain.
8. **Merge** with `gh pr merge <n> --squash --match-head-commit <sha>`, binding to the head the review actually saw. Its exit code lies in both directions — confirm against real state rather than trusting it.
9. **Clean up after merge.** Delete the local branch if it persists.

Every command above is the whole mechanism; there is no wrapper. `principles/git-workflow.md` carries the full sequence, including thread resolution.

Never use a direct default-branch push as an emergency path. Repositories with the audited policy enforce PR-only bypass; elsewhere this remains mandatory procedure until adoption. See `principles/git-workflow.md`.

## Routing table — read these when the trigger fires

| When you're about to... | Read |
|---|---|
| commit, branch, open a PR, run review, merge, recover from `no-commit-to-branch`, work with stacked PRs, or fan out worktrees | `principles/git-workflow.md` |
| understand the AI-authored change lifecycle or PR review loop architecture | `principles/ai-delivery-architecture.md` |
| start a non-trivial code change | `principles/pre-implementation-checklist.md` |
| understand the *why* of a daily-reminder rule | `principles/engineering-principles.md` |
| edit, write, or audit documentation | `principles/documentation-ownership.md` |
| coordinate parallel agents (subagents or worktrees) | `principles/agent-swarms.md` |
| audit a structural bug class after fixing one instance | `principles/audit-weak-points.md` |
| hit a bug in an upstream tool (don't silently work around it) | `principles/file-upstream-bugs.md` |
| write, trust, or audit agent memory — it is a cache, not truth | `principles/memory-hygiene.md` |

Claude Code agents: the bundled `touchstone-*` and `memory-audit` skills mirror this table in your session header. Trust whichever surface fires first.

<!-- touchstone:steering:end -->

### Git Workflow

Every change starts on a feature branch. Before editing tracked files, run `git branch --show-current`; if it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<short-description>`.

Use the normal lifecycle unless the user asks for a different flow:

1. Pull/rebase the default branch.
2. Branch before editing.
3. Claim every GitHub issue you are actively implementing with `bash scripts/claim-issue.sh <n>` before editing or dispatching an agent.
4. Make the change, stage explicit file paths, and commit with a concise message.
5. Reconcile issue state before opening the PR: fixed issues get closing trailers/PR body lines; partial or stale issues get an issue comment with evidence and remaining gaps.
6. Ship with `git push -u origin HEAD`, then `gh pr create` — put `Closes #123` in the **PR body**, since that is what squash-merge reads. Request review, answer every finding, then merge with `gh pr merge <n> --squash --match-head-commit <reviewed-sha>` and confirm the result rather than trusting the exit code.
7. The PR is the review surface. Do not treat PR creation as completion: answer every piece of PR feedback and resolve the thread — whoever left it — before merging.
8. Clean up the feature branch if it still exists locally.

File-writing subagents use isolated worktrees by default. Follow `principles/agent-swarms.md` for slice manifests, file ownership, concurrency caps, and cleanup; use `git worktree add` and `git worktree remove` for local setup and teardown.

### Testing

```bash
# Reinstall dependencies without rerunning the full machine setup
bash setup.sh --deps-only

# Before any push — uses .touchstone-config profile defaults and command overrides
bash scripts/touchstone-run.sh validate
```

Fix failing tests before pushing.

### Release & Distribution

{{RELEASE_AND_DISTRIBUTION — how is this project shipped? Include the release command, package registry or deployment target, required version bump, post-release verification, and rollback path. Examples: Homebrew tap, npm package, Docker image, Vercel/Railway deploy, app store build.}}

After merging release-affecting changes, verify the shipped artifact or deployed environment matches the pushed code.

### Architecture

{{ARCHITECTURE — describe key packages, their responsibilities, and how data flows between them. Keep it high-level.}}

### Key Files

| File | Purpose |
|------|---------|
| {{key files and their purposes}} | |

### State & Config

{{STATE_AND_CONFIG — where does mutable state live? What's gitignored? Where's the config template?}}

### Hard-Won Lessons

{{HARD_WON_LESSONS — bugs that cost real time or money. Each should teach a generalizable lesson. Format: what happened, what was the root cause, what's the fix/guard now in place.}}

---

## Review Guide

You are reviewing pull requests for **{{PROJECT_NAME}}**. Optimize your review for catching the things that bite this repo, not generic style polish.

### What to prioritize (in order)

{{PRIORITIES — list your project's review priorities in order of importance. Examples:

1. **Data integrity.** Anything that changes how data is written, migrated, or deleted.
2. **Security.** Auth, input validation, secrets handling, injection risks.
3. **Silent failures.** New `except: pass`, swallowed exceptions, fallbacks that mask broken state.
4. **Tests for new failure modes.** Bug fixes must add a test that reproduces the original failure.

Be specific to your project's actual risks. Generic priorities are useless.}}

Style nits, formatting, and theoretical refactors are **out of scope** unless they hide a bug. Do not flag them.

---

### Specific review rules

#### High-scrutiny paths

{{HIGH_SCRUTINY_PATHS — list the files/directories where mistakes are most expensive. Examples:

Files: `src/auth/`, `src/payments/`, `migrations/`

Flag any of the following:
- (specific anti-patterns relevant to your project)
- (things that have gone wrong before)
- (invariants that must hold)}}

#### Silent failures

Flag any of the following:

- New `except: pass`, `except Exception: pass`, or `except: ...` without logging.
- New `try / except` that catches a broad exception and continues without logging the exception object.
- Default values returned on error without a log line.
- Fallback behavior that masks broken state.

The rule: every exception is either re-raised or logged with enough context to debug from production logs alone.

#### Tests

- Bug fixes must include a test that reproduces the original failure mode.
- Tests should use relative values (percentages, ratios) not absolute values where applicable.
- Integration tests should hit real infrastructure for critical paths (mocks have masked real bugs in the past).

---

### What NOT to flag

- Formatting, whitespace, import order — pre-commit hooks handle these.
- Type annotations on existing untyped code.
- "You could refactor this for clarity" — only if the unclarity hides a bug.
- Missing docstrings on small private functions.
- Speculative future-proofing — don't suggest abstractions for hypothetical future requirements.
- Naming preferences absent a clear convention violation.

If you find yourself writing "consider" or "you might want to" without a concrete bug or risk attached, delete the comment.

---

### Output format

1. **Summary** — one paragraph: what this PR does and your overall verdict (approve / request changes / comment).
2. **Blocking issues** — bugs or risks that must be fixed before merge. Each item: file:line, what's wrong, why it matters, suggested fix.
3. **Non-blocking observations** — things worth noting but not blocking. Keep this section short.
4. **Tests** — does this PR add tests for the changed behavior? If not, is that OK?

If there are zero blocking issues, the review is just: "LGTM."
