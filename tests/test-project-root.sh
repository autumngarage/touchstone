#!/usr/bin/env bash
#
# tests/test-project-root.sh — every public --project option resolves to the
# repository root, and the engine stays fetchable as a single file.
#
# `--project sub` and `cd sub` used to select different roots for the same
# command, so validation and tracker claims looked for declarations below a
# subdirectory and reported a missing contract that was present.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-project-root.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }

# A project whose declaration lives at the root, with a subdirectory to invoke
# from. Resolution must find the root from either.
PROJECT="$TMP_DIR/project"
mkdir -p "$PROJECT/nested/deeper"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name Test
cat >"$PROJECT/.touchstone.toml" <<'EOF'
schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "noop"
target = "root"
command = "true"
required = true
EOF
git -C "$PROJECT" add -A >/dev/null 2>&1
git -C "$PROJECT" commit -qm "init" >/dev/null 2>&1

echo "==> validate resolves --project SUBDIR to the repository root"
if bash "$REPO_ROOT/scripts/touchstone-run.sh" validate --project "$PROJECT/nested/deeper" >/dev/null 2>&1; then
  pass "validate found the root declaration from a subdirectory"
else
  fail "validate --project SUBDIR did not resolve to the repository root"
fi

echo "==> validate agrees with the implicit path"
explicit_status=0
bash "$REPO_ROOT/scripts/touchstone-run.sh" validate --project "$PROJECT/nested/deeper" >/dev/null 2>&1 || explicit_status=$?
implicit_status=0
(cd "$PROJECT/nested/deeper" && bash "$REPO_ROOT/scripts/touchstone-run.sh" validate >/dev/null 2>&1) || implicit_status=$?
if [ "$explicit_status" = "$implicit_status" ]; then
  pass "explicit and implicit forms agree (exit $explicit_status)"
else
  fail "explicit exited $explicit_status but implicit exited $implicit_status"
fi

echo "==> a directory outside a work tree still resolves to itself"
PLAIN="$TMP_DIR/plain"
mkdir -p "$PLAIN"
out="$(bash "$REPO_ROOT/scripts/touchstone-run.sh" validate --project "$PLAIN" 2>&1 || true)"
case "$out" in
  *"validation contract not found"*) pass "a non-repository directory reports its own missing contract" ;;
  *) fail "unexpected result for a non-repository directory: $out" ;;
esac

echo "==> a missing directory keeps its existing error schema"
out="$(bash "$REPO_ROOT/scripts/touchstone-run.sh" validate --project "$TMP_DIR/absent" 2>&1 || true)"
case "$out" in
  *"project directory does not exist"*) pass "validate preserves its missing-directory message" ;;
  *) fail "validate changed its missing-directory error: $out" ;;
esac

out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" status 1 --project "$TMP_DIR/absent" 2>&1 || true)"
case "$out" in
  *"project directory does not exist"*) pass "pr preserves its missing-directory message" ;;
  *) fail "pr changed its missing-directory error: $out" ;;
esac

echo "==> pr still refuses a directory that is not a Git repository"
out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" status 1 --project "$PLAIN" 2>&1 || true)"
case "$out" in
  *"not a Git repository"*) pass "pr refuses a non-repository project" ;;
  *) fail "pr accepted a non-repository project: $out" ;;
esac

echo "==> ambient GIT_DIR cannot redirect --project to another repository"
# Review finding on PR #920: with GIT_DIR/GIT_WORK_TREE exported (as hooks and
# some CIs do), the resolver's git call answered for the ambient repository, so
# validating A could run B's declaration and return B's verdict as A's.
OTHER="$TMP_DIR/other"
mkdir -p "$OTHER"
git -C "$OTHER" init -q
git -C "$OTHER" config user.email test@example.com
git -C "$OTHER" config user.name Test
cat >"$OTHER/.touchstone.toml" <<'EOF'
schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "wrong-repo-sentinel"
target = "root"
command = "echo WRONG_REPOSITORY && exit 1"
required = true
EOF
git -C "$OTHER" add -A >/dev/null 2>&1
git -C "$OTHER" commit -qm init >/dev/null 2>&1

override_out="$(GIT_DIR="$OTHER/.git" GIT_WORK_TREE="$OTHER" bash "$REPO_ROOT/scripts/touchstone-run.sh" validate --project "$PROJECT" 2>&1)" || true
case "$override_out" in
  *WRONG_REPOSITORY*) fail "exported GIT_DIR redirected --project to the ambient repository" ;;
  *"PASS noop"*) pass "--project wins over exported GIT_DIR/GIT_WORK_TREE" ;;
  *) fail "unexpected output under GIT_DIR override: $override_out" ;;
esac

echo "==> tracker resolves --project SUBDIR to the repository root"
# Offline-observable: the tracker validates the project contract before any
# transport. Under the old resolver a subdirectory --project failed with
# invalid-project-contract (contract not found below the subdirectory); with
# resolution fixed it passes that gate and fails later on the absent tracker
# declaration instead. The distinction is the regression.
tracker_out="$(bash "$REPO_ROOT/scripts/touchstone-tracker.sh" claim AUT-1 --project "$PROJECT/nested/deeper" 2>&1)" || true
case "$tracker_out" in
  *invalid-project-contract*) fail "tracker still resolves --project SUBDIR below the root: $tracker_out" ;;
  *) pass "tracker passed the project-contract gate from a subdirectory" ;;
