#!/usr/bin/env bash
#
# tests/test-steering-size-caps.sh — scope guardrails for the steering layer.
#
# Two properties, both about keeping the prose honest:
#
#   1. SIZE. The whole point of the TOUCHSTONE.md routing layer is to keep
#      auto-loaded context lean: rules that fire on every turn live in
#      TOUCHSTONE.md (which CLAUDE.md @-imports and AGENTS.md/GEMINI.md inline
#      via the managed block), and everything else is routed to. These caps
#      catch someone adding a section without weighing the per-turn cost.
#
#      If a cap is hit, either move the content to principles/* and route to it
#      from the TOUCHSTONE.md table, or raise the cap deliberately with the
#      reasoning in the commit message.
#
#      Codex's project_doc_max_bytes default is 32 KiB; AGENTS.md staying under
#      24 KiB leaves headroom for project-specific tail content.
#
#   2. PATH INTEGRITY. Every repository path the steering docs name in
#      backticks must actually exist. Prose that tells an agent to run a
#      deleted script is worse than no prose: the agent follows it, the command
#      fails, and the failure looks like the agent's fault.
#
#      This is the guard for the whole class of breakage the strip could cause,
#      and it is why it was written in the same change: 21,000 lines were
#      deleted and every steering reference to them had to go with them.
#
# The capability registry that used to live here is gone with capabilities.toml.
# It policed FILES — every shipped file had to declare a mission job — which
# made it a tax on adding files rather than a test of whether the product does
# its jobs. The job list that replaces it polices JOBS instead.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_under() {
  local label="$1" path="$2" cap_bytes="$3"
  if [ ! -f "$path" ]; then
    fail "$label: file not found: $path"
    return
  fi
  local actual
  actual="$(wc -c <"$path" | tr -d '[:space:]')"
  if [ "$actual" -gt "$cap_bytes" ]; then
    fail "$label: $path is $actual bytes, cap is $cap_bytes (raise the cap deliberately or trim the file)"
  else
    printf '  OK: %s — %s bytes (cap %s)\n' "$label" "$actual" "$cap_bytes"
  fi
}

# 9 KiB, raised deliberately from 8 KiB: main's reviewed Purpose section
# (PR #746) plus the three-job scope contract left 8 KiB unreachable.
# Derivation: TOUCHSTONE.md is inlined into AGENTS.md as the managed block; at
# <= 9 KiB the rendered block stays under ~9.5 KiB, preserving >14 KiB of
# project-tail headroom inside the 24 KiB AGENTS.md cap below.
echo "==> TOUCHSTONE.md size cap (9 KiB — lean router)"
assert_under "TOUCHSTONE.md" "$TOUCHSTONE_ROOT/TOUCHSTONE.md" 9216

echo "==> AGENTS.md size cap (24 KiB — leaves headroom under Codex's 32 KiB default)"
assert_under "AGENTS.md" "$TOUCHSTONE_ROOT/AGENTS.md" 24576
assert_under "templates/AGENTS.md" "$TOUCHSTONE_ROOT/templates/AGENTS.md" 24576

echo "==> GEMINI.md size cap (24 KiB — same headroom)"
assert_under "GEMINI.md" "$TOUCHSTONE_ROOT/GEMINI.md" 24576
assert_under "templates/GEMINI.md" "$TOUCHSTONE_ROOT/templates/GEMINI.md" 24576

# =============================================================================
# Path integrity — the steering docs may not name a file that does not exist.
#
# Scanned: this repository's own steering surface. NOT templates/ — those
# describe a downstream project's tree, so their paths are claims about a
# different repository and asserting them here would be a category error.
#
# Detection is backtick-quoted paths under the governed prefixes. That is the
# house style for every path in these documents, and it keeps the check precise
# rather than guessing at prose. A path written without backticks is missed;
# this is a guard, not a proof.
# =============================================================================

echo ""
echo "==> Path integrity: every steering path in backticks exists"

STEERING_DOCS=()
while IFS= read -r doc; do
  STEERING_DOCS+=("$doc")
done < <(
  {
    printf '%s\n' \
      "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
      "$TOUCHSTONE_ROOT/CLAUDE.md" \
      "$TOUCHSTONE_ROOT/AGENTS.md" \
      "$TOUCHSTONE_ROOT/GEMINI.md" \
      "$TOUCHSTONE_ROOT/README.md"
    find "$TOUCHSTONE_ROOT/principles" -name '*.md' -type f 2>/dev/null
    find "$TOUCHSTONE_ROOT/skills" -name 'SKILL.md' -type f 2>/dev/null
  } | sort -u
)

