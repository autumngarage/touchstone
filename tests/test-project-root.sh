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

echo "==> the version surface reports the released shape"
# The Homebrew formula's test block asserts on exactly "touchstone v"; a
# reshaped or empty report breaks every install's verification.
out="$(bash "$REPO_ROOT/bin/touchstone" version)"
# Anchored: the glob form let "v3.0.0garbage" pass.
printf '%s\n' "$out" | awk '/^touchstone v[0-9]+\.[0-9]+\.[0-9]+$/ { ok = 1 } END { exit !ok }' \
  || fail "version output is not the released shape: $out"
[ "$out" = "touchstone v$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" ] \
  || fail "version output disagrees with the VERSION file"

# A malformed VERSION must refuse, not print an unusable shape.
BROKEN_ROOT="$TMP_DIR/broken-version"
mkdir -p "$BROKEN_ROOT/bin" "$BROKEN_ROOT/scripts"
cp "$REPO_ROOT/bin/touchstone" "$BROKEN_ROOT/bin/touchstone"
for bad_version in 'not a version' '3' '3.0' '3.0.0.1' '3 . 0 . 0' ''; do
  printf '%s\n' "$bad_version" >"$BROKEN_ROOT/VERSION"
  if bash "$BROKEN_ROOT/bin/touchstone" version >/dev/null 2>&1; then
    fail "a malformed VERSION ('$bad_version') still reported a version"
  fi
done
pass "malformed VERSION shapes all refuse loudly"

# The read-failure path is distinct from the malformed path. Injected without
# permission bits (which do not stop the required workflow's root user): an
# absent file and a directory at the path fail reads for any UID.
rm -f "$BROKEN_ROOT/VERSION"
if bash "$BROKEN_ROOT/bin/touchstone" version >/dev/null 2>&1; then
  fail "a missing VERSION file still reported a version"
fi
mkdir "$BROKEN_ROOT/VERSION"
if bash "$BROKEN_ROOT/bin/touchstone" version >/dev/null 2>&1; then
  fail "a directory at the VERSION path still reported a version"
fi
pass "VERSION read failures refuse with a non-zero exit"

echo "==> update is a compatibility no-op for repositories on the 2.x scripts"
# Their sync guard runs `touchstone update --check` whenever a touchstone is
# on PATH; 3.0.0 removing the command broke every vendored open-pr.sh on an
# upgraded machine. The shim succeeds, writes nothing, and says why.
SHIM_PROJECT="$TMP_DIR/shim-project"
mkdir -p "$SHIM_PROJECT"
printf 'untouched\n' >"$SHIM_PROJECT/file.txt"
for args in "--check" "--ship" "--in-place" ""; do
  # shellcheck disable=SC2086
  if ! (cd "$SHIM_PROJECT" && bash "$REPO_ROOT/bin/touchstone" update $args >"$TMP_DIR/update.out" 2>"$TMP_DIR/update.err"); then
    fail "touchstone update $args exited non-zero"
  fi
  # The 2.x setup.sh pipes this through grep -E "Already|Needs update|Run: touchstone update".
  grep -qx "Already up to date." "$TMP_DIR/update.out" || fail "touchstone update $args did not emit the 2.x sentinel"
  grep -q "nothing to do" "$TMP_DIR/update.err" || fail "touchstone update $args did not explain itself"
done
[ "$(ls -A "$SHIM_PROJECT")" = "file.txt" ] && [ "$(cat "$SHIM_PROJECT/file.txt")" = untouched ] \
  || fail "touchstone update wrote to the repository"
# `upgrade` upgrades the tool (Homebrew, or an install.sh prefix), never a
# repository: from a source checkout it names the install kinds and exits 1.
if bash "$REPO_ROOT/bin/touchstone" upgrade >"$TMP_DIR/upgrade.out" 2>"$TMP_DIR/upgrade.err"; then
  fail "upgrade from a source checkout succeeded; it must refuse rather than guess an install kind"
fi
grep -q "neither a Homebrew install nor an install.sh prefix" "$TMP_DIR/upgrade.err" \
  || fail "upgrade did not name the install kinds it serves: $(cat "$TMP_DIR/upgrade.err")"
[ "$(ls -A "$SHIM_PROJECT")" = "file.txt" ] || fail "touchstone upgrade wrote to the repository"
pass "update succeeds without writing; upgrade serves the tool install, never a repository"

