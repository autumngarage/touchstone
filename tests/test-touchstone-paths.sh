#!/usr/bin/env bash
# tests/test-touchstone-paths.sh — the path-set matcher and its refusals.
#
# The matcher delegates to `git check-ignore`, so a test that re-derives
# gitignore semantics would only be testing git. What is worth pinning is
# everything around that delegation: the traps a declaration author falls into,
# the hermeticity that makes a developer's answer equal CI's, the refusals, and
# the invariant that no failure is ever reported as an exemption.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATHS="$ROOT/scripts/touchstone-paths.sh"
TMP_DIR="$(mktemp -d -t touchstone-test-paths.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}
ok() { echo "  OK: $*"; }

# Write a policy declaring one set from the patterns given as arguments.
policy_with() {
  local out="$1" name="$2"
  shift 2
  printf '%s\n' "$@" | jq -R . | jq -s --arg n "$name" '{pathSets: {($n): .}}' >"$out"
}

# assert_member SET_POLICY EXPECT PATH  (EXPECT: in|out)
assert_member() {
  local policy="$1" expect="$2" path="$3" rc=0
  bash "$PATHS" match --set s --policy "$policy" "$path" >/dev/null 2>&1 || rc=$?
  case "$expect:$rc" in
    in:0 | out:1) ok "$path is $expect" ;;
    *:2) fail "$path: expected $expect, got an error (exit 2)" ;;
    *) fail "$path: expected $expect, got $([ "$rc" = 0 ] && echo in || echo out)" ;;
  esac
}

assert_exit() {
  local expect="$1" label="$2" rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "$expect" ] && ok "$label (exit $rc)" || fail "$label: expected exit $expect, got $rc"
}

echo "==> the negation trap: a parent-excluding pattern is not re-includable"
# The single most likely way a declared set is silently wrong. AUT-1242 stated
# the two-line form as working; git does not, because a file cannot be
# re-included when a parent directory of it is excluded.
policy_with "$TMP_DIR/trap-two.json" s 'docs/**' '!docs/generated/**'
assert_member "$TMP_DIR/trap-two.json" in docs/a.md
assert_member "$TMP_DIR/trap-two.json" in docs/generated/b.md

echo "==> re-including the directory first is what makes negation take effect"
policy_with "$TMP_DIR/trap-three.json" s 'docs/**' '!docs/generated/' '!docs/generated/**'
assert_member "$TMP_DIR/trap-three.json" in docs/a.md
assert_member "$TMP_DIR/trap-three.json" out docs/generated/b.md

echo "==> anchoring, last-match-wins, and directory patterns are git's"
policy_with "$TMP_DIR/anchor.json" s '/docs/**'
assert_member "$TMP_DIR/anchor.json" in docs/a.md
assert_member "$TMP_DIR/anchor.json" out src/docs/a.md
policy_with "$TMP_DIR/last.json" s '*.md' '!README.md'
assert_member "$TMP_DIR/last.json" out README.md
assert_member "$TMP_DIR/last.json" in CONTRIBUTING.md
policy_with "$TMP_DIR/deep.json" s 'docs/**'
assert_member "$TMP_DIR/deep.json" in docs/deep/nested/x.md

echo "==> hermetic: a hostile global core.excludesFile cannot change the answer"
# Without neutralising global and system config, a developer whose global
# gitignore names a pattern gets a different classification from CI for the
# same declaration -- and the set that decides whether review is required
# would depend on the machine asking.
printf 'src/main.c\n' >"$TMP_DIR/global-ignore"
printf '[core]\n\texcludesFile = %s\n' "$TMP_DIR/global-ignore" >"$TMP_DIR/hostile-gitconfig"
policy_with "$TMP_DIR/herm.json" s '*.md'
# Both levels, because the matcher neutralises both and a test that only
# proved the global half would pass on a machine whose /etc/gitconfig carried
# the same trap -- and would then fail spuriously rather than catching it.
for level in GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM; do
  rc=0
  env "$level=$TMP_DIR/hostile-gitconfig" \
    bash "$PATHS" match --set s --policy "$TMP_DIR/herm.json" src/main.c >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] && ok "hostile $level excludesFile ignored (src/main.c stays out)" \
    || fail "hostile $level excludesFile leaked into the match (exit $rc)"
done

