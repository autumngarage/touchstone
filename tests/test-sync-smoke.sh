#!/usr/bin/env bash
#
# tests/test-sync-smoke.sh — smoke-test `update-project.sh --dry-run` against
# the user's actual registered projects.
#
# Synthetic tempdir tests (test-bootstrap.sh, test-update.sh) exercise the
# code paths but cannot catch the canonical failure mode of a sync system —
# "a touchstone change subtly breaks a real downstream project's specific
# config." Real projects accumulate project-specific state that synthetic
# fixtures do not have. This smoke test runs touchstone's update flow in
# strict --dry-run mode against every project in ~/.touchstone-projects (or
# whatever registry is pointed to by TOUCHSTONE_PROJECTS_FILE) and asserts:
#
#   1. update-project.sh --dry-run exits 0
#   2. its combined stdout/stderr contains no `^ERROR` line
#   3. the project's `git status --porcelain` is byte-identical before and
#      after the run — i.e. --dry-run truly mutated nothing
#
# Tolerances:
#   - Missing registry file → skip (exit 0)
#   - Empty registry         → skip (exit 0)
#   - Registered path that no longer exists → warn, continue
#   - Registered path that is not a git repo → warn, continue (we can't
#     compare porcelain there, so we cannot enforce the no-mutation invariant)
#   - Any per-project failure → recorded, summary printed, exit 1 at the end
#
set -u

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY_FILE="${TOUCHSTONE_PROJECTS_FILE:-$HOME/.touchstone-projects}"

echo "==> Smoke test: dry-run sync against registered projects"
echo "    TOUCHSTONE_ROOT: $TOUCHSTONE_ROOT"
echo "    Registry file:   $REGISTRY_FILE"

if [ ! -f "$REGISTRY_FILE" ]; then
  echo "==> No registry file at $REGISTRY_FILE — no registered projects, skipping smoke test."
  exit 0
fi

# Read non-comment, non-blank lines into an array (portable; no mapfile).
PROJECTS=()
while IFS= read -r line || [ -n "$line" ]; do
  # Strip leading/trailing whitespace.
  trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$trimmed" ] && continue
  case "$trimmed" in
    \#*) continue ;;
  esac
  PROJECTS+=("$trimmed")
done < "$REGISTRY_FILE"

if [ "${#PROJECTS[@]}" -eq 0 ]; then
  echo "==> Registry is empty, skipping smoke test."
  exit 0
fi

TESTED=0
WARNINGS=0
FAILURES=0
FAILED_PROJECTS=()

for project in "${PROJECTS[@]}"; do
  echo ""
  echo "--- Project: $project ---"

  if [ ! -d "$project" ]; then
    echo "    WARN: $project registered but missing on disk"
    WARNINGS=$((WARNINGS + 1))
    continue
  fi

  TESTED=$((TESTED + 1))

  # Snapshot porcelain BEFORE the run. If the path is not a git repo, we
  # can't enforce the no-mutation invariant — log it and run anyway, but
  # mark the project as a warning since we lose half the test.
  is_git_repo=false
  porcelain_before=""
  if git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_git_repo=true
    porcelain_before="$(git -C "$project" status --porcelain 2>/dev/null || true)"
  else
    echo "    WARN: $project is not a git repo; cannot enforce no-mutation invariant"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Run --dry-run and capture combined stdout+stderr and exit code.
  output_file="$(mktemp -t touchstone-smoke.XXXXXX)"
  set +e
  ( cd "$project" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --dry-run ) \
    > "$output_file" 2>&1
  rc=$?
  set -e

  project_failed=false

  if [ "$rc" -ne 0 ]; then
    echo "    FAIL: --dry-run exited $rc"
    project_failed=true
  fi

  # Case-sensitive, line-anchored ERROR check.
  if grep -n '^ERROR' "$output_file" >/dev/null 2>&1; then
    echo "    FAIL: output contains an ERROR line"
    project_failed=true
  fi

  # Verify --dry-run did not mutate the worktree.
  if [ "$is_git_repo" = true ]; then
    porcelain_after="$(git -C "$project" status --porcelain 2>/dev/null || true)"
    if [ "$porcelain_before" != "$porcelain_after" ]; then
      echo "    FAIL: worktree changed during --dry-run (no-mutation invariant violated)"
      echo "    --- porcelain before ---"
      printf '%s\n' "$porcelain_before"
      echo "    --- porcelain after ---"
      printf '%s\n' "$porcelain_after"
      project_failed=true
    fi
  fi

  if [ "$project_failed" = true ]; then
    echo "    --- captured output ---"
    cat "$output_file"
    echo "    --- end output ---"
    FAILURES=$((FAILURES + 1))
    FAILED_PROJECTS+=("$project")
  else
    echo "    PASS"
  fi

  rm -f "$output_file"
done

echo ""
echo "==> Tested $TESTED projects, $WARNINGS warnings (missing paths or non-git), $FAILURES failures."

if [ "$FAILURES" -gt 0 ]; then
  echo "==> Failing projects:"
  # Bash 3.2 (macOS /bin/bash) aborts under set -u when expanding an empty
  # array as "${FAILED_PROJECTS[@]}". The +"..." idiom keeps the expansion
  # safe even though we only enter this branch when FAILURES > 0 (which
  # implies FAILED_PROJECTS is non-empty).
  for p in ${FAILED_PROJECTS[@]+"${FAILED_PROJECTS[@]}"}; do
    echo "      $p"
  done
  exit 1
fi

exit 0