echo "==> upgrade --help is a read-only probe"
# Agents probe subcommands with --help before trusting them; on a Homebrew
# install the router ignored the flag and ran `brew upgrade touchstone`.
# A fake brew on PATH records any invocation.
mkdir -p "$TMP_DIR/fakebrew"
printf '#!/usr/bin/env bash\necho "brew $*" >>"%s/brew.calls"\nexit 0\n' "$TMP_DIR" >"$TMP_DIR/fakebrew/brew"
chmod +x "$TMP_DIR/fakebrew/brew"
if PATH="$TMP_DIR/fakebrew:$PATH" bash "$REPO_ROOT/bin/touchstone" upgrade --help >"$TMP_DIR/upgrade-help.out" 2>&1; then
  grep -q "^Usage: touchstone upgrade" "$TMP_DIR/upgrade-help.out" \
    || fail "upgrade --help printed no usage: $(cat "$TMP_DIR/upgrade-help.out")"
else
  fail "upgrade --help exited nonzero: $(cat "$TMP_DIR/upgrade-help.out")"
fi
[ ! -f "$TMP_DIR/brew.calls" ] || fail "upgrade --help invoked brew: $(cat "$TMP_DIR/brew.calls")"
pass "upgrade --help prints usage and runs nothing"

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

# =============================================================================
# install.sh — the non-Homebrew distribution (Windows Git Bash, Linux), exercised
# entirely offline: the release archive is built from this checkout and a local
# formula file stands in for the tap's reviewed record. It lives here because
# it is the CLI's other entry point: bin/touchstone resolved through the
# installed wrapper instead of the repository root.
# =============================================================================
echo ""
echo "==> install.sh installs, verifies, and upgrades the recorded release (offline)"
INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-install-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR" "$INSTALL_TMP"' EXIT
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# A release archive in the exact shape GitHub serves for a tag: one top-level
# directory, VERSION inside. Built from the worktree so install.sh, bin, and
# hooks under test are the ones in this change.
make_release() {
  local version="$1" out="$2" stage
  stage="$INSTALL_TMP/stage-$version"
  rm -rf "$stage"
  mkdir -p "$stage"
  git -C "$REPO_ROOT" archive --format=tar --prefix="touchstone-$version/" HEAD | tar -xf - -C "$stage"
  # Uncommitted edits in this checkout must ship too: the archive is the code under test.
  for f in install.sh bin/touchstone scripts/touchstone-steering-install.sh; do
    cp "$REPO_ROOT/$f" "$stage/touchstone-$version/$f"
  done
  printf '%s\n' "$version" >"$stage/touchstone-$version/VERSION"
  (cd "$stage" && tar -czf "$out" "touchstone-$version")
}

make_formula() {
  local version="$1" sha="$2" out="$3"
  cat >"$out" <<EOF
class Touchstone < Formula
  desc "Delivery baseline"
  homepage "https://github.com/autumngarage/touchstone"
  url "https://github.com/autumngarage/touchstone/archive/refs/tags/v$version.tar.gz"
  sha256 "$sha"
  license "MIT"
end
EOF
}

# Deliberately not named .touchstone: the install kind is recognised by
# layout (cli/<version> + current), never by the prefix's name.
PREFIX="$INSTALL_TMP/home/tools/ts-cli"
mkdir -p "$INSTALL_TMP/home"

echo "==> A recorded release installs, verifies, and runs through the wrapper"
make_release 9.9.1 "$INSTALL_TMP/v9.9.1.tar.gz"
make_formula 9.9.1 "$(sha256_of "$INSTALL_TMP/v9.9.1.tar.gz")" "$INSTALL_TMP/formula-9.9.1.rb"
if bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.1.rb" --archive-file "$INSTALL_TMP/v9.9.1.tar.gz" >"$INSTALL_TMP/install.out" 2>&1; then
  pass "install succeeded"
else
  fail "install failed: $(cat "$INSTALL_TMP/install.out")"