echo "==> a set may not exempt what decides review"
for pattern in '**/*.yml' '.github/**' 'policy/**' '.touchstone.toml' '**'; do
  policy_with "$TMP_DIR/self.json" s "$pattern"
  assert_exit 2 "refuses a set matching '$pattern'" \
    bash "$PATHS" check --policy "$TMP_DIR/self.json"
done
policy_with "$TMP_DIR/fine.json" s 'docs/**' '*.md'
assert_exit 0 "accepts a set that exempts nothing load-bearing" \
  bash "$PATHS" check --policy "$TMP_DIR/fine.json"

echo "==> protection is structural, not a list of example paths"
# The refusal above is a diagnostic and enumeration cannot be complete: a set
# naming .github/workflows/deploy.yml matches no probe and passes it. Before
# this was structural, that set then classified the workflow as part of it, so
# a head changing only that workflow read as documents-only -- the exact
# self-service review bypass the policy-side declaration exists to prevent.
# Deliberately names only protected paths that no probe covers, so the set
# passes the diagnostic refusal and the structural guarantee is what is tested.
policy_with "$TMP_DIR/named.json" s 'docs/**' '.github/workflows/custom-deploy.yml' 'policy/github/consumers/x.json'
assert_exit 0 "a set naming unprobed protected paths passes the diagnostic" \
  bash "$PATHS" check --policy "$TMP_DIR/named.json"
for guarded in \
  .github/workflows/custom-deploy.yml \
  policy/github/consumers/x.json; do
  rc=0
  bash "$PATHS" match --set s --policy "$TMP_DIR/named.json" "$guarded" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] && ok "$guarded is out of the set even though the set names it" \
    || fail "$guarded classified in the set (exit $rc) -- a declaration exempted review machinery"
done
# The prefix is `policy/github/`, not `policy/`. AUT-1242's invariant names
# "the policy", and Touchstone's lives at that exact prefix; protecting all of
# `policy/` would silently change behaviour for a consumer keeping unrelated
# documents in a directory of that common name.
policy_with "$TMP_DIR/prefix.json" s 'docs/**' 'policy/privacy.md' 'policy/github/consumers/vesper.json'
assert_member "$TMP_DIR/prefix.json" in policy/privacy.md
assert_member "$TMP_DIR/prefix.json" out policy/github/consumers/vesper.json

# The consequence that matters: such a head can never be all-in-set.
named_only="$(printf '.github/workflows/custom-deploy.yml\n' \
  | bash "$PATHS" classify --set s --policy "$TMP_DIR/named.json" --paths-from - --json | jq -r .classification)"
[ "$named_only" = none ] && ok "a head touching only a named workflow classifies none, never all" \
  || fail "a head touching only a named workflow classified $named_only"
mixed_named="$(printf 'docs/a.md\n.github/workflows/custom-deploy.yml\n' \
  | bash "$PATHS" classify --set s --policy "$TMP_DIR/named.json" --paths-from - --json | jq -r .classification)"
[ "$mixed_named" = mixed ] && ok "documents plus a named workflow stays mixed" \
  || fail "documents plus a named workflow classified $mixed_named"
# Protection must not swallow ordinary members of the same set.
assert_member "$TMP_DIR/named.json" in docs/a.md

echo "==> the refusal holds at use, not only at check"
policy_with "$TMP_DIR/self2.json" s '.github/**'
assert_exit 2 "match refuses a self-exempting set" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/self2.json" README.md

echo "==> failure is never an exemption: every bad input exits 2, never 0 or 1"
# Exit 1 from `match` means "not in the set" -- an ordinary, trusted answer.
# An input error that arrives as 1 is a failure being read as a clean negative,
# which is how an EXIT trap returning non-zero silently downgraded exit 2 here.
assert_exit 2 "undeclared set" \
  bash "$PATHS" match --set absent --policy "$TMP_DIR/fine.json" README.md
assert_exit 2 "missing policy file" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/does-not-exist.json" README.md
printf 'not json at all\n' >"$TMP_DIR/broken.json"
assert_exit 2 "policy that is not JSON" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/broken.json" README.md
printf '{"pathSets":{"s":"docs/**"}}\n' >"$TMP_DIR/notarray.json"
assert_exit 2 "set declared as a string, not an array" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/notarray.json" README.md
printf '{"pathSets":{"s":[]}}\n' >"$TMP_DIR/empty.json"
assert_exit 2 "empty set" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/empty.json" README.md
printf '{"pathSets":{"s":["docs/**",""]}}\n' >"$TMP_DIR/blank.json"
assert_exit 2 "set containing an empty pattern" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/blank.json" README.md
printf '{"pathSets":{"s":["docs/**\\n.github/**"]}}\n' >"$TMP_DIR/newline.json"
assert_exit 2 "pattern smuggling a second rule through a newline" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/newline.json" README.md
assert_exit 2 "no --policy at all" \
  bash "$PATHS" match --set s README.md

