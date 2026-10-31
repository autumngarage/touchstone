#!/usr/bin/env bash
# tests/test-cleanup-check.sh — `touchstone cleanup check` reports repository
# residue without claiming session ownership or mutating anything.
# Offline: a fake gh answers repository identity and paginated history.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-cleanup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ERRORS=0
ok() { echo "  OK: $*"; }
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

mkdir -p "$TMP/bin" "$TMP/state"
# Fake gh: default branch main; merged/closed/open PR heads from state files.
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
state="$GH_FAKE_STATE"
printf '%s\n' "$*" >>"$state/calls"
case "$1 $2" in
  "repo view")
    [ -f "$state/gh-down" ] && exit 1
    printf 'autumngarage/current\tmain\n'
    ;;
  "api graphql")
    [[ " $* " == *" --paginate "* && " $* " == *" --slurp "* ]] || exit 1
    [ ! -f "$state/response" ] || { cat "$state/response"; exit 0; }
    # Rows in $state/prs: "head<TAB>number<TAB>state<TAB>sha<TAB>owner/repo<TAB>base"
    # Page shape follows the captured GitHub connection and gh's documented
    # --paginate --slurp contract; this mock counts CLI invocations, not HTTP.
    rows="$(cat "$state/prs" 2>/dev/null || true)"
    pages="$(printf '%s' "$rows" | jq -Rs '
      split("\n") | map(select(length > 0) | split("\t") | {
        headRefName: .[0], number: (.[1] | tonumber), state: .[2], headRefOid: .[3],
        headRepository: (if .[4] == "" then null else {nameWithOwner: .[4]} end), baseRefName: .[5]
      }) as $nodes
      | [range(0; ([1, (($nodes | length) / 100 | ceil)] | max)) as $page | {
        data: {repository: {nameWithOwner: "autumngarage/current", pullRequests: {
          nodes: $nodes[($page * 100):(($page + 1) * 100)],
          pageInfo: {hasNextPage: (($page + 1) * 100 < ($nodes | length)),
            endCursor: (if ($nodes | length) == 0 then null else "page-\($page)" end)}
        }}}
      }]
    ')"
    if [ -f "$state/api-down" ]; then
      printf '%s' "$pages" | jq '.[-1].data.repository.pullRequests.pageInfo.hasNextPage = true'
    else
      printf '%s\n' "$pages"
    fi
    [ ! -f "$state/list-down" ] || { echo "gh: GraphQL: rate limited" >&2; exit 1; }
    ;;
  *) echo "unhandled fake gh call: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_FAKE_STATE="$TMP/state"

# A bare origin and a clone with main, so origin/main exists and fetch works.
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m root
git -C "$TMP/repo" remote add origin "$TMP/origin.git"
git -C "$TMP/repo" push -q -u origin main
git -C "$TMP/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

run() {
  : >"$TMP/state/calls"
  set +e
  bash "$ROOT/bin/touchstone" cleanup check --project "$TMP/repo" "$@" >"$TMP/out" 2>&1
  RC=$?
  set -e
}
kinds() { grep -E '^  [a-z-]+ ' "$TMP/out" | awk '{print $1}' | sort -u | tr '\n' ' '; }

echo "==> a clean checkout reports nothing and exits 0"
run
[ "$RC" -eq 0 ] && grep -q '^clean:' "$TMP/out" && ok "clean checkout" || fail "clean checkout reported: $(cat "$TMP/out")"

