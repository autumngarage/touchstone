#!/usr/bin/env bash
#
# tests/test-validation-stages.sh — schema-2 execution stages.
#
# A project invariant that holds per commit cannot be enforced by a check that
# only runs at push: by then the commit exists and the cheap fix is gone. This
# was measured, not theorized — vesper PR #888 stalled mid-delivery on exactly
# that shape. Schema 2 lets a declaration say which tasks are authoring guards
# so they run locally while a fix is still free, and never in the enforcement
# run where a staged-tree check would be meaningless.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/touchstone-run.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-stages.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }

make_project() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  printf '%s\n' "$body" >"$dir/.touchstone.toml"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -qm init >/dev/null 2>&1
}

BOTH="$TMP_DIR/both"
make_project "$BOTH" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "echo ENFORCE_SENTINEL"
required = true

[[validation.tasks]]
name = "guard"
target = "root"
stage = "commit"
command = "echo COMMIT_SENTINEL"
required = true'

echo "==> the enforcement run never executes an authoring guard"
out="$(bash "$RUN" validate --project "$BOTH" 2>&1)"
case "$out" in
  *COMMIT_SENTINEL*) fail "a commit-stage task ran in the enforcement stage" ;;
  *ENFORCE_SENTINEL*) pass "enforce stage ran only its own task" ;;
  *) fail "enforce stage produced no sentinel: $out" ;;
esac

echo "==> the commit stage runs only authoring guards"
out="$(bash "$RUN" validate --stage commit --project "$BOTH" 2>&1)"
case "$out" in
  *ENFORCE_SENTINEL*) fail "an enforce-stage task ran in the commit stage" ;;
  *COMMIT_SENTINEL*) pass "commit stage ran only its own task" ;;
  *) fail "commit stage produced no sentinel: $out" ;;
esac

echo "==> schema 1 means exactly what it meant"
V1="$TMP_DIR/v1"
make_project "$V1" 'schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "echo V1_SENTINEL"
required = true'
out="$(bash "$RUN" validate --project "$V1" 2>&1)"
case "$out" in
  *V1_SENTINEL*"passed"*) pass "a schema-1 declaration runs unchanged at the default stage" ;;
  *) fail "schema 1 changed behavior: $out" ;;
esac

# A stage key in a schema-1 file is a contract error, not a silent default:
# accepting it would let a v1 consumer believe it declared a guard that never
# runs anywhere.
V1STAGE="$TMP_DIR/v1stage"
make_project "$V1STAGE" 'schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
stage = "commit"
command = "true"
required = true'
if bash "$RUN" validate --project "$V1STAGE" >/dev/null 2>&1; then
  fail "schema 1 accepted a stage key"
else
  pass "schema 1 rejects a stage key"
fi

echo "==> an empty commit stage passes; an empty enforcement stage fails"
ONLY="$TMP_DIR/enforce-only"
make_project "$ONLY" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "true"
required = true'
if bash "$RUN" validate --stage commit --project "$ONLY" >/dev/null 2>&1; then
  pass "no authoring guards is a pass at the commit stage"
else
  fail "a project without authoring guards failed its commit stage"
fi

GUARDONLY="$TMP_DIR/guard-only"
make_project "$GUARDONLY" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "guard"
target = "root"
stage = "commit"
command = "true"
required = true'
if bash "$RUN" validate --project "$GUARDONLY" >/dev/null 2>&1; then
  fail "a declaration with no enforcement task passed the gate"
else
  pass "no enforcement task still fails: a gate must run something"
fi

echo "==> unknown stages fail closed"
if bash "$RUN" validate --stage nope --project "$BOTH" >/dev/null 2>&1; then
  fail "an unknown --stage was accepted"
else
  pass "an unknown --stage is rejected"
fi
BADSTAGE="$TMP_DIR/badstage"
make_project "$BADSTAGE" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
stage = "prepush"
command = "true"
required = true'
if bash "$RUN" validate --project "$BADSTAGE" >/dev/null 2>&1; then
  fail "an unknown declared stage was accepted"
else
  pass "an unknown declared stage is rejected"
fi

echo "==> an unsupported schema still fails closed"
V3="$TMP_DIR/v3"
make_project "$V3" 'schema = 3

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "true"
required = true'
if bash "$RUN" validate --project "$V3" >/dev/null 2>&1; then
  fail "schema 3 was accepted"
else
  pass "an unsupported schema is rejected"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: execution stages select tasks and schema 1 is unchanged"