echo "==> classify: all, none, mixed over a real diff"
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
mkdir -p "$REPO/docs" "$REPO/src"
printf 'base\n' >"$REPO/src/main.c"
printf 'base\n' >"$REPO/docs/guide.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

classify() { bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --project "$REPO" --base "$BASE" --head "$1" --json; }

printf 'changed\n' >"$REPO/docs/guide.md"
git -C "$REPO" commit -qam docs-only
DOCS_ONLY="$(git -C "$REPO" rev-parse HEAD)"
[ "$(classify "$DOCS_ONLY" | jq -r .classification)" = all ] \
  && ok "documents-only head classifies all" || fail "documents-only head did not classify all"

printf 'changed\n' >"$REPO/src/main.c"
git -C "$REPO" commit -qam code-too
MIXED="$(git -C "$REPO" rev-parse HEAD)"
[ "$(classify "$MIXED" | jq -r .classification)" = mixed ] \
  && ok "one source file makes the head mixed" || fail "mixed head did not classify mixed"
[ "$(classify "$MIXED" | jq -r '.out[]')" = "src/main.c" ] \
  && ok "the deciding path comes back with the answer" || fail "deciding path not reported"

git -C "$REPO" checkout -q -b code-only "$BASE"
printf 'only code\n' >"$REPO/src/main.c"
git -C "$REPO" commit -qam code-only
[ "$(classify "$(git -C "$REPO" rev-parse HEAD)" | jq -r .classification)" = none ] \
  && ok "source-only head classifies none" || fail "source-only head did not classify none"

echo "==> classify: an empty diff is none, never a vacuous all"
# `all` on an empty diff would let a consumer skip a lane for a head it never
# looked at: every path in the set, because there are no paths.
[ "$(classify "$BASE" | jq -r .classification)" = none ] \
  && ok "empty diff classifies none" || fail "empty diff did not classify none"

echo "==> classify: a rename out of the set is not a hiding place"
# Diffed with --no-renames, so a source file moved into docs/ appears under
# both names and the head stays mixed rather than reading as documents-only.
git -C "$REPO" checkout -q -b renamer "$BASE"
git -C "$REPO" mv src/main.c docs/main.c
git -C "$REPO" commit -qm "move code into docs"
RENAMED="$(git -C "$REPO" rev-parse HEAD)"
[ "$(classify "$RENAMED" | jq -r .classification)" = mixed ] \
  && ok "a rename out of the set keeps the head mixed" \
  || fail "a rename hid a source path: classified $(classify "$RENAMED" | jq -r .classification)"

echo "==> classify: an unresolvable revision is an error, not a classification"
assert_exit 2 "unknown base revision" \
  bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --project "$REPO" \
  --base 0000000000000000000000000000000000000000 --head "$BASE"
assert_exit 2 "project that is not a git repository" \
  bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --project "$TMP_DIR" \
  --base "$BASE" --head "$BASE"

echo "==> classify: an explicit path list is the other supported input"
# The review gate is why this exists: a required workflow must not check out
# the head it is judging, so it has GitHub's changed-file list and no git range
# to diff. Same classification, different source of paths.
list_classify() { printf '%s\n' "$@" | bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --paths-from - --json; }
[ "$(list_classify docs/a.md README.md | jq -r .classification)" = all ] \
  && ok "a documents-only path list classifies all" || fail "path list did not classify all"
[ "$(list_classify docs/a.md src/main.c | jq -r .classification)" = mixed ] \
  && ok "one source path in the list makes it mixed" || fail "path list did not classify mixed"
[ "$(list_classify src/main.c | jq -r .classification)" = none ] \
  && ok "a source-only path list classifies none" || fail "path list did not classify none"
[ "$(printf '' | bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --paths-from - | head -1)" = none ] \
  && ok "an empty path list is none, not a vacuous all" || fail "empty path list did not classify none"
