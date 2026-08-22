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
# Threat model: lazy omission, not forgery. An author who wants to lie can
# write false prose no parser detects -- substance is review's job. This
# check catches unfilled templates and accidentally hidden text, so Markdown
# handling favors never refusing an honest body over never accepting an
# exotic one, and its parsing is line-local by declared limit.
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
# before any parsing: the template's guidance comment above the tier value is
# not part of the tier. Only a comment that opens and closes on one line is
# removed. That is the declared limit, and it is deliberate: a comment state
# carried across lines must know about fences, code spans, info strings,
# backslash escapes, and blockquotes to avoid swallowing the rest of an honest
# body -- six rounds of review found six such cases -- while a one-line strip
# can lose at most one comment's bytes. The template carries only one-line
# comments; anything else an author writes is visible text.
STRIPPED_BODY="$(mktemp "${TMPDIR:-/tmp}/delivery-evidence.XXXXXXXX")" \
  || die "could not create a working file"
trap 'rm -f "$STRIPPED_BODY"' EXIT
awk '
  {
    line = $0
    out = ""
    while ((open_at = index(line, "<!--")) > 0) {
      rest = substr(line, open_at + 4)
      close_at = index(rest, "-->")
      if (close_at == 0) break
      out = out substr(line, 1, open_at - 1)
      line = substr(rest, close_at + 3)
    }
    print out line
  }
' "$BODY_FILE" >"$STRIPPED_BODY" || die "could not read pull request body: $BODY_FILE"

# One exception to "everything else is visible": a body whose first line
# opens a comment it does not close renders as nothing at all on GitHub while
# its text would read as evidence here. That is refused, with the remedy,
# rather than parsed.
if awk 'NF { line = $0; sub(/^[[:space:]]+/, "", line); exit !(index(line, "<!--") == 1) } END { if (NR == 0) exit 1 }' "$STRIPPED_BODY"; then
  die "the body opens an HTML comment on its first line and does not close it there; close it on the same line or remove it (HTML comments are recognised one line at a time)"
fi

