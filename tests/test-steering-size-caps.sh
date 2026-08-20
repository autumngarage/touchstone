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

# 9.5 KiB, raised deliberately from 9 KiB (which was itself raised from 8 KiB
# by PR #746's Purpose section).
#
# What earned the 256 bytes: the contract now has to state what GitHub
# ACTUALLY enforces and, separately, that review is not part of it. The strip's
# own review filed that omission as a P1 twice — a driver who reads the gate as
# proof an unreviewed merge is impossible will not check, and merging an
# unreviewed head is currently possible. Trimming that back to fit a round
# number would restore the exact defect the cap is supposed to be protecting
# clarity for.
#
# Raised to 10.5 KiB on 2026-08-19, deliberately, for two rules that bound the
# review loop: review starts on PR open (so a hand-typed request, which fails
# the binding check closed and wedges the sequencer, is never written), and
# only high-severity findings are implemented, followed by at most one
# re-review. The occasion was PR #925 spending twenty review rounds on a
# change that was correct and tested after three. A contract that cannot say
# when to stop costs far more context than the bytes saved by not saying it.
#
# Paid for in part by trimming the Purpose section, where two paragraphs
# separately described where enforcement lives; they are now one.
#
# Derivation: TOUCHSTONE.md is inlined into AGENTS.md as the managed block. At
# <= 10.5 KiB, AGENTS.md sits near 18.8 KiB against its 24 KiB cap — about
# 5.7 KiB of project-tail headroom, still comfortably more than any consumer
# tail measured.
echo "==> TOUCHSTONE.md size cap (10.5 KiB — lean router)"
assert_under "TOUCHSTONE.md" "$TOUCHSTONE_ROOT/TOUCHSTONE.md" 10752

echo "==> AGENTS.md size cap (24 KiB — leaves headroom under Codex's 32 KiB default)"
assert_under "AGENTS.md" "$TOUCHSTONE_ROOT/AGENTS.md" 24576

echo "==> GEMINI.md size cap (24 KiB — same headroom)"
assert_under "GEMINI.md" "$TOUCHSTONE_ROOT/GEMINI.md" 24576

# =============================================================================
# Path integrity — the steering docs may not name a file that does not exist.
#
# Scanned: this repository's own steering surface.
#
# (templates/ was scanned here too until its deletion; it was excluded at
# first, on the theory that a template describes a
# downstream project's tree rather than this one. The reviewer of the strip PR
# immediately found the hole that left: templates/AGENTS.md still told projects
# to run a wrapper this repo had just deleted. The theory was wrong, because a
# template may only name files Touchstone actually ships — nothing else can
# arrive in the project. So the paths ARE claims about this repository, and
# checking them here is the guardrail for that class.
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
    find "$TOUCHSTONE_ROOT/templates" -maxdepth 1 -name '*.md' -type f 2>/dev/null
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

# =============================================================================
# No file may instruct the reader to run the CLI, because no CLI ships.
#
# The path-integrity check above only reads markdown, so it could not see
# setup.sh finishing with "Run `touchstone doctor`" after the same commit
# deleted the block that installed the binary. A user on a fresh clone would
# follow a successful setup straight into command-not-found.
#
# Matched by subcommand rather than by the bare word, so prose about the
# project and the surviving scripts/touchstone-run.sh both stay legal. A
# subcommand leaves this list in the commit that ships it -- `version` did
# (AUT-276) -- and the check retires entirely when the last one does.
# =============================================================================

echo ""
echo "==> No file invokes a touchstone CLI subcommand"

# POSIX ERE only. The first version of this check used `\b` for the trailing
# word boundary, which glibc's ERE honours and BSD/macOS does not — so it
# matched on CI and matched nothing locally. The suite went green on a
# developer machine and red on the required check, which is the worst possible
# split: local green is what people trust. Both boundaries are now bracket
# expressions, which behave identically on both platforms.
# `update` is absent on purpose: 3.0.1 ships it as a compatibility no-op for
# repositories still on the 2.x scripts (their sync guard calls it), so a
# mention of it is a mention of a command that exists.
CLI_SUBCOMMANDS='doctor|status|update-all|upgrade|new|init|release|list|diff|sync|changelog'
CLI_PATTERN="(^|[^-/[:alnum:]])touchstone (${CLI_SUBCOMMANDS})([^[:alnum:]-]|$)"

# The check must be able to fail, and must be proven to on THIS platform
# before its silence is allowed to mean anything.
probe_hit=0
printf 'Run `touchstone doctor` to verify.\n' | grep -qE "$CLI_PATTERN" && probe_hit=1
probe_miss=0
printf 'bash scripts/touchstone-run.sh validate\n' | grep -qE "$CLI_PATTERN" || probe_miss=1
if [ "$probe_hit" -eq 1 ] && [ "$probe_miss" -eq 1 ]; then
  echo "  OK: the pattern matches a CLI invocation and spares touchstone-run.sh"
else
  fail "the CLI-reference pattern is not working on this platform (hit=$probe_hit spared=$probe_miss); its silence below proves nothing"
fi

cli_refs="$(
  git -C "$TOUCHSTONE_ROOT" grep -nE "$CLI_PATTERN" \
    -- ':!tests/test-steering-size-caps.sh' ':!audits' ':!feedback' 2>/dev/null || true
)"
if [ -n "$cli_refs" ]; then
  printf '%s\n' "$cli_refs" >&2
  fail "a file tells the reader to run a touchstone CLI subcommand, but no CLI ships"
else
  echo "  OK: nothing instructs the reader to run a CLI that does not exist"
fi

# Touchstone must obey the conventions it ships. The repo root once lacked
# the '.claude/worktrees/' ignore its templates shipped to every project, so
# its OWN dirty-tree guards refused whenever an agent worktree existed
# (PR #794). templates/ is deleted; the root-side rule remains asserted.
echo ""
echo "==> Self-conformance: agent worktrees are ignored"
if git -C "$TOUCHSTONE_ROOT" check-ignore -q ".claude/worktrees/probe-slice/file.txt"; then
  echo "    OK: the repository root ignores paths under .claude/worktrees/"
else
  echo "FAIL: touchstone's own .gitignore must ignore .claude/worktrees/ (PR #794)" >&2
  echo "      Its dirty-tree guards refuse while any agent worktree exists." >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS scope-guardrail check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: steering size caps, path integrity, and self-conformance hold"
