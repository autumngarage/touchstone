#!/usr/bin/env bash
# Detect the frozen Touchstone workflow/config pairing that blocks validation
# after a legitimate push to a protected default branch.
set -euo pipefail

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
PRE_COMMIT="$ROOT/.pre-commit-config.yaml"
WORKFLOW_DIR="$ROOT/.github/workflows"

[ -f "$PRE_COMMIT" ] || exit 0
[ -d "$WORKFLOW_DIR" ] || exit 0

if ! grep -q 'id:[[:space:]]*no-commit-to-branch' "$PRE_COMMIT" \
  || ! grep -q 'stages:[[:space:]]*\[pre-commit\]' "$PRE_COMMIT"; then
  exit 0
fi

found=0
workflow_pushes_default() {
  awk '
    function flush_push() {
      if (in_push && (default_branch || (!branches_seen && !tags_seen && !ignored_default))) found = 1
      in_push = 0
      in_branches = 0
      in_ignored = 0
    }
    {
      trimmed = $0
      sub(/^[[:space:]]*/, "", trimmed)
      indent = index($0, substr(trimmed, 1, 1)) - 1
      content = trimmed
      sub(/[[:space:]]*#.*/, "", content)

      if (in_push && content != "" && indent <= push_indent) flush_push()
      if (in_on && content != "" && indent <= on_indent) {
        flush_push()
        in_on = 0
      }

      if (content ~ /^on:[[:space:]]*$/) {
        in_on = 1
        on_indent = indent
        next
      }
      if (content ~ /^on:[[:space:]]*(push|\[[^]]*push[^]]*\])[[:space:]]*$/) {
        found = 1
        next
      }
      if (in_push) {
        if (content ~ /^branches:[[:space:]]*/) {
          branches_seen = 1
          in_branches = 1
          in_ignored = 0
          filter_indent = indent
          if (content ~ /(main|master)/) default_branch = 1
        } else if (content ~ /^branches-ignore:[[:space:]]*/) {
          in_branches = 0
          in_ignored = 1
          filter_indent = indent
          if (content ~ /(main|master)/) ignored_default = 1
        } else if (content ~ /^tags(-ignore)?:/) {
          tags_seen = 1
          in_branches = 0
          in_ignored = 0
        } else if (content ~ /^-[[:space:]]*(main|master)[[:space:]]*$/ && indent > filter_indent) {
          if (in_branches) default_branch = 1
          if (in_ignored) ignored_default = 1
        } else if (content != "" && indent <= filter_indent) {
          in_branches = 0
          in_ignored = 0
        }
        next
      }
      if (!in_on || content !~ /^push:/) next

      flush_push()
      in_push = 1
      push_indent = indent
      branches_seen = 0
      default_branch = 0
      tags_seen = 0
      ignored_default = 0
      in_branches = 0
      in_ignored = 0
      sub(/^push:[[:space:]]*/, "", content)
      if (content ~ /branches:[^]}]*(main|master)/) {
        branches_seen = 1
        default_branch = 1
      } else if (content ~ /branches:/) {
        branches_seen = 1
      }
      if (content ~ /branches-ignore:[^]}]*(main|master)/) ignored_default = 1
      if (content ~ /tags(-ignore)?:/) tags_seen = 1
      next
    }
    END {
      flush_push()
      exit !found
    }
  ' "$1"
}

workflow_has_unguarded_precommit() {
  awk '
    function flush_step() {
      if (has_pre_commit && needs_step_env && !has_step_env) unsafe = 1
      has_pre_commit = 0
      needs_step_env = 0
      has_step_env = 0
      exported_skip = 0
      in_env = 0
    }
    /^[[:space:]]*-[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*:/ { flush_step() }
    {
      trimmed = $0
      sub(/^[[:space:]]*/, "", trimmed)
      indent = index($0, substr(trimmed, 1, 1)) - 1
      is_export = (trimmed !~ /^#/ && trimmed ~ /^export[[:space:]]+SKIP=[^[:cntrl:]]*no-commit-to-branch/)
      is_pre_commit = (trimmed !~ /^#/ && $0 ~ /pre-commit run --all-files --hook-stage pre-commit/)
      if (in_env && trimmed !~ /^($|#)/ && indent <= env_indent) in_env = 0
      if (trimmed == "env:") {
        in_env = 1
        env_indent = indent
      } else if (trimmed ~ /^-?[[:space:]]*env:[[:space:]]*\{[^}]*SKIP[^}]*no-commit-to-branch/) {
        has_step_env = 1
      } else if (in_env && trimmed ~ /^SKIP:[^#]*no-commit-to-branch/) {
        has_step_env = 1
      }
      if (is_export) {
        exported_skip = 1
      } else if (trimmed !~ /^($|#)/ && !is_pre_commit) {
        exported_skip = 0
      }
      if (is_pre_commit) {
        has_pre_commit = 1
        if ($0 !~ /(^[[:space:]]*(-[[:space:]]*)?(run:[[:space:]]*)?|[;&|][[:space:]]*)SKIP=[^[:space:];|&]*no-commit-to-branch[^[:space:];|&]*[[:space:]]+pre-commit run/ && !exported_skip) {
          needs_step_env = 1
        }
      }
    }
    END {
      flush_step()
      exit !unsafe
    }
  ' "$1"
}

for workflow in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [ -f "$workflow" ] || continue
  workflow_pushes_default "$workflow" || continue
  workflow_has_unguarded_precommit "$workflow" || continue
  printf 'LEGACY-CI-BRANCH-GUARD %s\n' "${workflow#"$ROOT/"}"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then exit 0; fi

cat >&2 <<'EOF'
ERROR: protected-branch CI runs the local no-commit-to-branch guard.
Repair the pre-commit step so only protected-branch push runs set
SKIP=no-commit-to-branch. Keep pull-request hygiene and every other hook on.
Then run the project validation command normally. Review this migration; do
not silently rewrite project-owned CI.
EOF
exit 3
