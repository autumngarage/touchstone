## Touchstone — Shared Agent Steering

This shared contract applies to Claude Code, Codex, and other driving CLIs. Use the routing table when its triggers apply. Project-specific guidance lives outside this block in `CLAUDE.md`, `AGENTS.md`, or `GEMINI.md`.

## Purpose

**Humans approve plans. Agents write and ship code. GitHub reviews code.**

Machines own the code-quality bar; human review of a diff is not a merge precondition.

GitHub's effective repository policy is the enforcement authority. Where the Touchstone policy is installed and verified, the protected validation workflow and required `review-gate` workflow must pass, every finding must be answered, every thread must be resolved, and native rules reject direct and force pushes and branch deletion; emergency admin bypass is limited to pull requests, where GitHub records it. Local hooks are fast feedback, not the boundary. Do not infer adoption from this document: inspect the repository's effective rules — and a repository without that enforcement still does not authorize a direct push.

**Review is always required, and `review-gate` is what represents it — not any one reviewer.** The AI reviewer reports `COMMENTED`, not `APPROVED`, so approval count does not represent it either. More than one reviewer can satisfy the gate: where the primary is unavailable, the pinned gate reviews the head itself. A green `review-gate` means the head was reviewed; the absence of a comment from a particular reviewer does not mean it was not. Read the check, not the commenter. Where that gate is absent, exact-head review remains mandatory driver procedure — a rollout gap, not permission to skip it.

**A reviewer quota notice is not a blocker and not a wait.** The pinned gate then reviews the head itself; answer what it reports with `pr answer --finding`.

To hold those lines, Touchstone does three things and nothing else:

1. **Constrain** — adopted GitHub policy blocks unsafe delivery; before adoption, the driver follows the same delivery contract and treats missing enforcement as a tracked gap.
2. **Make state legible** — keep PRs, issues, and replies concise: behavior, reason, evidence. Git and GitHub prove outcomes.
3. **Carry the contract** — the same rules reach every project and every agent, automatically.
   - **Every agent on a machine shares one GitHub REST quota.** Poll PR and check state no faster than every 2 min, GraphQL first; run `gh api rate_limit --hostname <host>` before bulk reads; never retry-loop on a rate limit (403 or 429) — wait for the reset.

Add guidance only when it serves one of these three responsibilities. Keep project-specific recovery in the project.

## Agent Roles And Fallbacks

- **Driving CLI** — Claude Code, Codex, or Gemini CLI. Owns file edits, git state, tests, commits, PR creation, PR comment triage, fix commits, approval tracking, and merge. Drivers are interchangeable; driver fallback is shared-contract fallback — if one is unavailable, another reads the same files and continues.
- **PR-visible reviewer** — GitHub-hosted review runs asynchronously against the exact pushed head. It reports findings on the PR; it never owns local files, git state, validation, or merge authority.

**Retain unfinished work.** After an interruption, resume the original objective unless the user cancels or replaces it. A checkpoint or queue entry does not end delivery ownership. Continue authorized work or record a concrete blocker, resumption condition and responsible driver; hand off explicitly. Follow `principles/git-workflow.md`.

## Engineering principles (always in mind)

Use judgment within these boundaries. Find the existing owner, choose the smallest complete change, and test the uncertainty. Keep routine reasoning internal. Full guidance lives in `principles/engineering-principles.md`.

- **No band-aids** — fix the root cause; if patching a symptom, say so explicitly and name the root cause.
- **Extend existing systems** — search for the existing owner; improve it before adding a parallel system. Reuse follows responsibility.
- **Choose the simplest design** — justify abstractions by current needs; minimize concepts, not lines.
- **Keep interfaces narrow** — hide internals, separate decisions from side effects, and make state/resource ownership explicit.
- **Derive limits from domain** — use input/config/domain constants; test small, typical, and large scales.
- **Derive, don't persist** — derived state needs a source of truth, invalidation, rebuild, and reconciliation.
- **No silent failures** — propagate or report failures with diagnostic context; never expose secrets or hide errors behind defaults.
- **Every retained fix gets a test** — reuse or extend CI regression evidence that fails on old code; add only distinct defect coverage, with minimal fixtures. Never justify a fix-created regression.
- **Think in invariants** — name and assert one for nontrivial logic; make invalid states hard to represent.
- **One code path** — share business rules across modes; isolate differences at adapters/config/I/O.
- **Version your data boundaries** — preserve provenance and compatibility; never silently combine incompatible meanings.
- **Separate behavior changes from tidying** — keep unrelated renames, formatting, and refactors separate.
- **Leave no residue** — comments give the present why, not history; retiring something removes its code, tests, and references.
- **Make irreversible actions recoverable** — plan recovery before mutation, including partial completion and retries.
- **Preserve compatibility at boundaries** — public contracts and generated artifacts need compatibility or migration plans.
- **Audit weak-point classes** — search relevant siblings; choose proportionate regression coverage; follow `principles/audit-weak-points.md`.
- **File-writing subagents** — use worktrees; remove one only after final result delivery or confirmed cancellation.
- **File tracked bugs** — file bugs found here or upstream in the configured tracker; review feedback follows the dispositions in `principles/git-workflow.md`.
- **Checkpoint scope expansion before editing** — a follow-up approves doing the work, not bundling it. Route independent additions pre-edit; file count alone never decides.
- **Keep review subordinate to scope** — review cannot amend approved scope. A review-fix defect stops patching. A second ends same-shape work.
- **Count fix rounds; at three, take an exit** — one push of review-driven change is one round. Exits: merge-answered, revert-simplify, split, close-replan; more rounds is not one. Three fix rounds follow the capability across replacement PRs; closing or renaming never resets the budget.
- **Stop when the task is correct** — deterministic gates first. **The badge is the bar: fix P0/P1; consider P2, P3, or unbadged feedback, briefly answer and resolve; default to no further action, including no follow-up ticket unless requested — never fix one here, and never reopen the design space.** **Exact-head review after a fix commit is never skipped** and never authorizes mutation past a stop.