fi
[ -x "$PREFIX/bin/touchstone" ] || fail "wrapper was not created"
[ "$(cat "$PREFIX/current")" = "9.9.1" ] || fail "current does not name 9.9.1"
[ -f "$PREFIX/cli/9.9.1/bin/touchstone" ] || fail "release tree is not under cli/9.9.1"
out="$(bash "$PREFIX/bin/touchstone" version 2>&1)" || fail "wrapper could not run version: $out"
[ "$out" = "touchstone v9.9.1" ] && pass "wrapper runs the installed version" || fail "wrapper reported '$out'"
out="$(printf '{"tool_input":{"command":"git status"}}' | bash "$PREFIX/bin/touchstone" hook branch-guard 2>&1)" \
  && pass "hook subcommand resolves from the installed tree" \
  || fail "hook branch-guard failed through the wrapper: $out"
grep -q 'export PATH=' "$INSTALL_TMP/install.out" && pass "PATH instruction printed when the prefix is not on PATH" \
  || fail "no PATH instruction: $(cat "$INSTALL_TMP/install.out")"
# The prefix is data inside the wrapper, never shell source: a prefix carrying
# a command substitution must not run it when the wrapper starts.
META_PREFIX="$INSTALL_TMP/home/meta \$(touch \"$INSTALL_TMP/sentinel\")"
mkdir -p "$INSTALL_TMP/home"
bash "$REPO_ROOT/install.sh" --prefix "$META_PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.1.rb" --archive-file "$INSTALL_TMP/v9.9.1.tar.gz" >"$INSTALL_TMP/meta.out" 2>&1 \
  || fail "install into a metacharacter prefix failed: $(cat "$INSTALL_TMP/meta.out")"
out="$(bash "$META_PREFIX/bin/touchstone" version 2>&1)" && [ "$out" = "touchstone v9.9.1" ] \
  && pass "wrapper runs from a metacharacter prefix" || fail "wrapper failed from a metacharacter prefix: $out"
[ ! -e "$INSTALL_TMP/sentinel" ] && pass "the prefix was not executed as shell source" || fail "the wrapper executed a command embedded in the prefix"

echo "==> A second run is a no-op"
bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.1.rb" --archive-file "$INSTALL_TMP/v9.9.1.tar.gz" >"$INSTALL_TMP/again.out" 2>&1 \
  || fail "re-run failed: $(cat "$INSTALL_TMP/again.out")"
grep -q "already installed" "$INSTALL_TMP/again.out" && pass "re-run reports already installed" || fail "re-run did not short-circuit: $(cat "$INSTALL_TMP/again.out")"

echo "==> A checksum mismatch is refused and the prior install survives"
make_release 9.9.2 "$INSTALL_TMP/v9.9.2.tar.gz"
make_formula 9.9.2 "0000000000000000000000000000000000000000000000000000000000000000" "$INSTALL_TMP/formula-bad.rb"
if bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-bad.rb" --archive-file "$INSTALL_TMP/v9.9.2.tar.gz" >"$INSTALL_TMP/bad.out" 2>&1; then
  fail "a tarball with the wrong checksum was installed"
else
  grep -q "checksum mismatch" "$INSTALL_TMP/bad.out" && pass "mismatch refused with the checksums named" || fail "unexpected refusal: $(cat "$INSTALL_TMP/bad.out")"
fi
[ "$(cat "$PREFIX/current")" = "9.9.1" ] && pass "current still names 9.9.1" || fail "a refused install changed current"
[ ! -e "$PREFIX/cli/9.9.2" ] && pass "no partial 9.9.2 tree" || fail "partial tree left behind"

echo "==> An archive that predates the installer is refused"
make_release 9.9.0 "$INSTALL_TMP/v9.9.0.tar.gz"
(cd "$INSTALL_TMP/stage-9.9.0" && rm "touchstone-9.9.0/install.sh" && tar -czf "$INSTALL_TMP/v9.9.0.tar.gz" "touchstone-9.9.0")
make_formula 9.9.0 "$(sha256_of "$INSTALL_TMP/v9.9.0.tar.gz")" "$INSTALL_TMP/formula-9.9.0.rb"
if bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.0.rb" --archive-file "$INSTALL_TMP/v9.9.0.tar.gz" >"$INSTALL_TMP/old.out" 2>&1; then
  fail "an archive without install.sh was installed"
else
  grep -q "predates the non-Homebrew install" "$INSTALL_TMP/old.out" && pass "pre-installer release refused" || fail "unexpected: $(cat "$INSTALL_TMP/old.out")"