echo "==> each kind of leftover is reported once, with a remedy, and nothing is mutated"
# untracked residue + a dirty tracked file
echo residue >"$TMP/repo/__pycache__.tmp"
echo tracked >"$TMP/repo/tracked.txt"
git -C "$TMP/repo" add tracked.txt && git -C "$TMP/repo" -c user.email=t@example.com -c user.name=t commit -q -m tracked
git -C "$TMP/repo" push -q origin main
# a merged branch locally and on origin, and a closed-unmerged one on origin
git -C "$TMP/repo" branch feat/done
git -C "$TMP/repo" push -q origin feat/done
git -C "$TMP/repo" push -q origin main:refs/heads/fix/abandoned
git -C "$TMP/repo" fetch -q origin
DONE_SHA="$(git -C "$TMP/repo" rev-parse feat/done)"
ABANDONED_SHA="$(git -C "$TMP/repo" rev-parse origin/fix/abandoned)"
# a reused branch name: its merged PR was at a different SHA, so the current
# ref is live work and must not be reported
git -C "$TMP/repo" branch feat/reused
git -C "$TMP/repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m newer
REUSED_SHA="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" branch -f feat/reused "$REUSED_SHA"
git -C "$TMP/repo" reset -q --hard origin/main
echo changed >>"$TMP/repo/tracked.txt"
# a linked worktree, on a path with a space
git -C "$TMP/repo" worktree add -q "$TMP/repo wt" -b feat/in-flight >/dev/null 2>&1
FLIGHT_SHA="$(git -C "$TMP/repo" rev-parse feat/in-flight)"
# a merged branch that still bases an open stacked PR: must not be deleted
git -C "$TMP/repo" push -q origin main:refs/heads/feat/stack-parent
git -C "$TMP/repo" fetch -q origin
PARENT_SHA="$(git -C "$TMP/repo" rev-parse origin/feat/stack-parent)"
# a fork's OPEN PR with the same name as our merged branch: ours is finished
git -C "$TMP/repo" branch feat/fork-open "$DONE_SHA"
{
  printf 'feat/done\t41\tMERGED\t%s\tautumngarage/current\tmain\n' "$DONE_SHA"
  printf 'fix/abandoned\t42\tCLOSED\t%s\tautumngarage/current\tmain\n' "$ABANDONED_SHA"
  printf 'feat/reused\t30\tMERGED\t%s\tautumngarage/current\tmain\n' "$DONE_SHA"
  printf 'feat/in-flight\t43\tOPEN\t%s\tautumngarage/current\tmain\n' "$FLIGHT_SHA"
  printf 'feat/fork-name\t44\tMERGED\t%s\tsomeone/fork\tmain\n' "$DONE_SHA"
  printf 'feat/stack-parent\t45\tMERGED\t%s\tautumngarage/current\tmain\n' "$PARENT_SHA"
  printf 'feat/stack-child\t46\tOPEN\t%s\tautumngarage/current\tfeat/stack-parent\n' "$DONE_SHA"
  printf 'feat/fork-open\t47\tMERGED\t%s\tautumngarage/current\tmain\n' "$DONE_SHA"
  printf 'feat/fork-open\t48\tOPEN\t%s\tsomeone/fork\tmain\n' "$DONE_SHA"
} >"$TMP/state/prs"
git -C "$TMP/repo" branch feat/fork-name "$DONE_SHA"
rm -f "$TMP/repo/.git/FETCH_HEAD" # the fixture fetched; the check must not
run
[ "$RC" -eq 1 ] || fail "leftovers did not exit 1 (rc=$RC)"
grep -q '^.*repository cleanup finding(s):$' "$TMP/out" \
  && grep -q '^Resolve only findings this session owns; leave active sibling work untouched and route stale residue\.$' "$TMP/out" \
  && ! grep -q 'thing(s) left behind' "$TMP/out" \
  && ok "human output distinguishes repository residue from session ownership" \
  || fail "human output still claims session ownership: $(head -3 "$TMP/out")"
for kind in untracked dirty worktree local-branch remote-branch; do
  grep -qE "^  $kind " "$TMP/out" && ok "$kind reported" || fail "$kind not reported: $(cat "$TMP/out")"
done
grep -q 'feat/done (#41 merged)' "$TMP/out" && ok "merged branch names its PR" || fail "merged branch lacks its PR"
grep -q -- "--force-with-lease=feat/done:$DONE_SHA :feat/done" "$TMP/out" && ok "remote delete remedy is lease-protected" || fail "remote remedy not lease-protected: $(grep 'origin/feat/done' -A1 "$TMP/out")"
grep -q 'fix/abandoned (#42 closed)' "$TMP/out" && grep -q 'closed without merging' "$TMP/out" \
  && ok "closed-unmerged branch gets the cautious remedy" || fail "closed branch remedy wrong"
