# AI Delivery Architecture

This document owns Touchstone's end-to-end delivery architecture for AI-authored changes. Other docs should link here instead of restating the workflow in detail.

## Target Flow

```text
Human user
  |
  | asks for a change
  v
Driver AI
  |
  | reads Touchstone steering
  | - checks repo state
  | - pulls main
  | - creates a feature branch before edits
  | - inspects the relevant code
  v
Implementation
  |
  | Driver AI edits files
  | may delegate bounded work through its native agent tools
  | may run focused local checks while developing
  v
Commit
  |
  | stage explicit paths
  | create focused commit(s)
  v
Ship
  |
  | git push, then touchstone pr open (closing reference in the PR body)
  v
Agentic PR Review Loop
  |
  | - required checks run
  | - the configured reviewer reviews the exact head
  | - the driver answers every comment and resolves its thread
  | - a fully-answered head merges (clean verdict, or
  |   findings with every thread resolved)
  |
  v
Merge Gate
  |
  | ENFORCED by GitHub when the repository's effective policy requires them:
  |   pinned required validation workflow green
  |   review-gate covers this head and every finding is answered
  |   every review thread resolved
  |   no outstanding CHANGES_REQUESTED
  | Until adoption, the same exact-head review remains driver procedure;
  | missing server-side constraints are a rollout gap.
  |
  v
Final Verification
  |
  | the driver confirms state against GitHub rather than
  | trusting an exit code; nothing local revalidates
  v
Merge PR
  |
  | squash merge
  | sync local main
  | clean up branch/worktree
  v
Human user
  |
  | receives concise outcome
```

## Required Invariants

- Every change reaches `main` through a GitHub PR, including the documented emergency path.
- PR creation is not completion. The driver remains accountable until every piece of PR feedback is answered and resolved, the PR is merged, and the merge is synced locally.
- A draft PR is a review-free coordination surface. It does not emit semantic-review intent or consume an exact-head review until final shipping explicitly marks it ready.
- The exact commit merged has passed the pinned deterministic validation workflow after its last mutation.
- The exact commit merged has no unresolved blocking review comments, requested changes, or failing required checks.
- Touchstone invokes no model router. The bounded local review pass in `principles/local-review.md` is driver-initiated and tier-routed; it informs the driver and never gates a merge — GitHub's PR-visible review remains the only semantic authority.
- PR creation is the review coordination surface. It should happen early enough for CI and any PR-visible agentic reviewers to work against visible PR state.
- Feature-branch push is not the expensive gate. It should preserve cheap local guardrails without running full test suites or LLM review by default.
- Merge is allowed only after PR-visible review and check approval: required checks green, a review bound to the current head with every thread answered, and no active `CHANGES_REQUESTED`.
- The merge path binds the exact reviewed head. Use a project-documented executable merge boundary when present; otherwise use `gh pr merge --squash --match-head-commit <reviewed-sha>`. Both rely on GitHub refusing a moved head, which prevents an unreviewed commit from slipping behind a passing review.
- **The configured AI reviewer reports `COMMENTED`, not `APPROVED`.**
  `required_approving_review_count` therefore does not express this review
  contract. Where the repository's effective policy requires `review-gate`,
  that check binds trusted review evidence to the exact head and requires every
  finding answered. Until adoption, the same exact-head review remains
  mandatory driver procedure.

## Driver AI Responsibilities

The driver AI is Claude Code, Codex, Gemini CLI, or another AGENTS.md-native coding agent. The driver owns repo operations:

- branch before editing
- inspect and modify files
- run focused checks during implementation
- stage explicit file paths
- commit coherent changes
- ship with `git push` + `touchstone pr open --expect-branch <branch>`, which requests review on the exact head (raw recovery: `gh pr create`, then a bare `@codex review`)
- answer every piece of PR feedback and resolve its thread
- commit fixes for actionable feedback and ship again
- explain the outcome to the user

## Reviewer Responsibilities

The configured GitHub reviewer is an asynchronous, PR-visible adapter.

- Review the exact requested head and base revisions.
- Publish findings where the driver and other maintainers can inspect them.
- Produce durable authorship, revision, and timestamp evidence that the
  `review-gate` workflow can evaluate from GitHub.
- Never mutate the local branch or own merge authority.

## Agent Swarms And Worktrees

Parallel file-writing agents use worktrees by default.

```text
Driver AI
  |
  | decides work is parallelizable
  v
Agent swarm
  |
  | one agent per worktree
  | each agent gets an explicit file/module scope
  | agents commit only in their own worktree
  v
Driver AI integration
  |
  | integrates candidate changes into the primary PR branch
  | resolves conflicts
  | owns PR review loop, final checks, merge, and cleanup
```

Rules:

- Use worktrees for file-writing parallel agents.
- Give every agent a bounded task and explicit file ownership.
- Workers must not edit outside their assigned scope.
- Agents must not revert or overwrite another agent's work.
- Workers may produce candidate changes; only the driver integrates them into the PR that enters the review loop.
- No agent opens or merges the final PR unless the driver explicitly assigns that role.
- Clean up worktrees after merge or abandonment.

## Implementation Scope

**Nothing local enforces this architecture right now.** The scripts that did — 5,399 lines of open-pr and merge-pr helpers — were deleted because 43% of them re-decided locally what GitHub decides at the merge button, and they never once read the server-side settings that already expressed the same rules.

Where the repository's effective policy contains the Touchstone ruleset, the
enforcement split is:

1. **GitHub enforces.** The organization ruleset refuses direct and force pushes, requires a PR, runs the pinned validation workflow, requires exact-head `review-gate`, and blocks unresolved threads.
2. **Prose instructs.** `git-workflow.md` carries the full sequence in raw `git` and `gh`, including the head binding at merge and the thread-resolution mutation.
3. **The driver executes and verifies.** It runs the commands, reads what GitHub actually reports, and does not trust an exit code that is known to lie in both directions.

Before that policy is installed and verified, the prose and driver still carry
the delivery procedure, but the missing server-side constraint remains a
rollout gap rather than permission to skip review.

## Product Boundary

Touchstone's supported core is policy distribution, deterministic validation,
PR creation, current-revision review authorization, and guarded merge. Model
providers and PR-visible reviewers are adapters around that contract.

Autonomous repair is not part of the contract. When the gate stops it names the
blocking condition and the driver fixes it — Touchstone constrains the change,
it does not repair it. A project that wants shipping automation on top of this
contract owns that automation itself.