# Section text is everything between one `## Heading` and the next heading.
# Headings inside a fenced block are sample text, not sections -- a fenced
# copy of the whole template must not read as the template filled in.
section() {
  awk -v want="## $1" '
    in_fence {
      if (match($0, /^ {0,3}(`{3,}|~{3,})[[:space:]]*$/)) {
        seg = $0
        gsub(/[[:space:]]/, "", seg)
        if (substr(seg, 1, 1) == fence_char && length(seg) >= fence_len) in_fence = 0
      }
      if (grabbing) print; next
    }
    match($0, /^ {0,3}(`{3,}|~{3,})/) {
      seg = substr($0, RSTART, RLENGTH)
      gsub(/[[:space:]]/, "", seg)
      info = substr($0, RSTART + RLENGTH)
      if (substr(seg, 1, 1) == "`" && index(info, "`") > 0) {
        # Not a fence per CommonMark: backtick info strings may not contain
        # a backtick. Fall through to ordinary line handling.
      } else {
        fence_char = substr(seg, 1, 1); fence_len = length(seg); in_fence = 1
        if (grabbing) print; next
      }
    }
    { line = $0; sub(/^ {0,3}/, "", line) }
    { sub(/^#{2}\t/, "## ", line) }
    line == want { grabbing = 1; next }
    grabbing && line ~ /^#{1,2}[ \t]/ { exit }
    # Setext: a paragraph line underlined by = or - is an H1/H2 and ends the
    # section; the underlined line is the heading, not content. Output runs
    # one line behind so the underline can retract it.
    grabbing && have_pending && line ~ /^(=+|-+)[[:space:]]*$/ && pending_is_text { have_pending = 0; exit }
    grabbing {
      if (have_pending) print pending
      pending = $0; have_pending = 1
      pending_is_text = ($0 ~ /[^[:space:]]/ && $0 !~ /^[[:space:]]*([-*+>]|[0-9]+[.)])([[:space:]]|$)/ && $0 !~ /^[[:space:]]*#/)
    }
    END { if (have_pending) print pending }
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
      # A fence delimiter is scaffolding too: an empty fenced block has two
      # delimiter lines and no content.
      # A backtick fence whose info string contains a backtick is not a fence
      # (CommonMark), exactly as section() treats it; tilde fences have no
      # such rule.
      if (line ~ /^~{3,}/) next
      if (match(line, /^`{3,}/) && index(substr(line, RLENGTH + 1), "`") == 0) next
      # Bullets, task boxes, and "Label:" prefixes are scaffolding, not
      # content: judge what follows. Stripped repeatedly, so "- -" or a
      # nested empty list cannot smuggle a marker through as evidence.
      # Comments were removed from the body before any parsing.
      while (sub(/^>[[:space:]]*/, "", line) \
             || sub(/^[-*+][[:space:]]+/, "", line) || sub(/^[-*+]$/, "", line) \
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
      # The template ships an em dash after n/a; under LC_ALL=C it is three
      # bytes, not [[:punct:]], so dashes are normalised by byte first.
      gsub(/\342\200\223|\342\200\224/, "-", line)
      if (tolower(line) ~ /^(n\/a|tbd|todo|none)[[:space:][:punct:]]*$/) next
      found = 1
    }
    END { exit !found }
  '
}

# The template's three Validation rows are the promise: Build, Automated
# tests, Manual validation. Each must be present and each is judged by the
# same rules as a section, so a deleted row, a bare `n/a`, `TBD`, or an
# unedited placeholder on any of them is absence on that row. The value is
# read from the labelled bullet itself, never from prose that mentions it.
VALIDATION_ROWS="Build
Automated tests
Manual validation"
# A row inside a fenced block is an example, not a record: section() keeps
# fenced text for filled() to judge, so the fence is tracked again here with
# the same CommonMark rule (a backtick info string may not contain a backtick;
# a tilde fence has no such rule).
row_text() {
  printf '%s\n' "$1" | awk -v label="$2" '
    BEGIN { pattern = "^[[:space:]]*[-*+][[:space:]]+" label ":" }
    in_fence {
      if (match($0, /^ {0,3}(`{3,}|~{3,})[[:space:]]*$/)) {
        seg = $0
        gsub(/[[:space:]]/, "", seg)
        if (substr(seg, 1, 1) == fence_char && length(seg) >= fence_len) in_fence = 0
      }
      next
    }
    match($0, /^ {0,3}(`{3,}|~{3,})/) {
      seg = substr($0, RSTART, RLENGTH)
      gsub(/[[:space:]]/, "", seg)
      info = substr($0, RSTART + RLENGTH)
      if (!(substr(seg, 1, 1) == "`" && index(info, "`") > 0)) {
        fence_char = substr(seg, 1, 1); fence_len = length(seg); in_fence = 1
        next
      }
    }
    $0 ~ pattern { row = $0; sub(pattern "[[:space:]]*", "", row); print row; found = 1; exit }
    END { if (!found) exit 1 }'
}

FAILURES=0
report() {
  printf '  missing: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

TIER_RAW="$(section "Review tier")"
# Edge-trim and lowercase only: deleting internal whitespace would normalize
# a visibly invalid 'nor mal' into an accepted tier.
TIER="$(printf '%s\n' "$TIER_RAW" | awk 'NF { n++; line = $0 } END { if (n == 1) print line }' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
case " $REQUIRED_TIERS " in
  *" $TIER "*) ;;
  *)
    report "a '## Review tier' section naming one of: $REQUIRED_TIERS"
    TIER=""
    ;;
esac

filled "$(section "Intent")" || report "a '## Intent' section stating what behavior this change creates or fixes"
VALIDATION_SECTION="$(section "Validation")"
filled "$VALIDATION_SECTION" || report "a '## Validation' section recording what actually ran"
while IFS= read -r row; do
  [ -n "$row" ] || continue
  if ! value="$(row_text "$VALIDATION_SECTION" "$row")"; then
    report "the Validation row '- $row:' present (the template ships it; record what ran, or n/a with a reason)"
  elif ! filled "$value"; then
    report "the Validation row '- $row:' filled in (what ran and its result, or n/a with a reason)"
  fi
done <<<"$VALIDATION_ROWS"
[ -z "$TIER" ] || filled "$(section "Why this tier")" \
  || report "a '## Why this tier' section justifying the '$TIER' classification"

# The bar rises with the tier, because the cost of an unreviewed mistake does.
# The local review pass is the one step of the delivery contract nothing
# else witnesses (hooks gate commits, this gate the body, review-gate the
# review): an agent shipped four PRs without running it and nothing could
# notice (AUT-443). So a normal or serious PR must record it here -- the
# reviewer the tier routes to and what it found, or an explicit waiver. Shape
# only, like every other row: the gate cannot see a terminal, but it can
# refuse silence.
case "$TIER" in
  normal | serious)
    filled "$(section "Invariants")" \
      || report "a '## Invariants' section (required for tier '$TIER')"
    if ! local_review="$(row_text "$VALIDATION_SECTION" "Local review")"; then
      report "the Validation row '- Local review:' present (the tier's local pass: reviewer, head, and finding count -- or n/a with the waiver reason)"
    elif ! filled "$local_review"; then
      report "the Validation row '- Local review:' filled in (reviewer, head, and finding count -- or n/a with the waiver reason)"
    else
      # Two documented shapes. A run: the reviewer, the head it saw, and a
      # finding count ("codex on abc1234: 3 findings, 2 fixed, 1 routed").
      # A waiver: n/a with one of the three documented reasons -- the CLI
      # not installed, not authenticated, or out of quota. "codex" alone,
      # "codex not run", or "n/a — skipped" is silence with a reviewer's
      # name on it.
      lr_norm="$(printf '%s\n' "$local_review" | tr '[:upper:]' '[:lower:]')"
      if printf '%s\n' "$lr_norm" | grep -qE '^[[:space:]]*n/a'; then
        # A waiver needs a reason; the threat model is omission, not forgery,
        # so any stated reason is accepted -- the words are the author's.
        # An unedited "<reason>" is the template's words, not the author's.
        if ! printf '%s\n' "$lr_norm" | grep -qE '^[[:space:]]*n/a[^[:alnum:]<]*[[:alnum:]]' \
          || printf '%s\n' "$lr_norm" | grep -q '<'; then
          report "the Validation row '- Local review:' waiver stating why (reviewer CLI not installed, not authenticated, or out of quota)"
        fi
      else
        # The tier routes the reviewer, deterministically; the row opens with
        # that reviewer (a mention elsewhere is not the run record) and states
        # a finding count, and a serious pass names the revision it reviewed.
        # "codex not run" carries no count and is refused by the same check.
        case "$TIER" in
          normal) lr_tool=coderabbit ;;
          serious) lr_tool=codex ;;
        esac
        # The run record is the documented prefix "<reviewer> on <target>:";
        # a serious target is the bare reviewed revision, nothing decorated
        # around it, so the SHA binds to the prefix and not to any hex string
        # elsewhere in the row, and the
        # finding count opens the result immediately after it -- nothing may
        # sit between the target and the count, so "codex on abc: not run;
        # 0 findings" is refused as neither a pass nor a waiver.
        case "$TIER" in
          normal) lr_prefix="^[[:space:]]*$lr_tool on [^:]+:" ;;
          serious) lr_prefix="^[[:space:]]*$lr_tool on [0-9a-f]{7,40}:" ;;
        esac
        if ! printf '%s\n' "$lr_norm" | grep -qE "${lr_prefix}[[:space:]]*[0-9]+[[:space:]]*finding"; then
          report "the Validation row '- Local review:' recording the $TIER tier's pass as '$lr_tool on <$([ "$TIER" = serious ] && echo revision || echo staged slice)>: <n> findings, <disposition>'"
        fi
      fi
    fi
    ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  printf '\nThis pull request does not record the evidence its tier requires.\n' >&2
  printf 'The required sections are in .github/pull_request_template.md;\n' >&2
  printf 'the tier rules live in principles/local-review.md.\n' >&2
  exit 1
fi

printf 'delivery evidence recorded: tier=%s\n' "$TIER"
