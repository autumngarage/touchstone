#!/usr/bin/env bash
#
# Differential guardrail for emergency-disclosure shell parsing.
#
# Each fixture is evaluated twice:
#   1. Real Bash executes it with a fake `git` first on PATH. The fake records
#      protected pushes and their resolved repository but never contacts a
#      remote or invokes `git push`.
#   2. The emergency-disclosure hook inspects the same command.
#
# The invariant is based on execution, not parser expectations: every protected
# push observed by Bash must be blocked without authorization. Authorized
# commands either write evidence to the observed repository or, when explicitly
# classified as structurally ambiguous, fail closed.
#
# Shell snippets are intentionally single-quoted so this harness does not
# expand them before the isolated Bash oracle does.
# shellcheck disable=SC2016
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh"
SCRIPT_MIRROR="$TOUCHSTONE_ROOT/scripts/emergency-disclosure.sh"
REAL_GIT="$(command -v git)"

if ! command -v jq >/dev/null 2>&1; then
	echo "==> SKIP: jq not installed"
	exit 0
fi

TEST_ROOT="$(mktemp -d -t touchstone-emergency-differential.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO_A="$TEST_ROOT/repo-a"
REPO_B="$TEST_ROOT/repo b"
FAKE_BIN="$TEST_ROOT/fake-bin"
ORACLE_LOG="$TEST_ROOT/oracle.log"
mkdir -p "$REPO_A" "$REPO_B" "$FAKE_BIN"
REPO_A="$(cd "$REPO_A" && pwd -P)"
REPO_B="$(cd "$REPO_B" && pwd -P)"

init_repo() {
	local repo="$1"
	"$REAL_GIT" -C "$repo" init --quiet --initial-branch=main
	"$REAL_GIT" -C "$repo" config user.email "test@touchstone.test"
	"$REAL_GIT" -C "$repo" config user.name "Touchstone Test"
	"$REAL_GIT" -C "$repo" config alias.p push
}
init_repo "$REPO_A"
init_repo "$REPO_B"

# This is the only `git` visible to oracle commands. It emulates enough global
# option and alias handling to identify the protected operation, then exits.
cat >"$FAKE_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

target="$PWD"
subcommand=""
bypass=0
args=("$@")
index=0

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
      ;;
    --no-pager|-P|--paginate|-p|--no-replace-objects|--literal-pathspecs|--no-literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
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

while [ "$index" -lt "${#args[@]}" ]; do
  [ "${args[$index]}" = "--no-verify" ] && bypass=1
  index=$((index + 1))
done

if [ "$subcommand" = "push" ] && [ "$bypass" -eq 1 ]; then
  root="$("$REAL_GIT" -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  printf '%s\t%s\n' "$PWD" "$root" >>"$ORACLE_LOG"
fi
exit 0
FAKE_GIT
chmod +x "$FAKE_BIN/git"

# Wrapper shims keep historical wrapper fixtures deterministic and prevent
# privilege changes, process detachment, or host-specific option behavior.
cat >"$FAKE_BIN/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
exec "$@"
FAKE_SUDO
cat >"$FAKE_BIN/nohup" <<'FAKE_NOHUP'
#!/usr/bin/env bash
exec "$@"
FAKE_NOHUP
cat >"$FAKE_BIN/nice" <<'FAKE_NICE'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then
  shift 2
fi
exec "$@"
FAKE_NICE
chmod +x "$FAKE_BIN/sudo" "$FAKE_BIN/nohup" "$FAKE_BIN/nice"

PASS=0
FAIL=0
CASE_COUNT=0

hook_payload() {
	local command="$1"
	jq -nc \
		--arg command "$command" \
		--arg cwd "$REPO_A" \
		'{tool_name: "Bash", tool_input: {command: $command}, cwd: $cwd}'
}

run_hook() {
	local command="$1" authorized="$2" exit_code=0
	if [ "$authorized" = "1" ]; then
		printf '%s' "$(hook_payload "$command")" |
			GIT=git TOUCHSTONE_EMERGENCY=1 bash "$HOOK" >/dev/null 2>&1 ||
			exit_code=$?
	else
		printf '%s' "$(hook_payload "$command")" |
			GIT=git bash "$HOOK" >/dev/null 2>&1 ||
			exit_code=$?
	fi
	printf '%s' "$exit_code"
}

