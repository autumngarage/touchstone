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

# Avoid jq only when neither a literal bypass fragment nor shell expansion can
# produce the protected flag. Expanded commands must take the conservative
# parser path because separate values can assemble the flag at runtime.
if ! printf '%s' "$input" | grep -q -- '--no-verify' \
  && ! printf '%s' "$input" | grep -q -- '--no-' \
  && ! printf '%s' "$input" | grep -qE '(\\|\$|`|git)'; then
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "emergency-disclosure: jq not installed — hook bypassed (install jq to enable)" >&2
  exit 0
fi

command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
tool_workdir="$(printf '%s' "$input" | jq -r '.tool_input.workdir // ""')"

# Remove comments using shell token boundaries while preserving newlines, so a
# later physical line remains executable input. A # inside a word or quotes is
# data, not a comment opener.
without_shell_comments() {
  awk '
    {
      line = $0 "\n"
      comment = 0
      previous = ""
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (comment) {
          if (char == "\n") {
            printf "\n"
            comment = 0
          }
        } else if (escaped) {
          printf "%s", char
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          printf "%s", char
          escaped = 1
        } else if (quote == "") {
          if (char == "\"" || char == "\047") {
            quote = char
            printf "%s", char
          } else if (char == "#" && (previous == "" || previous ~ /[[:space:];&|()]/)) {
            comment = 1
          } else {
            printf "%s", char
          }
        } else {
          printf "%s", char
          if (char == quote) {
            quote = ""
          }
        }
        previous = char
      }
    }
  '
}

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
          } else if (char == "(") {
            group_depth++
            segment = segment char
          } else if (char == ")" && group_depth > 0) {
            group_depth--
            segment = segment char
          } else if (char == "{") {
            brace_depth++
            segment = segment char
          } else if (char == "}" && brace_depth > 0) {
            brace_depth--
            segment = segment char
          } else if (group_depth == 0 && brace_depth == 0 && (char == ";" || char == "&" || char == "|" || char == "\n")) {
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

# Quoted heredocs are literal. Unquoted heredocs expand command substitutions,
# so retain only those executable regions and mask the surrounding prose.
without_heredoc_bodies() {
  awk '
    function print_executable_substitutions(line, output, i, char, next_char) {
      output = ""
      body_escaped = 0
      substitution_escaped = 0
      backtick_escaped = 0
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        next_char = substr(line, i + 1, 1)
        if (substitution_depth > 0) {
          output = output char
          if (substitution_escaped) {
            substitution_escaped = 0
          } else if (char == "\\" && substitution_quote != "\047") {
            substitution_escaped = 1
          } else if (substitution_quote != "") {
            if (char == substitution_quote) {
              substitution_quote = ""
            }
          } else if (char == "\"" || char == "\047") {
            substitution_quote = char
          } else if (char == "(") {
            substitution_depth++
          } else if (char == ")") {
            substitution_depth--
          }
        } else if (backtick_substitution) {
          output = output char
          if (backtick_escaped) {
            backtick_escaped = 0
          } else if (char == "\\") {
            backtick_escaped = 1
          } else if (char == "`") {
            backtick_substitution = 0
          }
        } else if (body_escaped) {
          output = output " "
          body_escaped = 0
        } else if (char == "\\") {
          output = output " "
          body_escaped = 1
        } else if (char == "$" && next_char == "(") {
          output = output "$("
          substitution_depth = 1
          i++
        } else if (char == "`") {
          output = output char
          backtick_substitution = 1
        } else {
          output = output " "
        }
      }
      print output
    }
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
          heredoc_expands = 0
          substitution_depth = 0
          substitution_quote = ""
          backtick_substitution = 0
        } else if (heredoc_expands) {
          print_executable_substitutions(line)
        }
        next
      }

      print line
      quote = ""
      escaped = 0
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (escaped) {
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          escaped = 1
        } else if (quote != "") {
          if (char == quote) {
            quote = ""
          }
        } else if (arithmetic_depth > 0) {
          if (char == "(") {
            arithmetic_depth++
          } else if (char == ")") {
            arithmetic_depth--
          }
        } else if (char == "$" && substr(line, i + 1, 2) == "((") {
          arithmetic_depth = 2
          i += 2
        } else if (char == "(" && substr(line, i + 1, 1) == "(") {
          arithmetic_depth = 2
          i++
        } else if (char == "\"" || char == "\047") {
          quote = char
        } else if (char == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];|&()]/)) {
          break
        } else if (char == "<" && substr(line, i + 1, 1) == "<") {
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
            heredoc_delimiter = token
            heredoc_expands = !delimiter_quoted
          }
          break
        }
      }
    }
  '
}

