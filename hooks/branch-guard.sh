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

# Fast path — cheaply skip calls that cannot be a commit, WITHOUT trying to
# match the command's shape.
#
# Matching shape against the raw payload is unsound, because the payload is
# JSON and the shell text inside it is encoded (issue #634):
#
#   - a newline is the two characters \ and n, so `x=1\ngit commit` puts a
#     word character immediately before `git` and `\bgit` finds no boundary;
#   - a tab is \ and t, with the same effect;
#   - a line continuation puts backslashes between `git` and `commit`, which
#     no [[:space:]]+ will cross;
#   - an embedded quote is \ and ", so `[^"]*` stops dead at the first one,
#     which is why `eval "git commit"` and `sh -c "git commit"` slipped past.
#
# Seven distinct spellings of a real commit bypassed the old shape regex and
# exited 0 on main. The decision belongs to the structured parse below, which
# sees the decoded command; this test exists only to avoid the jq/git cost on
# the overwhelming majority of calls. It is therefore deliberately
# over-inclusive: it may admit non-commits, but it must never reject a commit.
#
# Three ways a real commit can reach the shell, so three ways through here:
#
#   1. `commit` appears literally — the ordinary case. JSON encodes ASCII
#      letters as themselves, so the substring survives encoding.
#   2. A \u escape spells a letter of it (`commit`).
#   3. A line continuation splits a token: `git com\<newline>mit` executes as
#      `git commit`, and neither `commit` nor `\u` appears in the payload.
#      Any continuation needs a literal backslash, which JSON encodes as two,
#      so an escaped backslash anywhere means "might be a split token".
if ! printf '%s' "$input" | grep -qE 'commit|\\u|\\\\'; then
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

# Remove backslash-newline continuations before any matching. `git \<newline>
# commit -m x` is ONE command, but every check below is line-oriented (grep
# scans line by line; the segment walker reads line by line), so without this
# the two halves never meet and a real commit reads as neither (issue #634).
#
# REMOVED, not replaced with a space: that is what bash does. Substituting a
# space rejoins `git \<newline>commit` correctly but turns `g\<newline>it
# commit` into `g it commit`, which no longer matches — the split-token case
# would still walk past the guard (PR #706 review).
command="${command//\\$'\n'/}"
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
commit_context_ambiguous=false
while IFS= read -r segment; do
  trimmed="$(printf '%s' "$segment" | sed -E 's/^[[:space:]]+//')"
  if printf '%s' "$trimmed" \
    | grep -qE '^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*(env([[:space:]]+-[^[:space:]]+)*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)*[[:space:]]+)?git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
    commit_segment="$trimmed"
    if printf '%s' "$trimmed" \
      | grep -qE '(^|[[:space:]])GIT_(DIR|WORK_TREE|NAMESPACE|OBJECT_DIRECTORY|COMMON_DIR)='; then
      commit_context_ambiguous=true
    fi
    break
  fi
  cd_target="$(printf '%s' "$trimmed" | grep -oE '^cd[[:space:]]+[^[:space:]]+' | sed -E 's/^cd[[:space:]]+//' || true)"
  if [ -n "$cd_target" ]; then
    target_cwd_from_cd="$cd_target"
  fi
done < <(printf '%s\n' "$command" | tr '&;|' '\n')
if [ -n "$commit_segment" ] && [ "$commit_context_ambiguous" = false ]; then
  target_cwd_from_C="$(printf '%s' "$commit_segment" | grep -oE '\-C[[:space:]]+[^[:space:]]+' | sed -E 's/^-C[[:space:]]+//' | tail -1 || true)"
fi

# `-C` is the more explicit form; prefer it. Fall back to the last `cd`
# target seen before the commit.
target_cwd=""
if [ "$commit_context_ambiguous" = false ]; then
  target_cwd="${target_cwd_from_C:-$target_cwd_from_cd}"
fi

if [ "$commit_context_ambiguous" = true ]; then
  echo "branch-guard: Git context environment overrides are not allowed for guarded commits." >&2
  exit 2
fi

if [ -n "$target_cwd" ]; then
  if [ -n "$cwd" ] && [ -d "$cwd/$target_cwd" ]; then
    cwd="$cwd/$target_cwd"
  elif [ -d "$target_cwd" ]; then
    cwd="$target_cwd"
  fi
fi

# A heredoc body is DATA, not commands, but it arrives as ordinary lines and
# the segment walker above cannot tell the difference. Worse, continuation
# removal happens before the walk, so a quoted heredoc containing
# `c\<newline>d /feature` — text bash would pass through untouched — becomes a
# literal `cd /feature` line that the walker adopts as the commit's target
# worktree. A real `git commit` later in the same command would then be
# checked against that worktree instead of the one it actually runs in
# (PR #706 review).
#
# Redirection is the only thing that can WEAKEN this guard, so it is the only
# thing that has to be certain. When a heredoc is present, drop the redirect
# and check the real working directory. Cost is over-blocking a worktree
# commit that also carries a heredoc; the fix for that is two tool calls.
case "$command" in
  *'<<'*)
    if [ -n "$target_cwd" ]; then
      cwd="${tool_workdir:-$session_cwd}"
      if [ -n "$tool_workdir" ] && [ -n "$session_cwd" ]; then
        case "$tool_workdir" in
          /*) cwd="$tool_workdir" ;;
          *) cwd="$session_cwd/$tool_workdir" ;;
        esac
      fi
    fi
    ;;
esac

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
