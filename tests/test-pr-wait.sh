#!/usr/bin/env bash
# `touchstone pr wait`: the one tested wait on a pull request's merge-queue life (offline; fake gh and sleep).
#
# Every GitHub answer is a response captured from GitHub, served from tests/fixtures/pr-wait/ (see its README).
# The wait must read GitHub's own `state` and `mergeQueueEntry` and queue events, never a field of its own
# invention, and end on exactly one of: merged, removed from the queue (naming the failing check), closed,
# the head changed, or nothing to wait for.
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$TOUCHSTONE_ROOT/tests/fixtures/pr-wait"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ERRORS=0

fail() { echo "FAIL: $*" >&2; ERRORS=$((ERRORS + 1)); }
ok() { echo "  OK: $*"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3: expected '$2', got '$1'"; }
assert_has() { grep -qF -- "$2" "$1" && ok "has '$2'" || { fail "missing '$2' in $1"; sed 's/^/    /' "$1" >&2; }; }
assert_not_has() { ! grep -qF -- "$2" "$1" && ok "lacks '$2'" || fail "unexpected '$2' in $1"; }

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/project"
git -C "$TMP_DIR/project" init -q -b main
git -C "$TMP_DIR/project" -c user.email=t@example.test -c user.name=t commit -q --allow-empty -m base

# gh: the repository reads, then the captured GraphQL answers in order (the last repeats), then the REST reads.
cat >"$TMP_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
state="$GH_STATE"
printf '%s\n' "$*" >>"$state/gh-calls"
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "repo view") printf 'example/repo\thttps://github.com/example/repo\tmain\n'; exit 0 ;;
esac
if [ "$1" = api ]; then
  case "$*" in
    *graphql*)
      [ "${GH_GRAPHQL_FAILS:-}" != 1 ] || { echo 'GraphQL unavailable' >&2; exit 1; }
      count="$(cat "$state/graphql-count" 2>/dev/null || echo 0)"
      total="$(wc -l <"$state/graphql-sequence" | tr -d ' ')"
      index=$((count + 1)); [ "$index" -le "$total" ] || index="$total"
      printf '%s' "$((count + 1))" >"$state/graphql-count"
      cat "$(sed -n "${index}p" "$state/graphql-sequence")"
      exit 0
      ;;
    *"actions/runs?event=merge_group"*)
      [ "${GH_RUNS_FAIL:-}" != 1 ] || { echo 'HTTP 502' >&2; exit 1; }
      cat "$FIXTURES/runs-merge-group.json"; exit 0 ;;
    *"/jobs"*) cat "$FIXTURES/jobs-failed-run.json"; exit 0 ;;
  esac
fi
echo "unexpected gh call: $*" >&2
exit 97
GH
chmod +x "$TMP_DIR/bin/gh"
# sleep: never sleeps; records how long the command asked to.
cat >"$TMP_DIR/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$GH_STATE/sleeps"
SLEEP
chmod +x "$TMP_DIR/bin/sleep"

# The answers a waiting pull request gets: the captured queued answer (a live `mergeQueueEntry`) for the pull
# request's own head, so the wait sees one head throughout; and the captured idle answer with auto-merge armed,
# the one field GitHub fills for a pull request armed and not yet queued.
shaped() {
  local kind="$1" head="$2"
  if [ "$kind" = queued ]; then
    jq --arg head "$head" '.data.repository.pullRequest.headRefOid = $head' "$FIXTURES/graphql-queued.json"
  else
    jq --arg head "$head" '.data.repository.pullRequest |= (.headRefOid = $head | .autoMergeRequest = {"enabledAt":"2026-11-20T08:00:00Z"})' "$FIXTURES/graphql-open-idle.json"
  fi
}

# wait_run <name> <exit code wanted> <number> <head> <fixture>... : runs `pr wait` against the answers in order.
wait_run() {
  local name="$1" want="$2" number="$3" head="$4" fixture code=0
  shift 4
  export GH_STATE="$TMP_DIR/state-$name" FIXTURES
  rm -rf "$GH_STATE"; mkdir -p "$GH_STATE"
  for fixture in "$@"; do printf '%s\n' "$fixture" >>"$GH_STATE/graphql-sequence"; done
  PATH="$TMP_DIR/bin:$PATH" bash "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" wait "$number" --head "$head" \
    --project "$TMP_DIR/project" ${WAIT_ARGS:-} >"$GH_STATE/out" 2>"$GH_STATE/err" || code=$?
  assert_eq "$code" "$want" "$name exits $want"
}

