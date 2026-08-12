#!/usr/bin/env bash
#
# tests/test-emergency-corpus.sh — differential corpus for the
# emergency-disclosure PreToolUse guard (issue #507).
#
# Every fixture in tests/fixtures/emergency-corpus.txt is evaluated twice:
#
#   1. Real Bash executes it with a fake `git` first on PATH. The fake
#      records protected pushes (subcommand resolving to push, plus a
#      bypass flag) and the repository they would target. It never
#      contacts a remote and never runs a real push.
#   2. The guard inspects the same command through the PreToolUse hook
#      protocol.
#
# The oracle is execution, not a parser's opinion. That matters because the
# guard this corpus was built for is known to be wrong on some shapes: a
# fixture whose corpus verdict is `allow` but which really executes a
# protected push is a corpus bug and fails hard, so the corpus cannot drift
# into blessing a false negative.
#
# Modes:
#   (no args)   assert every corpus verdict; fail on any mismatch
#   --report    print a TSV table (label, oracle pushes, oracle repo,
#               unauthorized exit, authorized exit, verdict) and exit 0.
#               Used to record a baseline before changing the guard.
#   --guard P   evaluate an alternative guard implementation at path P
#
# shellcheck disable=SC2016
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$TOUCHSTONE_ROOT/scripts/emergency-disclosure.sh"
HOOK_MIRROR="$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh"
CORPUS="$TOUCHSTONE_ROOT/tests/fixtures/emergency-corpus.txt"
REPORT_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      REPORT_ONLY=1
      shift
      ;;
    --guard)
      GUARD="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--report] [--guard PATH]" >&2
      exit 64
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "==> SKIP: jq not installed"
  exit 0
fi

REAL_GIT="$(command -v git)"
TEST_ROOT="$(mktemp -d -t touchstone-emergency-corpus.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"

REPO_A="$TEST_ROOT/repo-a"
REPO_B="$TEST_ROOT/repo b"
FAKE_BIN="$TEST_ROOT/fake-bin"
ORACLE_LOG="$TEST_ROOT/oracle.log"
mkdir -p "$REPO_A" "$REPO_B" "$FAKE_BIN"

init_repo() {
  local repo="$1"
  "$REAL_GIT" -C "$repo" init --quiet --initial-branch=main
  "$REAL_GIT" -C "$repo" config user.email "test@touchstone.test"
  "$REAL_GIT" -C "$repo" config user.name "Touchstone Test"
  "$REAL_GIT" -C "$repo" config alias.p push
  : >"$repo/file.txt"
  "$REAL_GIT" -C "$repo" add file.txt
  "$REAL_GIT" -C "$repo" commit --quiet -m init
}
init_repo "$REPO_A"
init_repo "$REPO_B"
# Pathname expansion fixture: `git push --no-*` must glob to a real file.
touch "$REPO_A/--no-verify"

# The only `git` visible to oracle commands. It emulates just enough global
# option and alias handling to identify the protected operation, then exits.
cat >"$FAKE_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

target="$PWD"
subcommand=""
command_alias=""
bypass=0
args=("$@")
index=0

if [ "${GIT_CONFIG_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  config_index=0
  while [ "$config_index" -lt "$GIT_CONFIG_COUNT" ]; do
    key_name="GIT_CONFIG_KEY_$config_index"
    value_name="GIT_CONFIG_VALUE_$config_index"
    config_key="${!key_name:-}"
    config_value="${!value_name:-}"
    case "$config_key=$config_value" in
      alias.*=push)
        command_alias="${config_key#alias.}"
        ;;
    esac
    config_index=$((config_index + 1))
  done
fi

