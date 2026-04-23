#!/usr/bin/env bash
#
# bootstrap/migrate-review-config.sh — rewrite a 1.x .codex-review.toml
# to the 2.0 shape so projects stop firing migration warnings on every
# push.
#
# 1.x → 2.0 transformations:
#   [review] reviewers = ["X", "Y"] → [review] reviewer = "conductor"
#                                     [review.conductor] with = "X"
#                                       (first reviewer becomes the pin;
#                                       multi-element cascades note their
#                                       fallback chain in a comment)
#   [review.local] {command = ...} → commented out, with a pointer to the
#                                    Conductor v0.3 custom-provider flow
#   [review.assist] {enabled = ...} → commented out, with a pointer to v2.1
#   [review.routing].small_reviewers = ["X"] → small_with = "X"
#                  .large_reviewers = ["Y"] → large_with = "Y"
#
# `local` as a reviewer name maps to `ollama` (the closest 2.0 analog
# for "run on this machine").
#
# Safe by default: writes a .bak before changing anything; idempotent
# (detects already-migrated configs and exits 0); --dry-run shows the
# diff without writing.

set -euo pipefail

usage() {
  cat <<EOF
Usage: touchstone migrate-review-config [--dry-run] [--no-backup] [--file PATH]

Options:
  --dry-run      Show what would change without writing.
  --no-backup    Don't write .codex-review.toml.bak before rewriting.
  --file PATH    Path to the config file (default: ./.codex-review.toml).
  -h, --help     Show this help.
EOF
}

dry_run=false
no_backup=false
file=".codex-review.toml"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --no-backup) no_backup=true; shift ;;
    --file)
      [ "$#" -ge 2 ] || { echo "ERROR: --file requires a path" >&2; exit 1; }
      file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

if [ ! -f "$file" ]; then
  echo "ERROR: $file not found." >&2
  echo "  Run from a touchstone-bootstrapped project, or pass --file <path>." >&2
  exit 1
fi

# Idempotency: a file is "already 2.0" if it has both `reviewer = "conductor"`
# and a `[review.conductor]` section, AND no 1.x markers remain.
already_migrated=true
grep -qE '^[[:space:]]*reviewer[[:space:]]*=[[:space:]]*"conductor"' "$file" || already_migrated=false
grep -qE '^\[review\.conductor\]' "$file" || already_migrated=false

# Detect 1.x markers
has_legacy_reviewers=false
has_legacy_local=false
has_legacy_assist=false
has_legacy_routing=false
grep -qE '^[[:space:]]*reviewers[[:space:]]*=[[:space:]]*\[' "$file" && has_legacy_reviewers=true
grep -qE '^\[review\.local\]' "$file" && has_legacy_local=true
grep -qE '^\[review\.assist\]' "$file" && has_legacy_assist=true
grep -qE '^[[:space:]]*(small|large)_reviewers[[:space:]]*=[[:space:]]*\[' "$file" && has_legacy_routing=true

if [ "$already_migrated" = true ] \
   && [ "$has_legacy_reviewers" = false ] \
   && [ "$has_legacy_local" = false ] \
   && [ "$has_legacy_assist" = false ] \
   && [ "$has_legacy_routing" = false ]; then
  echo "==> $file is already in 2.0 shape — nothing to migrate."
  exit 0
fi

if [ "$has_legacy_reviewers" = false ] \
   && [ "$has_legacy_local" = false ] \
   && [ "$has_legacy_assist" = false ] \
   && [ "$has_legacy_routing" = false ]; then
  echo "==> $file has no recognizable 1.x markers — nothing to migrate."
  echo "    (Looked for: reviewers=[...], [review.local], [review.assist], small_/large_reviewers=[...])"
  exit 0
fi

echo "==> Migrating $file from 1.x → 2.0"
[ "$has_legacy_reviewers" = true ] && echo "    - reviewers=[...] → reviewer=\"conductor\" + [review.conductor].with"
[ "$has_legacy_local" = true ]     && echo "    - [review.local] → commented out (retired in 2.0)"
[ "$has_legacy_assist" = true ]    && echo "    - [review.assist] → commented out (returns in 2.1)"
[ "$has_legacy_routing" = true ]   && echo "    - small_/large_reviewers=[...] → small_/large_with=\"...\""

tmp="$(mktemp "${TMPDIR:-/tmp}/codex-review-migrate.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# Awk transformer. Single pass; tracks current section, rewrites known
# legacy keys, comments out retired sections, and appends a synthesized
# [review.conductor] block at end if the file didn't already have one.
awk '
BEGIN {
  section = ""
  saw_conductor_block = 0
  pending_with = ""
  pending_fallback = ""
}

