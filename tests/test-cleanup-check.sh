#!/usr/bin/env bash
# tests/test-cleanup-check.sh — `touchstone cleanup check` reports what a
# session left behind and nothing else, without mutating anything.
# Offline: a fake gh answers the three PR-list reads and the repo view.
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
case "$1 $2" in
  "repo view")
    [ -f "$state/gh-down" ] && exit 1
    printf 'autumngarage/current\tmain\n'
    ;;
  "pr list")
    st=""
    while [ "$#" -gt 0 ]; do [ "$1" = --state ] && st="$2"; shift; done
    f="$state/prs-$st"
    [ -f "$f" ] || exit 0
    case "$st" in
      open) cut -f1 "$f" ;;
      *) cat "$f" ;;
    esac
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
echo changed >>"$TMP/repo/tracked.txt"
# a merged branch locally and on origin, and a closed-unmerged one on origin
git -C "$TMP/repo" branch feat/done
git -C "$TMP/repo" push -q origin feat/done
git -C "$TMP/repo" push -q origin main:refs/heads/fix/abandoned
git -C "$TMP/repo" fetch -q origin
printf 'feat/done\t41\tMERGED\n' >"$TMP/state/prs-merged"
printf 'fix/abandoned\t42\tCLOSED\n' >"$TMP/state/prs-closed"
# a linked worktree
git -C "$TMP/repo" worktree add -q "$TMP/repo-wt" -b feat/in-flight >/dev/null 2>&1
printf 'feat/in-flight\n' >"$TMP/state/prs-open"
run
[ "$RC" -eq 1 ] || fail "leftovers did not exit 1 (rc=$RC)"
for kind in untracked dirty worktree local-branch remote-branch; do
  grep -qE "^  $kind " "$TMP/out" && ok "$kind reported" || fail "$kind not reported: $(cat "$TMP/out")"
done
grep -q 'feat/done (#41 merged)' "$TMP/out" && ok "merged branch names its PR" || fail "merged branch lacks its PR"
grep -q 'fix/abandoned (#42 closed)' "$TMP/out" && grep -q 'closed without merging' "$TMP/out" \
  && ok "closed-unmerged branch gets the cautious remedy" || fail "closed branch remedy wrong"
grep -q 'feat/in-flight' "$TMP/out" | grep -q 'local-branch' && fail "a branch with an open PR was reported as finished" || ok "open-PR branch is not a finished branch"
grep -q "repo-wt \[feat/in-flight\]" "$TMP/out" && ok "worktree named with its branch" || fail "worktree not named"
# nothing mutated
[ -f "$TMP/repo/__pycache__.tmp" ] && git -C "$TMP/repo" rev-parse --verify -q feat/done >/dev/null \
  && [ -d "$TMP/repo-wt" ] && ok "check mutated nothing" || fail "check mutated the repository"

echo "==> --json carries the same findings under a versioned schema"
run --json
[ "$RC" -eq 1 ] || fail "json leftovers did not exit 1"
jq -e '.schema == "touchstone.cleanup/v1" and .clean == false and (.findings | length) >= 5 and (.findings | map(.kind) | index("worktree"))' "$TMP/out" >/dev/null \
  && ok "json shape" || fail "json shape wrong: $(cat "$TMP/out")"

echo "==> a detached HEAD and a feature-branch checkout are reported"
git -C "$TMP/repo" checkout -q --detach
run
grep -q 'checkout.*detached HEAD' "$TMP/out" && ok "detached HEAD reported" || fail "detached HEAD missed: $(cat "$TMP/out")"
git -C "$TMP/repo" checkout -q feat/done
run
grep -q 'checkout.*on branch feat/done' "$TMP/out" && ok "feature checkout reported" || fail "feature checkout missed"
git -C "$TMP/repo" checkout -q main

echo "==> a failed GitHub read is a finding, never silence"
touch "$TMP/state/gh-down"
run
[ "$RC" -eq 1 ] && grep -q 'github.*repository read failed' "$TMP/out" && ok "gh failure reported" || fail "gh failure not reported: $(cat "$TMP/out")"
grep -qE '^  (local|remote)-branch' "$TMP/out" && fail "branch findings claimed without GitHub" || ok "branch findings withheld without GitHub"
rm -f "$TMP/state/gh-down"

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
