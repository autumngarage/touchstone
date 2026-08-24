# Agent Swarms And Worktrees

Agent swarms are useful only when the work is truly separable. The default
coordination primitive is an isolated git worktree per file-writing worker:
one checkout, one branch, one bounded file surface, one report back to the
parent. A flat shared checkout is the exception and should be explicitly
waived.

## When To Spawn Worktrees

Use one branch in the main checkout when the change is small or conceptually
tight:

- 1-3 files
- one concept or one bug
- one test surface
- edits that need continuous judgment across the same files

Use 2-4 worktrees when the work spans separable modules:

- 4-12 files split across clear ownership boundaries
- independent implementation slices with disjoint file sets
- each slice can run focused tests without waiting on the others
- the parent can integrate the final state without redesigning the work

Use many worktrees only for broad repeated migrations:

- the pattern is mechanical and already understood
- slices are listed in a manifest before launch
- each worker owns a narrow directory or file set
- shared files are held back for the parent
- automated PR fan-out or review routing exists

Disjoint file sets are the prerequisite. If two workers need the same file,
schema, generated index, lockfile, changelog, version file, or release note,
they are not parallel for that part of the work. Sequence the overlapping edit
or assign it to the parent.

## The Slice Manifest

Write the manifest before fan-out. It is the parent-owned contract that keeps
parallel work from becoming unreviewable shared state.

Each worker gets:

- **Name**: stable label used in prompts, branches, and status updates.
- **Branch**: unique `<type>/<slug>` branch. Never share a branch across
  worktrees.
- **Worktree path**: explicit directory, usually `../<repo>-<slug>`.
- **Files allowed**: files or directories the worker may edit.
- **Files forbidden**: shared files the worker must not touch.
- **Tests/validation**: exact commands or manual checks for the slice.
- **Expected output**: changed paths, commit SHA, tests run, and blockers.

Example:

| Worker | Branch | Worktree | Files allowed | Files forbidden | Validation | Output |
|--------|--------|----------|---------------|-----------------|------------|--------|
| auth-api | `feat/auth-api-slice` | `../app-auth-api` | `src/auth/**`, `tests/auth/**` | `package-lock.json`, `schema.sql`, `CHANGELOG.md` | `npm test -- auth` | changed paths, commit SHA, test result |
| billing-ui | `feat/billing-ui-slice` | `../app-billing-ui` | `src/billing/**`, `tests/billing/**` | `package-lock.json`, `routes.generated.ts`, `CHANGELOG.md` | `npm test -- billing` | changed paths, commit SHA, test result |
| docs-pass | `docs/swarm-docs-slice` | `../app-swarm-docs` | `docs/billing.md`, `docs/auth.md` | `CHANGELOG.md`, version files | `npm run docs:check` | changed paths, commit SHA, test result |

YAML form is fine when the manifest needs comments:

```yaml
slices:
  - name: auth-api
    branch: feat/auth-api-slice
    worktree: ../app-auth-api
    files_allowed:
      - src/auth/**
      - tests/auth/**
    files_forbidden:
      - package-lock.json
      - schema.sql
      - CHANGELOG.md
    validation:
      - npm test -- auth
    expected_output:
      - changed paths
      - commit SHA
      - test results
      - blockers
```

The manifest is not a suggestion. If a worker discovers it needs a forbidden
file, it reports the need and stops that part of the work. The parent decides
whether to edit the shared file centrally, revise the manifest, or sequence a
follow-up slice.

## Parent Orchestration Rules

The parent session owns the coordination boundary:

- creates or approves the slice manifest
- spawns worktrees with `git worktree add`
- owns shared files: lockfiles, schemas, generated indexes, changelogs,
  version files, route manifests, API indexes, and release notes
- integrates worker outputs
- runs final deterministic tests
- invokes the final review path
- opens or routes PRs
- cleans up worktrees with `git worktree remove`, but only after the worker's
  task is terminal and the parent has received its final report — whoever
  creates a worktree removes it, and the dispatch record (issue comment or
  brief) names the worktree path so a later sweep can find it; `touchstone
  cleanup check` in the main checkout lists any that remain

Workers own only their slice:

- edit allowed files only
- never edit forbidden files
- commit only their slice
- run the slice validation
- report changed paths, commit SHA, tests run, and blockers
- leave integration and shared-file changes to the parent

