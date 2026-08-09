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
Detached Shipping Handoff
  |
  | wait-only owner pushes and opens the PR
  | driver records status/takeover commands and starts disjoint work
  v
Agentic PR Review Loop
  |
  | Detached owner watches the PR
  | - check status and CI/check runs
  | - wait for exact-head review
  | - merge a clean head
  | - preserve actionable feedback as needs-attention
  |
  v
Approval Gate
  |
  | Required reviews approved
  | Blocking comments resolved
  | Required checks green
  |
  v
Final Verification
  |
  | merge helper runs deterministic checks and revalidates
  | trusted PR review for the exact head and base
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

- Every change reaches `main` through a GitHub PR unless the documented emergency path is used.
- PR creation is not completion. The driver remains accountable until every piece of PR feedback is answered and resolved, the PR is merged, and the merge is synced locally.
- A draft PR is a review-free coordination surface. It does not emit semantic-review intent or consume an exact-head review until final shipping explicitly marks it ready.
- The exact commit merged has passed deterministic checks after its last mutation.
- The exact commit merged has no unresolved blocking review comments, requested changes, or failing required checks.
- Touchstone does not invoke a local semantic reviewer or model router.
- PR creation is the review coordination surface. It should happen early enough for CI and any PR-visible agentic reviewers to work against visible PR state.
- Feature-branch push is not the expensive gate. It should preserve cheap local guardrails without running full test suites or LLM review by default.
- Merge is allowed only after PR-visible review and check approval. The local merge helper gates on requested-changes review decisions and unresolved review threads, runs deterministic checks, and requires a trusted current-head GitHub review signal bound to the captured base revision.
- A clean result observed after a durable request is persisted on the full
  reviewed SHA before later deterministic gates run. The versioned schema,
  trust checks, and rebase compatibility path are owned by
  [Review Evidence Contract](review-evidence.md).
- A deterministic check result may be reused only when the cache key includes the base ref, head commit, relevant config, and checker version/input boundary.

## Driver AI Responsibilities

The driver AI is Claude Code, Codex, Gemini CLI, or another AGENTS.md-native coding agent. The driver owns repo operations:

- branch before editing
- inspect and modify files
- run focused checks during implementation
- stage explicit file paths
- commit coherent changes
- hand routine shipping to a wait-only detached owner
- record status and takeover commands
- start only work disjoint from the handed-off worktree
- take over `needs-attention` jobs and commit feedback fixes
- use foreground shipping for interactive diagnosis
- explain the outcome to the user

## Reviewer Responsibilities

The configured GitHub reviewer is an asynchronous, PR-visible adapter.

- Review the exact requested head and base revisions.
- Publish findings where the driver and other maintainers can inspect them.
- Produce durable authorship and timestamp evidence that the merge helper can verify.
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
- Workers must not revert or overwrite another worker's work.
- Workers may produce candidate changes; only the driver integrates them into the PR that enters the review loop.
- No worker opens or merges the final PR unless the driver explicitly assigns that role.
- Clean up worktrees after merge or abandonment.

## Implementation Scope

The scripts now enforce the core merge-time parts of this architecture:

1. `bash scripts/open-pr.sh --auto-merge` is the default routine shipping entry point and invokes the project-local `open-pr.sh --auto-merge`; direct `open-pr.sh` remains the foreground diagnostic mode.
2. `open-pr.sh --draft` creates or updates a review-free coordination surface; it does not run the final PR-body protocol or emit semantic-review intent, completion status, or request comments.
3. Final shipping runs deterministic issue-claim and PR-body preflights before marking an existing draft ready and requesting exact-head review.
4. The wait-only owner watches review decisions and checks without mutating the branch; actionable feedback becomes a durable `needs-attention` handoff for the driver.
5. `merge-pr.sh` blocks draft PRs, active requested-changes decisions, unresolved review threads, and thread-state inspection failures before the final squash merge.
6. `merge-pr.sh` binds the trusted GitHub review signal to the exact current head and base, rejects base or merge-base movement, and merges with `--match-head-commit`.
7. Review and preflight markers should key on base/head/config so repeated operations reuse valid results without hiding stale state.
8. Detached events record review request count and wait time so external latency remains observable.
9. Docs, templates, tests, and issue guidance should describe the PR-visible review loop consistently.
10. The merge helper records versioned clean-result evidence on the reviewed
    commit so a fail-closed root-cause reset can prove a rewritten historical
    review without treating a short SHA as authorization.

## Product Boundary

Touchstone's supported core is policy distribution, deterministic validation,
PR creation, current-revision review authorization, and guarded merge. Model
providers and PR-visible reviewers are adapters around that contract.

Detached wait-only shipping is a supported latency adapter because it does not
mutate the branch. Detached review-fix remains experimental: it may author at
most two validated fix commits, then must preserve its worktree and emit a
`needs-attention` handoff before any third edit. The core workflow must not
depend on autonomous repair succeeding.
