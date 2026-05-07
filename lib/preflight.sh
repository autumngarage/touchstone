#!/usr/bin/env bash
#
# lib/preflight.sh — deterministic review preflight checks.
#
# Public entrypoint:
#   touchstone_preflight_main [repo-root]
#
# Tooling policy: missing local linters are skipped with a visible line, not
# treated as failures. Touchstone projects can run on fresh machines where the
# deterministic gate should still enforce every installed check and the test
# suite without turning optional dev-tool installation into a merge blocker.
#
set -euo pipefail

touchstone_preflight_info() { printf '==> %s\n' "$*"; }
touchstone_preflight_ok() { printf '  OK %s\n' "$*"; }
touchstone_preflight_skip() { printf '  SKIP %s\n' "$*"; }
touchstone_preflight_fail() { printf '  FAIL %s\n' "$*" >&2; }

touchstone_preflight_repo_root() {
  local requested="${1:-}"
  if [ -n "$requested" ]; then
    (cd "$requested" && pwd)
    return
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

touchstone_preflight_all_files() {
  git ls-files 2>/dev/null
}

touchstone_preflight_changed_files() {
  local base="${TOUCHSTONE_PREFLIGHT_BASE:-}"

  if [ -z "$base" ]; then
    base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    [ -n "$base" ] || base="origin/main"
  fi

  if git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
    {
      git diff --name-only "$base"...HEAD 2>/dev/null || true
      git diff --name-only --cached 2>/dev/null || true
      git diff --name-only 2>/dev/null || true
    } | sort -u
    return 0
  fi

  touchstone_preflight_all_files
}

touchstone_preflight_shell_files() {
  touchstone_preflight_changed_files \
    | awk '
        /^completions\// { next }
        /^prototypes\// { next }
        { print }
      ' \
    | while IFS= read -r path; do
      [ -n "$path" ] || continue
      [ -f "$path" ] || continue
      case "$path" in
        *.sh | bin/touchstone)
          printf '%s\n' "$path"
          ;;
        *)
          if IFS= read -r first_line <"$path" \
            && printf '%s\n' "$first_line" | grep -Eq '^#!.*(sh|bash|zsh|ksh)'; then
            printf '%s\n' "$path"
          fi
          ;;
      esac
    done
}

touchstone_preflight_shfmt_files() {
  touchstone_preflight_shell_files \
    | awk '
        $0 == "bin/touchstone" { next }
        { print }
      '
}

touchstone_preflight_markdown_files() {
  touchstone_preflight_changed_files \
    | awk '
        /^\.cortex\// { next }
        /\.md$/ { print }
      '
}

touchstone_preflight_workflow_files() {
  touchstone_preflight_changed_files \
    | awk '
        /^\.github\/workflows\/.*\.ya?ml$/ { print }
      '
}

touchstone_preflight_run_list() {
  local label="$1"
  local command_name="$2"
  shift 2
  local -a args=("$@")
  local files

  if ! command -v "$command_name" >/dev/null 2>&1; then
    touchstone_preflight_skip "$label ($command_name not installed)"
    return 0
  fi

  files="$(cat)"
  if [ -z "$files" ]; then
    touchstone_preflight_skip "$label (no matching files)"
    return 0
  fi

  touchstone_preflight_info "$label"
  if printf '%s\n' "$files" | xargs "$command_name" "${args[@]}"; then
    touchstone_preflight_ok "$label"
    return 0
  fi

  touchstone_preflight_fail "$label"
  return 1
}

touchstone_preflight_markdownlint() {
  local files
  files="$(touchstone_preflight_markdown_files)"
  if [ -z "$files" ]; then
    touchstone_preflight_skip "markdownlint (no matching files)"
    return 0
  fi

  if command -v markdownlint-cli2 >/dev/null 2>&1; then
    touchstone_preflight_info "markdownlint-cli2"
    if printf '%s\n' "$files" | xargs markdownlint-cli2; then
      touchstone_preflight_ok "markdownlint-cli2"
      return 0
    fi
    touchstone_preflight_fail "markdownlint-cli2"
    return 1
  fi

  if command -v markdownlint >/dev/null 2>&1; then
    touchstone_preflight_info "markdownlint"
    if printf '%s\n' "$files" | xargs markdownlint --config .markdownlint.json; then
      touchstone_preflight_ok "markdownlint"
      return 0
    fi
    touchstone_preflight_fail "markdownlint"
    return 1
  fi

  touchstone_preflight_skip "markdownlint (markdownlint-cli2/markdownlint not installed)"
  return 0
}

touchstone_preflight_validate() {
  local validate_script="${TOUCHSTONE_PREFLIGHT_VALIDATE_SCRIPT:-scripts/touchstone-run.sh}"
  local validate_command="${TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND:-}"

  if [ -n "$validate_command" ]; then
    touchstone_preflight_info "tests ($validate_command)"
    if TOUCHSTONE_PREFLIGHT_IN_PROGRESS=1 bash -c "$validate_command"; then
      touchstone_preflight_ok "tests"
      return 0
    fi
    touchstone_preflight_fail "tests"
    return 1
  fi

  if [ ! -f "$validate_script" ]; then
    touchstone_preflight_skip "tests ($validate_script not found)"
    return 0
  fi

  touchstone_preflight_info "tests (touchstone-run validate)"
  if TOUCHSTONE_PREFLIGHT_IN_PROGRESS=1 bash "$validate_script" validate; then
    touchstone_preflight_ok "tests"
    return 0
  fi

  touchstone_preflight_fail "tests"
  return 1
}

touchstone_preflight_run() {
  local repo_root="$1"
  local failures=0

  cd "$repo_root"
  touchstone_preflight_info "preflight in $repo_root"

  touchstone_preflight_shell_files \
    | touchstone_preflight_run_list "shellcheck" shellcheck --severity=warning \
    || failures=$((failures + 1))
  touchstone_preflight_shfmt_files \
    | touchstone_preflight_run_list "shfmt -d" shfmt -d -i 2 -ci -bn \
    || failures=$((failures + 1))
  touchstone_preflight_markdownlint || failures=$((failures + 1))
  touchstone_preflight_workflow_files \
    | touchstone_preflight_run_list "actionlint" actionlint \
    || failures=$((failures + 1))
  touchstone_preflight_validate || failures=$((failures + 1))

  if [ "$failures" -eq 0 ]; then
    touchstone_preflight_info "preflight clean"
    return 0
  fi

  touchstone_preflight_fail "preflight failed ($failures check group(s))"
  return 1
}

touchstone_preflight_main() {
  local repo_root
  repo_root="$(touchstone_preflight_repo_root "${1:-}")"
  touchstone_preflight_run "$repo_root"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  touchstone_preflight_main "$@"
fi
