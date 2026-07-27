#!/usr/bin/env bash
#
# hooks/emergency-disclosure.sh — Claude Code PreToolUse hook that blocks
# `git push --no-verify` invocations unless TOUCHSTONE_EMERGENCY=1 is set
# in the environment, in which case it logs the bypass for the next PR
# to disclose. Wired via .claude/settings.json from templates/.
#
# --no-verify bypasses pre-push hooks (Conductor review, default-branch
# checks). Routine pushes should not bypass these — the emergency path
# is documented in principles/git-workflow.md and convention requires
# the next PR to include an "Emergency-bypass disclosure" section.
#
# Override path: set TOUCHSTONE_EMERGENCY=1 for the session. The bypass
# is appended to .touchstone/emergency-bypass.log so a follow-up PR
# template (or a future bin/touchstone status check) can surface it.
#
# Hook protocol:
#   stdin   — JSON describing the tool call
#   exit 0  — allow the tool call
#   exit 2  — block; stderr is shown to the user and surfaced to Claude
#
set -euo pipefail

input="$(cat)"

# Fast path — avoid jq for calls that cannot contain the protected flag.
if ! printf '%s' "$input" | grep -q -- '--no-verify'; then
  exit 0
fi
if ! printf '%s' "$input" | grep -qE 'git([^[:alnum:]_]|$)'; then
  exit 0
fi
if ! printf '%s' "$input" | grep -qE 'push([^[:alnum:]_]|$)'; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "emergency-disclosure: jq not installed — hook bypassed (install jq to enable)" >&2
  exit 0
fi

command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
tool_workdir="$(printf '%s' "$input" | jq -r '.tool_input.workdir // ""')"

# Split only on shell control operators outside quotes. The authorization
# boundary is an executable command segment, not arbitrary prose inside an
# argument such as an issue body.
shell_segments() {
  awk '
    function emit() {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", segment)
      if (segment != "") {
        print segment
      }
      segment = ""
    }
    {
      line = $0 "\n"
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (escaped) {
          if (char != "\n") {
            segment = segment "\\" char
          }
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          escaped = 1
        } else if (quote == "") {
          if (char == "\"" || char == "\047") {
            quote = char
            segment = segment char
          } else if (char == ";" || char == "&" || char == "|" || char == "\n") {
            emit()
          } else {
            segment = segment char
          }
        } else {
          segment = segment char
          if (char == quote) {
            quote = ""
          }
        }
      }
    }
    END { emit() }
  '
}

# Preserve double-quoted text so executable command substitutions remain
# visible, while masking single-quoted literals that the shell never executes.
without_single_quoted_literals() {
  awk '
    {
      line = $0 "\n"
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (escaped) {
          printf "%s", char
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          printf "%s", char
          escaped = 1
        } else if (quote == "") {
          if (char == "\047") {
            quote = char
            printf " "
          } else {
            if (char == "\"") {
              quote = char
            }
            printf "%s", char
          }
        } else if (quote == "\047") {
          printf " "
          if (char == quote) {
            quote = ""
          }
        } else {
          printf "%s", char
          if (char == quote) {
            quote = ""
          }
        }
      }
    }
  '
}

without_heredoc_bodies() {
  awk '
    {
      line = $0
      if (heredoc_delimiter != "") {
        comparison = line
        if (strip_tabs) {
          sub(/^\t+/, "", comparison)
        }
        if (comparison == heredoc_delimiter) {
          heredoc_delimiter = ""
          strip_tabs = 0
        }
        next
      }

      print line
      opener = line
      if (match(opener, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        token = substr(opener, RSTART, RLENGTH)
        strip_tabs = token ~ /^<<-/
        sub(/^<<-?[[:space:]]*/, "", token)
        gsub(/["\047]/, "", token)
        heredoc_delimiter = token
      }
    }
  '
}

shell_words() {
  awk '
    function emit() {
      if (token_started) {
        print token
      }
      token = ""
      token_started = 0
    }
    {
      line = $0 "\n"
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (escaped) {
          if (char != "\n") {
            token = token char
            token_started = 1
          }
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          escaped = 1
          token_started = 1
        } else if (quote == "") {
          if (char == "\"" || char == "\047") {
            quote = char
            token_started = 1
          } else if (char ~ /[[:space:]]/) {
            emit()
          } else {
            token = token char
            token_started = 1
          }
        } else if (char == quote) {
          quote = ""
        } else {
          token = token char
          token_started = 1
        }
      }
    }
    END { emit() }
  '
}

segment_has_bypass_words() {
  local segment="$1"
  local word=""
  local seen_git=false
  local seen_push=false

  while IFS= read -r word; do
    if [ "$seen_git" = "false" ]; then
      case "$word" in
        git | */git)
          seen_git=true
          ;;
      esac
    elif [ "$seen_push" = "false" ] && [ "$word" = "push" ]; then
      seen_push=true
    elif [ "$seen_push" = "true" ] && [ "$word" = "--no-verify" ]; then
      return 0
    fi
  done < <(printf '%s' "$segment" | shell_words)

  return 1
}

segment_has_git_push_words() {
  local segment="$1"
  local word=""
  local seen_git=false

  while IFS= read -r word; do
    if [ "$seen_git" = "false" ]; then
      case "$word" in
        git | */git)
          seen_git=true
          ;;
      esac
    elif [ "$word" = "push" ]; then
      return 0
    fi
  done < <(printf '%s' "$segment" | shell_words)

  return 1
}

