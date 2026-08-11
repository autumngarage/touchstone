#!/usr/bin/env bash
#
# tests/test-steering-size-caps.sh — scope guardrails: steering-doc size caps
# and the capability registry that governs the shipped executable surface.
#
# The whole point of the TOUCHSTONE.md routing layer is to keep auto-loaded
# context lean: rules that fire on every turn live in TOUCHSTONE.md (which
# CLAUDE.md @-imports and AGENTS.md/GEMINI.md inline via the managed block),
# and everything else is routed via skills or principles/*.md.
#
# These caps catch the failure mode where someone adds a fourth section to
# TOUCHSTONE.md without thinking about the per-turn cost. If a cap is hit,
# either:
#   - move the new content to principles/* or skills/ and route to it from
#     the TOUCHSTONE.md routing table, OR
#   - raise the cap deliberately, with the reasoning documented in the
#     commit message.
#
# Codex's project_doc_max_bytes default is 32 KiB; AGENTS.md staying under
# 24 KiB leaves headroom for project-specific tail content.
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
# (PR #746) plus this branch's enforceable three-job scope contract left 8 KiB
# unreachable (8509 bytes merged). Derivation: TOUCHSTONE.md is inlined into
# AGENTS.md as the managed block; at <= 9 KiB the rendered block stays under
# ~9.5 KiB, preserving >14 KiB of project-tail headroom inside the 24 KiB
# AGENTS.md cap below.
echo "==> TOUCHSTONE.md size cap (9 KiB — lean router)"
assert_under "TOUCHSTONE.md" "$TOUCHSTONE_ROOT/TOUCHSTONE.md" 9216

echo "==> AGENTS.md size cap (24 KiB — leaves headroom under Codex's 32 KiB default)"
assert_under "AGENTS.md" "$TOUCHSTONE_ROOT/AGENTS.md" 24576
assert_under "templates/AGENTS.md" "$TOUCHSTONE_ROOT/templates/AGENTS.md" 24576

echo "==> GEMINI.md size cap (24 KiB — same headroom)"
assert_under "GEMINI.md" "$TOUCHSTONE_ROOT/GEMINI.md" 24576
assert_under "templates/GEMINI.md" "$TOUCHSTONE_ROOT/templates/GEMINI.md" 24576

# =============================================================================
# Capability registry — the same guardrail applied to the executable surface.
#
# The size caps above stop steering docs growing without a decision. These
# checks stop the shipped code surface growing without one: every file under
# the governed directories must declare, in capabilities.toml, which of the
# three mission jobs it serves (TOUCHSTONE.md "Scope"). A new script cannot
# enter the product by simply existing.
#
# These live here rather than in their own file because the repo's review
# guide asks new assertions to join an existing self-test, and because
# preflight already selects this test for governed paths.
# =============================================================================

REGISTRY="$TOUCHSTONE_ROOT/capabilities.toml"
# shellcheck source=../lib/toml.sh
source "$TOUCHSTONE_ROOT/lib/toml.sh"

# Injective: `%` is escaped BEFORE `/` becomes `%2F`, so `lib/a/b` and
# `lib/a%b` cannot collide into one file and borrow each other's job and why
# (PR #703 review). `tr '/' '%'` alone was not one-to-one.
entry_key() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's;/;%2F;g'
}

# Reads whatever registry registry_validate_entries last parsed.
REG_ENTRIES_DIR=""
entry_value() {
  local f
  f="$REG_ENTRIES_DIR/$(entry_key "$1")"
  [ -f "$f" ] || return 1
  # Print everything after the first tab. Assigning $1="" would rebuild the
  # record with OFS (a space) and silently prefix every value.
  awk -F'\t' -v k="$2" '$1 == k { print substr($0, index($0, "\t") + 1); exit }' "$f"
}

