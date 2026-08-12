#!/usr/bin/env bash
#
# hooks/emergency-disclosure.sh — Claude Code PreToolUse hook that refuses a
# protected push (a `git push` carrying a hook-bypass flag) unless
# TOUCHSTONE_EMERGENCY=1 authorizes it, in which case the bypass is appended
# to .touchstone/emergency-bypass.log for the next PR to disclose.
#
# THE CONTRACT (issue #507)
#
# This guard does not try to prove a command IS a protected push across every
# spelling of one. That inversion is what grew the previous implementation to
# 2,021 lines of shell emulation, and the corpus in
# tests/fixtures/emergency-corpus.txt shows it still produced false positives
# on ordinary prose the same week it was patched.
#
# Instead the guard proves a command is in a shape it can reason about:
#
#   1. The command is tokenized ONCE, by the lexer below, into words that
#      carry their quoting and expansion facts. Quoted text is data. It is
#      never re-scanned as code, which is what makes prose safe to write.
#   2. A segment carrying a bypass flag whose command word is not git is
#      REFUSED, naming the command word and the flag. Not guessed at.
#   3. A git segment whose subcommand, config options, or arguments are
#      assembled by expansion is REFUSED. Not resolved.
#   4. Anything the lexer cannot tokenize is REFUSED.
#
# "Unrecognized" means no, not "scan harder". A whitelist can only ever block
# more than the shape it recognizes, which is how the corpus proves this guard
# is no weaker than the emulator it replaces.
#
# NON-GOALS, stated so they are not rediscovered:
#
#   - No TOCTOU claim. A PreToolUse hook inspects a string; it cannot bind
#     that string to what the shell later executes. Branch protection and
#     required checks are the real boundary. This is fast feedback.
#   - No completeness claim. The grammar deliberately refuses constructs it
#     could probably handle — dynamic subcommands, foreign execution
#     wrappers, a directory change in the same call. Refusing is the point.
#
# Hook protocol:
#   stdin   — JSON describing the tool call
#   exit 0  — allow the tool call
#   exit 2  — block; stderr is shown to the user and surfaced to Claude
#
set -euo pipefail

BYPASS_FLAG="--no-verify"
TAB="$(printf '\t')"

input="$(cat)"

# A protected push needs a git invocation, the push subcommand, or the bypass
# flag to be nameable somewhere in the text. A command whose raw bytes carry
# none of those substrings cannot assemble one out of anything this hook can
# see, and the emulator it replaces reached the same verdict by a longer route.
#
# The here-string matters more here than anywhere else in this file. As a
# pipeline under `set -o pipefail`, a MATCH on a large input returns 141 —
# grep exits first, the producer takes SIGPIPE — and `! …` turns that into
# "no match", so the hook would exit 0 and allow the very command it just
# recognized. Input size is the trigger, so it fires on large payloads and
# never on a small fixture (issue #806).
if ! grep -qE 'git|push|--no' <<<"$input"; then
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "emergency-disclosure: jq not installed — hook bypassed (install jq to enable)" >&2
  exit 0
fi

command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
tool_workdir="$(printf '%s' "$input" | jq -r '.tool_input.workdir // ""')"

