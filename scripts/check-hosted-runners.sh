#!/usr/bin/env bash
#
# scripts/check-hosted-runners.sh -- refuse GitHub-hosted macOS and Windows
# runners in a repository's workflows.
#
# Usage:
#   bash scripts/check-hosted-runners.sh [PROJECT_DIR]
#
# Reads every .github/workflows/*.yml and *.yaml file in PROJECT_DIR (default:
# the current directory) and refuses two shapes:
#
#   1. A GitHub-hosted macOS or Windows image named on any non-comment line:
#      macos-<n>, macos-latest, windows-<n>, windows-latest, and the larger
#      runner variants spelled from them (macos-15-xlarge,
#      windows-latest-8-cores). Whole lines are read, so a matrix entry or an
#      expression's fallback is caught, not only a literal runs-on value.
#   2. A runs-on selector that takes a label from a setting (vars.*) without
#      also naming the self-hosted label. A setting can hold any label,
#      including a hosted image; with self-hosted required, no GitHub-hosted
#      runner can match (AUT-1588).
#
# Why: one macOS minute consumes about ten included Actions minutes, and the
# September 2026 overage came from exactly this. The shared validate workflow
# runs this on every pull request, so the rule holds in every consumer rather
# than in per-repository tests (AUT-1592).
#
# It reads lines, not YAML, so it needs nothing beyond the runner image. The
# price is that a hosted image named inside a run: script trips it too; spell
# that string another way. Rule 2 checks that the requirement is present, not
# that an expression cannot route around it; review owns that.
#
# Exit 0 when clean, 1 on any finding, 2 on a usage or read error.

set -euo pipefail

usage() {
  printf 'Usage: bash scripts/check-hosted-runners.sh [PROJECT_DIR]\n' >&2
  exit 2
}

case "${1:-}" in -h | --help) usage ;; esac
[ "$#" -le 1 ] || usage
project="${1:-.}"
[ -d "$project" ] || {
  printf 'ERROR: project directory %s does not exist\n' "$project" >&2
  exit 2
}

# GitHub reads workflows only from the top level of .github/workflows.
workflows=()
if [ -d "$project/.github/workflows" ]; then
  while IFS= read -r file; do
    workflows+=("$file")
  done < <(find "$project/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
fi
if [ "${#workflows[@]}" -eq 0 ]; then
  printf 'hosted-runner check: no workflow files in %s/.github/workflows; nothing to check.\n' "$project"
  exit 0
fi

# POSIX awk only: the runner's awk is mawk, so no character classes.
# \047 is a single quote inside this single-quoted program.
if awk '
  function flag(file, line, message) {
    printf "%s:%d: %s\n", file, line, message
    found = 1
  }
  function close_selector() {
    if (selecting && selector ~ /vars\./ && selector !~ /self-hosted/)
      flag(selector_file, selector_line, "runs-on takes its label from a setting (vars.*) without also requiring the self-hosted label, so the setting could name a GitHub-hosted image; use fromJSON(format(\047[\"self-hosted\",\"{0}\"]\047, vars.NAME))")
    selecting = 0
    selector = ""
  }
  FNR == 1 { close_selector() }
  {
    line = $0
    if (line ~ /^[ \t]*#/) line = ""
    sub(/[ \t]#.*$/, "", line)
    # A runs-on value continues on every more-indented line after it; blank
    # and comment-only lines do not end it.
    if (selecting && line !~ /^[ \t]*$/) {
      match(line, /^ */)
      if (RLENGTH > selector_indent) selector = selector " " line
      else close_selector()
    }
    lower = tolower(line)
    if (match(lower, /(^|[^a-z0-9_.-])(macos|windows)-(latest|[0-9])[a-z0-9._-]*/)) {
      image = substr(lower, RSTART, RLENGTH)
      sub(/^[^a-z]/, "", image)
      flag(FILENAME, FNR, "names the GitHub-hosted image \047" image "\047; macOS and Windows work runs only on a self-hosted runner that a setting names")
    }
    if (match(line, /^ *(- +)?runs-on:/)) {
      selecting = 1
      selector_file = FILENAME
      selector_line = FNR
      match(line, /^ */)
      selector_indent = RLENGTH
      selector = substr(line, index(line, "runs-on:") + 8)
    }
  }
  END {
    close_selector()
    exit (found ? 1 : 0)
  }
' "${workflows[@]}" >&2; then
  printf 'hosted-runner check: %d workflow file(s), no GitHub-hosted macOS or Windows runner.\n' "${#workflows[@]}"
  exit 0
else
  rc=$?
fi
[ "$rc" -eq 1 ] || {
  printf 'ERROR: awk exited %s while reading the workflows in %s\n' "$rc" "$project" >&2
  exit 2
}
printf 'hosted-runner check: refused. Route macOS and Windows work to a self-hosted runner that a setting names, with the self-hosted label required, or remove it.\n' >&2
exit 1