fi
[ "$(cat "$PREFIX/current")" = "9.9.1" ] || fail "a refused old release changed current"
# The message names the file that is actually missing.
(cd "$INSTALL_TMP/stage-9.9.0" && cp "$REPO_ROOT/install.sh" "touchstone-9.9.0/install.sh" && rm "touchstone-9.9.0/hooks/branch-guard.sh" && tar -czf "$INSTALL_TMP/v9.9.0b.tar.gz" "touchstone-9.9.0")
make_formula 9.9.0 "$(sha256_of "$INSTALL_TMP/v9.9.0b.tar.gz")" "$INSTALL_TMP/formula-9.9.0b.rb"
bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.0b.rb" --archive-file "$INSTALL_TMP/v9.9.0b.tar.gz" >"$INSTALL_TMP/oldb.out" 2>&1 && fail "an archive without the hook was installed"
grep -q "hooks/branch-guard.sh is missing" "$INSTALL_TMP/oldb.out" && pass "the missing hook is named" || fail "wrong refusal: $(cat "$INSTALL_TMP/oldb.out")"

echo "==> A version the formula does not record is refused"
if bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.1.rb" --archive-file "$INSTALL_TMP/v9.9.1.tar.gz" --version 1.2.3 >"$INSTALL_TMP/pin.out" 2>&1; then
  fail "an unrecorded version was accepted"
else
  grep -q "only the recorded release can be verified" "$INSTALL_TMP/pin.out" && pass "unrecorded version refused" || fail "unexpected: $(cat "$INSTALL_TMP/pin.out")"
fi

echo "==> touchstone upgrade on an install.sh prefix re-runs the installer for the recorded release"
make_formula 9.9.2 "$(sha256_of "$INSTALL_TMP/v9.9.2.tar.gz")" "$INSTALL_TMP/formula-9.9.2.rb"
UPGRADE_HOME="$INSTALL_TMP/upgrade-home"
UPGRADE_PROJECT="$INSTALL_TMP/upgrade-project"
mkdir -p "$UPGRADE_HOME/.codex" "$UPGRADE_PROJECT"
cat >"$UPGRADE_HOME/.codex/AGENTS.md" <<'EOF'
operator prefix
<!-- touchstone:steering:start -->

<!-- Installed by touchstone 9.9.1. Old contract. -->
OLD MANAGED COMMAND
<!-- touchstone:steering:end -->
operator suffix
EOF
printf 'project sentinel\n' >"$UPGRADE_PROJECT/sentinel"
upgrade_project_before="$(cksum <"$UPGRADE_PROJECT/sentinel")"
# The 3.5.0 launcher execed the old installer. Its process cannot return to a
# handoff that exists only in the archive it just installed; keep that exact
# release boundary executable instead of accidentally testing new code on
# both sides of the upgrade.
cp "$REPO_ROOT/tests/fixtures/touchstone-upgrade-v3.5.0.sh" "$PREFIX/cli/9.9.1/bin/touchstone"
if (cd "$UPGRADE_PROJECT" && HOME="$UPGRADE_HOME" bash "$PREFIX/bin/touchstone" upgrade \
  --formula-file "$INSTALL_TMP/formula-9.9.2.rb" \
  --archive-file "$INSTALL_TMP/v9.9.2.tar.gz") >"$INSTALL_TMP/upgrade.out" 2>&1; then
  pass "upgrade ran"
else
  fail "upgrade failed: $(cat "$INSTALL_TMP/upgrade.out")"
fi
[ "$(cat "$PREFIX/current")" = "9.9.2" ] && pass "current now names 9.9.2" || fail "upgrade did not switch current: $(cat "$PREFIX/current")"
[ "$(bash "$PREFIX/bin/touchstone" version)" = "touchstone v9.9.2" ] && pass "wrapper runs the upgraded version" || fail "wrapper did not follow the upgrade"
[ -d "$PREFIX/cli/9.9.1" ] && pass "previous release retained for rollback (current can be edited back)" || fail "previous release removed"
if HOME="$UPGRADE_HOME" bash "$PREFIX/bin/touchstone" steering check >/dev/null 2>&1; then
  fail "the 3.5.0 launcher somehow executed a handoff that it does not contain"
else
  pass "the 3.5.0 transition exposes its one-time steering migration"
fi
grep -qF 'Installed by touchstone 9.9.1.' "$UPGRADE_HOME/.codex/AGENTS.md" \
  || fail "the compatibility fixture did not preserve the old managed block"
if grep -qF 'Restart or reload already-running coding-agent sessions' "$INSTALL_TMP/upgrade.out"; then
  fail "the 3.5.0 launcher claimed it refreshed steering"