segment_has_shell_evaluator() {
  local segment="$1"
  local word=""
  local seen_shell=false

  while IFS= read -r word; do
    case "$word" in
      eval)
        return 0
        ;;
      sh | */sh | bash | */bash | dash | */dash | ksh | */ksh | zsh | */zsh)
        seen_shell=true
        ;;
      -*c*)
        if [ "$seen_shell" = "true" ]; then
          return 0
        fi
        ;;
    esac
  done < <(printf '%s' "$segment" | shell_words)

  return 1
}

segment_cd_target() {
  local segment="$1"
  local token=""
  local normalized=""
  local expect_target=false

  while IFS= read -r token; do
    if [ "$expect_target" = "true" ]; then
      printf '%s' "$token"
      return
    fi
    normalized="$(printf '%s' "$token" | sed -E 's/^[({]+//')"
    case "$normalized" in
      if | then | elif | else | while | until | do | ! | "")
        ;;
      cd)
        expect_target=true
        ;;
      *)
        return
        ;;
    esac
  done < <(printf '%s' "$segment" | shell_words)
}

segment_runs_bypass_push() {
  local segment="$1"
  local protected_push='git([^;&|)]*)[[:space:]]+push([^;&|)]*)--no-verify'

  if [ "$command_nested_protected" = "true" ]; then
    push_context="nested"
    return 0
  fi

  if segment_has_bypass_words "$segment"; then
    if [ "$command_has_substitution" = "true" ] || printf '%s' "$segment" \
      | grep -qE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{'; then
      push_context="nested"
    else
      push_context="direct"
    fi
    return 0
  fi

  # The protected flag may reach push through variable expansion. If the tool
  # call contains the literal anywhere and executes a push, require disclosure
  # rather than trying to evaluate shell data flow.
  if segment_has_git_push_words "$segment" \
    && printf '%s' "$command" | grep -q -- '--no-verify'; then
    if [ "$command_has_substitution" = "true" ]; then
      push_context="nested"
    else
      push_context="direct"
    fi
    return 0
  fi

  # Shell -c and eval turn a quoted argument into executable input, including
  # when an execution wrapper appears before the evaluator.
  if segment_has_shell_evaluator "$segment" \
    && printf '%s' "$segment" | grep -qE "$protected_push"; then
    push_context="nested"
    return 0
  fi

  return 1
}

push_segment=""
push_context=""
preceding_cd=""
ambiguous_cd_scope=false
command_has_substitution=false
command_nested_protected=false
command_sets_cdpath=false
cd_chain_proven=false
command_executable_text="$(printf '%s' "$command" | without_single_quoted_literals)"
if printf '%s' "$command_executable_text" \
  | grep -qE '(^|[;&|()[:space:]])(export[[:space:]]+)?CDPATH='; then
  command_sets_cdpath=true
fi
if printf '%s' "$command_executable_text" | grep -qE '\(' \
  && printf '%s' "$command_executable_text" \
    | grep -qE '(^|[;&|()[:space:]])cd[[:space:]]+'; then
  ambiguous_cd_scope=true
fi
if printf '%s' "$command_executable_text" \
  | tr '\n' ' ' \
  | grep -qE 'cd[[:space:]]+.*&&.*git.*push'; then
  cd_chain_proven=true
fi
if printf '%s' "$command_executable_text" \
  | grep -qE '(^|[^\\])\$\(|(^|[^\\])`'; then
  command_has_substitution=true
  if printf '%s' "$command_executable_text" \
    | tr '\n' ' ' \
    | grep -qE 'git.*push.*--no-verify'; then
    command_nested_protected=true
  fi
fi
if printf '%s' "$command_executable_text" \
    | grep -qE '(^|[^\\])\$[{A-Za-z_]' \
  && printf '%s' "$command_executable_text" | grep -qE 'git([^[:alnum:]_]|$)' \
  && printf '%s' "$command_executable_text" | grep -qE 'push([^[:alnum:]_]|$)' \
  && printf '%s' "$command_executable_text" | grep -q -- '--no-verify'; then
  command_nested_protected=true
fi
while IFS= read -r segment; do
  cd_target="$(segment_cd_target "$segment")"
  if [ -n "$cd_target" ]; then
    if printf '%s' "$segment" | grep -qE '^[[:space:]]*\('; then
      ambiguous_cd_scope=true
    fi
    if printf '%s' "$cd_target" | grep -qE '^/' || [ -z "$preceding_cd" ]; then
      preceding_cd="$cd_target"
    else
      preceding_cd="$preceding_cd/$cd_target"
    fi
  fi

  if segment_runs_bypass_push "$segment"; then
    push_segment="$segment"
    break
  fi
done < <(printf '%s\n' "$command" | without_heredoc_bodies | shell_segments)

if [ -z "$push_segment" ]; then
  exit 0
fi

if [ "${TOUCHSTONE_EMERGENCY:-0}" != "1" ]; then
  cat >&2 <<EOF
==> Blocked by Touchstone emergency-disclosure: 'git push --no-verify'

  --no-verify bypasses pre-push hooks (Conductor review, default-branch
  checks). Routine pushes should not bypass these.

  This is the documented emergency path. To use it:
    1. Set TOUCHSTONE_EMERGENCY=1 in the environment for this push.
    2. The next PR you open MUST include an "Emergency-bypass disclosure"
       section explaining what was bypassed and why.

  See principles/git-workflow.md ("Emergency path").
EOF
  exit 2
fi

if [ "$push_context" != "direct" ] || [ "$ambiguous_cd_scope" = "true" ]; then
  echo "emergency-disclosure: cannot safely resolve nested or subshell push context; bypass blocked" >&2
  exit 2
fi

# The tool workdir is the command execution context. Resolve a relative
# workdir from the driver session cwd, matching the command runner.
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
if [ -z "$cwd" ]; then
  cwd="$(pwd)"
fi
if [ ! -d "$cwd" ]; then
  echo "emergency-disclosure: cannot record emergency bypass: execution workdir does not exist: $cwd" >&2
  exit 2
fi
cwd="$(cd "$cwd" && pwd -P)"

push_cwd="$cwd"
if [ -n "$preceding_cd" ]; then
  if [ "$cd_chain_proven" != "true" ]; then
    echo "emergency-disclosure: cannot prove preceding cd gates the push; bypass blocked" >&2
    exit 2
  fi
  if printf '%s' "$preceding_cd" | grep -qE '^/'; then
    push_cwd="$preceding_cd"
  else
    if [ -n "${CDPATH:-}" ] || [ "$command_sets_cdpath" = "true" ]; then
      echo "emergency-disclosure: cannot safely resolve relative cd with CDPATH; bypass blocked" >&2
      exit 2
    fi
    push_cwd="$push_cwd/$preceding_cd"
  fi
fi

git_c_target=""
seen_git=false
expect_git_c_target=false
ambiguous_git_context=false
while IFS= read -r git_word; do
  if [ "$expect_git_c_target" = "true" ]; then
    if printf '%s' "$git_word" | grep -qE '^/' || [ -z "$git_c_target" ]; then
      git_c_target="$git_word"
    else
      git_c_target="$git_c_target/$git_word"
    fi
    expect_git_c_target=false
  elif [ "$seen_git" = "false" ]; then
    case "$git_word" in
      git | */git)
        seen_git=true
        ;;
    esac
  elif [ "$seen_git" = "true" ] && [ "$git_word" = "-C" ]; then
    expect_git_c_target=true
  elif [ "$seen_git" = "true" ] && [ "$git_word" = "push" ]; then
    break
  elif [ "$seen_git" = "true" ]; then
    case "$git_word" in
      --no-pager | --paginate | -P | -p)
        ;;
      -*)
        ambiguous_git_context=true
        ;;
    esac
  fi