cwd="$session_cwd"
if [ -n "$tool_workdir" ]; then
  case "$tool_workdir" in
    /*) cwd="$tool_workdir" ;;
    *)
      if [ -n "$session_cwd" ]; then
        cwd="$session_cwd/$tool_workdir"
      else
        cwd="$tool_workdir"
      fi
      ;;
  esac
fi
[ -n "$cwd" ] || cwd="$(pwd)"

# ------------------------------------------------------------------ the lexer
#
# One pass, one set of rules, emitting a flat token stream:
#
#   W  <flags> <literal>   a word; flags record what the shell will do to it
#   RT <flags> <literal>   a redirection target, never a command word
#   R  <operator>          a redirection operator
#   HD <q|u> <body>        a heredoc body belonging to the segment before it
#   OP <operator>          a control operator, or ( ) { } punctuation
#   SUB open | SUB close   a command substitution; its contents are code
#   ERR <reason>           the input left the grammar
#
# Word flags: d = the value depends on an expansion, g = pathname or brace
# expansion, q = the word was quoted, a = it contains an ANSI-C ($'...')
# string.
#
# `literal` holds only the statically known characters: an expansion
# contributes nothing to it, a quoted character contributes itself. That one
# choice is what makes `--no-verify` inside a sentence a different word from
# `--no-verify` as an argument, and it is why prose stops being executable.
#
# Newlines and tabs inside a literal are escaped so one token is one line;
# `printf %b` reverses it, which is safe because backslashes are doubled.
#
# LC_ALL=C classifies bytes, not glyphs: macOS awk aborts with "towc:
# multibyte conversion failure" on input that is not UTF-8 clean, and an em
# dash in a commit-message heredoc was enough to trigger it (issue #637).
lex() {
  LC_ALL=C awk '
    function enc(s) {
      gsub(/\\/, "\\\\", s); gsub(/\t/, "\\t", s); gsub(/\n/, "\\n", s)
      return s
    }
    function addf(f) { if (index(wflags, f) == 0) wflags = wflags f }
    function addvar(v) { wvars = (wvars == "" ? v : wvars " " v) }
    function emitw(   kind) {
      if (wstarted) {
        kind = redirect_target ? "RT" : "W"
        redirect_target = 0
        # Every field carries a one-character tag so none of them is ever
        # empty. `read` with a tab IFS collapses runs of tabs, so an empty
        # literal — which is exactly what a bare `$var` produces — would
        # otherwise shift the variable names into the literal field.
        printf "%s\t%s\tL%s\tV%s\n", kind, (wflags == "" ? "-" : wflags), enc(wlit), wvars
      }
      wlit = ""; wflags = ""; wstarted = 0; wvars = ""
    }
    # A control operator ends any pending redirection: the word after `(` in
    # `-m <(cmd)` is a command word, not the redirection target. Leaving the
    # flag set swallowed the first word of every process substitution.
    function emitop(o) { emitw(); redirect_target = 0; printf "OP\t%s\n", o }
    function push_state(term) {
      sp++
      st_lit[sp] = wlit; st_flags[sp] = wflags; st_started[sp] = wstarted
      st_vars[sp] = wvars; st_redirect[sp] = redirect_target
      st_quote[sp] = q; st_paren[sp] = paren; st_term[sp] = term
      wlit = ""; wflags = ""; wstarted = 0; wvars = ""; q = ""; paren = 0
      # The substitution is its own command list; a redirection pending
      # outside it does not consume the first word inside it.
      redirect_target = 0
    }
    function pop_state() {
      wlit = st_lit[sp]; wflags = st_flags[sp]; wstarted = st_started[sp]
      wvars = st_vars[sp]; redirect_target = st_redirect[sp]
      q = st_quote[sp]; paren = st_paren[sp]
      sp--
    }
    { S = S $0 "\n" }
    END {
      n = length(S); p = 1; sp = 0; paren = 0; q = ""; hn = 0
      while (p <= n) {
        c = substr(S, p, 1); d = substr(S, p + 1, 1)

        if (q == "\047") {
          if (c == "\047") { q = "" } else { wlit = wlit c }
          p++; continue
        }
        if (c == "\\") {
          if (d == "\n") { p += 2; continue }
          if (d == "") { p++; continue }
          if (q == "\"" && d != "\"" && d != "\\" && d != "$" && d != "`") {
            wlit = wlit c d
          } else {
            wlit = wlit d
          }
          wstarted = 1; p += 2; continue
        }
        if (c == "$") {
          if (d == "(" && substr(S, p + 2, 1) == "(") {
            # Arithmetic expansion is a value, never a command list. Skipping
            # it is why $((1 << 2)) is not misread as a heredoc.
            p += 3; depth = 2
            while (p <= n && depth > 0) {
              ch = substr(S, p, 1)
              if (ch == "(") depth++
              else if (ch == ")") depth--
              p++
            }
            addf("d"); wstarted = 1; continue
          }
          if (d == "(") { push_state(")"); printf "SUB\topen\n"; p += 2; continue }
          if (d == "`") { push_state("`"); printf "SUB\topen\n"; p += 2; continue }
          if (d == "{") {
            p += 2; depth = 1; name = ""
            while (p <= n && depth > 0) {
              ch = substr(S, p, 1)
              if (ch == "{") depth++
              else if (ch == "}") depth--
              else if (depth == 1) name = name ch
              p++
            }
            # Only a bare ${NAME} names a variable this hook can resolve; any
            # operator inside the braces makes the value unknowable.
            if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/) addvar(name)
            addf("d"); wstarted = 1; continue
          }
          if (d == "\047") {
            # ANSI-C quoting carries its own escapes; the caller decodes them.
            p += 2
            while (p <= n) {
              ch = substr(S, p, 1)
              if (ch == "\\") { wlit = wlit ch substr(S, p + 1, 1); p += 2; continue }
              if (ch == "\047") { p++; break }
              wlit = wlit ch; p++
            }
            addf("a"); addf("q"); wstarted = 1; continue
          }
          if (d == "\"") { q = "\""; addf("q"); wstarted = 1; p += 2; continue }
          if (d ~ /[A-Za-z_0-9@*#?!$-]/) {
            p++; name = d; p++
            if (d ~ /[A-Za-z_]/) {
              while (p <= n && substr(S, p, 1) ~ /[A-Za-z0-9_]/) { name = name substr(S, p, 1); p++ }
              addvar(name)
            }
            addf("d"); wstarted = 1; continue
          }
          wlit = wlit c; wstarted = 1; p++; continue
        }
        if (sp > 0 && paren == 0 \
          && ((c == ")" && st_term[sp] == ")") || (c == "`" && st_term[sp] == "`"))) {
          emitw(); printf "SUB\tclose\n"; pop_state(); addf("d"); wstarted = 1; p++; continue
        }
        if (c == "`") { push_state("`"); printf "SUB\topen\n"; p++; continue }
        if (q == "\"") {
          if (c == "\"") { q = ""; wstarted = 1; p++; continue }
          wlit = wlit c; wstarted = 1; p++; continue
        }
        if (c == "\"") { q = "\""; addf("q"); wstarted = 1; p++; continue }
        if (c == "\047") { q = "\047"; addf("q"); wstarted = 1; p++; continue }
        if (c == "#" && !wstarted && (p == 1 || substr(S, p - 1, 1) ~ /[[:space:];&|()]/)) {
          while (p <= n && substr(S, p, 1) != "\n") p++
          continue
        }
        if (c == "\n") {
          emitw()
          p++
          for (k = 1; k <= hn; k++) {
            body = ""
            while (p <= n) {
              e = index(substr(S, p), "\n")
              if (e == 0) { line = substr(S, p); p = n + 1 } else { line = substr(S, p, e - 1); p += e }
              cmp = line
              if (h_strip[k]) sub(/^\t+/, "", cmp)
              if (cmp == h_delim[k]) break
              body = body line "\n"
            }
            printf "HD\t%s\t%s\n", (h_quoted[k] ? "q" : "u"), enc(body)
          }
          hn = 0
          printf "OP\tnl\n"
          continue
        }
        if ((c == "<" || c == ">") && d == "(") {
          # Process substitution. Its body is a command list like any other,
          # so it is walked as code rather than treated as a redirection.
          push_state(")"); printf "SUB\topen\n"; p += 2; continue
        }
        if (c == "<" || c == ">") {
          if (wstarted && wflags == "" && wlit ~ /^[0-9]+$/) {
            wlit = ""; wstarted = 0
          } else {
            emitw()
          }
          p++
          if (c == "<" && substr(S, p, 1) == "<") {
            p++
            if (substr(S, p, 1) == "<") { p++; printf "R\t<<<\n"; redirect_target = 1; continue }
            strip = 0
            if (substr(S, p, 1) == "-") { strip = 1; p++ }
            while (p <= n && substr(S, p, 1) ~ /[ \t]/) p++
            delim = ""; quoted = 0
            while (p <= n) {
              ch = substr(S, p, 1)
              if (ch == "\047" || ch == "\"") {
                quoted = 1; term = ch; p++
                while (p <= n && substr(S, p, 1) != term) { delim = delim substr(S, p, 1); p++ }
                p++; continue
              }
              if (ch == "\\") { quoted = 1; delim = delim substr(S, p + 1, 1); p += 2; continue }
              if (ch ~ /[ \t\n;&|()<>]/) break
              delim = delim ch; p++
            }
            if (delim != "") { hn++; h_delim[hn] = delim; h_quoted[hn] = quoted; h_strip[hn] = strip }
            continue
          }
          if (substr(S, p, 1) ~ /[>&|]/) p++
          printf "R\t%s\n", c
          redirect_target = 1
          continue
        }
        if (c == "(" && d == "(" && !wstarted) {
          # An arithmetic command, `(( … ))`. Its body is an expression, not a
          # command list, and skipping it is why `(( v = 1 << 2 ))` does not
          # register `2))` as a heredoc delimiter and swallow the lines after
          # it — which silently hid every following command.
          p += 2; depth = 2
          while (p <= n && depth > 0) {
            ch = substr(S, p, 1)
            if (ch == "(") depth++
            else if (ch == ")") depth--
            p++
          }
          continue
        }
        if (c == "(") { if (sp > 0) paren++; emitop("("); p++; continue }
        if (c == ")") { if (sp > 0 && paren > 0) paren--; emitop(")"); p++; continue }
        if (c == ";") { if (d == ";") { emitop(";;"); p += 2 } else { emitop(";"); p++ }; continue }
        if (c == "&") { if (d == "&") { emitop("&&"); p += 2 } else { emitop("&"); p++ }; continue }
        if (c == "|") {
          if (d == "|") { emitop("||"); p += 2 } \
          else if (d == "&") { emitop("|"); p += 2 } \
          else { emitop("|"); p++ }
          continue
        }
        if (c ~ /[ \t]/) { emitw(); p++; continue }
        if (!wstarted && (c == "{" || c == "}")) { emitop(c); p++; continue }
        if (c == "*" || c == "?" || c == "[") { addf("g"); wstarted = 1; p++; continue }
        if (c == "{") {
          # Brace expansion contributes nothing statically knowable.
          j = p + 1; depth = 1; inner = ""
          while (j <= n && depth > 0) {
            ch = substr(S, j, 1)
            if (ch == "{") depth++
            else if (ch == "}") { depth--; if (depth == 0) break }
            inner = inner ch; j++
          }
          if (depth == 0 && (index(inner, ",") > 0 || index(inner, "..") > 0)) {
            addf("g"); wstarted = 1; p = j + 1; continue
          }
          wlit = wlit c; wstarted = 1; p++; continue
        }
        wlit = wlit c; wstarted = 1; p++
      }
      emitw()
      if (q != "") printf "ERR\tan unterminated quote\n"
      if (sp > 0) printf "ERR\tan unterminated command substitution\n"
    }
  '
}

decode() { printf '%b' "$1"; }

# ------------------------------------------------------------------ predicates
#
# Every text test below reads from a here-string, never from a pipe.
#
# `producer | grep -q PATTERN` under `set -o pipefail` returns 141 when grep
# matches early and the producer is still writing: grep exits on the first
# match, the producer takes SIGPIPE, and pipefail surfaces the signal. A match
# then reads as a failure, so `if producer | grep -q HOSTILE` is false exactly
# when the pattern was found. The trigger is input size, not content, so it is
# invisible on small fixtures and fires on the large command strings and
# heredoc payloads where this guard matters most (issue #806). A here-string
# is not a pipeline: the status is grep's alone.
matches() {
  grep -qE -- "$1" <<<"$2"
}
matches_fixed_line() {
  grep -Fqx -- "$1" <<<"$2"
}

# The bypass flag in every spelling the shell can produce, without a table of
# spellings: the statically known characters of the word must appear, in
# order, inside "--no-verify". Expansions and globs have already deleted
# themselves from the word, so `--no-*`, `--no-{veri,verify}` and
# `--no-$(printf ver)ify` all qualify, while `--no-pager`, `--no-edit`,
# `--no-verify-nothing` and a sentence that merely contains the flag do not.
is_subsequence_of() {
  local lit="$1" rest="$2" i=0 ch=""
  [ -n "$lit" ] || return 1
  while [ "$i" -lt "${#lit}" ]; do
    ch="${lit:$i:1}"
    case "$rest" in
      *"$ch"*) rest="${rest#*"$ch"}" ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

is_bypass_flag() {
  case "$1" in --no*) ;; *) return 1 ;; esac
  is_subsequence_of "$1" "--no-verify"
}

# Word splitting can turn one lexical word into a whole invocation, as in
# git${IFS}pu${x}sh${IFS}--no-veri${x}fy. Require static anchors for both git
# and the flag, then ask only whether the surviving characters still spell a
# protected push in order.
is_spliced_protected_push() {
  local flags="$1" lit="$2"
  case "$flags" in *d*) ;; *) return 1 ;; esac
  case "$lit" in *git*) ;; *) return 1 ;; esac
  case "$lit" in *--no*) ;; *) return 1 ;; esac
  is_subsequence_of "$lit" "gitpush--no-verify"
}

word_is_git() {
  case "$1" in
    git | */git) return 0 ;;
  esac
  return 1
}