run_oracle() {
	local command="$1" exit_code=0
	: >"$ORACLE_LOG"
	(
		cd "$REPO_A"
		PATH="$FAKE_BIN:/usr/bin:/bin" \
			REAL_GIT="$REAL_GIT" \
			ORACLE_LOG="$ORACLE_LOG" \
			GIT=git \
			bash --noprofile --norc -c "$command"
	) >/dev/null 2>&1 || exit_code=$?
	printf '%s' "$exit_code"
}

record_failure() {
	local name="$1" detail="$2" command="$3"
	echo "  FAIL: $name: $detail" >&2
	printf '        command: %q\n' "$command" >&2
	FAIL=$((FAIL + 1))
}

assert_case() {
	local name="$1" classification="$2" command="$3"
	local oracle_exit oracle_count observed_root unauthorized_exit authorized_exit
	local expected_root="" audit_a=0 audit_b=0

	CASE_COUNT=$((CASE_COUNT + 1))
	rm -rf "$REPO_A/.touchstone" "$REPO_B/.touchstone"
	oracle_exit="$(run_oracle "$command")"
	oracle_count="$(wc -l <"$ORACLE_LOG" | tr -d ' ')"
	observed_root=""
	if [ "$oracle_count" -eq 1 ]; then
		observed_root="$(cut -f2 "$ORACLE_LOG")"
	fi

	case "$classification" in
	none)
		if [ "$oracle_count" -ne 0 ]; then
			record_failure "$name" "fixture classified non-executing but Bash observed $oracle_count protected push(es)" "$command"
			return
		fi
		;;
	repo-a)
		expected_root="$REPO_A"
		;;
	repo-b)
		expected_root="$REPO_B"
		;;
	ambiguous)
		if [ "$oracle_count" -eq 0 ]; then
			record_failure "$name" "ambiguous fixture did not execute a protected push" "$command"
			return
		fi
		;;
	*)
		record_failure "$name" "unknown classification '$classification'" "$command"
		return
		;;
	esac

	if [ -n "$expected_root" ]; then
		if [ "$oracle_count" -ne 1 ] || [ "$observed_root" != "$expected_root" ]; then
			record_failure "$name" "Bash oracle expected one push in '$expected_root', observed count=$oracle_count root='$observed_root' (exit $oracle_exit)" "$command"
			return
		fi
	elif [ "$classification" = "none" ] && [ "$oracle_exit" -ne 0 ]; then
		record_failure "$name" "non-executing fixture failed under Bash with exit $oracle_exit" "$command"
		return
	fi

	unauthorized_exit="$(run_hook "$command" 0)"
	if [ "$oracle_count" -gt 0 ]; then
		if [ "$unauthorized_exit" -ne 2 ]; then
			record_failure "$name" "Bash executed a protected push but unauthorized hook exited $unauthorized_exit" "$command"
			return
		fi
	elif [ "$unauthorized_exit" -ne 0 ]; then
		record_failure "$name" "Bash executed no protected push but hook exited $unauthorized_exit" "$command"
		return
	fi

	authorized_exit="$(run_hook "$command" 1)"
	[ -f "$REPO_A/.touchstone/emergency-bypass.log" ] && audit_a=1
	[ -f "$REPO_B/.touchstone/emergency-bypass.log" ] && audit_b=1

	if [ "$classification" = "ambiguous" ]; then
		if [ "$authorized_exit" -ne 2 ] || [ "$audit_a" -ne 0 ] || [ "$audit_b" -ne 0 ]; then
			record_failure "$name" "ambiguous authorized push must fail closed without audit (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
			return
		fi
	elif [ "$classification" = "none" ]; then
		if [ "$authorized_exit" -ne 0 ] || [ "$audit_a" -ne 0 ] || [ "$audit_b" -ne 0 ]; then
			record_failure "$name" "non-executing fixture must pass without audit (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
			return
		fi
	elif [ "$expected_root" = "$REPO_A" ]; then
		if [ "$authorized_exit" -ne 0 ] || [ "$audit_a" -ne 1 ] || [ "$audit_b" -ne 0 ]; then
			record_failure "$name" "authorized push must audit repo-a only (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
			return
		fi
	elif [ "$expected_root" = "$REPO_B" ]; then
		if [ "$authorized_exit" -ne 0 ] || [ "$audit_a" -ne 0 ] || [ "$audit_b" -ne 1 ]; then
			record_failure "$name" "authorized push must audit repo-b only (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
			return
		fi
	fi

	echo "  OK: $name"
	PASS=$((PASS + 1))
}

