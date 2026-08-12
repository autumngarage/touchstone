#!/usr/bin/env bash
#
# lib/retired-managed.sh — the canonical set of Touchstone-managed paths that
# have been retired, and the single code path that removes them from a project.
#
# BOTH entrypoints have to retire. `touchstone update` always did.
# `touchstone init` did not, and init regenerates .touchstone-manifest from
# scratch — so an init-ed project kept every retired file on disk AND lost the
# ledger entries that make a file reachable. The result was permanent: on
# disk, absent from the manifest, invisible to every future `touchstone
# update` (#737 round-2 review). Sharing one list and one remover is the fix —
# a retirement added below reaches both entrypoints or neither.

if ! declare -F touchstone_ensure_safe_dest >/dev/null 2>&1; then
  # shellcheck source=safe-write.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safe-write.sh"
fi

# The retired set, one project-relative path per line.
#
#   lib/review-comment.sh          - local review comment plumbing, no consumer
#   scripts/cortex-pr-merged-hook.sh - journal hook retired with the Cortex
#                                    pause (#730); merge-pr.sh no longer calls
#                                    it, so a leftover copy is dead code that
#                                    still pushes HEAD:main on a manual run
#   scripts/spawn-worktree.sh      - wrapper around plain `git worktree add`
#   scripts/cleanup-worktrees.sh   - wrapper around plain `git worktree remove`
#   lib/events.sh                  - NDJSON telemetry whose only reader was the
#                                    worker engine removed in PR #697
#   lib/codex-auth.sh              - subscription auth with no runtime consumer
#   scripts/run-pytest-in-venv.sh  - duplicated what touchstone-run.sh already
#                                    dispatches through find_python_bin
#
# Adding an entry retires the file in init and update alike. The matching copy
# call in bootstrap/update-project.sh and bootstrap/new-project.sh must be
# deleted in the SAME commit, or the copy pass re-creates what this removes.
# lib/sync-discipline.sh must list the same paths in its planned write set so
# a failed update can roll the deletion back; tests/test-sync-scope-aware.sh
# fails when the two drift.
touchstone_retired_managed_paths() {
  printf 'lib/review-comment.sh\n'
  printf 'scripts/cortex-pr-merged-hook.sh\n'
  printf 'scripts/spawn-worktree.sh\n'
  printf 'scripts/cleanup-worktrees.sh\n'
  printf 'lib/events.sh\n'
  printf 'lib/codex-auth.sh\n'
  printf 'scripts/run-pytest-in-venv.sh\n'
}

# Does retirement have anything to do for this path in this project? True only
# when Touchstone's ledger still claims the path AND the file is really there.
# Callers use it to decide whether a retirement section has anything to report
# before printing a header, and to collect the set worth cross-checking against
# project-owned steering.
touchstone_retired_managed_file_applies() {
  local project_dir="$1" rel_path="$2"
  local manifest="$project_dir/.touchstone-manifest"
  local manifest_entries=""

  [ -f "$manifest" ] || return 1
  # CRLF tolerance: a manifest checked out with core.autocrlf carries \r,
  # which a plain fixed-string match would never equal. Read into a variable
  # rather than piping: grep -q exits at the first match, tr takes SIGPIPE,
  # and pipefail would turn a successful MATCH into a nonzero pipeline.
  manifest_entries="$(tr -d '\r' <"$manifest")" || return 1
  grep -qxF "$rel_path" <<<"$manifest_entries" || return 1
  [ -e "$project_dir/$rel_path" ]
}

# Remove one retired managed file from a project.
#
# Exit status is the outcome, so each caller can keep its own counters without
# this function knowing about them:
#   0  removed
#   1  nothing to do (not in the ledger, or already gone)
#   2  refused: unsafe path
#   3  refused: left in place (untracked, or carrying uncommitted edits)
#   4  would remove (dry run)
touchstone_remove_retired_managed_file() {
  local project_dir="$1" rel_path="$2" dry_run="${3:-false}"
  local target="$project_dir/$rel_path"

  touchstone_retired_managed_file_applies "$project_dir" "$rel_path" || return 1

  if ! touchstone_ensure_safe_dest "$target" "$project_dir" "$dry_run" || [ ! -f "$target" ]; then
    echo "    ! refusing to remove unsafe retired path: $target" >&2
    return 2
  fi
  if ! git -C "$project_dir" ls-files --error-unmatch -- "$rel_path" >/dev/null 2>&1; then
    echo "    ! leaving untracked retired file in place: $target" >&2
    echo "      Touchstone will stop managing it; remove it manually after preserving any local changes." >&2
    return 3
  fi
  # Never destroy local work: a retired file carrying uncommitted edits is
  # left in place with an explicit notice. Retirement removes Touchstone's
  # managed copy, it does not discard a project's modifications.
  # Worktree OR index: a staged customization must neither be deleted nor
  # swept into Touchstone's own update commit.
  if ! git -C "$project_dir" diff --quiet -- "$rel_path" 2>/dev/null \
    || ! git -C "$project_dir" diff --cached --quiet -- "$rel_path" 2>/dev/null; then
    echo "    ! leaving locally modified retired file in place: $target" >&2
    echo "      It has uncommitted changes (worktree or index); Touchstone no longer manages it." >&2
    echo "      Commit or discard them, then delete the file when you are ready." >&2
    return 3
  fi
  if [ "$dry_run" = true ]; then
    echo "    - would remove retired managed file: $target"
    return 4
  fi
  rm -f "$target"
  echo "    - removed retired managed file: $target"
  return 0
}

# Retirement removes Touchstone's managed copy of a script. It cannot touch the
# project's own steering docs, and no future sync ever will — CLAUDE.md,
# AGENTS.md, and GEMINI.md are project-owned, so a project whose AGENTS.md says
# "use scripts/spawn-worktree.sh to fan out worktrees" keeps instructing agents
# to run a file that is gone, forever, with nothing to correct it. A notice is
# the only mechanism available (#737 round-2 review).
#
# Same contract as update-project.sh's report_retired_worker_files: name the
# file, name the reference, change nothing. Rewriting project-owned prose to
# match a Touchstone decision is exactly the automation this release removes.
#
# Usage: touchstone_report_retired_steering_references <project_dir> [rel_path...]
# where the rel_paths are the retirements that applied in THIS run — the notice
# belongs to the moment the surface goes away, not to every subsequent sync.
touchstone_report_retired_steering_references() {
  local project_dir="$1"
  shift
  local doc rel found=false

  [ "$#" -gt 0 ] || return 0
  for doc in CLAUDE.md AGENTS.md GEMINI.md; do
    [ -f "$project_dir/$doc" ] || continue
    for rel in "$@"; do
      grep -qF -- "$rel" "$project_dir/$doc" 2>/dev/null || continue
      if [ "$found" = false ]; then
        echo "    ! project-owned steering still points at retired touchstone surfaces:"
        found=true
      fi
      echo "      - $doc names $rel"
    done
  done
  [ "$found" = true ] || return 0
  echo "      These files are project-owned; touchstone will never rewrite them."
  echo "      Edit the instructions yourself, or agents will keep invoking what is gone."
}