# Consumers that write their standard input somewhere instead of executing it.
# Every other consumer is treated as an interpreter, so an unknown one fails
# closed rather than silently turning a payload into data.
word_is_data_sink() {
  case "${1##*/}" in
    cat | tee | gh | git) return 0 ;;
  esac
  return 1
}

word_is_interpreter() {
  case "${1##*/}" in
    sh | bash | zsh | ksh | dash | ash | csh | tcsh) return 0 ;;
  esac
  return 1
}

# Wrappers that run the rest of the segment as another identity, on another
# host, or in another root. Their `-c` argument is a shell payload too, and
# their alias and config context is not the one this hook can inspect.
word_is_foreign_context() {
  case "${1##*/}" in
    sudo | su | doas | runuser | ssh | chroot | docker | podman | kubectl | nsenter) return 0 ;;
  esac
  return 1
}

# Interpreters whose language this hook does not read. It cannot tell what
# they will execute, only that the text handed to them names a push.
word_is_foreign_interpreter() {
  case "${1##*/}" in
    awk | gawk | mawk | perl | python | python2 | python3 | ruby | node | php | tclsh | expect) return 0 ;;
  esac
  return 1
}

git_builtins=""
git_builtins_loaded=false
# Derived from git, never curated. A hand-written subset of git's own command
# surface is a maintenance treadmill by construction, and every builtin
# missing from the old subset was misread as a possible push alias (#776).
subcommand_is_git_builtin() {
  if [ "$git_builtins_loaded" = "false" ]; then
    git_builtins="$(git --list-cmds=builtins 2>/dev/null || true)"
    git_builtins_loaded=true
  fi
  [ -n "$git_builtins" ] || return 1
  matches_fixed_line "$1" "$git_builtins"
}

names_git_push() {
  case "$1" in *git*) ;; *) return 1 ;; esac
  case "$1" in *push*) return 0 ;; esac
  return 1
}

# For a payload this hook cannot read — a string the shell assembles at
# runtime — any one of these is enough to refuse. Requiring all of them would
# miss `eval "git $sub --no-verify"`, where the expansion is exactly the word
# that would have completed the phrase.
mentions_any_push_token() {
  case "$1" in
    *git* | *push* | *--no*) return 0 ;;
  esac
  return 1
}