# Heredoc bodies are data by default, but become shell code when redirected to
# a shell interpreter or sourced from standard input.
shell_stdin_heredoc_payloads() {
  awk '
    {
      line = $0
      if (delimiter != "") {
        comparison = line
        if (strip_tabs) {
          sub(/^\t+/, "", comparison)
        }
        if (comparison == delimiter) {
          delimiter = ""
          executes = 0
          strip_tabs = 0
        } else if (executes) {
          print line
        }
        next
      }

      quote = ""
      escaped = 0
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (escaped) {
          escaped = 0
        } else if (char == "\\" && quote != "\047") {
          escaped = 1
        } else if (quote != "") {
          if (char == quote) {
            quote = ""
          }
        } else if (char == "\"" || char == "\047") {
          quote = char
        } else if (char == "<" && substr(line, i + 1, 1) == "<" && substr(line, i + 2, 1) != "<") {
          header = substr(line, 1, i - 1)
          executes = header ~ /(^|[;&|()])[[:space:]]*([^[:space:]]*\/)?(sh|bash|dash|ksh|zsh)([[:space:]]|$)/ \
            || header ~ /(^|[;&|()])[[:space:]]*(source|\.)[[:space:]]+\/dev\/stdin([[:space:]]|$)/
          j = i + 2
          strip_tabs = substr(line, j, 1) == "-"
          if (strip_tabs) {
            j++
          }
          while (substr(line, j, 1) ~ /[[:space:]]/) {
            j++
          }
          delimiter = ""
          delimiter_quote = ""
          while (j <= length(line)) {
            delimiter_char = substr(line, j, 1)
            if (delimiter_quote != "") {
              if (delimiter_char == delimiter_quote) {
                delimiter_quote = ""
              } else {
                delimiter = delimiter delimiter_char
              }
            } else if (delimiter_char == "\"" || delimiter_char == "\047") {
              delimiter_quote = delimiter_char
            } else if (delimiter_char == "\\") {
              j++
              delimiter = delimiter substr(line, j, 1)
            } else if (delimiter_char ~ /[[:space:];|&()<>]/) {
              break
            } else {
              delimiter = delimiter delimiter_char
            }
            j++
          }
          break
        }
      }
    }
  '
}

shell_words() {
  awk '
    function emit() {
      if (token_started) {
        if (token ~ /\{[^}]*([,]|\.\.)[^}]*\}/) {
          token_shell_expansion = 1
        }
        if (token_shell_expansion) {
          print "__touchstone_shell_expanded__:" token
        } else if (shell_composed_quote) {
          print "__touchstone_shell_composed__:" token
        } else {
          print token
        }
      }
      token = ""
      token_started = 0
      shell_composed_quote = 0
      token_quoted = 0
      token_shell_expansion = 0
    }
    function emit_redirection() {
      if (token_started && !(token ~ /^[0-9]+$/ && !token_quoted)) {
        emit()
      } else {
        token = ""
        token_started = 0
        shell_composed_quote = 0
        token_quoted = 0
        token_shell_expansion = 0
      }
      print "__touchstone_redirection__"
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
          if (char == "$" && (substr(line, i + 1, 1) == "\"" || substr(line, i + 1, 1) == "\047")) {
            quote = substr(line, i + 1, 1)
            shell_composed_quote = 1
            token_quoted = 1
            token_started = 1
            i++
          } else if (char == "\"" || char == "\047") {
            quote = char
            token_quoted = 1
            token_started = 1
          } else if (char == "<" || char == ">") {
            emit_redirection()
            while (substr(line, i + 1, 1) ~ /[<>&|]/) {
              i++
            }
          } else if (char == "(" || char == ")") {
            emit()
            print char
          } else if (char ~ /[[:space:]]/) {
            emit()
          } else {
            token = token char
            token_started = 1
            if (char == "[" || char == "]" || char == "*" || char == "?") {
              token_shell_expansion = 1
            }
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

word_may_expand_to() {
  local word="$1"
  local expected="$2"
  local static=""

  case "$word" in
    *'$'* | *'`'*) ;;
    *) return 1 ;;
  esac

  if printf '%s' "$word" | grep -qE '\$(\$|[0-9]+|[-*@#?!])'; then
    return 0
  fi

  static="$(printf '%s' "$word" \
    | sed -E 's/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$\([^)]*\)|`[^`]*`//g')"
  static="${static##*/}"
  [ -z "$static" ] && return 0

  awk -v static="$static" -v expected="$expected" '
    BEGIN {
      position = 1
      for (i = 1; i <= length(static); i++) {
        found = index(substr(expected, position), substr(static, i, 1))
        if (found == 0) {
          exit 1
        }
        position += found
      }
    }
  '
}

segment_may_compose_no_verify() {
  local segment="$1"

  printf '%s' "$segment" \
    | grep -qE -- '--no-[^[:space:]]*(\$|`).*ify([[:space:]]|$)'
}

word_is_shell_expanded_option() {
  local word="$1"

  case "$word" in
    __touchstone_shell_expanded__:-* | __touchstone_shell_expanded__:\{* | __touchstone_shell_expanded__:\[* | __touchstone_shell_expanded__:\** | __touchstone_shell_expanded__:\?*)
      return 0
      ;;
  esac
  return 1
}

word_is_bypass_option() {
  local word="$1"

  case "$word" in
    __touchstone_shell_composed__:*)
      word="${word#__touchstone_shell_composed__:}"
      word="$(printf '%b' "$word")"
      ;;
  esac

  case "$word" in
    --no-veri | --no-verif | --no-verify)
      return 0
      ;;
  esac
  return 1
}

