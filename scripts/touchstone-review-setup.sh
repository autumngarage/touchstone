#!/usr/bin/env bash
#
# Install the lower-cost Codex profile used for normal local review.
# The OpenRouter credential lives in macOS Keychain. The review launcher gives
# it only to one isolated Codex parent process. Project configuration is not
# trusted for that process, shell snapshots are disabled, and the managed
# profile strips it from every model-issued subprocess.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROFILE_SOURCE="$ROOT/config/review-normal.config.toml"
KEYCHAIN_SERVICE="com.autumngarage.touchstone.review-normal"
ACTION="${1:-}"

[ -n "$ACTION" ] || {
  echo "Usage: touchstone review setup|check|run|rotate|uninstall" >&2
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
CODEX_BIN="${TOUCHSTONE_REVIEW_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"

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
  local key
  key="$(
    "$SECURITY_BIN" find-generic-password \
      -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
  )" || return 1
  [ -n "$key" ]
}

cleanup_runtime_home() {
  local exit_status="$?"
  trap - EXIT HUP INT TERM
  unset OPENROUTER_API_KEY
  if [ -n "${RUNTIME_HOME:-}" ] && [ -d "$RUNTIME_HOME" ]; then
    if ! find "$RUNTIME_HOME" -depth -delete; then
      echo "ERROR: could not remove isolated review state: $RUNTIME_HOME" >&2
      exit 1
    fi
  fi
  exit "$exit_status"
}

rollback_new_key() {
  local exit_status="$?"
  trap - EXIT
  if [ "$exit_status" -ne 0 ] && [ "${KEY_WAS_ADDED:-false}" = true ]; then
    if ! "$SECURITY_BIN" delete-generic-password \
      -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
      echo "ERROR: setup failed and the new Keychain credential could not be rolled back; run: touchstone review uninstall" >&2
      exit 1
    fi
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
  if ! cp "$PROFILE_SOURCE" "$temporary"; then
    rm -f -- "$temporary" \
      || die "could not copy the managed profile and could not remove its temporary file: $temporary"
    die "could not copy the managed profile into $CODEX_HOME_DIR"
  fi
  if ! chmod 600 "$temporary"; then
    rm -f -- "$temporary" \
      || die "could not secure the temporary profile and could not remove it: $temporary"
    die "could not restrict the temporary review profile to mode 600"
  fi

  if [ -e "$PROFILE" ]; then
    if ! mv "$PROFILE" "$BACKUP"; then
      rm -f -- "$temporary" \
        || die "could not back up $PROFILE and could not remove its temporary replacement: $temporary"
      die "could not back up the operator profile: $PROFILE"
    fi
    echo "  backed up: $PROFILE -> $BACKUP"
  fi
  if [ "${TOUCHSTONE_REVIEW_FAIL_PROFILE_PUBLISH:-false}" = true ] \
    || ! mv "$temporary" "$PROFILE"; then
    if [ -e "$BACKUP" ]; then
      if mv "$BACKUP" "$PROFILE"; then
        rm -f -- "$temporary" \
          || die "profile publication failed and the operator profile was restored, but the temporary file remains: $temporary"
        die "could not install $PROFILE; the previous operator profile was restored"
      fi
      die "could not install $PROFILE and could not restore its backup; recover the operator profile from $BACKUP and inspect the temporary replacement at $temporary"
    fi
    rm -f -- "$temporary" \
      || die "profile publication failed and its temporary file remains: $temporary"
    die "could not install $PROFILE; no previous operator profile was moved"
  fi
  echo "  installed: $PROFILE"
}