# ------------------------------------------------------------------ verdict
refuse() {
  echo "emergency-disclosure: refusing this call — $1" >&2
  exit 2
}

push_count=0
push_description=""
push_authorizable=false
context_ambiguous=false
definition_seen=false

# The audit names a repository, so what matters is whether the context was
# already unresolvable when the push was reached. A `cd` AFTER the push cannot
# move the repository the push already targeted.
record_push() {
  push_count=$((push_count + 1))
  if [ "$push_count" -eq 1 ]; then
    push_description="$1"
    if [ "$2" = "true" ] && [ "$context_ambiguous" = "false" ] \
      && [ "$definition_seen" = "false" ] && [ "$resolved_expansion_used" = "false" ]; then
      push_authorizable=true
    else
      push_authorizable=false
    fi
  else
    push_authorizable=false
  fi
}

# Reading a variable this command assigned is good enough to decide whether a
# push is protected — `branch=feat/test; git push origin "$branch"` is provably
# not one. It is NOT good enough to authorize a bypass: this hook does not
# model execution order, so a variable assigned in a branch it cannot evaluate
# would resolve to the wrong value. Deciding may use the resolution;
# authorizing may not.
resolved_expansion_used=false

# ---- what the command told us about itself --------------------------------
# Assignments, git aliases configured in this very command, and alias names
# that route to git. All three are facts the command states outright; reading
# them is not the same as predicting what the shell will do.
asg_values=""
asg_unknown=""
remember_assignment() {
  asg_values="$1=$2
$asg_values"
}
# `x+=t` appends to a value this hook may not have seen, so the variable stops
# being a stated fact. Forgetting it is what keeps `x=gi; x+=t; "$x" push
# --no-verify` in the hidden-executable class instead of resolving to `gi`.
forget_assignment() {
  asg_unknown="$asg_unknown$1
"
}
assignment_value() {
  local name="$1" line=""
  if [ -n "$asg_unknown" ] && matches_fixed_line "$name" "$asg_unknown"; then
    return 1
  fi
  while IFS= read -r line; do
    if [ "${line%%=*}" = "$name" ]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$asg_values"
  return 1
}

command_git_aliases=""
remember_command_git_alias() {
  command_git_aliases="$command_git_aliases$1=$2
"
}
command_git_alias_value() {
  local name="$1" line=""
  while IFS= read -r line; do
    if [ "${line%%=*}" = "$name" ]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$command_git_aliases"
  return 1
}

push_routing_names=""
remember_push_routing_name() {
  push_routing_names="$1=$2
$push_routing_names"
}
# Returns the alias body if this name was defined in the call as one that runs
# git push.
push_routing_value() {
  local name="$1" line=""
  [ -n "$push_routing_names" ] || return 1
  while IFS= read -r line; do
    if [ "${line%%=*}" = "$name" ]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$push_routing_names"
  return 1
}

# ------------------------------------------------------------------ the walk
tk_kind=()
tk_a=()
tk_b=()
tk_c=()
tk_count=0
tk_index=0
payload_depth=0

load_tokens() {
  tk_kind=()
  tk_a=()
  tk_b=()
  tk_c=()
  local k="" a="" b="" c=""
  while IFS="$TAB" read -r k a b c; do
    case "$k" in
      W | RT)
        b="${b#L}"
        c="${c#V}"
        ;;
    esac
    tk_kind[${#tk_kind[@]}]="$k"
    tk_a[${#tk_a[@]}]="$a"
    tk_b[${#tk_b[@]}]="$b"
    tk_c[${#tk_c[@]}]="$c"
  done < <(printf '%s' "$1" | lex)
  tk_count="${#tk_kind[@]}"
  tk_index=0
}

# An explicit code carrier — `bash -c`, `eval`, `trap`, a heredoc reaching an
# interpreter — hands us another command list. Lex and walk it as one.
classify_payload() {
  local payload="$1" context="$2"
  local saved_kind=() saved_a=() saved_b=() saved_c=() saved_index=0 saved_count=0

  payload_depth=$((payload_depth + 1))
  if [ "$payload_depth" -gt 4 ]; then
    refuse "the call nests executable payloads deeper than this hook will follow"
  fi
  saved_kind=(${tk_kind[@]+"${tk_kind[@]}"})
  saved_a=(${tk_a[@]+"${tk_a[@]}"})
  saved_b=(${tk_b[@]+"${tk_b[@]}"})
  saved_c=(${tk_c[@]+"${tk_c[@]}"})
  saved_index="$tk_index"
  saved_count="$tk_count"

  load_tokens "$payload"
  walk "$context" "all"

  tk_kind=(${saved_kind[@]+"${saved_kind[@]}"})
  tk_a=(${saved_a[@]+"${saved_a[@]}"})
  tk_b=(${saved_b[@]+"${saved_b[@]}"})
  tk_c=(${saved_c[@]+"${saved_c[@]}"})
  tk_index="$saved_index"
  tk_count="$saved_count"
  payload_depth=$((payload_depth - 1))
  return 0
}

# git is the authority on its own aliases. Ask it; do not model it.
resolve_git_subcommand() {
  local name="$1" has_bypass="$2" cmd="$3" context="$4"
  local seen="" value="" next="" hops=0 word="" alias_bypass=false skip_value=false

  if subcommand_is_git_builtin "$name"; then
    # git refuses an alias that shadows a builtin, so no repository's config
    # can turn this into a push — directory ambiguity is irrelevant here.
    return 0
  fi
  if [ "$context_ambiguous" = "true" ] || [ "$context" != "direct" ]; then
    refuse "\`$cmd $name\` is not a git builtin, so it may be an alias, and this call changes the repository context before it runs"
  fi

  while [ "$hops" -lt 8 ]; do
    hops=$((hops + 1))
    case "$seen" in
      *"|$name|"*) refuse "\`$cmd $name\` expands through a loop of git aliases" ;;
    esac
    seen="$seen|$name|"

    if ! value="$(command_git_alias_value "$name")"; then
      value="$(git -C "$cwd" config --get "alias.$name" 2>/dev/null || true)"
    fi
    [ -n "$value" ] || return 0
    case "$value" in
      '!'*)
        # A shell alias runs arbitrary code. Refuse only when it names a push:
        # `!echo "$@"` cannot become one however it is called.
        if matches '(^|[^[:alnum:]_])push([^[:alnum:]_]|$)' "$value"; then
          refuse "\`$cmd $name\` is a shell alias (\`$value\`) that names a push, so what it runs cannot be checked"
        fi
        return 0
        ;;
    esac

    # An alias expansion is itself `[global options] subcommand …`. Skip the
    # harmless global options to reach the subcommand, and refuse the ones that
    # move the repository or redefine config out from under the lookup.
    next=""
    alias_bypass=false
    skip_value=false
    while IFS= read -r word; do
      [ -n "$word" ] || continue
      if [ "$skip_value" = "true" ]; then
        skip_value=false
        continue
      fi
      if [ -n "$next" ]; then
        if is_bypass_flag "$word"; then
          alias_bypass=true
        fi
        continue
      fi
      case "$word" in
        -C | --git-dir | --work-tree | --namespace | -c | --config-env)
          refuse "\`$cmd $name\` expands to a git alias that changes repository or config context (\`$value\`)"
          ;;
        --no-pager | --paginate | -P | -p | --bare | --no-replace-objects | --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs) ;;
        -*)
          refuse "\`$cmd $name\` expands to a git alias with an option this hook does not model (\`$value\`)"
          ;;
        *) next="$word" ;;
      esac
    done <<<"$(printf '%s' "$value" | tr " $TAB" '\n\n')"

    if [ -z "$next" ]; then
      refuse "\`$cmd $name\` expands to a git alias with no subcommand (\`$value\`)"
    fi
    if [ "$next" = "push" ]; then
      if [ "$has_bypass" = "true" ] || [ "$alias_bypass" = "true" ]; then
        record_push "$cmd $name (a git alias for \`$value\`)" false
      fi
      return 0
    fi
    name="$next"
  done
  refuse "\`$cmd $name\` expands through more git aliases than this hook will follow"
}

seg_flags=()
seg_lits=()
seg_vars=()

# The statically known text of word $1, with ANSI-C escapes resolved.
word_text() {
  local text=""
  text="$(decode "${seg_lits[$1]}")"
  case "${seg_flags[$1]}" in
    *a*) text="$(decode "$text")" ;;
  esac
  printf '%s' "$text"
}

