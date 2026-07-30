#!/usr/bin/env bash
#
# lib/sha256.sh — portable SHA-256 helpers for Touchstone shell workflows.
#
# macOS ships shasum, while Git for Windows and most Linux environments ship
# sha256sum. Keep that platform difference behind one fail-closed adapter so
# preflight, merge authorization, and project updates compute identical values.

touchstone_sha256_program() {
  if command -v shasum >/dev/null 2>&1; then
    printf 'shasum\n'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
    return 0
  fi

  echo "ERROR: SHA-256 hashing requires 'shasum' or 'sha256sum' on PATH." >&2
  return 127
}

touchstone_sha256_stream() {
  local program
  program="$(touchstone_sha256_program)" || return $?

  case "$program" in
    shasum) shasum -a 256 ;;
    sha256sum) sha256sum ;;
    *)
      echo "ERROR: unsupported SHA-256 program: $program" >&2
      return 127
      ;;
  esac | awk '{ print $1 }'
}

touchstone_sha256_file() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    echo "ERROR: touchstone_sha256_file requires a file path." >&2
    return 2
  fi

  touchstone_sha256_stream <"$path"
}