grep -E '^  (local|remote)-branch.*feat/in-flight' "$TMP/out" >/dev/null && fail "a branch with an open PR was reported as finished" || ok "open-PR branch is not a finished branch"
grep -E '^  local-branch.*feat/reused' "$TMP/out" >/dev/null && fail "a reused branch name at a new SHA was reported as finished" || ok "reused name at a new SHA is live work"
grep -E '^  local-branch.*feat/fork-name' "$TMP/out" >/dev/null && fail "a fork's PR with the same head name counted as ours" || ok "fork PR with the same name is not ours"
grep -q "repo wt \[feat/in-flight\]" "$TMP/out" && ok "worktree path with a space kept whole" || fail "worktree path split: $(grep worktree "$TMP/out")"
grep -E '^  remote-branch.*feat/stack-parent.*still bases open PR #46' "$TMP/out" >/dev/null && ! grep -E 'delete feat/stack-parent' "$TMP/out" >/dev/null \
  && ok "a merged branch that bases an open PR is preserved, retarget named" || fail "stack parent not protected: $(grep stack-parent "$TMP/out")"
grep -E '^  local-branch.*feat/fork-open \(#47 merged\)' "$TMP/out" >/dev/null && ok "a fork's open PR does not hide our finished branch" || fail "fork open PR hid a finished branch"
grep -q 'confirm the worker is terminal, then confirm its final report reached the parent or its cancellation was acknowledged; then git worktree remove' "$TMP/out" \
  && ok "worktree removal requires terminal-worker evidence" || fail "worktree removal remedy trusts repository state alone"
grep -q 'confirm its PR is merged' "$TMP/out" \
  && fail "worktree removal still depends on PR lifecycle" || ok "worktree removal ignores PR lifecycle"
grep -q 'git worktree prune' "$TMP/out" \
  && fail "intact worktree removal chains repository-wide pruning" || ok "intact worktree removal does not prune sibling records"
# nothing mutated
[ -f "$TMP/repo/__pycache__.tmp" ] && git -C "$TMP/repo" rev-parse --verify -q feat/done >/dev/null \
  && [ -d "$TMP/repo wt" ] && [ ! -f "$TMP/repo/.git/FETCH_HEAD" ] && ok "check mutated nothing (no FETCH_HEAD either)" || fail "check mutated the repository"

echo "==> --json carries the same findings under a versioned schema"
run --json
[ "$RC" -eq 1 ] || fail "json leftovers did not exit 1"
jq -e '.schema == "touchstone.cleanup/v1" and .clean == false and (.findings | length) >= 5 and (.findings | map(.kind) | index("worktree"))' "$TMP/out" >/dev/null \
  && ok "json shape" || fail "json shape wrong: $(cat "$TMP/out")"
jq -e 'all(.findings[] | select(.kind == "worktree"); (.remedy | test("\\bPR\\b|pull request"; "i") | not))' "$TMP/out" >/dev/null \
  && ok "worktree remedies contain no PR predicate" || fail "worktree remedy depends on repository lifecycle"

echo "==> history beyond the first page and later open heads are retained"
cp "$TMP/state/prs" "$TMP/state/prs.saved"
awk -v sha="$DONE_SHA" 'BEGIN { for (i=1; i<=300; i++) printf "unrelated/%04d\t%d\tMERGED\t%s\tautumngarage/current\tmain\n", i, 1000+i, sha }' >"$TMP/state/prs"
cat "$TMP/state/prs.saved" >>"$TMP/state/prs"
run --json
jq -e 'any(.findings[]; .kind == "local-branch" and (.subject | startswith("feat/done (#41 merged)")))' "$TMP/out" >/dev/null \
  && ok "old matching head beyond page one is reported" || fail "complete history was truncated"
printf 'feat/done\t1400\tOPEN\t%s\tautumngarage/current\tmain\n' "$REUSED_SHA" >>"$TMP/state/prs"
run --json
jq -e 'all(.findings[]; (.kind != "local-branch" and .kind != "remote-branch") or (.subject | test("^(origin/)?feat/done ") | not))' "$TMP/out" >/dev/null \
  && ok "a later-page own open head suppresses completion despite a different SHA" || fail "later open head was lost"
mv "$TMP/state/prs.saved" "$TMP/state/prs"

echo "==> fork and deleted-head PR bases still protect their parent"
cp "$TMP/state/prs" "$TMP/state/prs.saved"
for head_repo in '' someone/fork; do
  awk -F'\t' -v OFS='\t' -v repo="$head_repo" '$2 == 46 || $2 == 44 { $5 = repo } { print }' "$TMP/state/prs.saved" >"$TMP/state/prs"
  run --json
  jq -e 'all(.findings[]; .kind != "github") and any(.findings[]; .kind == "remote-branch" and (.subject | contains("feat/stack-parent")) and (.subject | contains("still bases open PR #46"))) and all(.findings[]; .kind != "local-branch" or (.subject | startswith("feat/fork-name ") | not))' "$TMP/out" >/dev/null \
    && ok "nullable/fork head cannot prove completion but protects its open base" || fail "null/fork head semantics lost"
