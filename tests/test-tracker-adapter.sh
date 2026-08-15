#!/usr/bin/env bash
# tests/test-tracker-adapter.sh — tracker-neutral adapter contract tests.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d -t touchstone-tracker.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ERRORS=0

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}
assert_has() { grep -qF -- "$2" "$1" || fail "expected $1 to contain: $2"; }
assert_not_has() { grep -qF -- "$2" "$1" && fail "expected $1 not to contain: $2" || true; }
assert_rc() { [ "$1" -eq "$2" ] || fail "expected rc $2, got $1"; }
assert_json() { jq -e '.schema == "touchstone.tracker/v1" and (.status == "verified" or .status == "unverifiable" or .status == "failed")' "$1" >/dev/null || fail "$1 is not a valid v1 tracker result"; }

mkdir -p "$TMP/bin" "$TMP/github" "$TMP/linear"
git -C "$TMP/github" init -q
git -C "$TMP/linear" init -q
git -C "$TMP/github" remote add origin git@github.com:autumngarage/current.git
git -C "$TMP/linear" remote add origin https://github.com/autumngarage/current.git
printf '%s\n' 'schema = 1' '' '[tracker]' 'schema = 1' 'type = "github"' \
  '' '[validation]' 'runtime = "bash"' \
  '' '[[validation.targets]]' 'name = "root"' 'path = "."' \
  '' '[[validation.tasks]]' 'name = "test"' 'target = "root"' \
  'command = "true"' 'required = true' >"$TMP/github/.touchstone.toml"
printf '%s\n' 'schema = 1' '' '[tracker]' 'schema = 1' 'type = "linear"' 'key_prefix = "AUT"' \
  '' '[validation]' 'runtime = "bash"' \
  '' '[[validation.targets]]' 'name = "root"' 'path = "."' \
  '' '[[validation.tasks]]' 'name = "test"' 'target = "root"' \
  'command = "true"' 'required = true' >"$TMP/linear/.touchstone.toml"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"
case "$1 ${2:-}" in
  "auth status") [ "${GH_MODE:-ok}" != auth_fail ] ;;
	"api user") printf '%s\n' henry ;;
  "api --paginate")
		[ "${GH_MODE:-ok}" != timeline_fail ] || exit 1
		[ "${GH_MODE:-ok}" != comment_unverified ] || exit 0
		printf '%s\n' 'https://github.com/autumngarage/current/issues/42#issuecomment-1'
		;;
  "repo view") printf '%s\n' autumngarage/current ;;
  "issue view")
		[ "${GH_MODE:-ok}" != state_fail ] || exit 1
		if printf '%s\n' "$*" | grep -q -- '--json state'; then
      if [ -f "$GH_CLOSED" ]; then printf '%s\n' CLOSED; else printf '%s\n' OPEN; fi
    elif [ -f "$GH_STATE" ]; then cat "$GH_STATE"
    fi
    ;;
  "issue edit")
    if [ "${GH_MODE:-ok}" = claim_control_error ]; then
      printf 'claim failed\rwith control\fbyte\n' >&2
      exit 1
    fi
    printf '%s\n' henry >"$GH_STATE"
    ;;
  "issue comment")
    [ "${GH_MODE:-ok}" != comment_fail ] || exit 1
    printf '%s\n' 'https://github.com/autumngarage/current/issues/42#issuecomment-1'
    ;;
  "issue close")
    [ "${GH_MODE:-ok}" != close_fail ] || exit 1
    printf '%s\n' CLOSED >"$GH_CLOSED"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_REPO="autumngarage/current" GH_CALLS="$TMP/gh-calls" GH_STATE="$TMP/gh-state" GH_CLOSED="$TMP/gh-closed"

run_adapter() {
  local output="$1"
  shift
  set +e
  bash "$ROOT/scripts/touchstone-tracker.sh" "$@" >"$output" 2>&1
  RUN_RC=$?
  set -e
}

echo "==> GitHub claim is verified only after the surviving adapter re-reads assignment"
: >"$GH_CALLS"
: >"$GH_STATE"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 0
assert_has "$TMP/out" '"schema":"touchstone.tracker/v1"'
assert_has "$TMP/out" '"status":"verified"'
assert_json "$TMP/out"
assert_has "$GH_CALLS" 'issue edit 42 --add-assignee @me'
test "$(cat "$GH_STATE")" = henry || fail "claim did not persist mocked assignment"

echo "==> authentication and failed mutations never report success"
GH_MODE=auth_fail run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 1
assert_has "$TMP/out" '"status":"failed"'
assert_not_has "$TMP/out" '"status":"verified"'
: >"$GH_STATE"
GH_MODE=claim_control_error run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 1
assert_json "$TMP/out"
assert_has "$TMP/out" 'claim failed\rwith control\u000cbyte'

