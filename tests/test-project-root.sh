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

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: project roots resolve consistently and the engine stays standalone"