simple_assignment_record() {
  local segment="$1"
  local word="" assignment="" word_count=0

  while IFS= read -r word; do
    word_count=$((word_count + 1))
    if [ "$word_count" -eq 1 ] && [ "$word" = "export" ]; then
      continue
    fi
    case "$word" in
      [A-Za-z_][A-Za-z0-9_]*=*)
        [ -z "$assignment" ] || return 0
        assignment="$word"
        ;;
      *)
        return 0
        ;;
    esac
  done < <(printf '%s' "$segment" | shell_words)

  if [ -n "$assignment" ]; then
    printf '%s\t%s' "${assignment%%=*}" "${assignment#*=}"
  fi
}

remember_simple_assignment() {
  local name="$1" value="$2" filtered=""

  if [ -n "$known_assignments" ]; then
    filtered="$(printf '%s\n' "$known_assignments" | awk -F '\t' -v name="$name" '$1 != name')"
  fi
  if [ -n "$filtered" ]; then
    known_assignments="$(printf '%s\n%s\t%s' "$filtered" "$name" "$value")"
  else
    known_assignments="$(printf '%s\t%s' "$name" "$value")"
  fi
}

known_assignment_value() {
  local name="$1"

  printf '%s\n' "$known_assignments" \
    | awk -F '\t' -v name="$name" '$1 == name { sub(/^[^\t]*\t/, ""); print; found=1 } END { exit !found }'
}

exact_variable_name() {
  local word="$1" name=""

  case "$word" in
    \$\{[A-Za-z_][A-Za-z0-9_]*\})
      name="${word#\$\{}"
      name="${name%\}}"
      ;;
    '$'[A-Za-z_][A-Za-z0-9_]*)
      name="${word#\$}"
      ;;
  esac
  [ -n "$name" ] && printf '%s' "$name"
}

segment_invokes_assigned_bypass() {
  local segment="$1"
  local command_word="" variable_name="" assigned_value=""

  command_word="$(printf '%s' "$segment" | shell_words | sed -n '1p')"
  variable_name="$(exact_variable_name "$command_word")"
  [ -n "$variable_name" ] || return 1
  assigned_value="$(known_assignment_value "$variable_name")" || return 1
  segment_has_bypass_words "$assigned_value"
}

segment_has_bypass_words() {
  local segment="$1"
  local word=""
  local seen_git=false
  local subcommand=""
  local expect_global_option_value=false
  local expect_redirection_target=false
  local seen_no_verify=false
  local seen_dynamic_push_arg=false
  local requires_alias_lookup=false
  local variable_name="" assigned_value=""

  while IFS= read -r word; do
    if [ "$expect_redirection_target" = "true" ]; then
      expect_redirection_target=false
      continue
    elif [ "$word" = "__touchstone_redirection__" ]; then
      expect_redirection_target=true
      continue
    elif [ "$seen_git" = "false" ]; then
      case "$word" in
        git | */git | __touchstone_shell_composed__:*)
          seen_git=true
          ;;
        *)
          if word_may_expand_to "$word" "git"; then
            seen_git=true
          fi
          ;;
      esac
    elif [ "$expect_global_option_value" = "true" ]; then
      expect_global_option_value=false
    elif [ -z "$subcommand" ]; then
      case "$word" in
        -C | -c | --git-dir | --work-tree | --namespace)
          expect_global_option_value=true
          ;;
        --no-pager | --paginate | -P | -p)
          ;;
        -*)
          ;;
        *)
          variable_name="$(exact_variable_name "$word")"
          if [ -n "$variable_name" ] \
            && assigned_value="$(known_assignment_value "$variable_name")" \
            && [ "$(printf '%s' "$assigned_value" | shell_words | sed -n '1p')" = "push" ]; then
            subcommand="push"
            if text_has_bypass_option "$assigned_value"; then
              seen_no_verify=true
              push_candidate_dynamic=true
            fi
          elif word_may_expand_to "$word" "push"; then
            # An unresolved subcommand expansion can emit both "push" and
            # following options through shell word splitting.
            subcommand="push"
            seen_dynamic_push_arg=true
            push_candidate_dynamic=true
          else
            subcommand="$word"
          fi
          ;;
      esac
    elif word_is_bypass_option "$word"; then
      seen_no_verify=true
    elif [ "$subcommand" = "push" ]; then
      variable_name="$(exact_variable_name "$word")"
      if [ -n "$variable_name" ] \
        && assigned_value="$(known_assignment_value "$variable_name")"; then
        if word_is_bypass_option "$assigned_value"; then
          seen_no_verify=true
        else
          case "$assigned_value" in
            *'$'* | *'`'*) seen_dynamic_push_arg=true ;;
          esac
        fi
      else
        if word_is_shell_expanded_option "$word"; then
          seen_dynamic_push_arg=true
        else
          case "$word" in
            *'$'* | *'`'*) seen_dynamic_push_arg=true ;;
          esac
        fi
      fi
    fi
  done < <(printf '%s' "$segment" | shell_words)

  if [ "$subcommand" = "push" ] && [ "$seen_dynamic_push_arg" = "true" ]; then
    seen_no_verify=true
  fi
  if [ "$subcommand" = "push" ] && [ "$seen_no_verify" = "false" ] \
    && segment_may_compose_no_verify "$segment"; then
    seen_no_verify=true
  fi

  if [ -n "$subcommand" ] && [ "$subcommand" != "push" ]; then
    requires_alias_lookup=true
  fi
  if [ -n "$subcommand" ] \
    && { [ "$seen_no_verify" = "true" ] || [ "$requires_alias_lookup" = "true" ]; }; then
    push_subcommand="$subcommand"
    push_candidate_has_bypass="$seen_no_verify"
    return 0
  fi

  return 1
}