MERGED_HEAD="$(jq -r .data.repository.pullRequest.headRefOid "$FIXTURES/graphql-merged.json")"
IDLE_HEAD="$(jq -r .data.repository.pullRequest.headRefOid "$FIXTURES/graphql-open-idle.json")"
REMOVED_HEAD="$(jq -r .data.repository.pullRequest.headRefOid "$FIXTURES/graphql-removed.json")"
CLOSED_HEAD="$(jq -r .data.repository.pullRequest.headRefOid "$FIXTURES/graphql-closed.json")"
MERGE_COMMIT="$(jq -r .data.repository.pullRequest.mergeCommit.oid "$FIXTURES/graphql-merged.json")"
shaped queued "$MERGED_HEAD" >"$TMP_DIR/queued-merged.json"
shaped armed "$MERGED_HEAD" >"$TMP_DIR/armed-merged.json"
shaped queued "$REMOVED_HEAD" >"$TMP_DIR/queued-removed.json"
shaped queued "$IDLE_HEAD" >"$TMP_DIR/queued-idle.json"

echo "==> merged: waits through the queue, then says the merge commit"
wait_run merged 0 1311 "$MERGED_HEAD" "$TMP_DIR/queued-merged.json" "$FIXTURES/graphql-merged.json"
assert_has "$GH_STATE/out" "PR #1311 merged at $MERGE_COMMIT (head $MERGED_HEAD)."
assert_has "$GH_STATE/err" 'queued (QUEUED, position 1); reading again in 120 s'
assert_eq "$(wc -l <"$GH_STATE/sleeps" | tr -d ' ')" 1 "slept once between its two reads"

echo "==> merged on the first read: no wait at all"
wait_run merged-now 0 1311 "$MERGED_HEAD" "$FIXTURES/graphql-merged.json"
[ ! -s "$GH_STATE/sleeps" ] && ok "never slept" || fail "slept although the PR had merged"

echo "==> removed from the queue: exit 10, one sentence naming the failing check"
wait_run removed 10 4106 "$REMOVED_HEAD" "$TMP_DIR/queued-removed.json" "$FIXTURES/graphql-removed.json"
assert_has "$GH_STATE/out" 'PR #4106 was removed from the merge queue at 2026-'
assert_has "$GH_STATE/out" '(failed_checks)'
assert_has "$GH_STATE/out" 'failing check: validate-groups (checks-b, checks-b) (https://github.com/example/repo/actions/runs/44694118552/job/'
assert_eq "$(wc -l <"$GH_STATE/out" | tr -d ' ')" 1 "the outcome is one line"

echo "==> removed, and the queue's runs cannot be read: it says so and still ends"
GH_RUNS_FAIL=1 wait_run removed-blind 10 4106 "$REMOVED_HEAD" "$FIXTURES/graphql-removed.json"
assert_has "$GH_STATE/out" 'failing check not identified: the queue'"'"'s runs could not be read'
unset GH_RUNS_FAIL

echo "==> closed: exit 11"
wait_run closed 11 1233 "$CLOSED_HEAD" "$FIXTURES/graphql-closed.json"
assert_has "$GH_STATE/out" 'PR #1233 was closed without merging.'

echo "==> the head changed: exit 12, before any other outcome, and without waiting"
wait_run head-changed 12 4076 "$(printf 'f%.0s' $(seq 40))" "$TMP_DIR/queued-idle.json"
assert_has "$GH_STATE/out" "PR #4076 is now at $IDLE_HEAD, not ffffffffffffffffffffffffffffffffffffffff"
[ ! -s "$GH_STATE/sleeps" ] && ok "never slept" || fail "waited on a head it was not asked about"
wait_run head-changed-merged 12 1311 "$IDLE_HEAD" "$FIXTURES/graphql-merged.json"
assert_has "$GH_STATE/out" "PR #1311 is now at $MERGED_HEAD, not $IDLE_HEAD"