## Never commit on the default branch

Before the first edit of a tracked file in a session, run `git branch --show-current`. If it reports the default branch (`main` or `master`), branch first with `git checkout -b <type>/<slug>` where `<type>` is `feat | fix | chore | refactor | docs`. Your unstaged changes carry over — there's no cost to switching now and a real cost to discovering at commit time. Recovery steps when it happens anyway live in `principles/git-workflow.md`.

## Required Delivery Workflow

Branch and claim before edits; ship when the user ends iteration. An explicit implement-and-ship request authorizes the full path: validate, review, merge, verify, and reconcile. Do not stop at a plan, passing tests, or an open PR. Keep one complete outcome per review unit; reuse unchanged evidence and stop expanding correct work. See `principles/local-review.md`.

1. **Pull.** `git pull --rebase` on the default branch.
2. **Branch.** Before any edit that might become a commit.
3. **Claim tracked work before implementation.** GitHub: `touchstone tracker claim <ref>` (race-safe, verified by re-read). Linear: the adapter has no transport — assign yourself through the Linear MCP and re-read the assignee before editing. Claim every item in a bundle so two agents do not ship competing fixes; an unavailable transport is unverifiable, never success.
4. **Change + commit.** Stage explicit files. One concern per commit. Run `git show --stat --oneline HEAD`; unchanged `HEAD`: do not ship. No local AI review runs before the PR: review is the PR-visible reviewer's, on every pushed head.
5. **Reconcile tracked work.** Before opening the PR, list every tracker item found, claimed, fixed, partially fixed, or made stale. Fixed items get the configured closing reference in the PR body; partial or stale items get a tracker note explaining the evidence or remaining gap. Do not leave shipped work stale silently.
6. **Ship.** `git push -u origin HEAD`, then `touchstone pr open --expect-branch <branch> --title "<type>: <what>" --body-file <file>` — the installed CLI is the sequencer everywhere: it creates or reuses the PR, posts the review request, and confirms the exact head and base binding (re-running any declared gate). Put the configured closing reference (`Closes #123` or `Fixes AUT-123`) in the PR body, not only a commit. Re-run it for a later head (idempotent). **Never put the sequencer's marker in a comment you write yourself** — it reads that as a request for other coordinates and refuses to repair anything. A bare `@codex review` from a collaborator is valid only in recovery — bounded stalled-request recovery, or the CLI-absent raw sequence (`gh pr create`, the bare comment, then re-run any declared gate) — never the instruction.
7. **Answer every piece of PR feedback before merging.** Answering is not implementing; classify by scope *and severity*, then answer what you are not fixing using the dispositions in `principles/git-workflow.md`. Stop widened work; allowed fixes follow the cascade and exact-head rules. Inspect GitHub's complete review surface, reply to each comment, and resolve every thread via `principles/git-workflow.md`; unresolved threads and `CHANGES_REQUESTED` block merge.
8. **Merge.** Once the head is pushed and bound, run `touchstone pr merge <n> --head <sha>` without polling for the gate: a successful gate enters the queue, a pending one arms auto-merge, a failed one is refused. A queue entry ends mutation; never dequeue or probe admin merge. Verified queue enforcement permits raw `gh pr merge <n> --squash --match-head-commit <sha>`; otherwise stop. The merge-group gate owns later feedback. Confirm state.
9. **Clean up before the session ends.** Remove residue this session created; leave sibling work untouched; reconcile open tasks before declaring completion. `touchstone cleanup check` is repo-wide: resolve yours, route stale residue; its nonzero exit never authorizes deleting another session's work.

Raw commands are portable recovery; GitHub owns verdict and state. `principles/git-workflow.md` carries the full sequence, including thread resolution.

Never push directly to the default branch, even in an emergency; rewriting your own unmerged branch is fine. Audited policy enforces PR-only bypass; elsewhere it stays mandatory. See `principles/git-workflow.md`.

## Routing table — read these when the trigger fires

| When you're about to... | Read |
|---|---|
| prepare a PR — slice the work, pick its review tier, write its evidence | `principles/local-review.md` |
| branch, open a PR, answer review, merge, recover from `no-commit-to-branch`, work with stacked PRs, or fan out worktrees | `principles/git-workflow.md` |
| understand the AI-authored change lifecycle or PR review loop architecture | `principles/ai-delivery-architecture.md` |
| start a non-trivial code change | `principles/pre-implementation-checklist.md` |
| understand the *why* of a daily-reminder rule | `principles/engineering-principles.md` |
| edit, write, or audit documentation | `principles/documentation-ownership.md` |
| audit a structural bug class after fixing one instance | `principles/audit-weak-points.md` |
| hit a bug in an upstream tool (don't silently work around it) | `principles/file-upstream-bugs.md` |
| write, trust, or audit agent memory — it is a cache, not truth | `principles/memory-hygiene.md` |

Claude Code agents: the bundled `touchstone-*` and `memory-audit` skills mirror this table in your session header; `touchstone steering install` keeps them current. Trust whichever surface fires first.
