#!/usr/bin/env bash
#
# lib/agents-principles-block.sh — manage the touchstone-owned shared-engineering-
# principles block inside a project's AGENTS.md.
#
# Why this exists:
#   AGENTS.md is project-owned: copied once at bootstrap and then maintained by
#   the project's authors. Claude Code gets these principles through
#   CLAUDE.md's @principles/... imports; Codex and other AGENTS.md-native tools
#   need them directly in AGENTS.md. Reviewers need the same principles too.
#
#   This helper inserts (and refreshes) a sentinel-delimited block at the top
#   of AGENTS.md that lists the principles in a format any agent can read.
#   The block is touchstone-owned; everything outside the markers is project-
#   owned and never touched.
#
# Public surface:
#   agents_principles_block_render               — print the current block to stdout
#   agents_principles_block_apply <agents_md>    — apply (inject or refresh) in place
#
# Exit codes for agents_principles_block_apply:
#   0 — file exists and is now current (may or may not have changed on disk)
#   1 — file is malformed (one sentinel without its pair); refused to touch
#   2 — file does not exist (caller decides whether to copy a template first)

AGENTS_PRINCIPLES_BLOCK_BEGIN='<!-- touchstone:shared-principles:start -->'
AGENTS_PRINCIPLES_BLOCK_END='<!-- touchstone:shared-principles:end -->'

agents_principles_block_render() {
  cat <<'BLOCK'
<!-- touchstone:shared-principles:start -->
## Shared Engineering Principles (apply these first)

These principles are touchstone-owned and shared across every project. Apply them as the **primary coding and review criteria** before any project-specific rule below — an agent that lets a band-aid or a silent failure through has missed the point of this gate.

## Agent Roles And Fallbacks

There are two AI roles in a Touchstone workflow:

- **Driving CLI:** Claude Code, Codex, or Gemini CLI owns the repo workflow. The driver reads the steering files, edits files, runs tests, creates the branch and commits, opens the PR, invokes review, and ships through the merge helper.
- **Conductor worker/reviewer:** Conductor is the model router used by the driving CLI for review and bounded model work. Conductor can route to Claude, Codex, Gemini, or other providers, and can fall back between configured providers, but Conductor does not replace the driving CLI's responsibility for the branch → PR → review → automerge workflow.

Driver fallback is shared-contract fallback: Codex and other AGENTS.md-native tools start here; Gemini starts in `GEMINI.md` and delegates back here; Claude starts in `CLAUDE.md` and imports the same `principles/` files. If one driving CLI is unavailable or rate-limited, another driving CLI can continue by reading its entry file plus this managed block and `principles/*.md`. If an agent-specific file is incomplete or conflicts with this block or `principles/*.md`, follow the managed block and principles first.

- **No band-aids** — Fix the root cause unless the PR explicitly documents why a symptom patch is the safer scoped change. If it's a symptom patch, say so: *"This patches the symptom. The root cause is X and fixing it properly would require Y. Which do you want?"* Undocumented symptom patches compound — a year later you have a codebase full of thin fixes and nobody remembers which ones were intentional.
- **Keep interfaces narrow** — Expose the smallest stable interface that lets callers do their job. Don't leak storage shape, vendor SDKs, temporary flags, or workflow sequencing across module boundaries. A deep module hides substantial complexity behind a stable contract; a shallow module exports its complexity to every caller and makes every future fix broad and risky.
- **Derive limits from domain; test at scale boundaries** — Derive thresholds, sizes, limits, and allocations from input, configuration, or named domain constants. Hard-code a value only when it represents a real invariant, and document why. Test behavior at small, typical, and large scales — not just the shape you developed against. Code that only works at one scale will silently misbehave at the scales you forgot.
- **Derive, don't persist** — Compute from the source of truth by default. Persist derived state only when recomputation is too slow, too expensive, or externally required — and when you do, document in the same commit: the source of truth, the invalidation trigger, the rebuild path, and a reconciliation check. Undocumented persisted state goes stale silently; that is the failure mode this rule prevents.
- **No silent failures** — Every exception is either re-raised or logged with enough context to debug from production logs alone. No `except: pass`. No swallowed errors. No default values returned on failure without a log line. Fallback behavior may continue only when it reports what failed, what was skipped, and what safety boundary still holds.
- **Every fix gets a test** — Bug fixes must include a test that reproduces the exact failure mode, and the test must run in CI — not just locally. A bug fix without a regression test means the bug can recur silently the next time someone refactors nearby. The test should fail on the old code and pass on the new code — if it passes on both, it isn't testing the right thing.
- **Think in invariants** — For nontrivial logic, name at least one invariant and assert it — either in a test or as a runtime boundary check. What must always be true? What relationship between values must hold? Happy-path outputs tell you the code worked for one input; invariants tell you it can't be wrong for any input in the covered space.
- **One code path** — Share business logic across modes (test/prod, paper/live, dev/staging). Divergent paths drift apart silently, and bugs in one path don't surface until it's too late. If modes must differ, confine the difference to adapters, configuration, or the final I/O boundary — not a fork at the top of the pipeline.
- **Version your data boundaries** — When a model, algorithm, or data source changes in a way that affects decisions, rankings, persisted state, metrics, or user-visible behavior, establish a boundary (cohort, epoch, version) and ensure every downstream consumer honors it. Reads that drive decisions must not blend data across the boundary; aggregating across it dilutes signal with noise from the old regime.
- **Separate behavior changes from tidying** — Do not mix functional changes with broad renames, formatting sweeps, dependency churn, or unrelated refactors. If cleanup is needed, do it before or after the behavior change in a separate commit or PR. Reviewers must be able to see the semantic change without diff noise; mixed changes hide regressions and make rollback unsafe.
- **Make irreversible actions recoverable** — Any destructive or one-way operation must have a recovery path before it runs. Deletes, migrations, format rewrites, external side effects, and history rewrites need a dry run, backup, idempotency key, rollback plan, or forward-fix plan. A change is not safe because it passed once; it is safe when failure leaves the system in a known recoverable state.
- **Preserve compatibility at boundaries** — Changes to public APIs, config files, schemas, CLIs, hooks, templates, and generated artifacts must include a compatibility or migration plan. Accept old and new formats during rollout when downstream consumers may lag. Boundary breaks multiply: one local assumption becomes N downstream failures.
- **Audit weak-point classes** — When you find a structural bug, audit the whole class — not just the one you noticed. Use the `touchstone-audit-weak-points` skill. This discipline prevents re-auditing the same code twice and catches bugs before they compound.
- **File issues for bugs** — Open a GitHub issue when you find a bug, in this project or in an autumngarage tool. Do not silently work around it.

Full rationale, worked examples, and the *why* behind each rule:

- `principles/engineering-principles.md`
- `principles/pre-implementation-checklist.md`
- `principles/documentation-ownership.md`
- `principles/git-workflow.md`
- `principles/agent-swarms.md`
- `principles/file-upstream-bugs.md`

## Required Delivery Workflow

For any task that may change tracked files, drive the full branch → PR → review → merge lifecycle unless the user explicitly asks you to stop before shipping:

1. Sync the default branch with `git pull --rebase`.
2. Before the first edit, run `git branch --show-current`. If it reports `main` or `master`, create a feature branch with `git checkout -b <type>/<short-description>`.
3. Make the change on that branch, keep commits scoped, stage explicit file paths, and commit with a concise message.
4. From a clean worktree, run `CODEX_REVIEW_FORCE=1 bash scripts/codex-review.sh`. If Conductor creates fix commits, let the loop finish; if it blocks, address findings, commit, and rerun until clean.
5. Ship with `bash scripts/open-pr.sh --auto-merge`. That command pushes the branch, creates the PR, runs the final read-only Conductor merge review, squash-merges after a clean review, and syncs the default branch.

Do not bypass the PR/review/automerge path with a direct default-branch push except through the documented emergency path in `principles/git-workflow.md`.

This block is managed by `touchstone` and refreshes on `touchstone update` / `touchstone init`. Edit content **outside** the markers to add project-specific agent guidance — touchstone will not touch it.
<!-- touchstone:shared-principles:end -->
BLOCK
}