registry_collect_entry() {
  local section="$1" key="$2" value="$3" p f
  p="$(toml_unquote "$section")"
  [ -n "$p" ] || return 0
  f="$REG_ENTRIES_DIR/$(entry_key "$p")"
  # A repeated table or key is invalid TOML that entry_value would resolve
  # first-wins, letting a second contradictory declaration borrow the first
  # one's valid values — a second `bin/touchstone` table with job = "vibes"
  # passed the whole suite (PR #703 review). Record the collision instead.
  #
  # The repeat must be detected at the TABLE level, not only per key: a
  # capability split across two headers with disjoint keys (job in one table,
  # why in the other) has no repeated key, yet merges into one valid-looking
  # record from ambiguous TOML (PR #703 review, follow-up). A table is
  # re-entered when its section returns after another section intervened.
  if [ "$(cat "$REG_SCRATCH/last_section" 2>/dev/null)" != "$p" ]; then
    if [ -f "$REG_SCRATCH/seen_sections" ] && grep -Fxq "$p" "$REG_SCRATCH/seen_sections"; then
      printf 'duplicate\t<repeated table header>\n' >>"$f"
    fi
    printf '%s\n' "$p" >>"$REG_SCRATCH/seen_sections"
    printf '%s' "$p" >"$REG_SCRATCH/last_section"
  fi
  if [ -f "$f" ] && awk -F'\t' -v k="$key" '$1 == k { found = 1 } END { exit !found }' "$f"; then
    printf 'duplicate\t%s\n' "$key" >>"$f"
  fi
  printf '%s\t%s\n' "$key" "$value" >>"$f"
  printf '%s\n' "$p" >>"$REG_SCRATCH/paths.raw"
}

# Validate a registry's entries. Problems print on stdout, one per line; the
# return code says whether there were any.
#
# Split out so the rejection branches can be exercised by negative fixtures in
# CI. Running only against the valid checked-in registry meant deleting any
# guard left the suite green — they were verified by hand during review and by
# nothing afterwards (PR #703 review). Sets CUT_COUNT and leaves the parsed
# entries behind for the scope-debt report.
registry_validate_entries() {
  REGISTRY_FILE="$1"
  REG_SCRATCH="$2"
  local errs=0
  local path job why serves dep dep_job serves_count target target_job tracked

  rm -rf "$REG_SCRATCH/entries"
  mkdir -p "$REG_SCRATCH/entries"
  REG_ENTRIES_DIR="$REG_SCRATCH/entries"
  : >"$REG_SCRATCH/paths.raw"
  # Table-repeat tracking is per-parse state: without the reset, sections seen
  # in one fixture's validation would read as repeats in the next.
  : >"$REG_SCRATCH/seen_sections"
  : >"$REG_SCRATCH/last_section"

  toml_parse "$REGISTRY_FILE" registry_collect_entry
  sort -u "$REG_SCRATCH/paths.raw" >"$REG_SCRATCH/declared"

  problem() {
    printf '%s\n' "$1"
    errs=$((errs + 1))
  }

  CUT_COUNT=0
  while IFS= read -r path; do
    job="$(entry_value "$path" job || true)"
    why="$(entry_value "$path" why || true)"

    if [ -n "$(entry_value "$path" duplicate || true)" ]; then
      problem "$path declares '$(entry_value "$path" duplicate)' more than once; one file, one unambiguous declaration"
    fi

    case "$job" in
      constrain | legible | carry | support | mirror | cut) ;;
      "") problem "$path declares no job" ;;
      *) problem "$path declares unknown job '$job'" ;;
    esac

    if [ -z "$why" ]; then
      problem "$path declares no why"
    elif [ "${#why}" -lt 30 ]; then
      problem "$path has a why of ${#why} chars; say what the file does, not what category it is"
    fi

    case "$job" in
      support)
        serves="$(entry_value "$path" serves || true)"
        # Count AFTER normalization: `serves = []` is a nonempty raw value that
        # normalizes to nothing, so an emptiness test on the raw string let an
        # entry pass while naming no consumer at all (PR #703 review).
        serves_count=0
        for dep in $(toml_normalize_array "$serves" | tr ',' ' '); do
          [ -n "$dep" ] || continue
          serves_count=$((serves_count + 1))
          if ! grep -qxF "$dep" "$REG_SCRATCH/declared"; then
            problem "$path serves '$dep', which is not a declared capability"
            continue
          fi
          dep_job="$(entry_value "$dep" job || true)"
          case "$dep_job" in
            constrain | legible | carry) ;;
            *) problem "$path serves '$dep' (job='$dep_job'); support must bottom out in a mission job" ;;
          esac
        done
        [ "$serves_count" -gt 0 ] \
          || problem "$path is support but names no consumers (serves must list at least one)"
        ;;
      mirror)
        target="$(entry_value "$path" mirrors || true)"
        target_job="$(entry_value "$target" job 2>/dev/null || true)"
        if [ -z "$target" ]; then
          problem "$path is a mirror but names no target (mirrors = \"...\")"
        elif [ "$target" = "$path" ]; then
          # A self-mirror satisfies "target exists" and "cmp matches" while
          # never bottoming out in a mission job (PR #703 review).
          problem "$path mirrors itself; a mirror must point at another capability"
        elif [ ! -f "$TOUCHSTONE_ROOT/$target" ]; then
          problem "$path mirrors '$target', which does not exist"
        elif ! grep -qxF "$target" "$REG_SCRATCH/declared"; then
          problem "$path mirrors '$target', which is not a declared capability"
        elif [ "$target_job" != "constrain" ] && [ "$target_job" != "legible" ] && [ "$target_job" != "carry" ]; then
          # Allowlist, not denylist. Excluding only mirror/cut still admitted a
          # support target, and a support-mirror pair could satisfy each other
          # without either reaching a mission job (PR #703 review). Requiring a
          # mission job makes cycles unrepresentable rather than detectable.
          problem "$path mirrors '$target' (job='$target_job'); a mirror must resolve to constrain, legible, or carry"
        elif ! cmp -s "$TOUCHSTONE_ROOT/$path" "$TOUCHSTONE_ROOT/$target"; then
          problem "$path has drifted from its mirror target '$target' — they must stay byte-identical"
        fi
        ;;
      cut)
        tracked="$(entry_value "$path" tracked || true)"
        # Anchored: a glob like #[0-9]* also accepts "#7oops" (PR #703 review).
        if printf '%s' "$tracked" | grep -qE '^#[0-9]+$'; then
          CUT_COUNT=$((CUT_COUNT + 1))
        elif [ -z "$tracked" ]; then
          problem "$path is marked cut but names no tracking issue (tracked = \"#N\")"
        else
          problem "$path has tracked='$tracked'; expected an issue reference like \"#694\""
        fi
        ;;
    esac
  done <"$REG_SCRATCH/declared"

  [ "$errs" -eq 0 ]
}