text_has_bypass_option() {
  local text="$1"
  local word=""

  while IFS= read -r word; do
    if word_is_bypass_option "$word"; then
      return 0
    fi
  done < <(printf '%s' "$text" | shell_words)

  return 1
}

segment_may_mutate_parent_directory() {
  local segment="$1"
  local word=""

  while IFS= read -r word; do
    case "$word" in
      if | then | elif | else | while | until | do | ! | time | command | builtin | "(" | ")")
        ;;
      [A-Za-z_][A-Za-z0-9_]*=*)
        ;;
      eval | source | .)
        return 0
        ;;
      -*)
        ;;
      *)
        return 1
        ;;
    esac
  done < <(printf '%s' "$segment" | shell_words)

  return 1
}

static_data_sink_segment() {
  local segment="$1"
  local word="" command_word="" executable_segment=""

  while IFS= read -r word; do
    [ -n "$command_word" ] || command_word="$word"
  done < <(printf '%s' "$segment" | shell_words)
  executable_segment="$(printf '%s' "$segment" | without_single_quoted_literals)"

  case "$command_word" in
    echo | printf)
      printf '%s' "$executable_segment" \
        | grep -qE '(^|[^\\])\$\(|(^|[^\\])`|[;&|<>]' && return 1
      return 0
      ;;
    gh)
      printf '%s' "$executable_segment" \
        | grep -qE '(^|[^\\])\$\(|(^|[^\\])`|[;&|<>]' && return 1
      printf '%s' "$segment" | grep -qE '(^|[[:space:]])(issue|pr)[[:space:]]+(create|comment)([[:space:]]|$)'
      return
      ;;
  esac
  return 1
}

plain_git_push_without_bypass() {
  local segment="$1"
  local word="" seen_git=false seen_push=false command_seen=false

  while IFS= read -r word; do
    if [ "$seen_git" = "false" ]; then
      case "$word" in
        if | then | elif | else | while | until | do | ! | time | command | builtin | "(" | ")" | "{" | "}")
          [ "$command_seen" = "false" ] || return 1
          ;;
        [A-Za-z_][A-Za-z0-9_]*=*)
          [ "$command_seen" = "false" ] || return 1
          ;;
        git | */git)
          seen_git=true
          command_seen=true
          ;;
        *)
          return 1
          ;;
      esac
    elif [ "$seen_push" = "false" ]; then
      case "$word" in
        push) seen_push=true ;;
        -C | -c | --git-dir | --work-tree | --namespace) ;;
        -*) ;;
        *) return 1 ;;
      esac
    elif word_is_bypass_option "$word"; then
      return 1
    fi
  done < <(printf '%s' "$segment" | shell_words)
  [ "$seen_push" = "true" ]
}

segment_is_static_nonprotected() {
  local segment="$1"
  local first_word=""

  static_data_sink_segment "$segment" && return 0
  segment_is_safe_code_carrier "$segment" && return 0
  plain_git_push_without_bypass "$segment" && return 0
  [ -n "$(simple_assignment_record "$segment")" ] && return 0
  first_word="$(printf '%s' "$segment" | shell_words | sed -n '1p')"
  case "$first_word" in
    alias | true | :)
      return 0
      ;;
  esac
  return 1
}

# Print code strings carried by explicit shell execution boundaries. The caller
# classifies these payloads; quoted text is not executable merely
# because it appears somewhere inside a shell command.
segment_code_payloads() {
  local segment="$1"
  local word="" seen_shell=false expect_payload=false
  local seen_eval=false seen_trap=false seen_source=false seen_stdin_redirection=false
  local words=()

  while IFS= read -r word; do
    words[${#words[@]}]="$word"
  done < <(printf '%s' "$segment" | shell_words)

  for word in "${words[@]}"; do
    if [ "$expect_payload" = "true" ]; then
      printf '%s\n' "$word"
      expect_payload=false
      continue
    fi
    if [ "$seen_eval" = "true" ]; then
      printf '%s\n' "$word"
      seen_eval=false
      continue
    fi
    if [ "$seen_trap" = "true" ]; then
      case "$word" in
        -*)
          continue
          ;;
      esac
      printf '%s\n' "$word"
      seen_trap=false
      continue
    fi
    case "$word" in
      eval)
        seen_eval=true
        ;;
      trap)
        seen_trap=true
        ;;
      source | .)
        seen_source=true
        ;;
      /dev/stdin)
        if [ "$seen_source" = "true" ]; then
          seen_shell=true
        fi
        ;;
      sh | */sh | bash | */bash | dash | */dash | ksh | */ksh | zsh | */zsh)
        seen_shell=true
        ;;
      -*c*)
        if [ "$seen_shell" = "true" ]; then
          expect_payload=true
        fi
        ;;
      __touchstone_redirection__)
        if [ "$seen_shell" = "true" ] \
          && printf '%s' "$segment" | grep -q '<<<'; then
          seen_stdin_redirection=true
        fi
        ;;
      *)
        if [ "$seen_stdin_redirection" = "true" ]; then
          printf '%s\n' "$word"
          seen_stdin_redirection=false
        fi
        ;;
    esac
  done
}

