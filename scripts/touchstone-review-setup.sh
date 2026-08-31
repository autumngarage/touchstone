#!/usr/bin/env bash
#
# Configure and launch the lower-cost Codex pass used for normal local review.
# The OpenRouter credential lives in macOS Keychain and is exported only to one
# isolated, ephemeral Codex process. Its sandbox cannot read Keychain and its
# child environment excludes the key.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROFILE_SOURCE="$ROOT/config/review-normal.config.toml"
KEYCHAIN_SERVICE="com.autumngarage.touchstone.review-normal"
ACTION="${1:-}"

# shellcheck source=lib/touchstone-review-codex.sh
source "$ROOT/scripts/lib/touchstone-review-codex.sh"

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

# A user may intentionally keep independent Codex homes. The home path is the
# Keychain account so rotating or uninstalling one cannot invalidate another.
KEYCHAIN_ACCOUNT="$CODEX_HOME_DIR"
PLATFORM="${TOUCHSTONE_REVIEW_PLATFORM:-$(uname -s)}"
SECURITY_BIN="${TOUCHSTONE_REVIEW_SECURITY_BIN:-/usr/bin/security}"

[ -r "$PROFILE_SOURCE" ] || die "managed review profile is missing: $PROFILE_SOURCE"

require_keychain() {
  [ "$PLATFORM" = Darwin ] \
    || die "automatic review credential setup currently requires macOS Keychain; leave the normal-review waiver explicit on this platform"
  [ -x "$SECURITY_BIN" ] \
    || die "macOS Keychain command is unavailable at $SECURITY_BIN"
}

# Results: 0 = usable value in KEY_VALUE, 3 = empty value, 44 = no item.
# Every other Keychain failure is operational and exits loudly.
lookup_key() {
  local status
  KEY_VALUE=""
  if KEY_VALUE="$(
    "$SECURITY_BIN" find-generic-password \
      -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
  )"; then
    [ -n "$KEY_VALUE" ] || return 3
    return 0
  else
    status="$?"
  fi
  [ "$status" -eq 44 ] && return 44
  die "macOS Keychain lookup failed with status $status; unlock Keychain or repair access before retrying"
}

require_usable_key() {
  local status
  if lookup_key; then
    return 0
  else
    status="$?"
  fi
  case "$status" in
    3) die "OpenRouter credential is empty; run: touchstone review rotate" ;;
    44) die "OpenRouter credential is absent from macOS Keychain; run: touchstone review setup" ;;
    *) die "unexpected Keychain lookup status: $status" ;;
  esac
}

resolve_codex() {
  local candidate bundled_path
  case "${PATH:-}" in
    *$'\n'*) die "PATH contains a newline and cannot safely resolve Codex" ;;
  esac
  candidate="$(command -v codex 2>/dev/null || true)"
  [ -n "$candidate" ] && [ -x "$candidate" ] \
    || die "Codex is unavailable; install the signed OpenAI Codex CLI before running normal review"
  touchstone_resolve_codex_native "$candidate" "$PLATFORM" "$(uname -m)" \
    || die "$TOUCHSTONE_CODEX_ERROR"
  candidate="$TOUCHSTONE_CODEX_BIN"
  bundled_path="$TOUCHSTONE_CODEX_BUNDLED_PATH"
  touchstone_verify_openai_codex "$candidate" /usr/bin/codesign \
    || die "$TOUCHSTONE_CODEX_ERROR"
  if [ -n "$bundled_path" ]; then
    if [ -n "${PATH:-}" ]; then
      PATH="$bundled_path:$PATH"
    else
      PATH="$bundled_path"
    fi
    export PATH
  fi
  CODEX_BIN="$candidate"
}

cleanup_runtime_home() {
  local exit_status="$?"
  trap - EXIT HUP INT TERM
  unset OPENROUTER_API_KEY KEY_VALUE
  if [ -n "${RUNTIME_HOME:-}" ] && [ -d "$RUNTIME_HOME" ]; then
    if ! find "$RUNTIME_HOME" -depth -delete; then
      echo "ERROR: could not remove isolated review state: $RUNTIME_HOME" >&2
      exit 1
    fi
  fi
  exit "$exit_status"
}

prepare_review_runtime() {
  local invoking_dir

  invoking_dir="$(pwd -P)"
  touchstone_review_resolve_git_context "$invoking_dir" \
    || die "$TOUCHSTONE_CODEX_ERROR"
  REPOSITORY_ROOT="$TOUCHSTONE_REVIEW_REPOSITORY_ROOT"
  REVIEW_GIT_DIR="$TOUCHSTONE_REVIEW_GIT_DIR"
  REVIEW_GIT_COMMON_DIR="$TOUCHSTONE_REVIEW_GIT_COMMON_DIR"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES \
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_SYSTEM=/dev/null
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=core.excludesFile
  GIT_CONFIG_VALUE_0=/dev/null
  export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT \
    GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  cd "$REPOSITORY_ROOT"
  RUNTIME_HOME="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-review.XXXXXX")" \
    || die "could not create isolated Codex state for normal review"
  trap cleanup_runtime_home EXIT HUP INT TERM
  touchstone_review_render_profile \
    "$PROFILE_SOURCE" "$RUNTIME_HOME/review-normal.config.toml" \
    "$REPOSITORY_ROOT" "$REVIEW_GIT_DIR" "$REVIEW_GIT_COMMON_DIR" \
    || die "$TOUCHSTONE_CODEX_ERROR"
  chmod 700 "$RUNTIME_HOME" \
    || die "could not restrict isolated review state"
  chmod 600 "$RUNTIME_HOME/review-normal.config.toml" \
    || die "could not restrict the isolated review profile"
  CODEX_HOME="$RUNTIME_HOME"
  export CODEX_HOME
}