echo "==> open, neither queued nor armed: exit 13"
wait_run not-queued 13 4076 "$IDLE_HEAD" "$FIXTURES/graphql-open-idle.json"
assert_has "$GH_STATE/out" 'neither queued nor armed for auto-merge'
assert_has "$GH_STATE/out" "touchstone pr merge 4076 --head $IDLE_HEAD"

echo "==> armed for auto-merge but not yet queued: waits"
wait_run armed 0 1311 "$MERGED_HEAD" "$TMP_DIR/armed-merged.json" "$FIXTURES/graphql-merged.json"
assert_has "$GH_STATE/err" 'auto-merge armed, not yet queued; reading again in 120 s'

echo "==> no read is faster than every two minutes"
wait_run pacing 0 1311 "$MERGED_HEAD" "$TMP_DIR/queued-merged.json" "$TMP_DIR/queued-merged.json" "$TMP_DIR/queued-merged.json" "$FIXTURES/graphql-merged.json"
assert_eq "$(wc -l <"$GH_STATE/sleeps" | tr -d ' ')" 3 "three waits for four reads"
slow=true
while read -r seconds; do [ "$seconds" -ge 120 ] || slow=false; done <"$GH_STATE/sleeps"
[ "$slow" = true ] && ok "every wait is at least 120 s" || fail "a wait shorter than 120 s"
assert_eq "$(grep -c graphql "$GH_STATE/gh-calls")" 4 "one GraphQL read per poll, no more"

echo "==> --json: one object with the outcome and the exit code"
WAIT_ARGS=--json wait_run json-removed 10 4106 "$REMOVED_HEAD" "$FIXTURES/graphql-removed.json"
assert_eq "$(jq -r '[.schema,.operation,.status,.exitCode,.pullRequest]|@tsv' "$GH_STATE/out")" $'touchstone.pr/v2\twait\tremoved\t10\t4106' "removal summary"
assert_eq "$(jq -r '.failedChecks[0].name' "$GH_STATE/out")" 'validate-groups (checks-b, checks-b)' "names the failing check"
WAIT_ARGS=--json wait_run json-merged 0 1311 "$MERGED_HEAD" "$FIXTURES/graphql-merged.json"
assert_eq "$(jq -r '[.status,.mergeCommit]|@tsv' "$GH_STATE/out")" $'merged\t'"$MERGE_COMMIT" "merge summary"

echo "==> GitHub unavailable: an operational failure (exit 1), never a guessed outcome"
GH_GRAPHQL_FAILS=1 wait_run unavailable 1 1311 "$MERGED_HEAD" "$FIXTURES/graphql-merged.json"
assert_has "$GH_STATE/err" 'could not read PR #1311'
unset GH_GRAPHQL_FAILS
printf '{"data":{"repository":{"pullRequest":null}}}\n' >"$TMP_DIR/graphql-null.json"
wait_run malformed 1 1311 "$MERGED_HEAD" "$TMP_DIR/graphql-null.json"
assert_has "$GH_STATE/err" 'malformed observation'

echo "==> the arguments"
for bad in "wait 7" "wait 7 --head abc123" "wait 7 --head $MERGED_HEAD --title t" "wait 7 --head $MERGED_HEAD --unguarded" "wait x --head $MERGED_HEAD"; do
  code=0
  # shellcheck disable=SC2086
  PATH="$TMP_DIR/bin:$PATH" GH_STATE="$TMP_DIR" bash "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" $bad --project "$TMP_DIR/project" >/dev/null 2>"$TMP_DIR/bad-err" || code=$?
  assert_eq "$code" 2 "'$bad' is refused as invalid input"
done

echo "==> status reads the same queue selection the wait does"
selection="$(sed -n "s/^QUEUE_OBSERVATION_SELECTION='\(.*\)'$/\1/p" "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh")"
[ -n "$selection" ] && ok "one shared selection" || fail "no shared selection"
[ "$(grep -c 'QUEUE_OBSERVATION_SELECTION' "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh")" -ge 3 ] && ok "status and wait both use it" || fail "a reader keeps its own copy"

if [ "$ERRORS" -gt 0 ]; then
  echo "FAILED: $ERRORS" >&2
  exit 1
fi
echo "all pr wait tests passed"