MISSING=0
CHECKED=0
for doc in "${STEERING_DOCS[@]}"; do
  [ -f "$doc" ] || continue
  # Pull backtick-quoted spans, keep the ones that look like a repo path under
  # a governed prefix, and strip the `:123` / `:12-34` line references the docs
  # use when pointing at a specific line.
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    CHECKED=$((CHECKED + 1))
    if [ ! -e "$TOUCHSTONE_ROOT/$ref" ]; then
      fail "$(basename "$doc") names \`$ref\`, which does not exist"
      MISSING=$((MISSING + 1))
    fi
  done < <(
    grep -oE '`[^`]+`' "$doc" 2>/dev/null \
      | tr -d '`' \
      | tr ' ' '\n' \
      | grep -vE '[*$<>]' \
      | grep -oE '^(bin|bootstrap|hooks|lib|scripts|principles|skills|templates|tests)/[A-Za-z0-9._/-]+' \
      | grep -vE '/$' \
      | sed -E 's/[:,.]+$//; s/:[0-9]+(-[0-9]+)?$//' \
      | sort -u
  )

  # Bare script basenames — `open-pr.sh` rather than `scripts/open-pr.sh`. The
  # prose routinely names a script without its directory, and those references
  # rot exactly the same way. Resolved against every directory that holds one.
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    CHECKED=$((CHECKED + 1))
    if [ ! -e "$TOUCHSTONE_ROOT/scripts/$base" ] \
      && [ ! -e "$TOUCHSTONE_ROOT/hooks/$base" ] \
      && [ ! -e "$TOUCHSTONE_ROOT/tests/$base" ] \
      && [ ! -e "$TOUCHSTONE_ROOT/$base" ]; then
      fail "$(basename "$doc") names \`$base\`, which does not exist in scripts/, hooks/, tests/, or the repository root"
      MISSING=$((MISSING + 1))
    fi
  done < <(
    grep -oE '`[^`]+`' "$doc" 2>/dev/null \
      | tr -d '`' \
      | tr ' ' '\n' \
      | grep -oE '^[a-z0-9][a-z0-9._-]*\.sh$' \
      | sort -u
  )
done

if [ "$MISSING" -eq 0 ]; then
  printf '  OK: %s path references across %s documents all resolve\n' \
    "$CHECKED" "${#STEERING_DOCS[@]}"
fi

# The guard must be able to fail, or it proves nothing. A deleted script that
# the docs still reference is the exact case this exists for.
echo "==> Path integrity: the check can actually fail"
PROBE_DIR="$(mktemp -d -t touchstone-pathprobe.XXXXXX)"
trap 'rm -rf "$PROBE_DIR"' EXIT
printf 'Run `scripts/does-not-exist.sh` to ship.\n' >"$PROBE_DIR/probe.md"
probe_hits="$(
  grep -oE '`[^`]+`' "$PROBE_DIR/probe.md" \
    | tr -d '`' \
    | grep -cE '^(bin|bootstrap|hooks|lib|scripts|principles|skills|templates|tests)/[A-Za-z0-9._/-]+' || true
)"
if [ "$probe_hits" -eq 1 ] && [ ! -e "$TOUCHSTONE_ROOT/scripts/does-not-exist.sh" ]; then
  echo "  OK: a reference to a deleted script is detected as missing"
else
  fail "the path-integrity extractor did not detect an obviously missing script; the check above is dead"
fi

# Touchstone must obey the conventions it ships. templates/gitignore has
# shipped '.claude/worktrees/' to every project since the agent-swarm workflow
# landed; the repo root lacked the rule, so its OWN dirty-tree guards refused
# whenever an agent worktree existed (PR #794). Assert BOTH sides so neither
# can drift.
echo ""
echo "==> Self-conformance: agent worktrees are ignored"
if git -C "$TOUCHSTONE_ROOT" check-ignore -q ".claude/worktrees/probe-slice/file.txt"; then
  echo "    OK: the repository root ignores paths under .claude/worktrees/"
else
  echo "FAIL: touchstone's own .gitignore must ignore .claude/worktrees/ (PR #794)" >&2
  echo "      Its dirty-tree guards refuse while any agent worktree exists." >&2
  ERRORS=$((ERRORS + 1))
fi
if grep -qxF '.claude/worktrees/' "$TOUCHSTONE_ROOT/templates/gitignore"; then
  echo "    OK: templates/gitignore still ships the same rule to projects"
else
  echo "FAIL: templates/gitignore must ship .claude/worktrees/ to every project (PR #794)" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS scope-guardrail check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: steering size caps, path integrity, and self-conformance hold"