resolve_review_git() {
  REVIEW_GIT_BIN=""
  if [ "$PLATFORM" = Darwin ] && [ -x /usr/bin/xcrun ]; then
    REVIEW_GIT_BIN="$(/usr/bin/xcrun --find git 2>/dev/null)" \
      || die "could not resolve the Git executable for the review preflight"
  else
    REVIEW_GIT_BIN="$(command -v git 2>/dev/null || true)"
  fi
  [ -n "$REVIEW_GIT_BIN" ] && [ -x "$REVIEW_GIT_BIN" ] \
    || die "Git is unavailable for the review preflight"
}

case "$ACTION" in
  credential-check)
    # Machine-level steering installation can run outside a repository. Its
    # only setup decision is whether the managed Keychain item already exists;
    # repository/profile/Git validation remains the public `review check`.
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for credential-check"
    require_keychain
    require_usable_key
    unset KEY_VALUE OPENROUTER_API_KEY
    ;;
  run)
    RUNTIME_HOME=""
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for run"
    touchstone_review_resolve_git_context "$(pwd -P)" \
      || die "$TOUCHSTONE_CODEX_ERROR"
    touchstone_review_require_uncommitted_slice \
      "$TOUCHSTONE_REVIEW_REPOSITORY_ROOT" \
      || die "$TOUCHSTONE_CODEX_ERROR"
    require_keychain
    require_usable_key
    resolve_codex
    resolve_review_git
    PATH="$(dirname "$REVIEW_GIT_BIN"):${PATH:-/usr/bin:/bin}"
    export PATH
    prepare_review_runtime
    OPENROUTER_API_KEY="$KEY_VALUE"
    unset KEY_VALUE
    export OPENROUTER_API_KEY
    touchstone_review_codex "$CODEX_BIN" \
      --strict-config \
      -a never \
      exec --ephemeral --ignore-rules review --uncommitted
    ;;
  check)
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for check"
    require_keychain
    require_usable_key
    unset KEY_VALUE OPENROUTER_API_KEY
    resolve_codex
    prepare_review_runtime
    resolve_review_git
    touchstone_review_validate_launch \
      "$CODEX_BIN" "$REPOSITORY_ROOT" "$REVIEW_GIT_BIN" \
      || die "$TOUCHSTONE_CODEX_ERROR"
    echo "==> PASS: lower-cost normal review is configured"
    ;;
  setup)
    require_keychain
    status=0
    lookup_key || status="$?"
    if [ "$DRY_RUN" = true ]; then
      case "$status" in
        0) echo "  current: OpenRouter credential in macOS Keychain" ;;
        3) echo "  would replace: empty OpenRouter credential in macOS Keychain" ;;
        44) echo "  would securely prompt for an OpenRouter key and save it in macOS Keychain" ;;
      esac
      echo "==> dry run: nothing was changed"
      exit 0
    fi
    if [ "$status" -ne 0 ]; then
      echo "OpenRouter powers Touchstone's lower-cost normal local review."
      echo "Paste a dedicated OpenRouter API key into the secure macOS Keychain prompt."
      "$SECURITY_BIN" add-generic-password -U \
        -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w \
        || die "OpenRouter credential was not saved"
      require_usable_key
      echo "  saved: OpenRouter credential in macOS Keychain"
    else
      echo "  current: OpenRouter credential in macOS Keychain"
    fi
    echo "==> lower-cost normal review is ready; future runs do not need an environment variable or approval"
    ;;
  rotate)
    [ "$DRY_RUN" = false ] || die "--dry-run is not valid for rotate"
    require_keychain
    echo "Paste the replacement OpenRouter API key into the secure macOS Keychain prompt."
    "$SECURITY_BIN" add-generic-password -U \
      -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w \
      || die "OpenRouter credential was not replaced"
    require_usable_key
    echo "==> OpenRouter credential replaced for $CODEX_HOME_DIR"
    ;;
  uninstall)
    require_keychain
    status=0
    lookup_key || status="$?"
    if [ "$DRY_RUN" = true ]; then
      [ "$status" -eq 44 ] \
        || echo "  would remove: OpenRouter credential from macOS Keychain"
      echo "==> dry run: nothing was changed"
      exit 0
    fi
    if [ "$status" -ne 44 ]; then
      "$SECURITY_BIN" delete-generic-password \
        -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" >/dev/null \
        || die "OpenRouter credential could not be removed"
      echo "  removed: OpenRouter credential from macOS Keychain"
    fi
    echo "==> lower-cost normal review setup removed"
    ;;
  *)
    echo "ERROR: unknown review command '$ACTION'; available: setup, check, run, rotate, uninstall" >&2
    exit 2
    ;;
esac