echo "==> Linear claim exposes an exact MCP/API action without false verification"
run_adapter "$TMP/out" claim aut-281 --project "$TMP/linear" --json
assert_rc "$RUN_RC" 3
assert_has "$TMP/out" '"tracker":"linear"'
assert_has "$TMP/out" '"reference":"AUT-281"'
assert_has "$TMP/out" '"status":"unverifiable"'
assert_has "$TMP/out" 'assign AUT-281 to yourself'
assert_json "$TMP/out"

echo "==> wrong-tracker issue references fail with a concrete rewrite"
run_adapter "$TMP/out" claim 281 --project "$TMP/linear"
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'Use a Linear issue key such as AUT-123'
run_adapter "$TMP/out" claim AUT-281 --project "$TMP/github"
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'Use a GitHub issue number such as #123'

echo "==> fixed GitHub and Linear work require their own closing grammar"
printf '%s\n' 'Closes #42' >"$TMP/body"
run_adapter "$TMP/out" reconcile 42 --disposition fixed --body-file "$TMP/body" --project "$TMP/github" --json
assert_rc "$RUN_RC" 0
assert_has "$TMP/out" '"reason":"closing-reference-present"'
printf '%s\n' 'Fixes AUT-281' >"$TMP/body"
run_adapter "$TMP/out" reconcile AUT-281 --disposition fixed --body-file "$TMP/body" --project "$TMP/linear" --json
assert_rc "$RUN_RC" 3
assert_has "$TMP/out" '"status":"unverifiable"'
printf '%s\n' 'Fixes AUT-281.' >"$TMP/body"
run_adapter "$TMP/out" reconcile AUT-281 --disposition fixed --body-file "$TMP/body" --project "$TMP/linear" --json
assert_rc "$RUN_RC" 3
assert_not_has "$TMP/out" 'missing-closing-reference'
printf '%s\n' '[skip-claim-check]' 'Closes #281' >"$TMP/body"
run_adapter "$TMP/out" reconcile AUT-281 --disposition fixed --body-file "$TMP/body" --project "$TMP/linear"
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" "Replace 'Closes #281' with 'Fixes AUT-281'"
printf '%s\n' 'Fixes AUT-281' >"$TMP/body"
run_adapter "$TMP/out" reconcile 42 --disposition fixed --body-file "$TMP/body" --project "$TMP/github"
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" "Replace 'Fixes AUT-281' with 'Closes #42'"

echo "==> cross-repository GitHub closes remain valid in Linear projects"
printf '%s\n' 'Fixes AUT-281' 'Closes autumngarage/other#77' >"$TMP/body"
run_adapter "$TMP/out" reconcile AUT-281 --disposition fixed --body-file "$TMP/body" --project "$TMP/linear" --json
assert_rc "$RUN_RC" 3
assert_not_has "$TMP/out" 'wrong-tracker-closing-syntax'
GH_REPO='' run_adapter "$TMP/out" reconcile AUT-281 --disposition fixed --body-file "$TMP/body" --project "$TMP/linear" --json
assert_rc "$RUN_RC" 3
assert_not_has "$TMP/out" 'wrong-tracker-closing-syntax'
printf '%s\n' 'Fixes AUT-281' 'Closes autumngarage/current#77' >"$TMP/body"
run_adapter "$TMP/out" reconcile AUT-281 --disposition fixed --body-file "$TMP/body" --project "$TMP/linear"
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'qualify cross-repository GitHub closes'

echo "==> partial and stale reconciliations make partial mutation visible"
printf '%s\n' 'Refs #42' >"$TMP/body"
printf '%s\n' 'Evidence and remaining gap.' >"$TMP/note"
: >"$GH_CALLS"
run_adapter "$TMP/out" reconcile 42 --disposition partial --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 0
assert_has "$TMP/out" '"status":"verified"'
assert_has "$GH_CALLS" 'issue comment 42 --body-file'
assert_has "$GH_CALLS" 'api --paginate repos/autumngarage/current/issues/42/comments'
GH_MODE=comment_unverified run_adapter "$TMP/out" reconcile 42 --disposition partial --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 1
assert_has "$TMP/out" '"reason":"github-comment-unverified"'
assert_has "$TMP/out" '"partial":true'
GH_MODE=timeline_fail run_adapter "$TMP/out" reconcile 42 --disposition partial --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 1
assert_has "$TMP/out" '"reason":"github-comment-verification-failed"'
assert_has "$TMP/out" '"partial":true'
GH_MODE=close_fail run_adapter "$TMP/out" reconcile 42 --disposition stale --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 1
assert_has "$TMP/out" '"partial":true'
assert_has "$TMP/out" 'github-close-failed'
rm -f "$GH_CLOSED"
GH_MODE=state_fail run_adapter "$TMP/out" reconcile 42 --disposition stale --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 1
assert_has "$TMP/out" 'github-close-verification-failed'
rm -f "$GH_CLOSED"