done < <(printf '%s' "$push_segment" | shell_words)
if [ "$expect_git_c_target" = "true" ] || [ "$ambiguous_git_context" = "true" ]; then
  echo "emergency-disclosure: cannot safely resolve Git global option context; bypass blocked" >&2
  exit 2
fi
if [ -n "$git_c_target" ]; then
  if printf '%s' "$git_c_target" | grep -qE '^/'; then
    push_cwd="$git_c_target"
  else
    push_cwd="$push_cwd/$git_c_target"
  fi
fi

audit_repo="$(git -C "$push_cwd" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$audit_repo" ]; then
  echo "emergency-disclosure: cannot resolve pushed repository from '$push_cwd'; bypass blocked" >&2
  exit 2
fi

# Audit persistence is part of emergency authorization. Never allow an
# emergency bypass when its required recovery evidence cannot be recorded.
log_dir="$audit_repo/.touchstone"
log_file="$log_dir/emergency-bypass.log"
if ! mkdir -p "$log_dir"; then
  echo "emergency-disclosure: cannot create emergency audit directory: $log_dir" >&2
  exit 2
fi
if ! printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$push_segment" >>"$log_file"; then
  echo "emergency-disclosure: cannot append emergency audit log: $log_file" >&2
  exit 2
fi

echo "emergency-disclosure: TOUCHSTONE_EMERGENCY=1 — push allowed; logged to .touchstone/emergency-bypass.log for next-PR disclosure" >&2
exit 0
