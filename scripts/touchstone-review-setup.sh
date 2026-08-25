#!/usr/bin/env bash
#
# Install the lower-cost Codex profile used for normal local review.
# The OpenRouter credential lives in macOS Keychain; the generated profile
# contains only a command-backed auth reference and can be read safely by every
# coding-agent process without inheriting an environment variable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROFILE_SOURCE="$ROOT/config/review-normal.config.toml"
KEYCHAIN_SERVICE="com.autumngarage.touchstone.review-normal"
ACTION="${1:-}"

[ -n "$ACTION" ] || {
  echo "Usage: touchstone review setup|check|rotate|uninstall" >&2
  exit 2
}
shift

CODEX_HOME_DIR="${CODEX_HOME:-${HOME:-}/.codex}"
DRY_RUN=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex-home)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --codex-home requires a non-empty directory" >&2
        exit 2
      }
      CODEX_HOME_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

case "$CODEX_HOME_DIR" in
  /*) ;;
  *) die "Codex home must be an absolute path: $CODEX_HOME_DIR" ;;
esac

PROFILE="$CODEX_HOME_DIR/review-normal.config.toml"
BACKUP="$CODEX_HOME_DIR/review-normal.config.toml.pre-touchstone"
# A user may intentionally keep independent Codex homes. The home path is the
# Keychain account so uninstalling or rotating one profile cannot invalidate
# another profile that uses the same service.
KEYCHAIN_ACCOUNT="$CODEX_HOME_DIR"
PLATFORM="${TOUCHSTONE_REVIEW_PLATFORM:-$(uname -s)}"
SECURITY_BIN="${TOUCHSTONE_REVIEW_SECURITY_BIN:-/usr/bin/security}"

[ -r "$PROFILE_SOURCE" ] || die "managed review profile is missing: $PROFILE_SOURCE"

files_equal() {
  [ -f "$1" ] && [ -f "$2" ] \
    && [ "$(cksum <"$1")" = "$(cksum <"$2")" ]
}

require_keychain() {
  [ "$PLATFORM" = Darwin ] \
    || die "automatic review credential setup currently requires macOS Keychain; leave the normal-review waiver explicit on this platform"
  [ -x "$SECURITY_BIN" ] \
    || die "macOS Keychain command is unavailable at $SECURITY_BIN"
}

key_exists() {
  "$SECURITY_BIN" find-generic-password \
    -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1
}

rollback_new_key() {
  local exit_status="$?"
  trap - EXIT
  if [ "$exit_status" -ne 0 ] && [ "${KEY_WAS_ADDED:-false}" = true ]; then
    "$SECURITY_BIN" delete-generic-password \
      -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}

profile_is_managed() {
  [ -f "$PROFILE" ] && [ ! -L "$PROFILE" ] \
    && grep -qFx '# touchstone:review-normal:v1' "$PROFILE"
}

profile_is_current() {
  [ ! -L "$PROFILE" ] && files_equal "$PROFILE" "$PROFILE_SOURCE"
}

preflight_profile() {
  [ ! -L "$CODEX_HOME_DIR" ] \
    || die "Codex home is a symlink; refusing to choose its ownership boundary: $CODEX_HOME_DIR"
  [ ! -L "$PROFILE" ] || die "review profile is a symlink; refusing to replace it: $PROFILE"
  [ ! -L "$BACKUP" ] || die "review profile backup is a symlink; refusing to use it: $BACKUP"
  if profile_is_managed && ! profile_is_current; then
    die "the Touchstone-managed review profile has local edits; move it aside before reinstalling: $PROFILE"
  fi
  if ! profile_is_current && [ -e "$PROFILE" ] && [ -e "$BACKUP" ]; then
    die "both the review profile and its pre-Touchstone backup exist; reconcile them before setup: $PROFILE"
  fi
}

install_profile() {
  local temporary
  mkdir -p "$CODEX_HOME_DIR"
  preflight_profile

  if profile_is_current; then
    return 0
  fi

  temporary="$(mktemp "$CODEX_HOME_DIR/.review-normal.config.toml.XXXXXX")" \
    || die "could not create a temporary profile in $CODEX_HOME_DIR"
  trap 'rm -f -- "${temporary:-}"' RETURN
  cp "$PROFILE_SOURCE" "$temporary"
  chmod 600 "$temporary"

  if [ -e "$PROFILE" ]; then
    mv "$PROFILE" "$BACKUP"
    echo "  backed up: $PROFILE -> $BACKUP"
  fi
  if ! mv "$temporary" "$PROFILE"; then
    [ ! -e "$BACKUP" ] || mv "$BACKUP" "$PROFILE" || true
    die "could not install $PROFILE"
  fi
  trap - RETURN
  echo "  installed: $PROFILE"
}

case "$ACTION" in
  token)
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for the token command"
    require_keychain
    exec "$SECURITY_BIN" find-generic-password \
      -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w
    ;;
  check)
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for check"
    require_keychain
    profile_is_current \
      || die "normal-review profile is absent or drifted; run: touchstone review setup"
    key_exists \
      || die "OpenRouter credential is absent from macOS Keychain; run: touchstone review setup"
    echo "==> PASS: lower-cost normal review is configured"
    ;;
  setup)
    KEY_WAS_ADDED=false
    require_keychain
    preflight_profile
    if [ "$DRY_RUN" = true ]; then
      if profile_is_current; then
        echo "  current: $PROFILE"
      elif [ -e "$PROFILE" ]; then
        echo "  would back up: $PROFILE -> $BACKUP"
        echo "  would install: $PROFILE"
      else
        echo "  would install: $PROFILE"
      fi
      if key_exists; then
        echo "  current: OpenRouter credential in macOS Keychain"
      else
        echo "  would securely prompt for an OpenRouter key and save it in macOS Keychain"
      fi
      echo "==> dry run: nothing was changed"
      exit 0
    fi
    if ! key_exists; then
      echo "OpenRouter powers Touchstone's lower-cost normal local review."
      echo "Paste a dedicated OpenRouter API key into the secure macOS Keychain prompt."
      "$SECURITY_BIN" add-generic-password -U \
        -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w \
        || die "OpenRouter credential was not saved"
      KEY_WAS_ADDED=true
      trap rollback_new_key EXIT
      key_exists || die "OpenRouter credential was not readable after setup"
      echo "  saved: OpenRouter credential in macOS Keychain"
    else
      echo "  current: OpenRouter credential in macOS Keychain"
    fi
    install_profile
    trap - EXIT
    echo "==> lower-cost normal review is ready; future runs do not need an environment variable or approval"
    ;;
  rotate)
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for rotate"
    require_keychain
    profile_is_current \
      || die "normal-review profile is absent or drifted; run: touchstone review setup"
    echo "Paste the replacement OpenRouter API key into the secure macOS Keychain prompt."
    "$SECURITY_BIN" add-generic-password -U \
      -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w \
      || die "OpenRouter credential was not replaced"
    key_exists || die "replacement OpenRouter credential was not readable; run: touchstone review rotate"
    echo "==> OpenRouter credential replaced for $CODEX_HOME_DIR"
    ;;
  uninstall)
    require_keychain
    if [ -e "$PROFILE" ] && ! profile_is_current; then
      die "review profile is not the current Touchstone-managed file; refusing to remove it: $PROFILE"
    fi
    [ ! -L "$BACKUP" ] || die "review profile backup is a symlink; refusing to restore it: $BACKUP"
    if [ "$DRY_RUN" = true ]; then
      [ ! -e "$PROFILE" ] || echo "  would remove: $PROFILE"
      [ ! -e "$BACKUP" ] || echo "  would restore: $BACKUP -> $PROFILE"
      key_exists && echo "  would remove: OpenRouter credential from macOS Keychain"
      echo "==> dry run: nothing was changed"
      exit 0
    fi
    if key_exists; then
      "$SECURITY_BIN" delete-generic-password \
        -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" >/dev/null
      echo "  removed: OpenRouter credential from macOS Keychain"
    fi
    if [ -e "$PROFILE" ]; then
      rm -f -- "$PROFILE"
      echo "  removed: $PROFILE"
    fi
    if [ -e "$BACKUP" ]; then
      mv "$BACKUP" "$PROFILE"
      echo "  restored: $PROFILE"
    fi
    echo "==> lower-cost normal review setup removed"
    ;;
  *)
    echo "ERROR: unknown review command '$ACTION'; available: setup, check, rotate, uninstall" >&2
    exit 2
    ;;
esac