done
mv "$TMP/state/prs.saved" "$TMP/state/prs"

echo "==> a detached HEAD and a feature-branch checkout are reported"
git -C "$TMP/repo" checkout -q --detach
run
grep -q 'checkout.*detached HEAD' "$TMP/out" && ok "detached HEAD reported" || fail "detached HEAD missed: $(cat "$TMP/out")"
git -C "$TMP/repo" checkout -q feat/done
run
grep -q 'checkout.*on branch feat/done' "$TMP/out" && ok "feature checkout reported" || fail "feature checkout missed"
git -C "$TMP/repo" checkout -q main

echo "==> a remote branch is judged by its live SHA, not a stale remote-tracking ref"
# origin/feat/done moves (another clone pushed new work) but this checkout
# has not fetched: the merged PR is at the OLD sha, so the live branch is
# not finished and must not be recommended for deletion.
git -C "$TMP/repo" push -q origin "$REUSED_SHA:refs/heads/feat/done"
run
grep -E '^  remote-branch.*feat/done' "$TMP/out" >/dev/null && fail "stale remote-tracking ref led to a deletion remedy for live work" || ok "live remote SHA consulted"
grep -E '^  local-branch.*feat/done \(#41 merged\)' "$TMP/out" >/dev/null && ok "the local ref at the merged SHA is still reported" || fail "local merged ref lost"
git -C "$TMP/repo" push -q -f origin "$DONE_SHA:refs/heads/feat/done"

echo "==> incomplete native pagination withholds all branch findings"
touch "$TMP/state/api-down"
run --json
jq -e '([.findings[] | select(.kind == "github")] | length) == 1 and all(.findings[]; .kind != "local-branch" and .kind != "remote-branch") and any(.findings[]; .kind == "dirty") and any(.findings[]; .kind == "worktree")' "$TMP/out" >/dev/null \
  && ok "one incomplete finding, local diagnostics retained, no branch suggestions" || fail "incomplete pagination was accepted: $(cat "$TMP/out")"
rm -f "$TMP/state/api-down"

echo "==> a worktree whose directory was removed by hand is reported, not a crash"
rm -rf "$TMP/repo wt"
run
[ "$RC" -eq 1 ] && grep -q 'worktree.*directory missing' "$TMP/out" && grep -q 'git worktree prune' "$TMP/out" \
  && ok "prunable worktree reported with the prune remedy" || fail "prunable worktree not handled (rc=$RC): $(head -3 "$TMP/out")"
grep -q 'confirm every prunable worker is terminal, then confirm each final report or cancellation was acknowledged; then git worktree prune' "$TMP/out" \
  && ok "pruning requires aggregate terminal-worker evidence" || fail "prune remedy proves only one missing worktree"
git -C "$TMP/repo" worktree prune

echo "==> an unreachable origin is a checkout finding, not a clean exit"
git -C "$TMP/repo" remote set-url origin "$TMP/does-not-exist.git"
run
grep -q 'checkout.*could not read origin/main' "$TMP/out" && ok "unreachable origin reported" || fail "unreachable origin not reported: $(cat "$TMP/out")"
git -C "$TMP/repo" remote set-url origin "$TMP/origin.git"

echo "==> a failed pull-request read is a finding, never an empty list"
touch "$TMP/state/list-down"
run
[ "$RC" -eq 1 ] && grep -q 'github.*pull-request inventory incomplete' "$TMP/out" && ok "list failure reported" || fail "list failure not reported: $(cat "$TMP/out")"
grep -qE '^  (local|remote)-branch' "$TMP/out" && fail "branch findings claimed after a failed read" || ok "no branch claimed clean or finished after a failed read"
rm -f "$TMP/state/list-down"

