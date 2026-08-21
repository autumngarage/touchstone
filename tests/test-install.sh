#!/usr/bin/env bash
# install.sh is the non-Homebrew distribution (Windows Git Bash, Linux). It is
# exercised here entirely offline: the release archive is built from this
# checkout, and a local formula file stands in for the tap's reviewed record.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-install-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ERRORS=0

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}
ok() { echo "  OK: $*"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# A release archive in the exact shape GitHub serves for a tag: one top-level
# directory, VERSION inside. Built from the worktree so install.sh, bin, and
# hooks under test are the ones in this change.
make_release() {
  local version="$1" out="$2" stage
  stage="$TMP/stage-$version"
  rm -rf "$stage"
  mkdir -p "$stage"
  git -C "$ROOT" archive --format=tar --prefix="touchstone-$version/" HEAD | tar -xf - -C "$stage"
  # Uncommitted edits in this checkout must ship too: the archive is the code under test.
  for f in install.sh bin/touchstone; do cp "$ROOT/$f" "$stage/touchstone-$version/$f"; done
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
PREFIX="$TMP/home/tools/ts-cli"
mkdir -p "$TMP/home"

echo "==> A recorded release installs, verifies, and runs through the wrapper"
make_release 9.9.1 "$TMP/v9.9.1.tar.gz"
make_formula 9.9.1 "$(sha256_of "$TMP/v9.9.1.tar.gz")" "$TMP/formula-9.9.1.rb"
if bash "$ROOT/install.sh" --prefix "$PREFIX" --formula-file "$TMP/formula-9.9.1.rb" --archive-file "$TMP/v9.9.1.tar.gz" >"$TMP/install.out" 2>&1; then
  ok "install succeeded"
else
  fail "install failed: $(cat "$TMP/install.out")"
fi
[ -x "$PREFIX/bin/touchstone" ] || fail "wrapper was not created"
[ "$(cat "$PREFIX/current")" = "9.9.1" ] || fail "current does not name 9.9.1"
[ -f "$PREFIX/cli/9.9.1/bin/touchstone" ] || fail "release tree is not under cli/9.9.1"
out="$(bash "$PREFIX/bin/touchstone" version 2>&1)" || fail "wrapper could not run version: $out"
[ "$out" = "touchstone v9.9.1" ] && ok "wrapper runs the installed version" || fail "wrapper reported '$out'"
out="$(printf '{"tool_input":{"command":"git status"}}' | bash "$PREFIX/bin/touchstone" hook branch-guard 2>&1)" \
  && ok "hook subcommand resolves from the installed tree" \
  || fail "hook branch-guard failed through the wrapper: $out"
grep -q 'export PATH=' "$TMP/install.out" && ok "PATH instruction printed when the prefix is not on PATH" \
  || fail "no PATH instruction: $(cat "$TMP/install.out")"

echo "==> A second run is a no-op"
bash "$ROOT/install.sh" --prefix "$PREFIX" --formula-file "$TMP/formula-9.9.1.rb" --archive-file "$TMP/v9.9.1.tar.gz" >"$TMP/again.out" 2>&1 \
  || fail "re-run failed: $(cat "$TMP/again.out")"
grep -q "already installed" "$TMP/again.out" && ok "re-run reports already installed" || fail "re-run did not short-circuit: $(cat "$TMP/again.out")"

echo "==> A checksum mismatch is refused and the prior install survives"
make_release 9.9.2 "$TMP/v9.9.2.tar.gz"
make_formula 9.9.2 "0000000000000000000000000000000000000000000000000000000000000000" "$TMP/formula-bad.rb"
if bash "$ROOT/install.sh" --prefix "$PREFIX" --formula-file "$TMP/formula-bad.rb" --archive-file "$TMP/v9.9.2.tar.gz" >"$TMP/bad.out" 2>&1; then
  fail "a tarball with the wrong checksum was installed"
else
  grep -q "checksum mismatch" "$TMP/bad.out" && ok "mismatch refused with the checksums named" || fail "unexpected refusal: $(cat "$TMP/bad.out")"
fi
[ "$(cat "$PREFIX/current")" = "9.9.1" ] && ok "current still names 9.9.1" || fail "a refused install changed current"
[ ! -e "$PREFIX/cli/9.9.2" ] && ok "no partial 9.9.2 tree" || fail "partial tree left behind"

echo "==> A version the formula does not record is refused"
if bash "$ROOT/install.sh" --prefix "$PREFIX" --formula-file "$TMP/formula-9.9.1.rb" --archive-file "$TMP/v9.9.1.tar.gz" --version 1.2.3 >"$TMP/pin.out" 2>&1; then
  fail "an unrecorded version was accepted"
else
  grep -q "only the recorded release can be verified" "$TMP/pin.out" && ok "unrecorded version refused" || fail "unexpected: $(cat "$TMP/pin.out")"
fi

echo "==> touchstone upgrade on an install.sh prefix re-runs the installer for the recorded release"
make_formula 9.9.2 "$(sha256_of "$TMP/v9.9.2.tar.gz")" "$TMP/formula-9.9.2.rb"
if bash "$PREFIX/bin/touchstone" upgrade --formula-file "$TMP/formula-9.9.2.rb" --archive-file "$TMP/v9.9.2.tar.gz" >"$TMP/upgrade.out" 2>&1; then
  ok "upgrade ran"
else
  fail "upgrade failed: $(cat "$TMP/upgrade.out")"
fi
[ "$(cat "$PREFIX/current")" = "9.9.2" ] && ok "current now names 9.9.2" || fail "upgrade did not switch current: $(cat "$PREFIX/current")"
[ "$(bash "$PREFIX/bin/touchstone" version)" = "touchstone v9.9.2" ] && ok "wrapper runs the upgraded version" || fail "wrapper did not follow the upgrade"
[ -d "$PREFIX/cli/9.9.1" ] && ok "previous release retained for rollback (current can be edited back)" || fail "previous release removed"

echo "==> Input validation"
bash "$ROOT/install.sh" --prefix relative/path >/dev/null 2>&1 && fail "relative prefix accepted" || ok "relative prefix refused"
# A Windows drive path passes the absolute-path grammar. On this machine the
# run must stop before it creates anything (a relative "C:" directory would
# otherwise appear), so the formula is pointed at a missing file: the refusal
# is the fetch, not the prefix.
bash "$ROOT/install.sh" --prefix "C:/Users/me/.touchstone" --formula-file "$TMP/does-not-exist.rb" >"$TMP/win.out" 2>&1 || true
grep -q "must be an absolute path" "$TMP/win.out" && fail "a Windows drive prefix was refused as relative" || ok "Windows drive prefix accepted by the grammar"
[ ! -e "$ROOT/C:" ] && [ ! -e "C:" ] || fail "the Windows-prefix probe created a relative C: directory"
bash "$ROOT/install.sh" --version nope >/dev/null 2>&1 && fail "malformed version accepted" || ok "malformed version refused"
bash "$ROOT/install.sh" --bogus >/dev/null 2>&1 && fail "unknown argument accepted" || ok "unknown argument refused"

echo "==> hook subcommand"
bash "$ROOT/bin/touchstone" hook nope >/dev/null 2>&1 && fail "unknown hook accepted" || ok "unknown hook refused"
grep -q 'branch-guard) exec bash "$TOUCHSTONE_ROOT/hooks/branch-guard.sh"' "$ROOT/bin/touchstone" && ok "branch-guard resolves from the tool root" || fail "hook does not resolve from the tool root"

if [ "$ERRORS" -ne 0 ]; then
  echo "==> FAIL: $ERRORS install assertion(s) failed" >&2
  exit 1
fi
echo "==> PASS: install.sh installs, verifies, and upgrades the recorded release offline"