# A word that is exactly one reference to a variable this command assigned:
# `$name`, `${name}` or `"$name"`. Its value is then a fact the command
# stated, not a guess about the shell.
word_known_value() {
  # Assign in separate statements: bash expands every word of a `local` line
  # before the builtin runs, so `local i="$1" v="${arr[$i]}"` reads the OUTER
  # i — unset here, which killed the lookup under `set -u`.
  local index="$1"
  local vars
  vars="${seg_vars[$index]}"
  case "${seg_flags[$index]}" in *d*) ;; *) return 1 ;; esac
  [ -n "$vars" ] || return 1
  case "$vars" in *" "*) return 1 ;; esac
  [ -z "$(word_text "$index")" ] || return 1
  # Callers run this in a command substitution, so they — not this function —
  # set `resolved_expansion_used`; an assignment made here would be lost with
  # the subshell.
  assignment_value "$vars"
}

classify_git() {
  local cmd="$1" start="$2" count="$3" has_bypass="$4" bypass_spelling="$5" context="$6"
  local i="$start" flags="" lit="" value="" word=""
  local subcommand="" subcommand_flags="" subcommand_found=false
  local safe_globals_only=true dynamic_argument=false authorizable=false

  while [ "$i" -lt "$count" ]; do
    flags="${seg_flags[$i]}"
    lit="$(word_text "$i")"
    case "$lit" in
      -C | --git-dir | --work-tree | --namespace)
        context_ambiguous=true
        safe_globals_only=false
        i=$((i + 2))
        continue
        ;;
      -c | --config-env)
        safe_globals_only=false
        i=$((i + 1))
        if [ "$i" -lt "$count" ]; then
          case "${seg_flags[$i]}" in
            *d* | *g*) refuse "\`git $lit\` is given a value assembled at runtime, and a config value can define an alias that pushes" ;;
          esac
          value="$(word_text "$i")"
          case "$value" in
            alias.*) refuse "\`git $lit $value\` defines a git alias for this call, so the subcommand cannot be resolved" ;;
          esac
        fi
        i=$((i + 1))
        continue
        ;;
      -C* | --git-dir=* | --work-tree=* | --namespace=*)
        context_ambiguous=true
        safe_globals_only=false
        ;;
      -c* | --config-env=*)
        safe_globals_only=false
        case "${lit#-c}" in
          alias.*) refuse "\`git $lit\` defines a git alias for this call, so the subcommand cannot be resolved" ;;
        esac
        case "${lit#*=}" in
          alias.*) refuse "\`git $lit\` defines a git alias for this call, so the subcommand cannot be resolved" ;;
        esac
        ;;
      --exec-path*)
        refuse "\`git --exec-path\` redirects git's own command lookup, so the subcommand cannot be resolved"
        ;;
      --no-pager | --paginate | -P | -p | --bare | --no-replace-objects | --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs) ;;
      -*)
        safe_globals_only=false
        context_ambiguous=true
        ;;
      *)
        subcommand="$lit"
        subcommand_flags="$flags"
        subcommand_found=true
        break
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$subcommand_found" = "false" ]; then
    return 0
  fi
  case "$subcommand_flags" in
    *d* | *g*)
      if value="$(word_known_value "$i")"; then
        resolved_expansion_used=true
        # The command assigned this variable itself, so the subcommand is a
        # stated fact. `sub=push; git "$sub" …` resolves to push. An unquoted
        # value also word-splits, so `args='push --no-verify'; git $args`
        # supplies the subcommand AND the flag from one expansion.
        subcommand="${value%%[ $TAB]*}"
        while IFS= read -r word; do
          if is_bypass_flag "$word"; then
            has_bypass=true
            bypass_spelling="$word"
          fi
        done <<<"$(printf '%s' "$value" | tr " $TAB" '\n\n')"
      else
        refuse "the git subcommand is built by expansion, so this call cannot be shown to be anything other than a push"
      fi
      ;;
  esac
  if [ "$subcommand" != "push" ]; then
    resolve_git_subcommand "$subcommand" "$has_bypass" "$cmd" "$context"
    return 0
  fi

  # `git config alias.NAME push …` teaches this command's own alias table.
  i=$((i + 1))
  while [ "$i" -lt "$count" ]; do
    case "${seg_flags[$i]}" in
      *d* | *g*)
        if value="$(word_known_value "$i")"; then
          resolved_expansion_used=true
          if is_bypass_flag "$value"; then
            has_bypass=true
            bypass_spelling="$value"
          fi
        else
          dynamic_argument=true
        fi
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$has_bypass" = "true" ]; then
    if [ "$context" = "direct" ] && [ "$safe_globals_only" = "true" ] \
      && [ "$dynamic_argument" = "false" ]; then
      authorizable=true
    fi
    record_push "$cmd push … $bypass_spelling" "$authorizable"
    return 0
  fi
  if [ "$dynamic_argument" = "true" ]; then
    refuse "\`$cmd push\` is given an argument assembled at runtime, which could be \`$BYPASS_FLAG\`"
  fi
  return 0
}