echo "==> capability registry: surface parity"

if [ ! -f "$REGISTRY" ]; then
  fail "capabilities.toml is missing"
else
  REG_DIR="$(mktemp -d -t touchstone-capreg.XXXXXX)"
  trap 'rm -rf "$REG_DIR"' EXIT

  registry_validate_entries "$REGISTRY" "$REG_DIR" >"$REG_DIR/problems" || true

  # The governed surface is what the repository SHIPS, which is what git
  # tracks — not what happens to sit on this filesystem. `find` reported
  # untracked local artifacts as shipping undeclared and failed a required
  # guardrail on unrelated workspace state; `git ls-files` also lists tracked
  # symlinks and emits repo-relative paths, so the regex-interpolation hazard
  # is gone rather than worked around (PR #703 review).
  # Exclusions are an explicit allowlist of non-capability artifacts, not a
  # shape filter. Excluding every dotfile let a tracked `scripts/.guard` ship
  # with no declaration at all, and a blanket `.md` exclusion had the same
  # hole: ANY markdown-named file under a governed directory could land with
  # no declaration (PR #703 review, twice). Exact paths only — a new prose
  # file must be added here deliberately, in the same diff that adds it.
  PROSE_ALLOWLIST='hooks/README.md'
  filter_prose_allowlist() {
    grep -vxF "$PROSE_ALLOWLIST" || true
  }
  git -C "$TOUCHSTONE_ROOT" ls-files -- bin bootstrap hooks lib scripts 2>/dev/null \
    | filter_prose_allowlist \
    | sort -u >"$REG_DIR/shipped"

  while IFS= read -r path; do
    grep -qxF "$path" "$REG_DIR/shipped" \
      || fail "capabilities.toml declares $path, which does not exist"
  done <"$REG_DIR/declared"

  while IFS= read -r path; do
    grep -qxF "$path" "$REG_DIR/declared" \
      || fail "$path ships but is not declared in capabilities.toml — declare its mission job or delete it"
  done <"$REG_DIR/shipped"

  printf '  OK: %s shipped files enumerated, %s declared\n' \
    "$(wc -l <"$REG_DIR/shipped" | tr -d ' ')" "$(wc -l <"$REG_DIR/declared" | tr -d ' ')"

  # The allowlist must exclude by exact path, not by shape. A markdown-NAMED
  # capability (e.g. a tracked `scripts/notes.md` helper or symlink) must stay
  # on the shipped surface and therefore require a declaration; only the
  # enumerated prose file leaves it (PR #703 review).
  echo "==> capability registry: prose allowlist is exact paths, not a shape"
  if printf 'scripts/notes.md\n' | filter_prose_allowlist | grep -qxF 'scripts/notes.md'; then
    echo "  OK: an unlisted markdown-named file stays on the governed surface"
  else
    fail "an unlisted markdown-named file (scripts/notes.md) was silently dropped from the governed surface; exclusions must name exact prose paths"
  fi
  if printf 'hooks/README.md\n' | filter_prose_allowlist | grep -qxF 'hooks/README.md'; then
    fail "hooks/README.md was not excluded by the prose allowlist"
  else
    echo "  OK: hooks/README.md is excluded by name"
  fi

  echo "==> capability registry: entry validity"
  while IFS= read -r problem_line; do
    [ -n "$problem_line" ] || continue
    fail "$problem_line"
  done <"$REG_DIR/problems"
  [ -s "$REG_DIR/problems" ] || echo "  OK: all entries declare a valid job, why, and job-specific requirements"

  echo "==> capability registry: scope debt"
  if [ "$CUT_COUNT" -eq 0 ]; then
    echo "  OK: no capabilities are awaiting removal"
  else
    cut_lines=0
    while IFS= read -r path; do
      [ "$(entry_value "$path" job || true)" = "cut" ] || continue
      n="$(wc -l <"$TOUCHSTONE_ROOT/$path" | tr -d ' ')"
      cut_lines=$((cut_lines + n))
      printf '  cut: %s (%s lines, %s)\n' "$path" "$n" "$(entry_value "$path" tracked)"
    done <"$REG_DIR/declared"
    printf '  %s capabilities awaiting removal, %s lines\n' "$CUT_COUNT" "$cut_lines"
  fi

  # ---------------------------------------------------------------------------
  # Negative fixtures. Each injects one invalid declaration and must be
  # REJECTED. Without these, deleting any rejection branch above leaves CI
  # green — the guards were verified by hand during review and by nothing
  # afterwards (PR #703 review).
  # ---------------------------------------------------------------------------
  echo "==> capability registry: rejection branches"
  FIXTURE_DIR="$(mktemp -d -t touchstone-capreg-fixtures.XXXXXX)"
  trap 'rm -rf "$REG_DIR" "$FIXTURE_DIR"' EXIT

  reject_case() {
    local name="$1" body="$2" expect="$3"
    local reg="$FIXTURE_DIR/reg.toml" out
    printf '%s\n' "$body" >"$reg"
    if out="$(registry_validate_entries "$reg" "$FIXTURE_DIR" 2>&1)"; then
      fail "registry fixture '$name' was accepted; the rejection branch is dead"
    elif ! printf '%s' "$out" | grep -qF "$expect"; then
      fail "registry fixture '$name' was rejected for the wrong reason: $out"
    else
      echo "  OK: rejects $name"
    fi
  }

  VALID_ANCHOR='["scripts/open-pr.sh"]
