#!/usr/bin/env bash
#
# install.sh — install or upgrade the Touchstone CLI without Homebrew.
#
# Homebrew is the distribution on macOS. Everywhere else bash runs (Windows
# Git Bash, Linux), this installs the same reviewed release: it reads the
# tap formula -- the one reviewed record of each release's tarball URL and
# sha256 -- downloads that tarball, verifies the checksum, and unpacks it
# under a prefix it owns. It never writes to a repository.
#
#   curl -fsSL https://raw.githubusercontent.com/autumngarage/touchstone/main/install.sh | bash
#   bash install.sh [--version X.Y.Z] [--prefix DIR]
#
# Layout under --prefix (default $HOME/.touchstone):
#   cli/<version>/   the release tree (bin/, scripts/, hooks/, principles/ ...)
#   bin/touchstone   wrapper that runs the current version (a script, not a
#                    symlink: Windows needs no privilege to create it)
#   current          the version the wrapper runs
#
# `touchstone upgrade` on such an install re-runs this script for the release
# the formula currently names. Test seams: --formula-file and --archive-file
# point at local copies so the behaviour is exercised offline.
set -euo pipefail

PREFIX="${TOUCHSTONE_INSTALL_PREFIX:-$HOME/.touchstone}"
VERSION=""
FORMULA_URL="https://raw.githubusercontent.com/autumngarage/homebrew-touchstone/main/Formula/touchstone.rb"
FORMULA_FILE=""
ARCHIVE_FILE=""

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version needs a value" 2
      VERSION="$2"
      shift 2
      ;;
    --prefix)
      [ $# -ge 2 ] || die "--prefix needs a value" 2
      PREFIX="$2"
      shift 2
      ;;
    --formula-file)
      [ $# -ge 2 ] || die "--formula-file needs a value" 2
      FORMULA_FILE="$2"
      shift 2
      ;;
    --archive-file)
      [ $# -ge 2 ] || die "--archive-file needs a value" 2
      ARCHIVE_FILE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$VERSION" in
  '' | [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "--version must be MAJOR.MINOR.PATCH, got '$VERSION'" 2 ;;
esac
# Absolute on POSIX (/...) or as Git Bash spells a Windows drive (C:/... or
# /c/...); the wrapper embeds this path, so it must not depend on the cwd.
case "$PREFIX" in
  /* | [A-Za-z]:/*) ;;
  *) die "--prefix must be an absolute path, got '$PREFIX'" 2 ;;
esac

for tool in bash tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 | cut -d' ' -f1; }
else
  die "sha256sum or shasum is required to verify the release"
fi

fetch() {
  # $1 url or local path, $2 destination
  case "$1" in
    /* | ./*) cp "$1" "$2" ;;
    *)
      command -v curl >/dev/null 2>&1 || die "curl is required to download $1"
      curl -fsSL --retry 3 --retry-delay 2 "$1" -o "$2" || die "could not download $1"
      ;;
  esac
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# The formula is the reviewed record of the release: url and sha256 together.
if [ -n "$FORMULA_FILE" ]; then
  fetch "$FORMULA_FILE" "$tmp/formula.rb"
else
  fetch "$FORMULA_URL" "$tmp/formula.rb"
fi
formula_url="$(sed -nE 's/^[[:space:]]*url[[:space:]]+"([^"]+)".*/\1/p' "$tmp/formula.rb" | head -n 1)"
formula_sha="$(sed -nE 's/^[[:space:]]*sha256[[:space:]]+"([0-9a-fA-F]{64})".*/\1/p' "$tmp/formula.rb" | head -n 1)"
[ -n "$formula_url" ] && [ -n "$formula_sha" ] || die "the formula names no release url and sha256"
formula_version="$(printf '%s' "$formula_url" | sed -nE 's#.*/v([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz$#\1#p')"
[ -n "$formula_version" ] || die "could not read a version from the formula url: $formula_url"

if [ -z "$VERSION" ] || [ "$VERSION" = "$formula_version" ]; then
  VERSION="$formula_version"
  archive_url="$formula_url"
  expected_sha="$formula_sha"
else
  # A pinned older or newer release has no reviewed checksum in the current
  # formula; refuse rather than install something nothing vouches for.
  die "the formula records $formula_version, not $VERSION; only the recorded release can be verified"
fi

target="$PREFIX/cli/$VERSION"
if [ -x "$target/bin/touchstone" ] && [ "$(cat "$PREFIX/current" 2>/dev/null)" = "$VERSION" ]; then
  printf 'touchstone %s is already installed at %s\n' "$VERSION" "$target"
  exit 0
fi

if [ -n "$ARCHIVE_FILE" ]; then
  fetch "$ARCHIVE_FILE" "$tmp/release.tar.gz"
else
  fetch "$archive_url" "$tmp/release.tar.gz"
fi
actual_sha="$(sha256 <"$tmp/release.tar.gz")"
[ "$actual_sha" = "$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')" ] \
  || die "checksum mismatch for $VERSION: expected $expected_sha, got $actual_sha"

mkdir -p "$tmp/unpack"
tar -xzf "$tmp/release.tar.gz" -C "$tmp/unpack"
unpacked="$(find "$tmp/unpack" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$unpacked" ] && [ -f "$unpacked/bin/touchstone" ] || die "the release archive does not contain bin/touchstone"
released="$(head -n 1 "$unpacked/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ "$released" = "$VERSION" ] || die "the archive reports VERSION '$released', not $VERSION"

