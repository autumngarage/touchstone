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
- **Conductor worker/reviewer:** Conductor is the model router used by the driving CLI for review and bounded worker tasks. Conductor can route to Claude, Codex, Gemini, or other providers, and can fall back between configured providers, but Conductor does not replace the driving CLI's responsibility for git, PR, and merge workflow.

Driver fallback is shared-contract fallback: Codex and other AGENTS.md-native tools start here; Gemini starts in `GEMINI.md` and delegates back here; Claude starts in `CLAUDE.md` and imports the same `principles/` files. If one driving CLI is unavailable or rate-limited, another driving CLI can continue by reading its entry file plus this managed block and `principles/*.md`. If an agent-specific file is incomplete or conflicts with this block or `principles/*.md`, follow the managed block and principles first.

- **No band-aids** — fix the root cause; if patching a symptom, say so explicitly and name the root cause.
- **Keep interfaces narrow** — expose the smallest stable contract; don't leak storage shape, vendor SDKs, or workflow sequencing.
- **Derive limits from domain** — thresholds and sizes come from input/config/named constants; test at small, typical, and large scales.
- **Derive, don't persist** — compute from the source of truth; persist derived state only with a documented invalidation + rebuild path.
- **No silent failures** — every exception is re-raised or logged with debug context. No `except: pass`, no swallowed errors.
- **Every fix gets a test** — bug fix includes a regression test that runs in CI and fails on the old code.
- **Think in invariants** — name and assert at least one invariant for nontrivial logic.
- **One code path** — share business logic across modes; confine mode-specific differences to adapters, config, or the I/O boundary.
- **Version your data boundaries** — when a model/algorithm/source change affects decisions, version the boundary; don't aggregate across.
- **Separate behavior changes from tidying** — never mix functional changes with broad renames, formatting sweeps, or unrelated refactors.
- **Make irreversible actions recoverable** — destructive operations need a dry-run, backup, idempotency, rollback, or forward-fix plan before they run.
- **Preserve compatibility at boundaries** — public API/config/schema/CLI/hook/template changes need a compatibility or migration plan.
- **Audit weak-point classes** — when a structural bug is found, audit the class and add a guardrail; don't fix only the one instance.

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
  agents_principles_block_render > "$block_file"

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
          cat "$block_file" >> "$out_file"
          spliced=1
        fi
        in_block=1
        continue
      fi
      printf '%s\n' "$line" >> "$out_file"
    done < "$target"
  else
    # Inject at top, after the first H1 if there is one — otherwise at line 1.
    local first_line
    first_line="$(head -n 1 "$target" || true)"
    if [[ "$first_line" =~ ^\#\  ]]; then
      printf '%s\n' "$first_line" >> "$out_file"
      printf '\n' >> "$out_file"
      cat "$block_file" >> "$out_file"
      printf '\n' >> "$out_file"
      tail -n +2 "$target" >> "$out_file"
    else
      cat "$block_file" >> "$out_file"
      printf '\n' >> "$out_file"
      cat "$target" >> "$out_file"
    fi
  fi

  if cmp -s "$out_file" "$target"; then
    rm -f "$block_file" "$out_file"
    return 0
  fi

  # Atomic replace; preserve the file's permissions.
  cat "$out_file" > "$target"
  rm -f "$block_file" "$out_file"
  return 0
}