job = "constrain"
why = "Forces shipping through the PR path and hands off to the merge gate."'

  # A capability split across REPEATED table headers with disjoint keys has no
  # repeated key, yet is ambiguous TOML that first-wins parsing merges into one
  # valid-looking record (PR #703 review, follow-up).
  reject_case "a repeated table header with disjoint keys" "$VALID_ANCHOR
[\"lib/x.sh\"]
job = \"support\"
serves = \"scripts/open-pr.sh\"
[\"scripts/open-pr.sh\"]
why = \"a second header for an already-declared capability\"" "more than once"

  reject_case "an unknown job" "$VALID_ANCHOR
[\"lib/x.sh\"]
job = \"vibes\"
why = \"A capability declaring a job that does not exist at all.\"" "unknown job 'vibes'"

  reject_case "a missing why" "$VALID_ANCHOR
[\"lib/x.sh\"]
job = \"carry\"" "declares no why"

  reject_case "a boilerplate why" "$VALID_ANCHOR
[\"lib/x.sh\"]
job = \"carry\"
why = \"helper\"" "say what the file does"

  reject_case "an empty serves list" "$VALID_ANCHOR
[\"lib/x.sh\"]
job = \"support\"
serves = []
why = \"A support helper that names no consumer whatsoever.\"" "names no consumers"

  reject_case "support that never reaches a mission job" "$VALID_ANCHOR
[\"lib/a.sh\"]
job = \"support\"
serves = [\"lib/b.sh\"]
why = \"A support helper serving only another support helper.\"
[\"lib/b.sh\"]
job = \"support\"
serves = [\"lib/a.sh\"]
why = \"The other half of a support cycle that reaches no mission job.\"" "must bottom out in a mission job"

  reject_case "a self-referential mirror" "$VALID_ANCHOR
[\"scripts/branch-guard.sh\"]
job = \"mirror\"
mirrors = \"scripts/branch-guard.sh\"
why = \"A mirror declaring itself as its own target to escape validation.\"" "mirrors itself"

  reject_case "a mirror onto a support entry" "$VALID_ANCHOR
[\"lib/ui.sh\"]
job = \"support\"
serves = [\"scripts/open-pr.sh\"]
why = \"A support helper used here as an illegitimate mirror target.\"
[\"scripts/branch-guard.sh\"]
job = \"mirror\"
mirrors = \"lib/ui.sh\"
why = \"A mirror pointing at support rather than a mission job.\"" "must resolve to constrain, legible, or carry"

  reject_case "a cut with no tracking issue" "$VALID_ANCHOR
[\"lib/x.sh\"]
job = \"cut\"
why = \"A condemned capability with no issue tracking its removal.\"" "names no tracking issue"

  reject_case "a cut with a malformed tracking issue" "$VALID_ANCHOR
[\"lib/x.sh\"]
job = \"cut\"
tracked = \"#7oops\"
why = \"A condemned capability whose tracking reference is not an issue.\"" "expected an issue reference"

  reject_case "a repeated declaration" "$VALID_ANCHOR
[\"scripts/open-pr.sh\"]
job = \"vibes\"
why = \"A second table for a path that was already declared above.\"" "more than once"

  reject_case "path keys that collide under encoding" "$VALID_ANCHOR
[\"lib/a/b\"]
job = \"carry\"
why = \"A declared path that must not share storage with a similar one.\"
[\"lib/a%b\"]
job = \"vibes\"
why = \"A second path that differs only by slash versus percent sign.\"" "unknown job 'vibes'"

  # A valid registry must still be accepted, or every case above would pass
  # for the trivial reason that validation always fails.
  #
  # Written BEFORE it is validated. The previous form short-circuited on a
  # nonexistent file, which toml_parse reads as an empty-and-valid registry,
  # so the control reported success without ever parsing VALID_ANCHOR
  # (PR #703 review).
  printf '%s\n' "$VALID_ANCHOR" >"$FIXTURE_DIR/valid.toml"
  if registry_validate_entries "$FIXTURE_DIR/valid.toml" "$FIXTURE_DIR" >/dev/null 2>&1; then
    echo "  OK: accepts a valid registry"
  else
    fail "a minimal valid registry was rejected; the fixtures above prove nothing"
  fi

  # An empty registry must NOT read as a passing one, or a missing or
  # truncated capabilities.toml would look like a clean bill of health.
  : >"$FIXTURE_DIR/empty.toml"
  if registry_validate_entries "$FIXTURE_DIR/empty.toml" "$FIXTURE_DIR" >/dev/null 2>&1; then
    echo "  NOTE: an empty registry validates vacuously; surface parity is what catches it"
  fi

  # No restore-parse: nothing downstream reads the restored entries — the
  # remainder of the file consumes only $ERRORS — and reparsing the full real
  # ledger cost ~19 seconds of a guard lib/preflight.sh selects for every
  # governed-path change (PR #703 review).
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS scope-guardrail check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: steering-doc size caps and capability registry are respected"