payload_has_protected_push() {
  local payload="$1"
  local nested_segment=""

  while IFS= read -r nested_segment; do
    push_subcommand=""
    push_candidate_has_bypass=false
    if segment_has_bypass_words "$nested_segment" \
      && [ "$push_subcommand" = "push" ] \
      && [ "$push_candidate_has_bypass" = "true" ]; then
      return 0
    fi
  done < <(printf '%s\n' "$payload" | without_heredoc_bodies | without_shell_comments | shell_segments)
  return 1
}

segment_has_protected_code_payload() {
  local segment="$1"
  local payload=""

  while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    if payload_has_protected_push "$payload"; then
      return 0
    fi
  done < <(segment_code_payloads "$segment")
  return 1
}

segment_is_safe_code_carrier() {
  local segment="$1"
  local payload="" payload_count=0

  while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    payload_count=$((payload_count + 1))
    static_data_sink_segment "$payload" || return 1
  done < <(segment_code_payloads "$segment")
  [ "$payload_count" -gt 0 ]
}

segment_push_forwarding_function_name() {
  local segment="$1"
  local header="" name="" body="" body_segment=""

  header="${segment%%\{*}"
  if ! printf '%s' "$header" \
    | grep -qE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?[[:space:]]*$'; then
    return 0
  fi
  name="$(printf '%s' "$header" \
    | sed -E 's/^[[:space:]]*function[[:space:]]+//; s/[[:space:]]*(\(\))?[[:space:]]*$//')"
  body="${segment#*\{}"
  body="${body%\}*}"

  while IFS= read -r body_segment; do
    if printf '%s' "$body_segment" | grep -qE '(\$@|\$\*)' \
      && segment_has_bypass_words "$body_segment" \
      && [ "$push_subcommand" = "push" ]; then
      printf '%s' "$name"
      return 0
    fi
  done < <(printf '%s' "$body" | shell_segments)
}

segment_git_push_alias_name() {
  local segment="$1"
  local word="" seen_git=false seen_config=false alias_name="" expect_value=false

  while IFS= read -r word; do
    if [ "$seen_git" = "false" ]; then
      case "$word" in
        git | */git) seen_git=true ;;
      esac
    elif [ "$seen_config" = "false" ]; then
      case "$word" in
        config) seen_config=true ;;
        -*) ;;
        *) return 0 ;;
      esac
    elif [ "$expect_value" = "true" ]; then
      case "$word" in
        push | "push "*)
          printf '%s' "$alias_name"
          return 0
          ;;
      esac
      return 0
    else
      case "$word" in
        alias.*)
          alias_name="${word#alias.}"
          expect_value=true
          ;;
      esac
    fi
  done < <(printf '%s' "$segment" | shell_words)
}

segment_invokes_named_bypass() {
  local segment="$1"
  local protected_names="$2"
  local word="" command_word="" seen_no_verify=false

  while IFS= read -r word; do
    if [ -z "$command_word" ]; then
      command_word="$word"
    elif word_is_bypass_option "$word"; then
      seen_no_verify=true
    fi
  done < <(printf '%s' "$segment" | shell_words)

  [ "$seen_no_verify" = "true" ] || return 1
  printf '%s\n' "$protected_names" | grep -Fqx "$command_word"
}

segment_bypass_alias_name() {
  local segment="$1"
  local word="" alias_name="" alias_value="" seen_alias=false

  while IFS= read -r word; do
    if [ "$seen_alias" = "false" ]; then
      [ "$word" = "alias" ] || return 0
      seen_alias=true
      continue
    fi
    case "$word" in
      [A-Za-z_][A-Za-z0-9_]*=*)
        alias_name="${word%%=*}"
        alias_value="${word#*=}"
        if printf '%s' "$alias_value" \
          | grep -qE '(^|[[:space:]])([^[:space:]]*/)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'; then
          printf '%s' "$alias_name"
          return 0
        fi
        ;;
    esac
  done < <(printf '%s' "$segment" | shell_words)
}

segment_invokes_bypass_alias() {
  local segment="$1"
  local protected_aliases="$2"
  local word="" command_word="" seen_no_verify=false

  while IFS= read -r word; do
    if [ -z "$command_word" ]; then
      command_word="$word"
    elif word_is_bypass_option "$word"; then
      seen_no_verify=true
    fi
  done < <(printf '%s' "$segment" | shell_words)

  [ "$seen_no_verify" = "true" ] || return 1
  printf '%s\n' "$protected_aliases" | grep -Fqx "$command_word"
}

segment_cd_target() {
  local segment="$1"
  local token=""
  local normalized=""
  local assignment_name=""
  local expect_target=false

  while IFS= read -r token; do
    if [ "$expect_target" = "true" ]; then
      printf '%s' "$token"
      return
    fi
    normalized="$(printf '%s' "$token" | sed -E 's/^[({]+//')"
    case "$normalized" in
      if | then | elif | else | while | until | do | ! | command | builtin | "")
        ;;
      *=*)
        assignment_name="${normalized%%=*}"
        printf '%s' "$assignment_name" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || return
        ;;
      cd)
        expect_target=true
        ;;
      *)
        return
        ;;
    esac
  done < <(printf '%s' "$segment" | shell_words)

  if [ "$expect_target" = "true" ]; then
    printf '%s' "${HOME:-__touchstone_home_unset__}"
  fi
}