# `git config alias.NAME VALUE` in this command defines an alias that a later
# segment can use before any repository config would show it.
record_git_config_alias() {
  local start="$1" count="$2" i="$1" lit="" name="" value=""
  [ "$((start + 2))" -lt "$count" ] || return 0
  [ "$(word_text "$start")" = "config" ] || return 0
  i=$((start + 1))
  while [ "$i" -lt "$count" ]; do
    lit="$(word_text "$i")"
    case "$lit" in
      alias.*)
        name="${lit#alias.}"
        if [ "$((i + 1))" -lt "$count" ]; then
          value="$(word_text "$((i + 1))")"
          remember_command_git_alias "$name" "$value"
        fi
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

classify_segment() {
  local seg="$1" heredocs="$2" herestring="$3" context="$4"
  local pipe_git="$5" pipe_interpreter="$6"
  local flags="" lit="" vars="" i=0 count=0 start=0
  local cmd="" cmd_flags="" cmd_base=""
  local has_bypass=false bypass_spelling="" payload="" payload_flags=""
  local hd_kind="" hd_body="" body="" value="" name=""
  local segment_names_git=false payload_consumed=false file_argument=false
  # Bash's dynamic scoping is load-bearing here: a nested payload walk gets
  # its own segment arrays, and returning restores this one's. Without the
  # `local`, classifying a heredoc payload would clobber the segment that
  # carried it.
  local seg_flags seg_lits seg_vars

  seg_flags=()
  seg_lits=()
  seg_vars=()
  while IFS="$TAB" read -r flags lit vars; do
    [ -n "$flags" ] || continue
    seg_flags[${#seg_flags[@]}]="$flags"
    seg_lits[${#seg_lits[@]}]="${lit#L}"
    seg_vars[${#seg_vars[@]}]="${vars#V}"
  done <<<"$seg"
  count="${#seg_flags[@]}"

  # Keywords, transparent shell wrappers, and assignments precede the command
  # word. `command`/`builtin`/`exec` are transparent: they do not change the
  # process's directory or identity, so what follows is still this segment.
  while [ "$i" -lt "$count" ]; do
    lit="$(word_text "$i")"
    case "$lit" in
      if | then | elif | else | fi | while | until | do | done | 'case' | 'esac' | 'in' | '!' | coproc | command | builtin | exec | export | local | declare | typeset)
        i=$((i + 1))
        continue
        ;;
      time)
        i=$((i + 1))
        if [ "$i" -lt "$count" ] && [ "$(word_text "$i")" = "-p" ]; then
          i=$((i + 1))
        fi
        continue
        ;;
      function)
        definition_seen=true
        return 0
        ;;
      [A-Za-z_]*+=*)
        # Checked before the plain-assignment case, which would otherwise
        # match `x+=t` and record a variable named `x+`, leaving `x` looking
        # like the value it had before the append.
        forget_assignment "${lit%%+=*}"
        i=$((i + 1))
        continue
        ;;
      [A-Za-z_]*=*)
        name="${lit%%=*}"
        case "$name" in
          GIT_DIR | GIT_WORK_TREE | GIT_COMMON_DIR | GIT_CEILING_DIRECTORIES | HOME | XDG_CONFIG_HOME | CDPATH | PATH | GIT_CONFIG*)
            context_ambiguous=true
            ;;
        esac
        case "${seg_flags[$i]}" in
          *d* | *g*) forget_assignment "$name" ;;
          *) remember_assignment "$name" "${lit#*=}" ;;
        esac
        i=$((i + 1))
        continue
        ;;
    esac
    break
  done
  [ "$i" -lt "$count" ] || return 0

  cmd_flags="${seg_flags[$i]}"
  cmd="$(word_text "$i")"
  cmd_base="${cmd##*/}"
  start=$((i + 1))

  # The bypass flag is looked for across the whole segment, so no wrapper can
  # hide one behind its own options. `git` anywhere in the segment is what
  # makes a stray flag reachable by a push.
  i=0
  while [ "$i" -lt "$count" ]; do
    lit="$(word_text "$i")"
    if [ "$has_bypass" = "false" ] && is_bypass_flag "$lit"; then
      has_bypass=true
      bypass_spelling="$lit"
    fi
    case "$lit" in *git*) segment_names_git=true ;; esac
    i=$((i + 1))
  done
  [ "$pipe_git" = "true" ] && segment_names_git=true

  # A heredoc or here-string reaching an interpreter is a code payload; one
  # reaching a data sink is text. An unquoted delimiter still expands, so a
  # substitution inside it is code even when the consumer only writes it out —
  # but only the substitution is, which is why the body is walked in
  # substitutions-only mode rather than treated as a script.
  while IFS="$TAB" read -r hd_kind hd_body; do
    [ -n "$hd_kind" ] || continue
    body="$(decode "$hd_body")"
    if word_is_data_sink "$cmd" && [ "$pipe_interpreter" != "true" ]; then
      if [ "$hd_kind" = "u" ]; then
        classify_text_substitutions "$body"
      fi
    else
      classify_payload "$body" "nested"
    fi
  done <<<"$heredocs"
  if [ -n "$herestring" ]; then
    body="$(decode "$herestring")"
    if word_is_interpreter "$cmd" || word_is_foreign_context "$cmd" \
      || [ "$cmd_base" = "source" ] || [ "$cmd_base" = "." ] \
      || [ "$pipe_interpreter" = "true" ]; then
      classify_payload "$body" "nested"
    elif ! word_is_data_sink "$cmd"; then
      classify_payload "$body" "nested"
    else
      classify_text_substitutions "$body"
    fi
  fi

  case "$cmd_base" in
    cd | pushd | popd)
      context_ambiguous=true
      return 0
      ;;
    alias | unalias)
      # An alias body runs later, under a name this hook cannot follow back to
      # its definition. Record the names that route to git rather than
      # refusing every definition: defining one and never calling it is
      # harmless, and calling one is what matters.
      definition_seen=true
      i="$start"
      while [ "$i" -lt "$count" ]; do
        lit="$(word_text "$i")"
        case "$lit" in
          [A-Za-z_]*=*)
            if names_git_push "${lit#*=}"; then
              remember_push_routing_name "${lit%%=*}" "${lit#*=}"
            fi
            ;;
        esac
        i=$((i + 1))
      done
      return 0
      ;;
    eval | trap)
      context_ambiguous=true
      i="$start"
      while [ "$i" -lt "$count" ]; do
        case "$(word_text "$i")" in
          -*)
            i=$((i + 1))
            continue
            ;;
        esac
        payload_flags="${seg_flags[$i]}"
        payload="$(word_text "$i")"
        case "$payload_flags" in
          *d* | *g*)
            if mentions_any_push_token "$payload"; then
              refuse "\`$cmd_base\` runs a string assembled at runtime, so what it runs cannot be checked"
            fi
            ;;
          *) classify_payload "$payload" "nested" ;;
        esac
        break
      done
      return 0
      ;;
    source | .)
      context_ambiguous=true
      if [ "$has_bypass" = "true" ]; then
        refuse "\`$cmd_base\` executes a file this hook cannot read, and the call carries \`$bypass_spelling\`"
      fi
      return 0
      ;;
  esac

  # An alias defined in this call is a protected push when the call supplies
  # the bypass flag, and also when the alias body already carries one — then
  # the invocation needs no flag of its own.
  if value="$(push_routing_value "$cmd_base")"; then
    if [ "$has_bypass" = "true" ]; then
      refuse "\`$cmd_base\` was defined in this call as an alias for \`$value\`, and the call carries \`$bypass_spelling\`"
    fi
    while IFS= read -r name; do
      if is_bypass_flag "$name"; then
        refuse "\`$cmd_base\` was defined in this call as an alias for \`$value\`, which already carries \`$name\`"
      fi
    done <<<"$(printf '%s' "$value" | tr " $TAB" '\n\n')"
  fi

  # An interpreter invoked with -c carries its argument as code wherever it
  # sits in the segment: `xargs -I{} sh -c '…'` is the same payload as
  # `sh -c '…'`, and `su user -c '…'` is one too.
  i="$start"
  while [ "$i" -lt "$count" ]; do
    lit="$(word_text "$i")"
    name="$(word_text "$((i - 1))")"
    if { word_is_interpreter "$name" || word_is_foreign_context "$name"; } \
      && [ "${lit#-}" != "$lit" ] && [ "${lit%c}" != "$lit" ] \
      && [ "$((i + 1))" -lt "$count" ]; then
      payload_flags="${seg_flags[$((i + 1))]}"
      payload="$(word_text "$((i + 1))")"
      payload_consumed=true
      case "$payload_flags" in
        *d* | *g*)
          if mentions_any_push_token "$payload"; then
            refuse "\`$name $lit\` runs a string assembled at runtime, so what it runs cannot be checked"
          fi
          ;;
        *) classify_payload "$payload" "nested" ;;
      esac
      break
    fi
    i=$((i + 1))
  done

  if word_is_git "$cmd"; then
    record_git_config_alias "$start" "$count"
    classify_git "$cmd" "$start" "$count" "$has_bypass" "$bypass_spelling" "$context"
    return 0
  fi

  # A command word this command assigned itself is a stated fact, not a guess.
  # A single word replaces the command word and classification continues, so
  # `GIT=git; $GIT push --no-verify` is still read as the push it is. A value
  # with spaces is a whole command list of its own.
  if value="$(word_known_value "$((start - 1))")"; then
    resolved_expansion_used=true
    case "$value" in
      *[[:space:]]*)
        classify_payload "$value" "nested"
        return 0
        ;;
      *)
        cmd="$value"
        cmd_base="${cmd##*/}"
        cmd_flags="-"
        if word_is_git "$cmd"; then
          record_git_config_alias "$start" "$count"
          classify_git "$cmd" "$start" "$count" "$has_bypass" "$bypass_spelling" "$context"
          return 0
        fi
        ;;
    esac
  fi

  if is_spliced_protected_push "$cmd_flags" "$cmd"; then
    refuse "the command word is spliced together by expansions and still spells a protected push (\`$cmd\`)"
  fi

  # A command word this hook cannot see the value of, in a call that carries a
  # bypass flag, is the hidden-executable shape: `"$GIT" push --no-verify`.
  # There is no visible `git` to key on, which is exactly the point.
  if [ "$has_bypass" = "true" ]; then
    case "$cmd_flags" in
      *d* | *g*)
        refuse "the command word is built by expansion and this call carries \`$bypass_spelling\`, so what it runs cannot be checked"
        ;;
    esac
  fi

  # An interpreter handed a file cannot be read from here. Refuse only when
  # the call also carries git push text — which is the shape of writing a
  # script and running it in the same call.
  if word_is_interpreter "$cmd" && [ "$payload_consumed" = "false" ]; then
    i="$start"
    while [ "$i" -lt "$count" ]; do
      case "$(word_text "$i")" in
        -*) ;;
        *) file_argument=true ;;
      esac
      i=$((i + 1))
    done
    if [ "$file_argument" = "true" ] && [ "$command_names_git_push" = "true" ]; then
      refuse "\`$cmd\` runs a file this hook cannot read, and this call also writes git push text"
    fi
  fi

  if word_is_foreign_interpreter "$cmd"; then
    i="$start"
    while [ "$i" -lt "$count" ]; do
      if names_git_push "$(word_text "$i")"; then
        refuse "\`$cmd\` is given a program in a language this hook does not read, and that program names a git push"
      fi
      i=$((i + 1))
    done
  fi

  if [ "$has_bypass" = "true" ] && [ "$segment_names_git" = "true" ]; then
    # Name the command word and the flag that were actually read. This hook
    # says nothing about a push it did not see: what it saw is a bypass flag
    # handed to something other than git, and what it cannot tell is where
    # that flag ends up.
    refuse "\`$cmd\` is not a git invocation, but this call carries \`$bypass_spelling\` alongside git, so where that flag ends up cannot be checked; invoke git directly"
  fi
  if word_is_foreign_context "$cmd" && [ "$segment_names_git" = "true" ]; then
    refuse "\`$cmd\` runs git as another identity, host, or root, whose alias and config context this hook cannot inspect"
  fi
  return 0
}