agents_principles_block_apply() {
  local target="$1"

  if [ -z "$target" ]; then
    echo "ERROR: agents_principles_block_apply requires a path argument" >&2
    return 1
  fi

  if [ ! -f "$target" ]; then
    return 2
  fi

  local has_begin has_end
  has_begin=0
  has_end=0
  grep -qF "$AGENTS_PRINCIPLES_BLOCK_BEGIN" "$target" && has_begin=1
  grep -qF "$AGENTS_PRINCIPLES_BLOCK_END" "$target" && has_end=1

  if [ "$has_begin" != "$has_end" ]; then
    echo "ERROR: $target has an orphaned shared-principles sentinel — refusing to touch." >&2
    echo "       Inspect both '$AGENTS_PRINCIPLES_BLOCK_BEGIN' and '$AGENTS_PRINCIPLES_BLOCK_END' and reconcile manually." >&2
    return 1
  fi

  local block_file out_file
  block_file="$(mktemp -t agents-principles-block.XXXXXX)"
  out_file="$(mktemp -t agents-principles-out.XXXXXX)"
  agents_principles_block_render >"$block_file"

  if [ "$has_begin" = 1 ]; then
    # Refresh: copy lines, but when we hit the start marker, splice the current
    # block in and skip until the end marker. Idempotent on a current file.
    local in_block=0 spliced=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$in_block" = 1 ]; then
        if [ "$line" = "$AGENTS_PRINCIPLES_BLOCK_END" ]; then
          in_block=0
        fi
        continue
      fi
      if [ "$line" = "$AGENTS_PRINCIPLES_BLOCK_BEGIN" ]; then
        if [ "$spliced" = 0 ]; then
          cat "$block_file" >>"$out_file"
          spliced=1
        fi
        in_block=1
        continue
      fi
      printf '%s\n' "$line" >>"$out_file"
    done <"$target"
  else
    # Inject at top, after the first H1 if there is one — otherwise at line 1.
    local first_line
    first_line="$(head -n 1 "$target" || true)"
    if [[ "$first_line" =~ ^\#\  ]]; then
      printf '%s\n' "$first_line" >>"$out_file"
      printf '\n' >>"$out_file"
      cat "$block_file" >>"$out_file"
      printf '\n' >>"$out_file"
      tail -n +2 "$target" >>"$out_file"
    else
      cat "$block_file" >>"$out_file"
      printf '\n' >>"$out_file"
      cat "$target" >>"$out_file"
    fi
  fi

  if cmp -s "$out_file" "$target"; then
    rm -f "$block_file" "$out_file"
    return 0
  fi

  # Atomic replace; preserve the file's permissions.
  cat "$out_file" >"$target"
  rm -f "$block_file" "$out_file"
  return 0
}