segment_runs_bypass_push() {
  local segment="$1"
  local segment_executable=""

  if [ "$command_dynamic_protected" = "true" ]; then
    push_context="nested"
    return 0
  fi

  if segment_invokes_assigned_bypass "$segment"; then
    push_context="nested"
    push_subcommand="push"
    return 0
  fi

  segment_executable="$(printf '%s' "$segment" | without_single_quoted_literals)"

  if segment_has_bypass_words "$segment"; then
    if [ "$push_candidate_dynamic" = "true" ] \
      || printf '%s' "$segment_executable" \
      | grep -qE '(^|[^\\])\$\(|(^|[^\\])`|^[[:space:]]*\(|^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{'; then
      push_context="nested"
    else
      push_context="direct"
    fi
    return 0
  fi

  if printf '%s' "$segment_executable" \
    | grep -qE '(^|[^\\])\$\(|(^|[^\\])`' \
    && printf '%s' "$segment_executable" \
    | tr '\n' ' ' \
      | grep -qE 'git.*push.*--no-verify'; then
    push_context="nested"
    return 0
  fi

  if segment_has_protected_code_payload "$segment"; then
    push_context="nested"
    push_subcommand="push"
    return 0
  fi

  return 1
}

push_segment=""
push_context=""
push_subcommand=""
push_candidate_has_bypass=false
push_candidate_dynamic=false
selected_push_context=""
selected_push_subcommand=""
selected_directory_context_ambiguous=false
non_push_candidate_segments=()
non_push_candidate_contexts=()
non_push_candidate_subcommands=()
non_push_candidate_has_bypass=()
non_push_candidate_directory_ambiguous=()
preceding_cd=""
ambiguous_cd_scope=false
command_dynamic_protected=false
command_sets_cdpath=false
command_sets_git_context=false
command_changes_directory_ambiguously=false
cd_chain_proven=false
cd_count=0
protected_aliases=""
configured_push_aliases=""
protected_functions=""
known_assignments=""
multiple_protected_pushes=false
preceding_parent_directory_mutator=false
segment_count=0
only_segment=""
command_executable_text="$(printf '%s' "$command" | without_shell_comments | without_single_quoted_literals)"
if printf '%s' "$command_executable_text" \
  | grep -qE '(^|[;&|()[:space:]])(export[[:space:]]+)?CDPATH='; then
  command_sets_cdpath=true
fi
if [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ] || [ -n "${GIT_COMMON_DIR:-}" ] \
  || printf '%s' "$command_executable_text" \
  | grep -qE '(^|[;&|()[:space:]])(export[[:space:]]+)?(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_CEILING_DIRECTORIES|GIT_CONFIG_[A-Z0-9_]+|HOME|XDG_CONFIG_HOME)='; then
  command_sets_git_context=true
fi
if printf '%s' "$command_executable_text" \
  | grep -qE '(^|[;&|()[:space:]])(pushd|popd|chroot)([;&|()[:space:]]|$)' \
  || printf '%s' "$command_executable_text" \
  | grep -qE '(^|[;&|()[:space:]])(env|sudo)([^;&|)]*)[[:space:]](-C|-D|--chdir)(=|[[:space:]]|$)'; then
  command_changes_directory_ambiguously=true
fi
if printf '%s' "$command_executable_text" | grep -qE '\(' \
  && printf '%s' "$command_executable_text" \
  | grep -qE '(^|[;&|()[:space:]])cd([;&|()[:space:]]|$)'; then
  ambiguous_cd_scope=true
fi
if printf '%s' "$command_executable_text" \
  | tr '\n' ' ' \
  | grep -qE '(^|[;&|()[:space:]])cd([[:space:]]+[^;&|)]*)?[[:space:]]*&&.*git.*push'; then
  cd_chain_proven=true
fi
if printf '%s' "$command_executable_text" | grep -qE '(^|[^\\])\$[{A-Za-z_]' \
  && printf '%s' "$command_executable_text" | grep -qE 'push([^[:alnum:]_]|$)' \
  && printf '%s' "$command_executable_text" | grep -q -- '--no-verify'; then
  if printf '%s' "$command_executable_text" | grep -qE 'git([^[:alnum:]_]|$)' \
    || printf '%s' "$command_executable_text" \
    | grep -qE '("?\\)?\$[{]?[A-Za-z_][A-Za-z0-9_]*[}]?"?[[:space:]]+push([^[:alnum:]_]|$)'; then
    command_dynamic_protected=true
  fi
fi
while IFS= read -r stdin_payload; do
  if [ -n "$stdin_payload" ] && payload_has_protected_push "$stdin_payload"; then
    command_dynamic_protected=true
    break
  fi