echo "==> Named PR #492 review reproductions"

assert_case "compound-if-condition" repo-a \
	"if git push --no-verify origin main; then printf ok; fi"
assert_case "time-prefix" repo-a \
	"time -p git push --no-verify origin main"
assert_case "command-substitution" ambiguous \
	'printf "%s" "$(git push --no-verify origin main)"'
assert_case "shell-c-payload" ambiguous \
	"bash -c 'git push --no-verify origin main'"
assert_case "invoked-function" ambiguous \
	"push_now() { git push --no-verify origin main; }; push_now"
assert_case "sudo-wrapper" repo-a \
	"sudo git push --no-verify origin main"
assert_case "nice-wrapper" repo-a \
	"nice -n 5 git push --no-verify origin main"
assert_case "nohup-wrapper" repo-a \
	"nohup git push --no-verify origin main"
assert_case "git-global-option" repo-a \
	"git --no-pager push --no-verify origin main"
assert_case "quoted-git-c" repo-b \
	"git -C \"$REPO_B\" push --no-verify origin main"
assert_case "preceding-direct-cd" repo-b \
	"cd \"$REPO_B\" && git push --no-verify origin main"
assert_case "subshell-cd-before-outer-push" ambiguous \
	"(cd \"$REPO_B\" && git status); git push --no-verify origin main"
assert_case "nested-substitution-cd" ambiguous \
	"printf '%s' \$(cd \"$REPO_B\" && git push --no-verify origin main)"
assert_case "wrapped-shell-payload" ambiguous \
	"sudo bash -c 'git push --no-verify origin main'"
line_continuation="git \\"
line_continuation+=$'\n'
line_continuation+="push --no-verify origin main"
assert_case "line-continuation" repo-a "$line_continuation"
assert_case "apostrophe-in-double-quotes" ambiguous \
	'printf "%s" "it'\''s $(git push --no-verify origin main)"'
assert_case "nested-command-substitutions" ambiguous \
	'printf "%s" "$(printf "%s" "$(date)"; git push --no-verify origin main)"'
assert_case "scoped-cd-before-outer-push" ambiguous \
	"(printf prep; cd \"$REPO_B\"; printf done); git push --no-verify origin main"
assert_case "expanded-bypass-flag" ambiguous \
	'flag=--no-verify; git push "$flag" origin main'
assert_case "command-local-cdpath" ambiguous \
	"CDPATH=\"$TEST_ROOT\"; cd \"repo b\" && git push --no-verify origin main"
assert_case "expanded-git-command" ambiguous \
	'cmd=git; "$cmd" push --no-verify origin main'
assert_case "expanded-push-subcommand" ambiguous \
	'sub=push; git "$sub" --no-verify origin main'
assert_case "dynamic-git-environment" ambiguous \
	'"$GIT" push --no-verify origin main'
assert_case "skipped-cd-before-push" ambiguous \
	"false && cd \"$REPO_B\"; git push --no-verify origin main"
assert_case "literal-quoted-heredoc" none \
	"$(printf '%s\n' "cat >/dev/null <<'EOF'" "git push --no-verify origin main" "EOF")"
assert_case "literal-unquoted-heredoc" none \
	"$(printf '%s\n' "cat >/dev/null <<EOF" "git push --no-verify origin main" "EOF")"
assert_case "unquoted-heredoc-substitution" ambiguous \
	"$(printf '%s\n' "cat >/dev/null <<EOF" '$(git push --no-verify origin main)' "EOF")"