# Only the command substitutions inside a text are code; the surrounding
# characters are the data the consumer will write out.
classify_text_substitutions() {
  local text="$1"
  local saved_kind=() saved_a=() saved_b=() saved_c=() saved_index=0 saved_count=0

  payload_depth=$((payload_depth + 1))
  if [ "$payload_depth" -gt 4 ]; then
    refuse "the call nests executable payloads deeper than this hook will follow"
  fi
  saved_kind=(${tk_kind[@]+"${tk_kind[@]}"})
  saved_a=(${tk_a[@]+"${tk_a[@]}"})
  saved_b=(${tk_b[@]+"${tk_b[@]}"})
  saved_c=(${tk_c[@]+"${tk_c[@]}"})
  saved_index="$tk_index"
  saved_count="$tk_count"

  load_tokens "$text"
  walk "nested" "substitutions"

  tk_kind=(${saved_kind[@]+"${saved_kind[@]}"})
  tk_a=(${saved_a[@]+"${saved_a[@]}"})
  tk_b=(${saved_b[@]+"${saved_b[@]}"})
  tk_c=(${saved_c[@]+"${saved_c[@]}"})
  tk_index="$saved_index"
  tk_count="$saved_count"
  payload_depth=$((payload_depth - 1))
  return 0
}

# Does the rest of this pipeline name git, or run an interpreter? An upstream
# segment can hand a bypass flag or a script to a downstream one.
pipeline_lookahead() {
  local i="$tk_index" saw_git=false saw_interpreter=false first=true
  while [ "$i" -lt "$tk_count" ]; do
    case "${tk_kind[$i]}" in
      OP)
        case "${tk_a[$i]}" in
          '|') first=true ;;
          *) break ;;
        esac
        ;;
      W | RT)
        case "$(decode "${tk_b[$i]}")" in *git*) saw_git=true ;; esac
        if [ "$first" = "true" ]; then
          if word_is_interpreter "$(decode "${tk_b[$i]}")"; then
            saw_interpreter=true
          fi
          first=false
        fi
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s %s' "$saw_git" "$saw_interpreter"
}