done < <(printf '%s\n' "$command" | shell_stdin_heredoc_payloads)
while IFS= read -r segment; do
  segment_count=$((segment_count + 1))
  only_segment="$segment"

  if segment_may_mutate_parent_directory "$segment"; then
    preceding_parent_directory_mutator=true
  fi

  assignment_record="$(simple_assignment_record "$segment")"
  if [ -n "$assignment_record" ]; then
    assignment_name="${assignment_record%%	*}"
    assignment_value="${assignment_record#*	}"
    remember_simple_assignment "$assignment_name" "$assignment_value"
  fi

  if segment_has_protected_code_payload "$segment"; then
    command_dynamic_protected=true
  fi

  function_name="$(segment_push_forwarding_function_name "$segment")"
  if [ -n "$function_name" ]; then
    if [ -n "$protected_functions" ]; then
      protected_functions="$(printf '%s\n%s' "$protected_functions" "$function_name")"
    else
      protected_functions="$function_name"
    fi
  elif [ -n "$protected_functions" ] \
    && segment_invokes_named_bypass "$segment" "$protected_functions"; then
    command_dynamic_protected=true
  fi

  configured_alias_name="$(segment_git_push_alias_name "$segment")"
  if [ -n "$configured_alias_name" ]; then
    if [ -n "$configured_push_aliases" ]; then
      configured_push_aliases="$(printf '%s\n%s' "$configured_push_aliases" "$configured_alias_name")"
    else
      configured_push_aliases="$configured_alias_name"
    fi
  fi

  alias_name="$(segment_bypass_alias_name "$segment")"
  if [ -n "$alias_name" ]; then
    if [ -n "$protected_aliases" ]; then
      protected_aliases="$(printf '%s\n%s' "$protected_aliases" "$alias_name")"
    else
      protected_aliases="$alias_name"
    fi
  elif [ -n "$protected_aliases" ] \
    && segment_invokes_bypass_alias "$segment" "$protected_aliases"; then
    command_dynamic_protected=true
  fi

  cd_target="$(segment_cd_target "$segment")"
  if [ -n "$cd_target" ]; then
    cd_count=$((cd_count + 1))
    if [ "$cd_count" -gt 1 ]; then
      # Multiple directory changes can belong to different conditional chains.
      # Refuse to guess which one controls the eventual push.
      ambiguous_cd_scope=true
    fi
    if printf '%s' "$segment" | grep -qE '^[[:space:]]*\('; then
      ambiguous_cd_scope=true
    fi
    if printf '%s' "$cd_target" | grep -qE '^/' || [ -z "$preceding_cd" ]; then
      preceding_cd="$cd_target"
    else
      preceding_cd="$preceding_cd/$cd_target"
    fi
  fi

  push_context=""
  push_subcommand=""
  push_candidate_has_bypass=false
  push_candidate_dynamic=false
  if segment_runs_bypass_push "$segment"; then
    if [ -n "$push_subcommand" ] && [ "$push_subcommand" != "push" ]; then
      candidate_index="${#non_push_candidate_segments[@]}"
      non_push_candidate_segments[$candidate_index]="$segment"
      non_push_candidate_contexts[$candidate_index]="$push_context"
      non_push_candidate_subcommands[$candidate_index]="$push_subcommand"
      non_push_candidate_has_bypass[$candidate_index]="$push_candidate_has_bypass"
      non_push_candidate_directory_ambiguous[$candidate_index]="$preceding_parent_directory_mutator"
      continue
    fi
    if [ -n "$push_segment" ]; then
      multiple_protected_pushes=true
      continue
    fi
    push_segment="$segment"
    selected_push_context="$push_context"
    selected_push_subcommand="$push_subcommand"
    selected_directory_context_ambiguous="$preceding_parent_directory_mutator"
  fi
done < <(printf '%s\n' "$command" | without_heredoc_bodies | without_shell_comments | shell_segments)