fi
HOME="$UPGRADE_HOME" bash "$PREFIX/bin/touchstone" steering install >"$INSTALL_TMP/transition-steering.out" 2>&1 \
  || fail "the documented one-time steering migration failed: $(cat "$INSTALL_TMP/transition-steering.out")"
HOME="$UPGRADE_HOME" bash "$PREFIX/bin/touchstone" steering check >/dev/null 2>&1 \
  || fail "the one-time transition did not converge machine steering"
grep -qF 'Installed by touchstone 9.9.2.' "$UPGRADE_HOME/.codex/AGENTS.md" \
  || fail "the one-time transition did not install the new steering version"
grep -qF 'operator prefix' "$UPGRADE_HOME/.codex/AGENTS.md" \
  && grep -qF 'operator suffix' "$UPGRADE_HOME/.codex/AGENTS.md" \
  || fail "the one-time transition changed content outside the managed block"

echo "==> a handoff-aware prefix upgrade refreshes an existing managed install"
cat >"$UPGRADE_HOME/.codex/AGENTS.md" <<'EOF'
operator prefix
<!-- touchstone:steering:start -->

<!-- Installed by touchstone 9.9.1. Old contract. -->
STALE AFTER TRANSITION
<!-- touchstone:steering:end -->
operator suffix
EOF
if (
  unset HOME
  bash "$PREFIX/bin/touchstone" upgrade \
    --formula-file "$INSTALL_TMP/formula-9.9.2.rb" \
    --archive-file "$INSTALL_TMP/v9.9.2.tar.gz"
) >"$INSTALL_TMP/no-home-upgrade.out" 2>&1; then
  fail "upgrade treated an unreadable ownership state as steering opt-out"
fi
grep -qF 'could not determine whether this machine has a Touchstone-managed steering install' "$INSTALL_TMP/no-home-upgrade.out" \
  || fail "upgrade did not distinguish a probe error from steering absence: $(cat "$INSTALL_TMP/no-home-upgrade.out")"
grep -qF 'STALE AFTER TRANSITION' "$UPGRADE_HOME/.codex/AGENTS.md" \
  || fail "the refused probe-error upgrade mutated steering"
UNREADABLE_HOME="$INSTALL_TMP/unreadable-home"
mkdir -p "$UNREADABLE_HOME/.codex"
cp "$UPGRADE_HOME/.codex/AGENTS.md" "$UNREADABLE_HOME/.codex/AGENTS.md"
chmod 000 "$UNREADABLE_HOME/.codex"
if [ ! -x "$UNREADABLE_HOME/.codex" ]; then
  unreadable_succeeded=false
  if HOME="$UNREADABLE_HOME" bash "$PREFIX/bin/touchstone" upgrade \
    --formula-file "$INSTALL_TMP/formula-9.9.2.rb" \
    --archive-file "$INSTALL_TMP/v9.9.2.tar.gz" >"$INSTALL_TMP/unreadable-upgrade.out" 2>&1; then
    unreadable_succeeded=true
  fi
  chmod 700 "$UNREADABLE_HOME/.codex"
  [ "$unreadable_succeeded" = false ] \
    || fail "upgrade treated an untraversable steering directory as opt-out"
  grep -qF 'could not determine whether this machine has a Touchstone-managed steering install' "$INSTALL_TMP/unreadable-upgrade.out" \
    || fail "upgrade did not report the untraversable steering path: $(cat "$INSTALL_TMP/unreadable-upgrade.out")"
  grep -qF 'STALE AFTER TRANSITION' "$UNREADABLE_HOME/.codex/AGENTS.md" \
    || fail "the refused untraversable-path upgrade mutated steering"
else
  chmod 700 "$UNREADABLE_HOME/.codex"
fi
if (cd "$UPGRADE_PROJECT" && HOME="$UPGRADE_HOME" bash "$PREFIX/bin/touchstone" upgrade \
  --formula-file "$INSTALL_TMP/formula-9.9.2.rb" \
  --archive-file "$INSTALL_TMP/v9.9.2.tar.gz") >"$INSTALL_TMP/handoff-upgrade.out" 2>&1; then
  pass "handoff-aware upgrade ran"
else
  fail "handoff-aware upgrade failed: $(cat "$INSTALL_TMP/handoff-upgrade.out")"