echo "==> reconciliation evidence must contain a substantive note"
: >"$TMP/note"
run_adapter "$TMP/out" reconcile 42 --disposition partial --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'Provide a non-empty --note-file'
printf '%s\n' '   ' >"$TMP/note"
run_adapter "$TMP/out" reconcile 42 --disposition partial --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'Provide a non-empty --note-file'
printf '%s\n' 'Evidence and remaining gap.' >"$TMP/note"

echo "==> partial and stale work require non-closing PR references"
printf '%s\n' 'Summary only.' >"$TMP/body"
run_adapter "$TMP/out" reconcile 42 --disposition partial --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'Add '\''Refs #42'\'' to the PR body'
printf '%s\n' 'Refs #42' 'Closes #42' >"$TMP/body"
run_adapter "$TMP/out" reconcile 42 --disposition stale --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'Replace the closing reference for #42'

echo "==> Linear partial reconciliation names the MCP/API action and never calls gh"
: >"$GH_CALLS"
printf '%s\n' 'Refs AUT-281' >"$TMP/body"
run_adapter "$TMP/out" reconcile AUT-281 --disposition partial --body-file "$TMP/body" --note-file "$TMP/note" --project "$TMP/linear" --json
assert_rc "$RUN_RC" 3
assert_has "$TMP/out" '"status":"unverifiable"'
assert_has "$TMP/out" 'verify the issue remains open'
[ ! -s "$GH_CALLS" ] || fail "Linear reconciliation invoked the GitHub transport"

echo "==> malformed, old-compatible, and unsupported tracker declarations are explicit"
cp "$TMP/github/.touchstone.toml" "$TMP/github/config-good"
printf '%s\n' 'schema = 1' >"$TMP/github/.touchstone.toml"
sed -n '/^\[validation\]/,$p' "$TMP/github/config-good" >>"$TMP/github/.touchstone.toml"
: >"$GH_STATE"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 0
printf '%s\n' 'schema = 1' '' '[tracker]' 'type = "linear"' 'key_prefix = "AUT"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim AUT-1 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'missing-tracker-schema'
printf '%s\n' 'schema = 1' '' '[tracker]' 'schema = 2' 'type = "github"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'unsupported-tracker-schema'
printf '%s\n' '[tracker]' 'schema = 1' 'type = "github"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'missing-project-schema'
printf '%s\n' 'schema = 2' '' '[tracker]' 'schema = 1' 'type = "github"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'unsupported-project-schema'
printf '%s\n' 'schema = 1' 'schema = 1' '' '[tracker]' 'schema = 1' 'type = "github"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'duplicate-project-schema'
printf '%s\n' 'schema = 1' '' '[[tracker]]' 'schema = 1' 'type = "github"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'malformed-tracker-table'
printf '%s\n' 'schema = 1' '' '[tracker]' 'schema = 1' 'type = "linear"' 'key_prefix = "aut"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim AUT-1 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'invalid-key-prefix'
printf '%s\n' 'schema = 1' '' '[tracker]' 'schema = 1' 'type = "github"' '[tracker]' 'schema = 1' 'type = "github"' >"$TMP/github/.touchstone.toml"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'duplicate-tracker-table'
mv "$TMP/github/config-good" "$TMP/github/.touchstone.toml"

echo "==> tracker mutations require a valid project contract"
printf '%s\n' 'schema = 1' '' '[tracker]' 'schema = 1' 'type = "github"' \
  '' '[validation]' 'runtime = "bash"' >"$TMP/github/.touchstone.toml"
: >"$GH_CALLS"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'invalid-project-contract'
assert_not_has "$GH_CALLS" 'issue edit'

echo "==> tracker selection cannot follow a configuration symlink"
rm "$TMP/github/.touchstone.toml"
ln -s "$TMP/linear/.touchstone.toml" "$TMP/github/.touchstone.toml"
: >"$GH_CALLS"
run_adapter "$TMP/out" claim 42 --project "$TMP/github" --json
assert_rc "$RUN_RC" 2
assert_has "$TMP/out" 'unsafe-config'
assert_not_has "$GH_CALLS" 'issue edit'

if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS tracker adapter assertion(s) failed" >&2
  exit 1
fi
echo "==> PASS: tracker adapter preserves claim/reconciliation semantics"