Default to one PR per worker when slices are independently shippable. Use an
aggregate PR when the feature only makes sense as a unit, when shared files
must be updated centrally, or when the change only makes sense reviewed as
a whole.

### Pipeline Meta-Fixes Ship First

If a lane changes the review/merge pipeline itself, ship that lane before other
parallel lanes. Pipeline fixes include the delivery prose in
`principles/git-workflow.md`, delivery workflows, review-response tooling,
and pre-commit hooks. Every
other lane flows through that path at review/merge time, so leaving known
pipeline bugs in place can invalidate otherwise-correct slice PRs.

Worked example (Wave 2): land pipeline PR **#214** first, then run content
lanes **#215** and **#216** through the fixed pipeline. Do not merge #215/#216
first and "fix the pipeline later."

## Concurrency Cap

Parallel work has real coordination cost.

- **Solo human supervising**: 3-5 concurrent worktrees.
- **Parent-agent supervised**: 4-6 concurrent worktrees.
- **10+ workers**: only with a manifest, automated PR fan-out, and automated
  status collection.

Higher numbers do not come for free. Every extra worker adds review load,
branch state, test output, and cleanup responsibility. If the parent cannot
name the current state of every slice, the swarm is too large.

## Anti-Coordination Rules

These rules prevent hidden shared state:

- No `git stash` as a coordination mechanism.
- No worker edits another worker's files.
- No worker waits on another worker's in-flight result.
- No shared branch across worktrees.
- No worker-owned edits to shared files.
- No checkpoint commits in review artifacts.

Local recovery commits are allowed while a worker is exploring. Pushed `WIP:`,
`checkpoint`, or deliberately broken commits do not belong on review branches.
Squash or fix them before opening or marking a PR ready.

## Worktree Hygiene

Git already provides the primitive; use it directly:

```bash
git worktree add -b feat/my-slice ../app-my-slice
git worktree list
git worktree remove ../app-my-slice
```

Deleting a worktree directory is not the same as `git worktree remove <path>`.
`rm -rf ../app-slice` removes files but can leave stale records under Git's
shared worktree metadata, so Git may still think a branch is checked out there
and refuse later checkouts, branch deletes, or merges. For normal cleanup, use
`git worktree remove <path>`. If someone already deleted one or more
directories directly, first confirm every affected worker task is terminal and
the parent received every final report. Then run `git worktree prune` from a
remaining checkout to remove metadata for the missing paths, and rerun the
failed checkout, merge, or cleanup command.

Rules:

- never remove a worker's tree before its task is terminal and the parent has
  received its final report; an open or merged PR and a clean worktree prove
  neither condition
- never run repository-wide `git worktree prune` until every prunable worker
  meets that lifecycle precondition
- if abandoning a live worker, interrupt or cancel it and confirm that it is
  terminal before removing its tree
- never `git worktree remove --force` another agent's tree
- never `git gc --prune=now` while sibling worktrees are active
- never share one branch across multiple worktrees
- never delete the main worktree from a cleanup script
- never remove a dirty worktree unless the owner explicitly abandons it

## The Untracked-File Problem

Git worktrees contain tracked files. They do not bring along `.env`, local
config, generated certificates, dependency directories, editor state, or other
ignored local files. Copy the ones a slice needs explicitly, and name them in
the slice manifest so the parent knows what left the original checkout.

Do not copy secrets without explicit opt-in. A secret carried into a worktree
is duplicated into another directory on disk; the person or agent launching
the worker owns that decision.

Never symlink dependency or build artifact directories across worktrees:

- `node_modules`
- `.venv`
- `target`
- `.next`
- `dist`
- `build`

Those directories carry platform artifacts, absolute shebangs, interpreter
paths, lock state, and installer side effects. Sharing them across concurrent
worktrees can corrupt installs or make tests pass for the wrong checkout.
Recreate dependencies per worktree or use the project's normal setup command.

## Cloud And Vendor Parallel

Cloud agents use the same primitive under different names: isolated checkout,
branch, validation, and PR. Claude Code supports agent isolation with
worktrees, Codex cloud tasks run in isolated sandboxes, and Cursor background
agents use separate branches and review artifacts. Local git worktrees are the
cross-stack version of that model.

The invariant is the same everywhere: file-writing workers do not share a
mutable checkout. They return a branch, a diff, tests, and any blockers to the
parent.