while [ "$index" -lt "${#args[@]}" ]; do
  word="${args[$index]}"
  case "$word" in
    -C)
      index=$((index + 1))
      [ "$index" -lt "${#args[@]}" ] || exit 0
      candidate="${args[$index]}"
      if [[ "$candidate" = /* ]]; then
        target="$candidate"
      else
        target="$target/$candidate"
      fi
      ;;
    -c)
      index=$((index + 1))
      [ "$index" -lt "${#args[@]}" ] || exit 0
      case "${args[$index]}" in
        alias.*=push*)
          command_alias="${args[$index]#alias.}"
          command_alias="${command_alias%%=*}"
          case "${args[$index]}" in
            *--no-verify* | *--no-verif | *--no-veri) bypass=1 ;;
          esac
          ;;
      esac
      ;;
    --config-env=alias.*=*)
      config_spec="${word#--config-env=}"
      config_key="${config_spec%%=*}"
      env_name="${config_spec#*=}"
      if [ "${!env_name:-}" = "push" ]; then
        command_alias="${config_key#alias.}"
      fi
      ;;
    --no-pager | -P | --paginate | -p | --no-replace-objects | --literal-pathspecs | --no-literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs)
      ;;
    --*)
      ;;
    *)
      subcommand="$word"
      index=$((index + 1))
      break
      ;;
  esac
  index=$((index + 1))
done

if [ "$subcommand" = "p" ]; then
  subcommand="push"
fi
if [ -n "$command_alias" ] && [ "$subcommand" = "$command_alias" ]; then
  subcommand="push"
fi

while [ "$index" -lt "${#args[@]}" ]; do
  case "${args[$index]}" in
    --no-veri | --no-verif | --no-verify) bypass=1 ;;
  esac
  index=$((index + 1))
done

if [ "$subcommand" = "push" ] && [ "$bypass" -eq 1 ]; then
  root="$("$REAL_GIT" -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  printf '%s\t%s\n' "$PWD" "$root" >>"$ORACLE_LOG"
fi
exit 0
FAKE_GIT

# Wrapper shims keep wrapper fixtures deterministic and prevent privilege
# changes, process detachment, or host-specific option behavior.
printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"$FAKE_BIN/sudo"
printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"$FAKE_BIN/nohup"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$FAKE_BIN/gh"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "-n" ]; then shift 2; fi' 'exec "$@"' >"$FAKE_BIN/nice"
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/sudo" "$FAKE_BIN/nohup" "$FAKE_BIN/gh" "$FAKE_BIN/nice"

# ---------------------------------------------------------------- corpus load
labels=()
commands=()
expects=()
homes=()

load_corpus() {
  local line="" label="" home="" expect="" body="" in_case=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '%%CASE '*)
        label="${line#\%\%CASE }"
        home="repo-a"
        expect=""
        body=""
        in_case=1
        continue
        ;;
      '%%HOME '*)
        [ "$in_case" -eq 1 ] || continue
        home="${line#\%\%HOME }"
        continue
        ;;
      '%%EXPECT '*)
        [ "$in_case" -eq 1 ] || continue
        expect="${line#\%\%EXPECT }"
        continue
        ;;
      '%%END')
        [ "$in_case" -eq 1 ] || continue
        labels[${#labels[@]}]="$label"
        commands[${#commands[@]}]="$body"
        expects[${#expects[@]}]="$expect"
        homes[${#homes[@]}]="$home"
        in_case=0
        continue
        ;;
    esac
    if [ "$in_case" -eq 1 ]; then
      if [ -z "$body" ]; then
        body="$line"
      else
        body="$body
$line"
      fi
    fi
  done <"$CORPUS"
}
load_corpus

# 96 KiB of inert filler, comfortably past the 64 KiB pipe buffer. A guard that
# tests its input with `producer | grep -q` returns 141 on a MATCH at this size
# — grep exits first and the producer takes SIGPIPE — so a matched hostile
# pattern reads as unmatched and the guard fails open. Small fixtures finish
# writing before grep exits, which is why the whole class stayed invisible
# (issue #806).
FILLER="$(awk 'BEGIN { s = ""; while (length(s) < 98304) s = s "filler-text-padding "; print s }')"

substitute() {
  # Placeholders are literal in the corpus so the data file never depends on
  # shell expansion order.
  local text="$1"
  text="${text//%REPO_A%/$REPO_A}"
  text="${text//%REPO_B%/$REPO_B}"
  text="${text//%TEST_ROOT%/$TEST_ROOT}"
  text="${text//%FILLER%/$FILLER}"
  printf '%s' "$text"
}

# ------------------------------------------------------------------ execution
hook_payload() {
  jq -nc --arg command "$1" --arg cwd "$REPO_A" \
    '{tool_name: "Bash", tool_input: {command: $command}, cwd: $cwd}'
}

run_guard() {
  local command="$1" authorized="$2" fixture_home="$3" exit_code=0
  if [ "$authorized" = "1" ]; then
    hook_payload "$command" \
      | HOME="$fixture_home" GIT=git TOUCHSTONE_EMERGENCY=1 bash "$GUARD" \
        >/dev/null 2>"$TEST_ROOT/guard-err.txt" || exit_code=$?
  else
    hook_payload "$command" \
      | HOME="$fixture_home" GIT=git bash "$GUARD" \
        >/dev/null 2>"$TEST_ROOT/guard-err.txt" || exit_code=$?
  fi
  printf '%s' "$exit_code"
}

run_oracle() {
  local command="$1" fixture_home="$2" exit_code=0
  : >"$ORACLE_LOG"
  (
    cd "$REPO_A" || exit 1
    PATH="$FAKE_BIN:/usr/bin:/bin" \
      HOME="$fixture_home" \
      REAL_GIT="$REAL_GIT" \
      ORACLE_LOG="$ORACLE_LOG" \
      GIT=git \
      bash --noprofile --norc -c "$command"
  ) >/dev/null 2>&1 || exit_code=$?
  printf '%s' "$exit_code"
}

PASS=0
FAIL=0
fail_case() {
  echo "  FAIL: $1: $2" >&2
  FAIL=$((FAIL + 1))
}

if [ "$REPORT_ONLY" -eq 1 ]; then
  printf 'label\toracle_pushes\toracle_repo\tunauth_exit\tauth_exit\tverdict\n'
fi

index=0
while [ "$index" -lt "${#labels[@]}" ]; do
  label="${labels[$index]}"
  expect="${expects[$index]}"
  command="$(substitute "${commands[$index]}")"
  fixture_home="$REPO_A"
  [ "${homes[$index]}" = "repo-b" ] && fixture_home="$REPO_B"
  index=$((index + 1))

  rm -rf "$REPO_A/.touchstone" "$REPO_B/.touchstone"
  run_oracle "$command" "$fixture_home" >/dev/null
  oracle_pushes="$(wc -l <"$ORACLE_LOG" | tr -d ' ')"
  oracle_repo="-"
  if [ "$oracle_pushes" -eq 1 ]; then
    oracle_repo="$(cut -f2 "$ORACLE_LOG")"
    case "$oracle_repo" in
      "$REPO_A") oracle_repo="repo-a" ;;
      "$REPO_B") oracle_repo="repo-b" ;;
      "") oracle_repo="none" ;;
    esac
  elif [ "$oracle_pushes" -gt 1 ]; then
    oracle_repo="multi"
  fi

  unauth_exit="$(run_guard "$command" 0 "$fixture_home")"
  auth_exit="$(run_guard "$command" 1 "$fixture_home")"

  verdict="allow"
  [ "$unauth_exit" -ne 0 ] && verdict="block"

  if [ "$REPORT_ONLY" -eq 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$oracle_pushes" "$oracle_repo" "$unauth_exit" "$auth_exit" "$verdict"
    continue
  fi

  if [ -z "$expect" ]; then
    fail_case "$label" "corpus record has no %%EXPECT verdict"
    continue
  fi

  # A corpus that claims `allow` for a command Bash really pushes with would
  # bless a false negative. That is a corpus bug, and it fails hard.
  if [ "$expect" = "allow" ] && [ "$oracle_pushes" -gt 0 ]; then
    fail_case "$label" \
      "corpus says allow but Bash executed $oracle_pushes protected push(es)"
    continue
  fi

  if [ "$expect" = "block" ] && [ "$unauth_exit" -ne 2 ]; then
    fail_case "$label" "expected block (exit 2), guard exited $unauth_exit"
    continue
  fi
  if [ "$expect" = "allow" ] && [ "$unauth_exit" -ne 0 ]; then
    fail_case "$label" "expected allow (exit 0), guard exited $unauth_exit"
    sed 's/^/        /' "$TEST_ROOT/guard-err.txt" >&2
    continue
  fi
  if [ "$expect" = "allow" ] && [ "$auth_exit" -ne 0 ]; then
    fail_case "$label" \
      "expected allow under TOUCHSTONE_EMERGENCY=1, guard exited $auth_exit"
    continue
  fi
  PASS=$((PASS + 1))
done

if [ "$REPORT_ONLY" -eq 1 ]; then
  exit 0
fi

if cmp -s "$GUARD" "$HOOK_MIRROR"; then
  PASS=$((PASS + 1))
else
  fail_case "hook-mirror" "hooks/emergency-disclosure.sh differs from scripts/"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "==> FAIL: $FAIL of $((PASS + FAIL)) emergency corpus checks failed" >&2
  exit 1
fi
echo "==> PASS: all $PASS emergency corpus checks passed"