case "$ACTION" in
  run)
    RUNTIME_HOME=""
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for run"
    require_keychain
    profile_is_current \
      || die "normal-review profile is absent or drifted; run: touchstone review setup"
    [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] \
      || die "Codex is unavailable; install it before running normal review"
    OPENROUTER_API_KEY="$(
      "$SECURITY_BIN" find-generic-password \
        -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w
    )" || die "OpenRouter credential is absent from macOS Keychain; run: touchstone review setup"
    [ -n "$OPENROUTER_API_KEY" ] \
      || die "OpenRouter credential is empty; run: touchstone review rotate"
    REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || die "normal review must run inside a git repository"
    REPOSITORY_ROOT="$(cd "$REPOSITORY_ROOT" && pwd -P)"
    case "$REPOSITORY_ROOT" in
      *[\"\\]* | *$'\n'*)
        die "repository path cannot be represented safely in the isolated Codex trust boundary: $REPOSITORY_ROOT"
        ;;
    esac
    RUNTIME_HOME="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-review.XXXXXX")" \
      || die "could not create isolated Codex state for normal review"
    trap cleanup_runtime_home EXIT HUP INT TERM
    cp "$PROFILE" "$RUNTIME_HOME/review-normal.config.toml" \
      || die "could not stage the managed review profile in isolated Codex state"
    chmod 700 "$RUNTIME_HOME" \
      || die "could not restrict isolated Codex state"
    chmod 600 "$RUNTIME_HOME/review-normal.config.toml" \
      || die "could not restrict the isolated review profile"
    CODEX_HOME="$RUNTIME_HOME"
    export CODEX_HOME
    export OPENROUTER_API_KEY
    "$CODEX_BIN" \
      -p review-normal \
      -c "projects.\"$REPOSITORY_ROOT\".trust_level=\"untrusted\"" \
      -c 'shell_environment_policy.filters.OPENROUTER_API_KEY="exclude"' \
      -c 'allow_login_shell=false' \
      --disable shell_snapshot \
      --disable plugins \
      --disable plugin_hooks \
      --disable enable_mcp_apps \
      -s read-only \
      -a never \
      exec --ephemeral --ignore-rules review --uncommitted
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
    transaction=""
    restored_backup=false
    if [ -e "$PROFILE" ] || [ -e "$BACKUP" ]; then
      transaction="$(mktemp -d "$CODEX_HOME_DIR/.review-normal-uninstall.XXXXXX")" \
        || die "could not start a recoverable uninstall transaction in $CODEX_HOME_DIR"
    fi
    if [ -e "$PROFILE" ]; then
      if ! mv "$PROFILE" "$transaction/managed-profile"; then
        rmdir "$transaction" 2>/dev/null \
          || die "could not remove empty uninstall transaction: $transaction"
        die "could not stage the managed review profile for removal: $PROFILE"
      fi
      echo "  staged removal: $PROFILE"
    fi
    if [ -e "$BACKUP" ]; then
      if ! mv "$BACKUP" "$PROFILE"; then
        if [ -e "$transaction/managed-profile" ]; then
          if ! mv "$transaction/managed-profile" "$PROFILE"; then
            die "could not restore $BACKUP and could not roll back $PROFILE; recover the managed profile from $transaction/managed-profile"
          fi
        fi
        rmdir "$transaction" 2>/dev/null \
          || die "profile restoration failed and the empty transaction remains: $transaction"
        die "could not restore the operator profile from $BACKUP; the managed profile was put back"
      fi
      restored_backup=true
      echo "  restored: $PROFILE"
    fi
    if key_exists; then
      if ! "$SECURITY_BIN" delete-generic-password \
        -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" >/dev/null; then
        rollback_error=""
        if [ "$restored_backup" = true ] && ! mv "$PROFILE" "$BACKUP"; then
          rollback_error="could not move the restored operator profile back to $BACKUP"
        fi
        if [ -n "$transaction" ] && [ -e "$transaction/managed-profile" ] \
          && ! mv "$transaction/managed-profile" "$PROFILE"; then
          rollback_error="${rollback_error:+$rollback_error; }could not put the managed profile back at $PROFILE"
        fi
        if [ -n "$rollback_error" ]; then
          die "Keychain credential removal failed and profile rollback was incomplete: $rollback_error; inspect $transaction"
        fi
        [ -z "$transaction" ] || rmdir "$transaction" \
          || die "Keychain credential removal failed; profile state was restored, but the empty transaction remains: $transaction"
        die "OpenRouter credential could not be removed; the managed profile state was restored"
      fi
      echo "  removed: OpenRouter credential from macOS Keychain"
    fi
    if [ -n "$transaction" ]; then
      if [ -e "$transaction/managed-profile" ]; then
        rm -f -- "$transaction/managed-profile" \
          || die "credential was removed, but the staged managed profile remains: $transaction/managed-profile"
      fi
      rmdir "$transaction" \
        || die "credential was removed, but the empty uninstall transaction remains: $transaction"
    fi
    echo "==> lower-cost normal review setup removed"
    ;;
  *)
    echo "ERROR: unknown review command '$ACTION'; available: setup, check, run, rotate, uninstall" >&2
    exit 2
    ;;
esac