assert_case "parenthesized-push" ambiguous \
	"(git push --no-verify origin main)"
assert_case "commented-heredoc-lookalike" repo-a \
	"$(printf '%s\n' "# example <<EOF" "git push --no-verify origin main")"
assert_case "quoted-heredoc-lookalike" repo-a \
	"$(printf '%s\n' "printf '%s' '<<EOF'" "git push --no-verify origin main")"
assert_case "unrelated-substitution-before-push" repo-a \
	'printf "%s" "$(date)"; git push --no-verify origin main'
assert_case "arithmetic-left-shift-before-push" repo-a \
	"$(printf '%s\n' "printf '%s' \$((1 << 2))" "git push --no-verify origin main")"
assert_case "multiple-conditional-directory-chains" ambiguous \
	"cd \"$REPO_B\" && printf ok; false && cd \"$REPO_A\"; git push --no-verify origin main"
assert_case "git-push-alias" repo-a \
	"git p --no-verify origin main"
assert_case "unquoted-shell-comment" none \
	"printf ok # git push --no-verify origin main"
assert_case "command-wrapped-cd" repo-b \
	"command cd \"$REPO_B\" && git push --no-verify origin main"
assert_case "builtin-wrapped-cd" repo-b \
	"builtin cd \"$REPO_B\" && git push --no-verify origin main"

echo "==> Deterministic generated execution matrix"

matrix_prefixes=(
	""
	"command "
	"time -p "
	"sudo "
	"nice -n 1 "
	"nohup "
)
matrix_index=0
for prefix in "${matrix_prefixes[@]}"; do
	matrix_index=$((matrix_index + 1))
	assert_case "matrix-prefix-$matrix_index" repo-a \
		"${prefix}git push --no-verify origin matrix-$matrix_index"
done

matrix_index=0
for global_option in "--no-pager" "-c color.ui=false" "-C \"$REPO_B\""; do
	matrix_index=$((matrix_index + 1))
	expected="repo-a"
	# The hook detects `-c` but deliberately fails closed because its audit
	# resolver does not model config-option arity.
	[ "$matrix_index" -eq 2 ] && expected="ambiguous"
	[ "$matrix_index" -eq 3 ] && expected="repo-b"
	assert_case "matrix-global-option-$matrix_index" "$expected" \
		"git $global_option push --no-verify origin matrix-$matrix_index"
done

assert_case "matrix-control-and" repo-a \
	"true && git push --no-verify origin matrix-and"
assert_case "matrix-control-or" repo-a \
	"false || git push --no-verify origin matrix-or"
assert_case "matrix-control-group" repo-a \
	"{ git push --no-verify origin matrix-group; }"
assert_case "matrix-control-subshell" ambiguous \
	"(git push --no-verify origin matrix-subshell)"

echo "==> Deterministic false-positive matrix"

assert_case "prose-single-quoted" none \
	"printf '%s' 'git push --no-verify origin main'"
assert_case "prose-double-quoted" none \
	'printf "%s" "git push --no-verify origin main"'
assert_case "prose-comment-newline" none \
	"$(printf '%s\n' "printf ok # git push --no-verify origin stale" "printf done")"
assert_case "prose-escaped-substitution-heredoc" none \
	"$(printf '%s\n' "cat >/dev/null <<EOF" '\$(git push --no-verify origin main)' "EOF")"
assert_case "prose-quoted-substitution-heredoc" none \
	"$(printf '%s\n' "cat >/dev/null <<'EOF'" '$(git push --no-verify origin main)' "EOF")"

if cmp -s "$HOOK" "$SCRIPT_MIRROR"; then
	echo "  OK: emergency-disclosure hook mirror is byte-identical"
	PASS=$((PASS + 1))
else
	echo "  FAIL: emergency-disclosure hook mirror differs" >&2
	FAIL=$((FAIL + 1))
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
	echo "==> FAIL: $FAIL of $((PASS + FAIL)) checks failed"
	exit 1
fi
echo "==> OK: all $PASS checks passed across $CASE_COUNT differential fixtures"