fi
HOME="$UPGRADE_HOME" bash "$PREFIX/bin/touchstone" steering check >/dev/null 2>&1 \
  || fail "handoff-aware prefix upgrade left machine steering stale"
grep -qF 'Restart or reload already-running coding-agent sessions' "$INSTALL_TMP/handoff-upgrade.out" \
  || fail "handoff-aware upgrade did not tell active agent sessions to reload"
if grep -qF 'Set up lower-cost normal reviews through OpenRouter now?' "$INSTALL_TMP/handoff-upgrade.out"; then
  fail "handoff-aware upgrade prompted for unrelated credential setup"
fi
[ "$(cksum <"$UPGRADE_PROJECT/sentinel")" = "$upgrade_project_before" ] \
  && [ "$(find "$UPGRADE_PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" = 1 ] \
  || fail "tool upgrade mutated the invoking project"

echo "==> Homebrew upgrade refreshes steering through the newly active CLI"
BREW_PREFIX="$INSTALL_TMP/brew-prefix"
BREW_HOME="$INSTALL_TMP/brew-home"
BREW_BIN="$INSTALL_TMP/brew-bin"
mkdir -p "$BREW_PREFIX/libexec" "$BREW_HOME/.codex" "$BREW_BIN"
cp -R "$PREFIX/cli/9.9.2/." "$BREW_PREFIX/libexec/"
cat >"$BREW_HOME/.codex/AGENTS.md" <<'EOF'
brew operator content
<!-- touchstone:steering:start -->

<!-- Installed by touchstone 9.9.1. Old contract. -->
OLD BREW MANAGED COMMAND
<!-- touchstone:steering:end -->
EOF
cat >"$BREW_BIN/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  '--prefix touchstone') printf '%s\n' "$TOUCHSTONE_TEST_BREW_PREFIX" ;;
  'upgrade touchstone') printf 'upgraded\n' >"$TOUCHSTONE_TEST_BREW_PREFIX/brew-upgraded" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BREW_BIN/brew"
HOME="$BREW_HOME" TOUCHSTONE_TEST_BREW_PREFIX="$BREW_PREFIX" PATH="$BREW_BIN:$PATH" \
  bash "$BREW_PREFIX/libexec/bin/touchstone" upgrade >"$INSTALL_TMP/brew-upgrade.out" 2>&1 \
  || fail "Homebrew upgrade path failed: $(cat "$INSTALL_TMP/brew-upgrade.out")"
if grep -qF 'Set up lower-cost normal reviews through OpenRouter now?' "$INSTALL_TMP/brew-upgrade.out"; then
  fail "Homebrew upgrade prompted for unrelated credential setup"
fi
[ -f "$BREW_PREFIX/brew-upgraded" ] || fail "Homebrew upgrade adapter did not run"
HOME="$BREW_HOME" bash "$BREW_PREFIX/libexec/bin/touchstone" steering check >/dev/null 2>&1 \
  || fail "Homebrew upgrade left machine steering stale"
grep -qF 'brew operator content' "$BREW_HOME/.codex/AGENTS.md" \
  || fail "Homebrew upgrade discarded operator steering content"

echo "==> upgrade preserves steering opt-out"
BREW_OPT_OUT_HOME="$INSTALL_TMP/brew-opt-out-home"
mkdir -p "$BREW_OPT_OUT_HOME/.touchstone/principles"
printf 'operator-owned manifest collision\n' >"$BREW_OPT_OUT_HOME/.touchstone/principles/.touchstone-installed"
opt_out_manifest_before="$(cksum <"$BREW_OPT_OUT_HOME/.touchstone/principles/.touchstone-installed")"
HOME="$BREW_OPT_OUT_HOME" TOUCHSTONE_TEST_BREW_PREFIX="$BREW_PREFIX" PATH="$BREW_BIN:$PATH" \
  bash "$BREW_PREFIX/libexec/bin/touchstone" upgrade >"$INSTALL_TMP/brew-opt-out.out" 2>&1 \
  || fail "opted-out Homebrew upgrade failed: $(cat "$INSTALL_TMP/brew-opt-out.out")"
[ ! -e "$BREW_OPT_OUT_HOME/.claude" ] \
  && [ ! -e "$BREW_OPT_OUT_HOME/.codex" ] \
  && [ ! -e "$BREW_OPT_OUT_HOME/.gemini" ] \
  && [ "$(cksum <"$BREW_OPT_OUT_HOME/.touchstone/principles/.touchstone-installed")" = "$opt_out_manifest_before" ] \
  || fail "upgrade enrolled an opted-out machine into steering"