# Map legacy reviewer name to a 2.0 `with=` provider name.
function map_provider(name,    out) {
  out = name
  if (out == "local") out = "ollama"
  return out
}

# Extract the first quoted token from a TOML array literal.
function first_quoted(line,    q1, rest, q2) {
  q1 = index(line, "\"")
  if (q1 == 0) return ""
  rest = substr(line, q1 + 1)
  q2 = index(rest, "\"")
  if (q2 == 0) return ""
  return substr(rest, 1, q2 - 1)
}

# Extract all comma-separated quoted tokens from a TOML array literal,
# joined with ", " — used to record the original cascade in a comment.
function all_quoted(line,   out, n, copy, q1, rest, q2, tok) {
  out = ""
  copy = line
  n = 0
  while (1) {
    q1 = index(copy, "\"")
    if (q1 == 0) break
    rest = substr(copy, q1 + 1)
    q2 = index(rest, "\"")
    if (q2 == 0) break
    tok = substr(rest, 1, q2 - 1)
    if (out == "") out = tok
    else out = out ", " tok
    copy = substr(rest, q2 + 1)
    n++
  }
  return out
}

# Track section headers.
/^\[review\.conductor\][[:space:]]*$/ {
  saw_conductor_block = 1
  section = "review.conductor"
  print
  next
}
/^\[review\.local\][[:space:]]*$/ {
  section = "review.local"
  print "# [review.local] — retired in Touchstone 2.0; register as a Conductor"
  print "# custom provider when v0.3 ships:"
  print "#   conductor providers add --name local --shell '\''<cmd>'\''"
  next
}
/^\[review\.assist\][[:space:]]*$/ {
  section = "review.assist"
  print "# [review.assist] — disabled in Touchstone 2.0; returns in v2.1"
  print "# via `conductor call --exclude <primary_provider>`."
  next
}
/^\[review\.routing\][[:space:]]*$/ { section = "review.routing"; print; next }
/^\[review\][[:space:]]*$/          { section = "review"; print; next }
/^\[/                                { section = "other"; print; next }

# In retired sections, comment out everything until the next section.
section == "review.local" || section == "review.assist" {
  if ($0 ~ /^[[:space:]]*$/) { print; next }
  if ($0 ~ /^[[:space:]]*#/) { print; next }
  print "# " $0
  next
}

# In [review]: replace `reviewers = [...]` with the 2.0 reviewer scalar.
section == "review" && /^[[:space:]]*reviewers[[:space:]]*=[[:space:]]*\[/ {
  first = first_quoted($0)
  all   = all_quoted($0)
  if (first != "" && first != "conductor") {
    pending_with = map_provider(first)
    if (all != first) pending_fallback = all
  }
  print "reviewer = \"conductor\""
  next
}

# In [review.routing]: small_reviewers / large_reviewers → small_with / large_with.
section == "review.routing" && /^[[:space:]]*small_reviewers[[:space:]]*=[[:space:]]*\[/ {
  first = first_quoted($0)
  if (first != "") {
    print "small_with = \"" map_provider(first) "\""
  } else {
    print  # fallback: leave alone if we cant parse
  }
  next
}
section == "review.routing" && /^[[:space:]]*large_reviewers[[:space:]]*=[[:space:]]*\[/ {
  first = first_quoted($0)
  if (first != "") {
    print "large_with = \"" map_provider(first) "\""
  } else {
    print
  }
  next
}

# Default: pass through.
{ print }

END {
  if (!saw_conductor_block) {
    print ""
    print "[review.conductor]"
    print "# Conductor routing knobs. See touchstone CHANGELOG for the 2.0 contract."
    print "prefer = \"best\""
    print "effort = \"max\""
    print "tags = \"code-review\""
    if (pending_with != "") {
      print "with = \"" pending_with "\""
      if (pending_fallback != "") {
        print "# Original 1.x cascade was: " pending_fallback
        print "# Conductor auto-router now handles fallback when this provider is degraded."
      }
    } else {
      print "# Pin a specific underlying provider with: with = \"<provider>\""
    }
  }
}
' "$file" > "$tmp"

if [ "$dry_run" = true ]; then
  echo ""
  echo "==> Diff (dry-run; no files written):"
  diff -u "$file" "$tmp" || true
  echo ""
  echo "==> Re-run without --dry-run to apply."
  exit 0
fi

if [ "$no_backup" = false ]; then
  cp "$file" "$file.bak"
  echo "    backup: $file.bak"
fi

mv "$tmp" "$file"
trap - EXIT

echo "==> Migrated $file."
echo ""
echo "Next steps:"
echo "  - Review the change: git diff $file"
[ "$no_backup" = false ] && echo "  - If something looks wrong, restore: mv $file.bak $file"
echo "  - Push as usual; migration warnings should no longer fire."