# Install into place atomically: a failed unpack never leaves a half tree
# that the wrapper would run.
mkdir -p "$PREFIX/cli" "$PREFIX/bin"
rm -rf "$target.partial"
mv "$unpacked" "$target.partial"
chmod +x "$target.partial/bin/touchstone"
rm -rf "$target"
mv "$target.partial" "$target"

# The wrapper embeds the prefix as data, never as shell source: it is written
# through printf %q so a prefix containing metacharacters cannot execute when
# the wrapper starts. Written to a temporary file and renamed into place, so
# a CLI or hook invocation that starts mid-upgrade never reads a half-written
# script.
prefix_quoted="$(printf '%q' "$PREFIX")"
# Unique per process: two installers sharing a prefix must not write the same
# staging file; the rename keeps the last complete one.
wrapper_next="$(mktemp "$PREFIX/bin/touchstone.next.XXXXXX")"
{
  printf '#!/usr/bin/env bash\n'
  printf '# Touchstone CLI wrapper (installed by install.sh). Runs the version named\n'
  printf '# in <prefix>/current; "touchstone upgrade" rewrites that file.\n'
  printf 'set -euo pipefail\n'
  printf 'prefix=%s\n' "$prefix_quoted"
  # shellcheck disable=SC2016 # the wrapper's own variables, expanded when it runs
  printf 'current="$(cat "$prefix/current" 2>/dev/null)" || { echo "ERROR: $prefix/current is missing; re-run install.sh" >&2; exit 1; }\n'
  # shellcheck disable=SC2016
  printf 'exec bash "$prefix/cli/$current/bin/touchstone" "$@"\n'
} >"$wrapper_next"
chmod +x "$wrapper_next"
mv "$wrapper_next" "$PREFIX/bin/touchstone"
printf '%s\n' "$VERSION" >"$PREFIX/current.next"
mv "$PREFIX/current.next" "$PREFIX/current"

printf 'touchstone %s installed at %s\n' "$VERSION" "$target"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *)
    printf '\nAdd the wrapper to PATH (then open a new shell):\n'
    # shellcheck disable=SC2016 # the literal $PATH is for the reader's shell
    printf '  export PATH="%s/bin:$PATH"\n' "$PREFIX"
    ;;
esac
for tool in git gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'warning: %s is not on PATH; touchstone needs it.' "$tool" >&2
    case "$(uname -s 2>/dev/null)" in
      MINGW* | MSYS* | CYGWIN*)
        case "$tool" in
          git) printf ' Install Git for Windows: winget install Git.Git' >&2 ;;
          gh) printf ' winget install GitHub.cli' >&2 ;;
          jq) printf ' winget install jqlang.jq' >&2 ;;
        esac
        ;;
    esac
    printf '\n' >&2
  fi
done