echo "==> Overlapping installers are serialised, and a failed publication keeps the active release"
make_release 9.9.3 "$INSTALL_TMP/v9.9.3.tar.gz"
make_formula 9.9.3 "$(sha256_of "$INSTALL_TMP/v9.9.3.tar.gz")" "$INSTALL_TMP/formula-9.9.3.rb"
mkdir "$PREFIX/.install.lock"
if bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.3.rb" --archive-file "$INSTALL_TMP/v9.9.3.tar.gz" >"$INSTALL_TMP/lock.out" 2>&1; then
  fail "a second installer ran while the lock was held"
else
  grep -q "another installer holds" "$INSTALL_TMP/lock.out" && pass "second installer refused while the lock is held" || fail "unexpected: $(cat "$INSTALL_TMP/lock.out")"
fi
rmdir "$PREFIX/.install.lock"
# Publication failure, injected through the installer's seam (no permission
# bit stops root from renaming): `current` must still name a tree that runs,
# and a reinstall's set-aside tree must be restored.
mkdir -p "$PREFIX/cli/9.9.3" && printf 'stand-in\n' >"$PREFIX/cli/9.9.3/marker"
TOUCHSTONE_INSTALL_FAIL_PUBLISH=1 bash "$REPO_ROOT/install.sh" --prefix "$PREFIX" --formula-file "$INSTALL_TMP/formula-9.9.3.rb" --archive-file "$INSTALL_TMP/v9.9.3.tar.gz" >"$INSTALL_TMP/pub.out" 2>&1 && fail "an injected publication failure reported success"
grep -q "the previous tree was restored" "$INSTALL_TMP/pub.out" || fail "publication failure was not reported: $(cat "$INSTALL_TMP/pub.out")"
[ -f "$PREFIX/cli/9.9.3/marker" ] && pass "the set-aside tree is restored after a failed publication" || fail "the set-aside tree was not restored"
rm -rf "$PREFIX/cli/9.9.3"
[ "$(cat "$PREFIX/current")" = "9.9.2" ] || fail "a failed publication changed current: $(cat "$PREFIX/current")"
[ "$(bash "$PREFIX/bin/touchstone" version)" = "touchstone v9.9.2" ] && pass "the active release still runs after a failed publication" || fail "the wrapper broke after a failed publication"
[ ! -e "$PREFIX/.install.lock" ] && pass "the lock is released on failure" || fail "the lock was left behind"

echo "==> Input validation"
bash "$REPO_ROOT/install.sh" --prefix relative/path >/dev/null 2>&1 && fail "relative prefix accepted" || pass "relative prefix refused"
# A Windows drive path passes the absolute-path grammar. On this machine the
# run must stop before it creates anything (a relative "C:" directory would
# otherwise appear), so the formula is pointed at a missing file: the refusal
# is the fetch, not the prefix.
bash "$REPO_ROOT/install.sh" --prefix "C:/Users/me/.touchstone" --formula-file "$INSTALL_TMP/does-not-exist.rb" >"$INSTALL_TMP/win.out" 2>&1 || true
grep -q "must be an absolute path" "$INSTALL_TMP/win.out" && fail "a Windows drive prefix was refused as relative" || pass "Windows drive prefix accepted by the grammar"
[ ! -e "$REPO_ROOT/C:" ] && [ ! -e "C:" ] || fail "the Windows-prefix probe created a relative C: directory"
bash "$REPO_ROOT/install.sh" --version nope >/dev/null 2>&1 && fail "malformed version accepted" || pass "malformed version refused"
bash "$REPO_ROOT/install.sh" --bogus >/dev/null 2>&1 && fail "unknown argument accepted" || pass "unknown argument refused"

echo "==> hook subcommand"
bash "$REPO_ROOT/bin/touchstone" hook nope >/dev/null 2>&1 && fail "unknown hook accepted" || pass "unknown hook refused"
grep -q 'branch-guard) exec bash "$TOUCHSTONE_ROOT/hooks/branch-guard.sh"' "$REPO_ROOT/bin/touchstone" && pass "branch-guard resolves from the tool root" || fail "hook does not resolve from the tool root"

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: project roots resolve consistently and the engine stays standalone"
