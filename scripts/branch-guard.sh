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

# Parse the structured command before deciding whether it can commit. Raw JSON
# escapes whitespace and line continuations, so it cannot provide a safe
# negative fast path. Skip gracefully if jq is missing
# (downstream projects may not have it) — same pattern as test-shellcheck.sh.
if ! command -v jq >/dev/null 2>&1; then
  echo "branch-guard: jq not installed — hook bypassed (install jq to enable)" >&2
  exit 0
fi

command="$(printf '%s' "$input" | jq -r '(.tool_input.command // "") | gsub("\\\\\n"; "")')"
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

# Remove shell quote and escape fragments before the detection-only precheck.
# The scanner below still receives the original command. This catches shell
# word composition such as `g''it com''mit` without treating prose containing
# the word "commit" as an invocation. Variable-dispatched commands are
# ambiguous and therefore enter the fail-closed path as well.
command_probe="$(printf '%s' "$command" | sed "s/[\\\\'\"]//g")"
if ! printf '%s' "$command_probe" | grep -qE '(^|[^[:alnum:]_])commit([[:space:];&|()]|$)' \
  || { ! printf '%s' "$command_probe" | grep -qE '(^|[^[:alnum:]_])([^[:space:]]*/)?git([[:space:];&|()]|$)' \
    && ! printf '%s' "$command_probe" | grep -qE '\$[{]?[A-Za-z_][A-Za-z0-9_]*[}]?'; }; then
  exit 0
fi

# Split only on shell control operators outside quotes. This is a lexical
# boundary scan only; it never evaluates the command.
shell_segments() {
  awk '
    BEGIN { word_start = 1 }

    function emit() {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", segment)
      if (segment != "") {
        print segment
      }
      segment = ""
    }
    {
      if (heredoc_active) {
        comparison = $0
        if (heredoc_strip_tabs[heredoc_index]) {
          sub(/^\t+/, "", comparison)
        }
        if (comparison == heredoc_delimiter[heredoc_index]) {
          heredoc_index++
          if (heredoc_index > heredoc_count) {
            delete heredoc_delimiter
            delete heredoc_strip_tabs
            heredoc_active = 0
            heredoc_count = 0
            heredoc_index = 0
          }
        }
        next
      }

      line = $0 "\n"
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (comment) {
          if (char == "\n") {
            comment = 0
            emit()
            word_start = 1
          }
        } else if (escaped) {
          if (char != "\n") {
            segment = segment "\\" char
            word_start = 0
          }
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          escaped = 1
        } else if (quote == "") {
          if (arithmetic_depth > 0) {
            if ((char == "$" && substr(line, i + 1, 1) == "(") || ((char == "<" || char == ">") && substr(line, i + 1, 1) == "(") || char == "`") {
              print "__TOUCHSTONE_AMBIGUOUS__"
            }
            segment = segment char
            if (char == "(") {
              arithmetic_depth++
            } else if (char == ")") {
              arithmetic_depth--
            }
            word_start = 0
          } else if (char == "$" && substr(line, i + 1, 2) == "((") {
            segment = segment "$(("
            arithmetic_depth = 2
            word_start = 0
            i += 2
          } else if (char == "(" && substr(line, i + 1, 1) == "(") {
            segment = segment "(("
            arithmetic_depth = 2
            word_start = 0
            i++
          } else if ((char == "$" && substr(line, i + 1, 1) == "(") || ((char == "<" || char == ">") && substr(line, i + 1, 1) == "(") || char == "`") {
            print "__TOUCHSTONE_AMBIGUOUS__"
            segment = segment char
            word_start = 0
          } else if (char == "#" && word_start) {
            comment = 1
          } else if (char == "<" && substr(line, i + 1, 1) == "<" && substr(line, i + 2, 1) != "<") {
            j = i + 2
            strip_tabs = substr(line, j, 1) == "-"
            if (strip_tabs) {
              j++
            }
            while (substr(line, j, 1) ~ /[[:space:]]/) {
              j++
            }
            token = ""
            delimiter_quote = ""
            delimiter_escaped = 0
            delimiter_quoted = 0
            while (j <= length(line)) {
              delimiter_char = substr(line, j, 1)
              if (delimiter_escaped) {
                if (delimiter_char == "\n") {
                  print "__TOUCHSTONE_AMBIGUOUS__"
                  token = ""
                  break
                }
                token = token delimiter_char
                delimiter_escaped = 0
              } else if (delimiter_char == "\\" && delimiter_quote != "\047") {
                delimiter_quoted = 1
                delimiter_escaped = 1
              } else if (delimiter_quote != "") {
                if (delimiter_char == delimiter_quote) {
                  delimiter_quote = ""
                } else {
                  token = token delimiter_char
                }
              } else if (delimiter_char == "\"" || delimiter_char == "\047") {
                delimiter_quoted = 1
                delimiter_quote = delimiter_char
              } else if (delimiter_char ~ /[[:space:];|&()<>]/) {
                break
              } else {
                token = token delimiter_char
              }
              j++
            }
            if (token != "") {
              consumer = segment
              gsub(/^[[:space:]({]+/, "", consumer)
              if (!delimiter_quoted || consumer !~ /^(cat|tee)([[:space:]]|$)/) {
                print "__TOUCHSTONE_AMBIGUOUS__"
              }
              heredoc_count++
              heredoc_delimiter[heredoc_count] = token
              heredoc_strip_tabs[heredoc_count] = strip_tabs
            }
            segment = segment char
            word_start = 0
          } else if (char == "\"" || char == "\047") {
            quote = char
            segment = segment char
            word_start = 0
          } else if (char == ";" || char == "&" || char == "|" || char == "\n") {
            emit()
            word_start = 1
          } else {
            segment = segment char
            if (char ~ /[[:space:]]/ || char == "(" || char == ")") {
              word_start = 1
            } else {
              word_start = 0
            }
          }
        } else {
          if (quote == "\"" && ((char == "$" && substr(line, i + 1, 1) == "(") || ((char == "<" || char == ">") && substr(line, i + 1, 1) == "(") || char == "`")) {
            print "__TOUCHSTONE_AMBIGUOUS__"
          }
          if (char == "\n") {
            segment = segment " "
          } else {
            segment = segment char
          }
          if (char == quote) {
            quote = ""
          }
          word_start = 0
        }
      }
      if (heredoc_count > 0) {
        heredoc_active = 1
        heredoc_index = 1
      }
    }
    END {
      if (escaped) {
        segment = segment "\\"
      }
      emit()
    }
  '
}

has_dynamic_commit_dispatch() {
  local probe="$1"

  printf '%s' "$probe" | grep -qE '(^|[;&|()])[[:space:]]*((env|command)([[:space:]]+[^[:space:]]+)*[[:space:]]+)?\$[{]?[A-Za-z0-9_@*]+[}]?[[:space:]]+commit([[:space:];&|()]|$)' \
    || printf '%s' "$probe" | grep -qE '(^|[;&|()[:space:]])([^[:space:]]*/)?git[[:space:]]+\$[{]?[A-Za-z0-9_@*]+[}]?([[:space:];&|()]|$)' \
    || { printf '%s' "$probe" | grep -qE '=git[[:space:]]+commit([[:space:];&|()]|$)' \
      && printf '%s' "$probe" | grep -qE '(^|[;&|()])[[:space:]]*\$[{]?[A-Za-z0-9_@*]+[}]?([[:space:];&|()]|$)'; }
}

branch_first_compound=false
branch_first_changes_branch=false
branch_first_seen_commit=false
branch_first_has_later_commit=false
branch_first_ambiguous=false
if printf '%s' "$command" | grep -qE '^[[:space:]]*git([[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+(feat|fix|docs|chore|refactor)/[^[:space:];&|]+[[:space:]]*&&'; then
  branch_first_compound=true
  branch_first_post_create="$(printf '%s' "$command" | sed -E 's/^[[:space:]]*git([[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+(feat|fix|docs|chore|refactor)\/[^[:space:];&|]+[[:space:]]*&&[[:space:]]*//')"
  branch_first_probe="$(printf '%s' "$branch_first_post_create" | sed "s/[\\\\'\"]//g")"
  if has_dynamic_commit_dispatch "$branch_first_probe"; then
    branch_first_ambiguous=true
  fi
  if ! branch_first_segments="$(printf '%s\n' "$branch_first_post_create" | shell_segments)"; then
    echo "branch-guard: failed to parse branch-first command; blocking conservatively" >&2
    exit 2
  fi
  while IFS= read -r segment; do
    if [ "$segment" = "__TOUCHSTONE_AMBIGUOUS__" ]; then
      branch_first_ambiguous=true
      continue
    fi
    trimmed="$(printf '%s' "$segment" | sed -E 's/^[[:space:]({]+//')"
    trimmed_probe="$(printf '%s' "$trimmed" | sed "s/[\\\\'\"]//g")"
    if printf '%s' "$trimmed_probe" | grep -qE '^((exec|sudo)([[:space:]]+[^[:space:]]+)*[[:space:]]+)?git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
      if [ "$branch_first_seen_commit" = "true" ]; then
        branch_first_has_later_commit=true
      else
        branch_first_seen_commit=true
      fi
    fi
    if printf '%s' "$trimmed" | grep -qE '^git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+(checkout|switch)([[:space:]]|$)'; then
      branch_first_changes_branch=true
    elif printf '%s' "$trimmed" | grep -qE '^(eval|source|\.|trap|bash|sh|zsh)([[:space:]]|$)' \
      || printf '%s' "$trimmed" | grep -qE '^(python[0-9.]*|ruby|perl|node)([[:space:]].*)?[[:space:]]-[ce]([[:space:]]|$)'; then
      branch_first_ambiguous=true
    fi
  done <<<"$branch_first_segments"
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
command_ambiguous=false
if has_dynamic_commit_dispatch "$command_probe"; then
  command_ambiguous=true
fi
if ! command_segments="$(printf '%s\n' "$command" | shell_segments)"; then
  echo "branch-guard: failed to parse Git command; blocking conservatively" >&2
  exit 2
fi
while IFS= read -r segment; do
  if [ "$segment" = "__TOUCHSTONE_AMBIGUOUS__" ]; then
    command_ambiguous=true
    continue
  fi
  trimmed="$(printf '%s' "$segment" | sed -E 's/^[[:space:]({]+//')"
  trimmed_probe="$(printf '%s' "$trimmed" | sed "s/[\\\\'\"]//g")"
  if printf '%s' "$trimmed_probe" | grep -qE '^((if|then|elif|while|until|do|!|time([[:space:]]+-p)?|env([[:space:]]+[^[:space:]]+)*|command|(exec|sudo)([[:space:]]+[^[:space:]]+)*)[[:space:]]+)*([^[:space:]]*/)?git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
    commit_segment="$trimmed_probe"
    break
  fi
  cd_target="$(printf '%s' "$trimmed" | grep -oE '^cd[[:space:]]+[^[:space:]]+' | sed -E 's/^cd[[:space:]]+//' || true)"
  if [ -n "$cd_target" ]; then
    target_cwd_from_cd="$cd_target"
  fi
done <<<"$command_segments"
if [ -z "$commit_segment" ] && [ "$command_ambiguous" = "false" ]; then
  exit 0
fi
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
  && [ "$branch_first_seen_commit" = "true" ] \
  && [ "$branch_first_ambiguous" = "false" ] \
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