esac

# The organization-required workflow fetches scripts/touchstone-run.sh alone
# from raw.githubusercontent.com into RUNNER_TEMP and runs it there. It never
# checks out this repository, so any `source` of a sibling file would break the
# required check in every consumer at once. Nothing else guards that.
echo "==> the validation engine stays a single self-contained file"
if grep -nE '^[[:space:]]*(source|\.)[[:space:]]+' "$REPO_ROOT/scripts/touchstone-run.sh" >"$TMP_DIR/sourced" 2>/dev/null; then
  cat "$TMP_DIR/sourced" >&2
  fail "touchstone-run.sh sources another file; the required workflow fetches it alone"
else
  pass "touchstone-run.sh sources nothing"
fi

echo "==> pr open binds the branch it will act on"
# Two pull requests were opened for the wrong branch because open acts on
# whatever branch the invoking directory has checked out, and a worktree has a
# different one per directory. --expect-branch states the intent; the refusal
# is local, so it must land before GitHub is consulted -- these fixtures have
# no remote at all, and a check that reached the network could not run here.
WT_MAIN="$TMP_DIR/wt-main"
git init -q "$WT_MAIN"
git -C "$WT_MAIN" config user.email touchstone@example.com
git -C "$WT_MAIN" config user.name Touchstone
printf 'seed\n' >"$WT_MAIN/seed.txt"
git -C "$WT_MAIN" add seed.txt
git -C "$WT_MAIN" commit -qm "seed"
git -C "$WT_MAIN" checkout -q -b feat/first
git -C "$WT_MAIN" worktree add -q "$TMP_DIR/wt-second" -b feat/second

# The option is only a safety binding if an operator can find it: the
# unknown-argument error points at this help text.
out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" pr 2>&1 || true)"
case "$out" in
  *"--expect-branch BRANCH"*) pass "the help text advertises the branch binding" ;;
  *) fail "usage() omits --expect-branch: $out" ;;
esac

out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" open --project "$TMP_DIR/wt-second" --expect-branch feat/first 2>&1 || true)"
case "$out" in
  *"expected branch feat/first"*"feat/second"*) pass "a branch mismatch is refused, naming both branches" ;;
  *) fail "open did not refuse a branch mismatch: $out" ;;
esac
case "$out" in
  *"could not resolve the canonical base repository"*)
    fail "open consulted GitHub before checking the branch it was given"
    ;;
  *) pass "the refusal happens before any network call" ;;
esac

out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" open --project "$TMP_DIR/wt-second" --expect-branch feat/second 2>&1 || true)"
case "$out" in
  *"expected branch"*) fail "open refused a branch that matched: $out" ;;
  *) pass "a matching branch proceeds past the binding" ;;
esac

out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" open --project "$TMP_DIR/wt-second" --expect-branch 2>&1 || true)"
case "$out" in
  *"missing value for --expect-branch"*) pass "a bare --expect-branch is refused" ;;
  *) fail "open accepted --expect-branch with no value: $out" ;;
esac

# An omitted value followed by another option must be reported as missing,
# not swallowed as the branch name -- which would also silently drop the
# output mode the caller asked for.
out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" open --project "$TMP_DIR/wt-second" --expect-branch --json 2>&1 || true)"
case "$out" in
  *"missing value for --expect-branch"*) pass "an option token is not consumed as the branch name" ;;
  *) fail "open took --json as the branch name: $out" ;;
esac

# The implicit (no --project) path chooses PROJECT_ROOT from the working
# directory. Unsanitized, ambient GIT_DIR selected a different repository
# entirely -- and --expect-branch matched, because it compared against that
# same ambient repository.
out="$(cd "$TMP_DIR/wt-second" && GIT_DIR="$WT_MAIN/.git" GIT_WORK_TREE="$WT_MAIN" \
  bash "$REPO_ROOT/scripts/touchstone-pr.sh" open --expect-branch feat/second 2>&1 || true)"
case "$out" in
  *"expected branch feat/second"*)
    fail "ambient GIT_DIR redirected the implicit repository lookup: $out"
    ;;
  *) pass "the implicit lookup ignores ambient GIT_DIR too" ;;
esac

# #920 sanitized the resolver but not the reads after it, so with GIT_DIR
# exported every later project read answered for the ambient repository --
# here, refusing a correct --expect-branch by reporting another repo's branch.
out="$(GIT_DIR="$WT_MAIN/.git" GIT_WORK_TREE="$WT_MAIN" \
  bash "$REPO_ROOT/scripts/touchstone-pr.sh" open --project "$TMP_DIR/wt-second" \
  --expect-branch feat/second 2>&1 || true)"
case "$out" in
  *"expected branch feat/second"*)
    fail "ambient GIT_DIR made open read another repository's branch: $out"
    ;;
  *) pass "ambient GIT_DIR cannot redirect the branch binding" ;;
esac

out="$(bash "$REPO_ROOT/scripts/touchstone-pr.sh" status 1 --project "$TMP_DIR/wt-second" --expect-branch feat/second 2>&1 || true)"
case "$out" in
  *"does not accept mutation options"*) pass "status rejects an option that belongs to open" ;;
  *) fail "status accepted --expect-branch: $out" ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: project roots resolve consistently and the engine stays standalone"
