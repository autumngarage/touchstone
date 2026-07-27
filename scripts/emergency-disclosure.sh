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
if ! printf '%s' "$input" | grep -qE '\bgit([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+push\b'; then
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
          segment = segment char
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          segment = segment char
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
        } else if (!single_quote && char == "\\") {
          printf "%s", char
          escaped = 1
        } else if (char == "\047") {
          printf " "
          single_quote = !single_quote
        } else if (single_quote) {
          printf " "
        } else {
          printf "%s", char
        }
      }
    }
  '
}

segment_runs_bypass_push() {
  local segment="$1"
  local executable_text=""
  local protected_push='git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+push([^;&|)]*)--no-verify'

  if printf '%s' "$segment" \
      | grep -qE '^[[:space:]({]*(((if|then|elif|else|while|until|do|!|time([[:space:]]+-[[:alpha:]]+)*)|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+|env|command|exec)[[:space:]]+)*git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)' \
    && printf '%s' "$segment" \
      | grep -qE '(^|[[:space:]'\''"])--no-verify([[:space:]'\''"]|$)'; then
    return 0
  fi

  executable_text="$(printf '%s' "$segment" | without_single_quoted_literals)"

  # Command substitutions and legacy backticks execute even inside double
  # quotes. Single-quoted lookalikes were removed above.
  if printf '%s' "$executable_text" \
    | grep -qE "(^|[^\\\\])\\$\\([^)]*$protected_push|(^|[^\\\\])\`[^\`]*$protected_push"; then
    return 0
  fi

  # Shell -c and eval turn a quoted argument into executable input.
  if printf '%s' "$executable_text" \
      | grep -qE '^[[:space:]({]*(((if|then|elif|else|while|until|do|!|time([[:space:]]+-[[:alpha:]]+)*)|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+|env|command|exec)[[:space:]]+)*(([^[:space:]]*/)?(ba|da|k|z)?sh[[:space:]]+(-[^[:space:]]*[cC][^[:space:]]*|[^[:space:]]+[[:space:]]+-[^[:space:]]*[cC][^[:space:]]*)|eval)([[:space:]]|$)' \
    && printf '%s' "$segment" | grep -qE "$protected_push"; then
    return 0
  fi

  # Function bodies are executable shell code. Conservatively require the
  # emergency path even when invocation is not visible to this parser.
  if printf '%s' "$executable_text" \
      | grep -qE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{' \
    && printf '%s' "$executable_text" | grep -qE "$protected_push"; then
    return 0
  fi

  return 1
}

push_segment=""
preceding_cd=""
while IFS= read -r segment; do
  cd_target="$(printf '%s' "$segment" \
    | grep -oE '^[[:space:]({]*((if|then|elif|else|while|until|do|!)[[:space:]]+)*cd[[:space:]]+[^[:space:]]+' \
    | sed -E 's/^.*cd[[:space:]]+//' || true)"
  if [ -n "$cd_target" ]; then
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
done < <(printf '%s\n' "$command" | shell_segments)

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
  if printf '%s' "$preceding_cd" | grep -qE '^/'; then
    push_cwd="$preceding_cd"
  else
    push_cwd="$push_cwd/$preceding_cd"
  fi
fi

git_c_target=""
while IFS= read -r next_git_c_target; do
  if printf '%s' "$next_git_c_target" | grep -qE '^/' || [ -z "$git_c_target" ]; then
    git_c_target="$next_git_c_target"
  else
    git_c_target="$git_c_target/$next_git_c_target"
  fi
done < <(printf '%s' "$push_segment" \
  | grep -oE '(^|[[:space:]])-C[[:space:]]+[^[:space:]]+' \
  | sed -E 's/^[[:space:]]*-C[[:space:]]+//' || true)
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