walk() {
  local context="$1" mode="$2"
  local seg="" heredocs="" herestring="" redirection="" word_count=0
  local k="" a="" b="" c="" pipe_git=false pipe_interpreter=false look=""

  while [ "$tk_index" -lt "$tk_count" ]; do
    k="${tk_kind[$tk_index]}"
    a="${tk_a[$tk_index]}"
    b="${tk_b[$tk_index]}"
    c="${tk_c[$tk_index]}"
    tk_index=$((tk_index + 1))
    case "$k" in
      W)
        # Same tagging as the token stream, for the same reason.
        seg="$seg$a${TAB}L$b${TAB}V$c
"
        word_count=$((word_count + 1))
        ;;
      RT)
        if [ "$redirection" = "<<<" ]; then
          herestring="$b"
        fi
        redirection=""
        ;;
      R) redirection="$a" ;;
      HD)
        heredocs="$heredocs$a$TAB$b
"
        ;;
      SUB)
        if [ "$a" = "open" ]; then
          # A substitution's contents are code in every mode, including the
          # substitutions-only walk of an unquoted heredoc body.
          walk "nested" "all"
        else
          if [ "$mode" = "all" ]; then
            classify_segment "$seg" "$heredocs" "$herestring" "$context" false false
          fi
          return 0
        fi
        ;;
      ERR) refuse "$a left the shapes this hook can read" ;;
      OP)
        if [ "$a" = "(" ]; then
          if [ "$word_count" -eq 1 ]; then
            # `name ()` opens a function definition, it does not call one.
            definition_seen=true
          elif [ "$word_count" -eq 0 ]; then
            context_ambiguous=true
          fi
        fi
        pipe_git=false
        pipe_interpreter=false
        if [ "$a" = "|" ]; then
          look="$(pipeline_lookahead)"
          pipe_git="${look%% *}"
          pipe_interpreter="${look##* }"
        fi
        if [ "$mode" = "all" ]; then
          classify_segment "$seg" "$heredocs" "$herestring" "$context" \
            "$pipe_git" "$pipe_interpreter"
        fi
        seg=""
        heredocs=""
        herestring=""
        word_count=0
        ;;
    esac
  done
  if [ "$mode" = "all" ]; then
    classify_segment "$seg" "$heredocs" "$herestring" "$context" false false
  fi
  return 0
}

# Does the call anywhere carry the text of a git push? Used only to decide
# whether an unreadable script is worth refusing, never on its own.
command_names_git_push=false
if names_git_push "$command"; then
  command_names_git_push=true
fi

# A repository redirection inherited from the environment is just as real as
# one written in the command, and the audit would name the wrong repository.
if [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ] || [ -n "${GIT_COMMON_DIR:-}" ]; then
  context_ambiguous=true
fi

load_tokens "$command"
walk "direct" "all"

# ------------------------------------------------------------------ the answer
if [ "$push_count" -eq 0 ]; then
  exit 0
fi

if [ "$push_count" -gt 1 ]; then
  echo "emergency-disclosure: this call runs $push_count protected pushes; run them as separate audited calls" >&2
  exit 2
fi

if [ "${TOUCHSTONE_EMERGENCY:-0}" != "1" ]; then
  cat >&2 <<EOF
==> Blocked by Touchstone emergency-disclosure: $push_description

  $BYPASS_FLAG bypasses pre-push hooks (default-branch checks).
  Routine pushes should not bypass these.

  This is the documented emergency path. To use it:
    1. Set TOUCHSTONE_EMERGENCY=1 in the environment for this push.
    2. The next PR you open MUST include an "Emergency-bypass disclosure"
       section explaining what was bypassed and why.

  See principles/git-workflow.md ("Emergency path").
EOF
  exit 2
fi

if [ "$push_authorizable" != "true" ]; then
  echo "emergency-disclosure: the emergency path audits a push in this call's own working directory, and this call wraps the push in a directory change, a definition, or another execution context — so the repository it would push cannot be resolved. Run the push on its own." >&2
  exit 2
fi

if [ ! -d "$cwd" ]; then
  echo "emergency-disclosure: cannot record the emergency bypass: working directory does not exist: $cwd" >&2
  exit 2
fi
audit_repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$audit_repo" ]; then
  echo "emergency-disclosure: cannot resolve the repository from '$cwd'; bypass blocked" >&2
  exit 2
fi

# Audit persistence is part of the authorization, not a side effect of it.
log_dir="$audit_repo/.touchstone"
log_file="$log_dir/emergency-bypass.log"
if ! mkdir -p "$log_dir"; then
  echo "emergency-disclosure: cannot create the emergency audit directory: $log_dir" >&2
  exit 2
fi
if ! printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$command" >>"$log_file"; then
  echo "emergency-disclosure: cannot append the emergency audit log: $log_file" >&2
  exit 2
fi

echo "emergency-disclosure: TOUCHSTONE_EMERGENCY=1 — push allowed; logged to .touchstone/emergency-bypass.log for next-PR disclosure" >&2
exit 0
