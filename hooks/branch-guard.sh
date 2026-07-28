#!/usr/bin/env bash
#
# hooks/branch-guard.sh — Claude Code PreToolUse hook that blocks
# `git commit` invocations when the current branch is the project's
# default branch (main/master). Wired via .claude/settings.json shipped
# in templates/claude-settings.json.
#
# This is the deterministic enforcement layer for the never-commit-on-
# default-branch rule documented in principles/git-workflow.md. The
# .pre-commit-config.yaml hook (no-commit-to-branch) and GitHub branch
# protection are downstream defenses; this hook fires earlier — at the
# Claude tool boundary — and prevents the commit attempt rather than
# rolling it back.
#
# Hook protocol:
#   stdin   — JSON describing the tool call
#             { "tool_name": "Bash",
#               "tool_input": { "command": "...", "workdir": "..." },
#               "cwd": "..." }
#   exit 0  — allow the tool call
#   exit 2  — block; stderr is shown to the user and surfaced to Claude
#
# Override (documented emergency path): set TOUCHSTONE_EMERGENCY=1 in the
# environment for the session. The next PR must include an "Emergency-
# bypass disclosure" section. See principles/git-workflow.md.
#
set -euo pipefail

# Read stdin once; reuse for both fast-path and full parse.
input="$(cat)"

# Fast path — bail on non-git-commit calls without the jq/git overhead.
# Matches `git commit` with optional `-c key=value` / `-C <path>` flags
# ahead of the subcommand; explicitly NOT matching `commit-tree`.
if ! printf '%s' "$input" | grep -qE '"command"[[:space:]]*:[[:space:]]*"[^"]*\bgit([[:space:]]+-c[[:space:]]+[^[:space:]]+|[[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

# Past the fast path: we need to parse JSON. Skip gracefully if jq missing
# (downstream projects may not have it) — same pattern as test-shellcheck.sh.
if ! command -v jq >/dev/null 2>&1; then
  echo "branch-guard: jq not installed — hook bypassed (install jq to enable)" >&2
  exit 0
fi

command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
tool_workdir="$(printf '%s' "$input" | jq -r '.tool_input.workdir // ""')"
cwd="$session_cwd"
if [ -n "$tool_workdir" ]; then
  if printf '%s' "$tool_workdir" | grep -qE '^/'; then
    cwd="$tool_workdir"
  elif [ -n "$session_cwd" ]; then
    cwd="$session_cwd/$tool_workdir"
  else
    cwd="$tool_workdir"
  fi
fi

# Re-verify with the parsed command (the fast-path regex is a heuristic
# over raw JSON; final decision uses the structured value). The trailing
# class is explicit — `\b` would match `commit-tree` because `-` is a
# non-word char; we want `commit` followed by whitespace or end-of-string
# only, so plumbing subcommands like `git commit-tree` pass through.
if ! printf '%s' "$command" | grep -qE '\bgit([[:space:]]+-c[[:space:]]+[^[:space:]]+|[[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

branch_first_compound=false
branch_first_changes_branch=false
branch_first_seen_commit=false
branch_first_has_later_commit=false
if printf '%s' "$command" | grep -qE '^[[:space:]]*git([[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+(feat|fix|docs|chore|refactor)/[^[:space:];&|]+[[:space:]]*&&'; then
  branch_first_compound=true
  branch_first_post_create="$(printf '%s' "$command" | sed -E 's/^[[:space:]]*git([[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+(feat|fix|docs|chore|refactor)\/[^[:space:];&|]+[[:space:]]*&&[[:space:]]*//')"
  while IFS= read -r segment; do
    trimmed="$(printf '%s' "$segment" | sed -E 's/^[[:space:]]+//')"
    if printf '%s' "$trimmed" | grep -qE '^git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
      if [ "$branch_first_seen_commit" = "true" ]; then
        branch_first_has_later_commit=true
      else
        branch_first_seen_commit=true
      fi
    fi
    if printf '%s' "$trimmed" | grep -qE '^git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout|switch)([[:space:]]|$)'; then
      branch_first_changes_branch=true
    fi
  done < <(printf '%s\n' "$branch_first_post_create" | tr '&;|' '\n')