echo "==> malformed or error-bearing history is one explicit incomplete finding"
gh api graphql --paginate --slurp >"$TMP/state/valid-pages"
for mutation in invalid-json '[]' '.[0].errors = [{message:"unavailable"}]' \
  '.[0].data.repository = null' '.[0].data.repository.nameWithOwner = "someone/else"' \
  '.[0].data.repository.pullRequests.nodes = null' \
  '.[0].data.repository.pullRequests.nodes[0].state = "UNKNOWN"' \
  '.[0].data.repository.pullRequests.pageInfo = {}'; do
  if [ "$mutation" = invalid-json ]; then
    printf 'not json\n' >"$TMP/state/response"
  else
    jq "$mutation" "$TMP/state/valid-pages" >"$TMP/state/response"
  fi
  run --json
  if [ "$RC" -eq 1 ] && jq -e '([.findings[] | select(.kind == "github")] | length) == 1 and all(.findings[]; .kind != "local-branch" and .kind != "remote-branch") and any(.findings[]; .kind == "dirty")' "$TMP/out" >/dev/null \
    && [ "$(grep -c '^api graphql ' "$TMP/state/calls" || true)" -eq 1 ]; then
    ok "invalid history is reported once without retry or branch suggestions"
  else
    fail "invalid history was accepted or retried: $mutation: $(cat "$TMP/out")"
  fi
done
rm -f "$TMP/state/response"

echo "==> a failed GitHub read is a finding, never silence"
touch "$TMP/state/gh-down"
run
[ "$RC" -eq 1 ] && grep -q 'github.*repository read failed' "$TMP/out" && ok "gh failure reported" || fail "gh failure not reported: $(cat "$TMP/out")"
grep -qE '^  (local|remote)-branch' "$TMP/out" && fail "branch findings claimed without GitHub" || ok "branch findings withheld without GitHub"
rm -f "$TMP/state/gh-down"

echo "==> a branch name with shell metacharacters is quoted in its remedy"
git -C "$TMP/repo" branch 'feat/semi;touch' "$DONE_SHA"
printf 'feat/semi;touch\t49\tMERGED\t%s\tautumngarage/current\tmain\n' "$DONE_SHA" >>"$TMP/state/prs"
run
grep -qF 'git branch -D feat/semi\;touch' "$TMP/out" && ok "metacharacter branch quoted in remedy" || fail "unquoted branch in remedy: $(grep 'semi' "$TMP/out")"
git -C "$TMP/repo" branch -D 'feat/semi;touch' >/dev/null

echo "==> a relative --project resolves against the invoking directory, not CDPATH"
mkdir -p "$TMP/cdtrap/repo"
(cd "$TMP" && CDPATH="$TMP/cdtrap" bash "$ROOT/bin/touchstone" cleanup check --project repo --json >"$TMP/out2" 2>&1 || true)
jq -e '.schema == "touchstone.cleanup/v1"' "$TMP/out2" >/dev/null 2>&1 && ! grep -q cdtrap "$TMP/out2" \
  && ok "relative --project used the invoking directory" || fail "relative --project went through CDPATH or failed: $(head -c 300 "$TMP/out2")"

echo "==> a large shared branch inventory reuses one repository PR read"
awk -v sha="$DONE_SHA" 'BEGIN { for (i=1; i<=1000; i++) printf "create refs/heads/bulk/%04d %s\n", i, sha }' \
  | git -C "$TMP/repo" update-ref --stdin
run --json
[ "$(grep -c '^api graphql ' "$TMP/state/calls" || true)" -eq 1 ] \
  && ! grep -Eq '^pr list|^api --paginate ' "$TMP/state/calls" \
  && grep -Fq 'query($owner: String!, $name: String!, $endCursor: String)' "$TMP/state/calls" \
  && grep -Fq 'pullRequests(first: 100, after: $endCursor, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC})' "$TMP/state/calls" \
  && ok "1,000 extra heads cause one paginated inventory invocation, no per-head calls" \
  || fail "cleanup still queries per ref: $(grep -c '^pr list' "$TMP/state/calls" || true) head reads"
awk 'BEGIN { for (i=1; i<=1000; i++) printf "delete refs/heads/bulk/%04d\n", i }' \
  | git -C "$TMP/repo" update-ref --stdin

echo "==> invalid input exits 2"
set +e
bash "$ROOT/bin/touchstone" cleanup >/dev/null 2>&1
[ $? -eq 2 ] && ok "missing action exits 2" || fail "missing action did not exit 2"
bash "$ROOT/bin/touchstone" cleanup check --project "" >/dev/null 2>&1
[ $? -eq 2 ] && ok "empty --project exits 2" || fail "empty --project did not exit 2"
set -e

if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS cleanup-check assertion(s) failed"
  exit 1
fi
echo "==> PASS: cleanup check reports leftovers and mutates nothing"
