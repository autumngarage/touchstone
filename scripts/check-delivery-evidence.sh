#!/usr/bin/env bash
#
# scripts/check-delivery-evidence.sh — verify a pull request records the
# evidence its review tier requires.
#
# Usage:
#   bash scripts/check-delivery-evidence.sh BODY_FILE
#
# Reads a pull request body and refuses one that has not declared a review
# tier or recorded its validation. It checks SHAPE AND PRESENCE ONLY: that the
# driver wrote down what they did. It never judges whether the work is good --
# that is review's job, and a check that graded content would be a second
# adjudicator.
#
# Why this exists: the tiered review workflow shipped as prose, and the first
# driver to read it (the author) then skipped the local pass entirely for a
# day. Prose instructs; only a gate enforces. This is the gate.
#
# Exit 0 when the evidence is recorded, 1 when it is missing or unfilled.

set -euo pipefail

REQUIRED_TIERS="trivial normal serious"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

BODY_FILE="${1:-}"
[ -n "$BODY_FILE" ] || usage
[ -f "$BODY_FILE" ] || die "cannot read pull request body: $BODY_FILE"

# HTML comments are invisible in the rendered body, so they are removed
# before any parsing at all: a heading inside a comment is not a heading, and
# the template's guidance comment above the tier value is not part of the
# tier. Removing them here, once, is what keeps every later rule honest.
STRIPPED_BODY="$(mktemp "${TMPDIR:-/tmp}/delivery-evidence.XXXXXXXX")" \
  || die "could not create a working file"
trap 'rm -f "$STRIPPED_BODY"' EXIT
awk '
  {
    line = $0
    out = ""
    while (length(line) > 0) {
      if (in_comment) {
        close_at = index(line, "-->")
        if (close_at == 0) { line = ""; continue }
        line = substr(line, close_at + 3)
        in_comment = 0
        continue
      }
      open_at = index(line, "<!--")
      if (open_at == 0) { out = out line; line = ""; continue }
      out = out substr(line, 1, open_at - 1)
      line = substr(line, open_at + 4)
      in_comment = 1
    }
    print out
  }
' "$BODY_FILE" >"$STRIPPED_BODY" || die "could not read pull request body: $BODY_FILE"

# Section text is everything between one `## Heading` and the next heading.
section() {
  awk -v want="## $1" '
    $0 == want { grabbing = 1; next }
    grabbing && /^## / { exit }
    grabbing { print }
  ' "$STRIPPED_BODY"
}

# A section counts as filled only if it carries content the author wrote.
# Placeholders from the template are absence wearing a costume: an angle
# bracket line is the template, a bare "n/a" with no reason explains nothing.
filled() {
  printf '%s\n' "$1" | awk '
    { line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      # Bullets, task boxes, and "Label:" prefixes are scaffolding, not
      # content: judge what follows. Stripped repeatedly, so "- -" or a
      # nested empty list cannot smuggle a marker through as evidence.
      # Comments were removed from the body before any parsing.
      while (sub(/^[-*+][[:space:]]+/, "", line) || sub(/^[-*+]$/, "", line) \
             || sub(/^[0-9]+[.)][[:space:]]+/, "", line) \
             || sub(/^\[[xX]\][[:space:]]*/, "", line)) { }
      if (line == "") next                    # bare scaffolding is nothing
      if (line ~ /^\[[ ]\]/) next            # an unchecked box records nothing
      if (line ~ /^[A-Za-z][A-Za-z0-9 \/-]*:[[:space:]]*/)
        sub(/^[A-Za-z][A-Za-z0-9 \/-]*:[[:space:]]*/, "", line)
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (line ~ /^<.*>$/) next               # unedited <placeholder>
      if (tolower(line) ~ /^(n\/a|tbd|todo|none)[.]?$/) next
      found = 1
    }
    END { exit !found }
  '
}

FAILURES=0
report() {
  printf '  missing: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

TIER_RAW="$(section "Review tier")"
TIER="$(printf '%s\n' "$TIER_RAW" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case " $REQUIRED_TIERS " in
  *" $TIER "*) ;;
  *)
    report "a '## Review tier' section naming one of: $REQUIRED_TIERS"
    TIER=""
    ;;
esac

filled "$(section "Intent")" || report "a '## Intent' section stating what behavior this change creates or fixes"
filled "$(section "Validation")" || report "a '## Validation' section recording what actually ran"
[ -z "$TIER" ] || filled "$(section "Why this tier")" \
  || report "a '## Why this tier' section justifying the '$TIER' classification"

# The bar rises with the tier, because the cost of an unreviewed mistake does.
case "$TIER" in
  normal | serious)
    filled "$(section "Invariants")" \
      || report "a '## Invariants' section (required for tier '$TIER')"
    ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  printf '\nThis pull request does not record the evidence its tier requires.\n' >&2
  printf 'The required sections are in .github/pull_request_template.md;\n' >&2
  printf 'the tier rules live in principles/local-review.md.\n' >&2
  exit 1
fi

printf 'delivery evidence recorded: tier=%s\n' "$TIER"