fi

# Worktree-aware: when commit targets a different repo via `-C <path>` OR
# the operator wrote `cd <path> && git commit`, check that branch instead.
# The previous version saw `main` as the current branch even when the commit
# was being directed at a feature worktree, blocking legitimate work.
# Lowercase `-c` (the config-override flag) does not change directory
# and so does NOT trigger this override.
target_cwd_from_C=""

# `cd <path> && git commit` shape: walk shell-statement boundaries (&&, ||,
# ;) and remember the last `cd <path>` from segments BEFORE the segment
# that runs `git commit`. cds AFTER the commit (e.g. `git commit; cd
# elsewhere`) don't affect the commit's cwd and must be ignored — otherwise
# they'd silently bypass the guard on main.
target_cwd_from_cd=""
commit_segment=""
while IFS= read -r segment; do
  trimmed="$(printf '%s' "$segment" | sed -E 's/^[[:space:]]+//')"
  if printf '%s' "$trimmed" | grep -qE '^git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
    commit_segment="$trimmed"
    break
  fi
  cd_target="$(printf '%s' "$trimmed" | grep -oE '^cd[[:space:]]+[^[:space:]]+' | sed -E 's/^cd[[:space:]]+//' || true)"
  if [ -n "$cd_target" ]; then
    target_cwd_from_cd="$cd_target"
  fi
done < <(printf '%s\n' "$command" | tr '&;|' '\n')
if [ -n "$commit_segment" ]; then
  target_cwd_from_C="$(printf '%s' "$commit_segment" | grep -oE '\-C[[:space:]]+[^[:space:]]+' | sed -E 's/^-C[[:space:]]+//' | tail -1 || true)"
fi

# `-C` is the more explicit form; prefer it. Fall back to the last `cd`
# target seen before the commit.
target_cwd="${target_cwd_from_C:-$target_cwd_from_cd}"

# A compound that starts by creating a standard Touchstone feature branch with
# `&&` will run a same-cwd later commit after leaving the default branch. Allow
# that exact remedy shape instead of blocking before checkout can happen. Do
# not allow a later commit or branch change: subsequent control flow can return
# to the default branch before committing. If the commit targets another cwd via
# `git -C` or `cd`, keep checking that target.
if [ "$branch_first_compound" = "true" ] \
  && [ "$branch_first_changes_branch" = "false" ] \
  && [ "$branch_first_has_later_commit" = "false" ] \
  && [ -z "$target_cwd" ]; then
  exit 0
fi

if [ -n "$target_cwd" ]; then
  if [ -n "$cwd" ] && [ -d "$cwd/$target_cwd" ]; then
    cwd="$cwd/$target_cwd"
  elif [ -d "$target_cwd" ]; then
    cwd="$target_cwd"
  fi
fi

# Determine current branch in the project Claude is operating in.
branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
else
  branch="$(git branch --show-current 2>/dev/null || true)"
fi

if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  if [ "${TOUCHSTONE_EMERGENCY:-0}" = "1" ]; then
    echo "branch-guard: TOUCHSTONE_EMERGENCY=1 — allowing commit on '$branch' (next PR must disclose)" >&2
    exit 0
  fi

  cat >&2 <<EOF
==> Blocked by Touchstone branch-guard: on '$branch'

  This project doesn't allow direct commits to '$branch'. Branch first:
    git checkout -b feat/<short-description>
    git checkout -b fix/<short-description>
    git checkout -b docs/<short-description>
    git checkout -b chore/<short-description>
    git checkout -b refactor/<short-description>

  See principles/git-workflow.md for the full lifecycle.

  Override (emergencies only): set TOUCHSTONE_EMERGENCY=1 and re-run.
EOF
  exit 2
fi

exit 0