if [ "${#non_push_candidate_segments[@]}" -gt 0 ]; then
  candidate_cwd="$session_cwd"
  if [ -n "$tool_workdir" ]; then
    if printf '%s' "$tool_workdir" | grep -qE '^/'; then
      candidate_cwd="$tool_workdir"
    elif [ -n "$session_cwd" ]; then
      candidate_cwd="$session_cwd/$tool_workdir"
    else
      candidate_cwd="$tool_workdir"
    fi
  fi
  [ -n "$candidate_cwd" ] || candidate_cwd="$(pwd)"

  for candidate_index in "${!non_push_candidate_segments[@]}"; do
    candidate_segment="${non_push_candidate_segments[$candidate_index]}"
    candidate_subcommand="${non_push_candidate_subcommands[$candidate_index]}"
    if [ -n "$configured_push_aliases" ] \
      && printf '%s\n' "$configured_push_aliases" | grep -Fqx "$candidate_subcommand" \
      && [ "${non_push_candidate_has_bypass[$candidate_index]}" = "true" ]; then
      if [ -n "$push_segment" ]; then
        multiple_protected_pushes=true
        continue
      fi
      push_segment="$candidate_segment"
      selected_push_context="nested"
      selected_push_subcommand="$candidate_subcommand"
      selected_directory_context_ambiguous=true
      continue
    fi
    if [ "$command_sets_git_context" = "true" ] \
      || [ "$command_changes_directory_ambiguously" = "true" ] \
      || [ "$cd_count" -gt 0 ] \
      || printf '%s' "$candidate_segment" \
      | grep -qE '(^|[[:space:]])(-C|-c|--config-env)(=|[[:space:]]|$)'; then
      # Alias configuration is repository-scoped. A composed directory context
      # cannot be confirmed here without executing the shell, so fail closed.
      push_segment="$candidate_segment"
      selected_push_context="nested"
      selected_push_subcommand="$candidate_subcommand"
      multiple_protected_pushes=true
      continue
    fi
    alias_expansion="$(git -C "$candidate_cwd" config --get "alias.$candidate_subcommand" 2>/dev/null || true)"
    alias_command="$(printf '%s' "$alias_expansion" | shell_words | sed -n '1p')"
    case "$alias_command" in
      push)
        if [ "${non_push_candidate_has_bypass[$candidate_index]}" != "true" ] \
          && ! text_has_bypass_option "$alias_expansion"; then
          continue
        fi
        if [ -n "$push_segment" ]; then
          multiple_protected_pushes=true
          continue
        fi
        push_segment="$candidate_segment"
        selected_push_context="${non_push_candidate_contexts[$candidate_index]}"
        selected_push_subcommand="$candidate_subcommand"
        selected_directory_context_ambiguous="${non_push_candidate_directory_ambiguous[$candidate_index]}"
        ;;
      !*)
        if printf '%s' "$alias_expansion" | grep -qE '(^|[[:space:]])(git[[:space:]]+)?push([[:space:]]|$)' \
          && { [ "${non_push_candidate_has_bypass[$candidate_index]}" = "true" ] \
            || text_has_bypass_option "$alias_expansion"; }; then
          if [ -n "$push_segment" ]; then
            multiple_protected_pushes=true
            continue
          fi
          push_segment="$candidate_segment"
          selected_push_context="nested"
          selected_push_subcommand="$candidate_subcommand"
          selected_directory_context_ambiguous="${non_push_candidate_directory_ambiguous[$candidate_index]}"
        fi
        ;;
    esac
  done
fi

# The supported authorization subset is deliberately narrower than Bash.
# Protected atoms outside a static data sink or classified code carrier are
# dynamic: they may be joined by pipelines, generated files, xargs/find, or
# another interpreter, so no repository can be audited safely.
command_classifiable_text="$(
  printf '%s\n' "$command" \
    | without_heredoc_bodies \
    | without_shell_comments
)"
if [ -z "$push_segment" ] \
  && printf '%s' "$command_classifiable_text" | grep -qE '(^|[^[:alnum:]_])git([^[:alnum:]_]|$)' \
  && printf '%s' "$command_classifiable_text" | grep -qE '(^|[^[:alnum:]_])push([^[:alnum:]_]|$)' \
  && printf '%s' "$command_classifiable_text" | grep -qE -- '--no-veri(f(y)?)?([^[:alnum:]_]|$)'; then
  fallback_dynamic=false
  while IFS= read -r fallback_segment; do
    if ! segment_is_static_nonprotected "$fallback_segment"; then
      fallback_dynamic=true
      break
    fi
  done < <(printf '%s\n' "$command_classifiable_text" | shell_segments)
  if [ "$fallback_dynamic" = "false" ]; then
    exit 0
  fi
  push_segment="${only_segment:-$command_classifiable_text}"
  selected_push_context="nested"
  selected_push_subcommand="push"
  selected_directory_context_ambiguous=true
fi

if [ -z "$push_segment" ]; then
  exit 0
fi

push_context="$selected_push_context"
push_subcommand="$selected_push_subcommand"

if [ "$multiple_protected_pushes" = "true" ]; then
  echo "emergency-disclosure: multiple protected push segments require separate audited tool calls; bypass blocked" >&2
  exit 2
fi

if [ "$push_context" != "direct" ] || [ "$ambiguous_cd_scope" = "true" ] \
  || [ "$command_sets_git_context" = "true" ] \
  || [ "$command_changes_directory_ambiguously" = "true" ] \
  || [ "$selected_directory_context_ambiguous" = "true" ]; then
  echo "emergency-disclosure: cannot safely resolve protected push repository context; bypass blocked" >&2
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
      git | */git | __touchstone_shell_composed__:*)
        seen_git=true
        ;;
    esac
  elif [ "$seen_git" = "true" ] && [ "$git_word" = "-C" ]; then
    expect_git_c_target=true
  elif [ "$seen_git" = "true" ] && [ "$git_word" = "$push_subcommand" ]; then
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

if [ "$push_subcommand" != "push" ]; then
  alias_expansion="$(git -C "$push_cwd" config --get "alias.$push_subcommand" 2>/dev/null || true)"
  alias_command="$(printf '%s' "$alias_expansion" | shell_words | sed -n '1p')"
  case "$alias_command" in
    push)
      ;;
    !*)
      if printf '%s' "$alias_expansion" | grep -qE '(^|[[:space:]])(git[[:space:]]+)?push([[:space:]]|$)'; then
        push_context="nested"
      else
        exit 0
      fi
      ;;
    *)
      exit 0
      ;;
  esac
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

if [ "$push_context" != "direct" ]; then
  echo "emergency-disclosure: cannot safely resolve shell-based Git alias context; bypass blocked" >&2
  exit 2
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