printf 'docs/a.md\n' >"$TMP_DIR/changed.txt"
[ "$(bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --paths-from "$TMP_DIR/changed.txt" --json | jq -r .classification)" = all ] \
  && ok "--paths-from reads a file as well as stdin" || fail "--paths-from FILE did not classify"
# The answer says which input produced it, so a consumer reading a stored
# classification can tell a git range from a supplied list.
[ "$(list_classify docs/a.md | jq -r .input)" = path-list ] \
  && ok "the answer records a path-list input" || fail "input not recorded for a path list"
[ "$(classify "$DOCS_ONLY" | jq -r .input)" = git-range ] \
  && ok "the answer records a git-range input" || fail "input not recorded for a git range"

echo "==> a leading ./ means the same thing to both surfaces"
# They disagreed once: match stripped it and classify did not, so the same path
# was in the set from one entry point and out of it from the other.
[ "$(list_classify ./docs/a.md | jq -r .classification)" = all ] \
  && ok "classify accepts a ./-prefixed path" || fail "classify rejected a ./-prefixed path"
assert_member "$TMP_DIR/fine.json" in ./docs/a.md

echo "==> an absolute path is refused, never answered"
# check-ignore errors on a path outside its repository, and that error was
# being swallowed into "not in the set" -- conservative for every consumer,
# but a wrong answer reached silently.
assert_exit 2 "match refuses an absolute path" \
  bash "$PATHS" match --set s --policy "$TMP_DIR/fine.json" /etc/passwd
printf '/etc/passwd\n' >"$TMP_DIR/abs.txt"
assert_exit 2 "classify refuses an absolute path" \
  bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --paths-from "$TMP_DIR/abs.txt"

echo "==> classify: the two inputs are mutually exclusive"
# Accepting both would leave precedence to be discovered from behaviour, and a
# caller passing a stale list beside a correct range would silently get one.
assert_exit 2 "--paths-from with --base/--head" \
  bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --paths-from "$TMP_DIR/changed.txt" --base "$BASE" --head "$BASE"
assert_exit 2 "--paths-from with --project" \
  bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --paths-from "$TMP_DIR/changed.txt" --project "$REPO"
assert_exit 2 "--paths-from naming no file" \
  bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json" --paths-from "$TMP_DIR/absent.txt"
assert_exit 2 "neither input given" \
  bash "$PATHS" classify --set s --policy "$TMP_DIR/fine.json"

echo "==> the matcher runs standalone, from anywhere, with no Touchstone checkout"
# AUT-1241's review gate is a required workflow: it fetches this script by
# pinned revision into a runner temp directory and runs it beside a fetched
# policy, with no repository checked out and no `bin/touchstone` present.
# Anything that made the script depend on its position in this repository
# would break that consumer without breaking any test here.
STANDALONE="$TMP_DIR/away/matcher.sh"
mkdir -p "$TMP_DIR/away" "$TMP_DIR/unrelated"
cp "$PATHS" "$STANDALONE"
cp "$TMP_DIR/fine.json" "$TMP_DIR/away/fetched-policy.json"
standalone_out="$(cd "$TMP_DIR/unrelated" && printf 'docs/a.md\nREADME.md\n' \
  | bash "$STANDALONE" classify --set s --policy "$TMP_DIR/away/fetched-policy.json" --paths-from - --json)"
[ "$(jq -r .classification <<<"$standalone_out")" = all ] \
  && ok "classifies correctly when copied out of the repository" \
  || fail "standalone invocation did not classify: $standalone_out"
standalone_rc=0
(cd "$TMP_DIR/unrelated" && bash "$STANDALONE" match --set s --policy "$TMP_DIR/away/fetched-policy.json" src/main.c >/dev/null 2>&1) || standalone_rc=$?
[ "$standalone_rc" = 1 ] && ok "standalone match keeps its exit-code contract" \
  || fail "standalone match exited $standalone_rc, expected 1"

echo "==> classify: the answer names the set and the source that produced it"
answer="$(classify "$DOCS_ONLY")"
[ "$(jq -r .source <<<"$answer")" = policy ] \
  && ok "source recorded as policy" || fail "source not recorded"
[ "$(jq -r .set <<<"$answer")" = s ] \
  && ok "set name recorded" || fail "set name not recorded"

if [ "$ERRORS" -eq 0 ]; then
  echo "PASS: touchstone paths"
else
  echo "FAILED: $ERRORS assertion(s)" >&2
  exit 1
fi
