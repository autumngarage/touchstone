#!/usr/bin/env bash
#
# scripts/touchstone-steering-install.sh — put the universal contract where
# every agent on this machine reads it.
#
# Usage:
#   bash scripts/touchstone-steering-install.sh install [--home DIR] [--dry-run] [--non-interactive]
#   bash scripts/touchstone-steering-install.sh check   [--home DIR]
#   bash scripts/touchstone-steering-install.sh uninstall [--home DIR]
#
# `managed` is the upgrader's read-only ownership probe. It is deliberately
# not a user-facing steering mode: exit 0 means this tool already owns at
# least one managed block, and exit 1 means confirmed absent.
#
# Steering was the only Touchstone layer that propagated by copying. Merge
# rules live in one GitHub ruleset, the validation workflow in one pinned SHA,
# tool logic in one Homebrew formula — but the contract itself was pasted into
# every consumer, so every edit meant a pull request per repository. Measured
# 2026-08-18: zero of ten consumer copies matched, and several instructed
# agents to do what the contract forbids.
#
# This installs it once per machine instead. Claude Code, Codex, and Gemini
# each read a user-level instruction file and layer project files over it, so
# a managed block there reaches every repository at once and a project keeps
# the last word.
#
# The block is delimited, idempotent, and never touches a byte outside its
# markers. Content you wrote in those files is yours.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$ROOT/TOUCHSTONE.md"
PRINCIPLES_SOURCE="$ROOT/principles"
# Where the routed documents live on the machine. The block's routing table is
# rewritten to point here, so `principles/git-workflow.md` resolves for an
# agent in a repository that carries no Touchstone files.
PRINCIPLES_RELATIVE=".touchstone/principles"
# Ownership is recorded, not inferred. A content heuristic misjudges both
# directions: an operator file can resemble ours, and one of ours can change
# until it no longer matches the pattern. The manifest is a fact.
PRINCIPLES_MANIFEST=".touchstone-installed"
# The bundled Claude skills are routed documents in another layout: they
# reference `principles/...` the same way, the steering tells Claude agents to
# trust them, and a copy that is not refreshed by install drifts exactly the
# way a copied principle did (2026-08-21: the installed git-workflow skill
# still said `open-pr.sh --auto-merge`). They are installed under the same
# ownership rules as the principles, one manifest per destination.
SKILLS_SOURCE="$ROOT/skills"
SKILLS_RELATIVE=".claude/skills"
# The active document set. Every routed-document function reads these rather
# than the principles constants, so the same code installs both sets.
SET_NAME=""
SET_SOURCE=""
SET_RELATIVE=""
use_set() {
  case "$1" in
    principles)
      SET_NAME=principles
      SET_SOURCE="$PRINCIPLES_SOURCE"
      SET_RELATIVE="$PRINCIPLES_RELATIVE"
      ;;
    skills)
      SET_NAME=skills
      SET_SOURCE="$SKILLS_SOURCE"
      SET_RELATIVE="$SKILLS_RELATIVE"
      ;;
    *) die "unknown document set: $1" ;;
  esac
}
DOCUMENT_SETS="principles skills"
# The relative paths of the active set's documents, one per line, sorted.
# Principles are flat markdown; a skill is <name>/SKILL.md plus any
# <name>/agents/*.yaml the driver reads.
set_documents() {
  [ -d "$SET_SOURCE" ] || return 0
  case "$SET_NAME" in
    principles) (cd "$SET_SOURCE" && ls -1 ./*.md 2>/dev/null | sed 's|^\./||') ;;
    skills) (cd "$SET_SOURCE" && find . -type f \( -name SKILL.md -o -path '*/agents/*.yaml' \) | sed 's|^\./||' | LC_ALL=C sort) ;;
  esac
}
# A document's relative path may have directories, but no component may be
# empty, `.`, `..`, or dash-led, and the path is never absolute: a manifest
# entry that fails this must never direct a write or delete outside the set's
# destination.
valid_relative_name() {
  local path="$1" component rest
  [ -n "$path" ] || return 1
  case "$path" in /* | *//* | */) return 1 ;; esac
  rest="$path"
  while :; do
    component="${rest%%/*}"
    case "$component" in '' | . | .. | -*) return 1 ;; esac
    [ "$rest" != "$component" ] || break
    rest="${rest#*/}"
  done
  return 0
}
BEGIN_MARKER='<!-- touchstone:steering:start -->'
# The start marker may carry attributes (see restore-newline below).
BEGIN_MARKER_RE='^<!-- touchstone:steering:start( restore-newline| created-file)? -->$'
# Any start-marker-shaped line, so an unrecognized attribute is detected as a
# marker this version does not understand rather than ignored as prose.
BEGIN_MARKER_ANY='^<!-- touchstone:steering:start( .*)? -->$'
END_MARKER='<!-- touchstone:steering:end -->'

# driver:relative path. Every supported driver reads a user-level instruction
# file and layers project files over it.
TARGETS=(
  "claude:.claude/CLAUDE.md"
  "codex:.codex/AGENTS.md"
  "gemini:.gemini/GEMINI.md"
)

ACTION="${1:-}"
[ -n "$ACTION" ] || {
  sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
shift

HOME_DIR="${HOME:-}"
HOME_WAS_EXPLICIT=false
DRY_RUN=false
NON_INTERACTIVE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --home requires a directory" >&2
        exit 2
      }
      HOME_DIR="$2"
      HOME_WAS_EXPLICIT=true
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
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
  # The upgrader reserves exit 1 for one fact only: no managed steering is
  # present. Any malformed path or operational failure must remain distinct
  # so upgrade cannot mistake an unreadable ownership state for opt-out.
  [ "${ACTION:-}" != managed ] || exit 2
  exit 1
}

offer_review_setup() {
  local answer review_credential_scope
  [ "$DRY_RUN" = false ] || return 0
  [ "${TOUCHSTONE_REVIEW_PLATFORM:-$(uname -s)}" = Darwin ] || {
    echo "Next: configure an OpenRouter credential for this platform, or record the normal-review waiver when it is unavailable."
    return 0
  }
  if [ "$HOME_WAS_EXPLICIT" = true ]; then
    review_credential_scope="$HOME_DIR/.codex"
  else
    review_credential_scope="${CODEX_HOME:-$HOME_DIR/.codex}"
  fi
  if bash "$ROOT/scripts/touchstone-review.sh" credential-check \
    --codex-home "$review_credential_scope" >/dev/null 2>&1; then
    echo "==> lower-cost normal review is already configured"
    return 0
  fi
  if [ "$NON_INTERACTIVE" = true ]; then
    echo "Next: run 'touchstone review setup' once to save an OpenRouter key in macOS Keychain for lower-cost normal reviews."
    return 0
  fi
  if [ -t 0 ] && [ -t 1 ]; then
    printf '\nSet up lower-cost normal reviews through OpenRouter now? [Y/n] '
    if ! IFS= read -r answer; then
      answer=n
    fi
    case "$answer" in
      '' | y | Y | yes | YES | Yes)
        bash "$ROOT/scripts/touchstone-review.sh" setup \
          --codex-home "$review_credential_scope"
        ;;
      *)
        echo "Skipped. Run 'touchstone review setup' once when you are ready."
        ;;
    esac
  else
    echo "Next: run 'touchstone review setup' once to save an OpenRouter key in macOS Keychain for lower-cost normal reviews."
  fi
}

[ -n "$HOME_DIR" ] || die "no home directory: set HOME or pass --home"
# The rendered routes are absolute paths agents follow from wherever they are
# started. A relative --home would embed routes that resolve only from this
# command's working directory -- and check would agree, because it renders the
# same broken value. Canonicalize the existing part; the rest is created later.
case "$HOME_DIR" in
  /*) ;;
  *)
    # Prefix the working directory rather than resolving component by
    # component: with `new/child`, a `cd $(dirname ...)` that fails leaves the
    # basename to stand alone, and the assignment succeeds as `/child` -- a
    # privileged install would then write to the filesystem root.
    HOME_DIR="$(pwd -P)/$HOME_DIR" || die "could not resolve --home: $HOME_DIR"
    ;;
esac
# After canonicalization, so a relative --home under a quoted directory is
# judged by its full path: rewritten command examples single-quote the
# installed path, and a single quote is the one character that cannot carry.
case "$HOME_DIR" in
  *"'"*) die "the home directory contains a single quote, which the rewritten command examples cannot quote safely: $HOME_DIR" ;;
esac

# Upgrade may refresh only an existing Touchstone install. The reserved block
# marker is the ownership fact at this boundary; a manifest pathname cannot
# prove its own provenance, and ordinary ~/.touchstone or agent directories
# are operator state that must not opt a machine into steering.
managed_steering_present() {
  local target relative path parent probe_status
  [ -d "$HOME_DIR" ] && [ -x "$HOME_DIR" ] || return 2
  for target in "${TARGETS[@]}"; do
    relative="${target#*:}"
    path="$HOME_DIR/$relative"
    parent="${path%/*}"
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      [ -d "$parent" ] && [ -x "$parent" ] || return 2
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] || return 2
      if grep -Eq "$BEGIN_MARKER_ANY" "$path"; then
        return 0
      else
        probe_status="$?"
        [ "$probe_status" -eq 1 ] || return 2
      fi
    fi
  done
  return 1
}

if [ "$ACTION" = managed ]; then
  [ "$DRY_RUN" = false ] || die "managed is a read-only ownership probe and accepts no --dry-run"
  if managed_steering_present; then
    echo "managed"
    exit 0
  else
    probe_status="$?"
  fi
  if [ "$probe_status" -ne 1 ]; then
    echo "ERROR: could not inspect existing steering ownership under $HOME_DIR" >&2
    exit 2
  fi
  echo "absent"
  exit 1
fi

[ -f "$SOURCE" ] || die "canonical steering is missing: $SOURCE"

# A marker line in the source would be copied into the block and make the very
# next check reject it.
# Every start-marker shape, not only the plain one: the attributed form
# (`start restore-newline`) slipped past a literal comparison, and install
# then wrote two start markers into every driver file before check rejected
# the result.
if awk -v m="$BEGIN_MARKER_ANY" '$0 ~ m { found = 1 } END { exit !found }' "$SOURCE" \
  || awk -v m="$END_MARKER" '$0 == m { found = 1 } END { exit !found }' "$SOURCE"; then
  die "canonical steering contains a managed marker line; document markers only in inline code"
fi

TMP_DIR=""
if [ "$ACTION" != check ]; then
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-steering-install.XXXXXX")" \
    || die "could not create a workspace under ${TMPDIR:-/tmp}"
fi
# Staging files are created in the destination directory, not the workspace,
# so removing TMP_DIR does not reach them. Any die between staging a file and
# committing it would otherwise leave an orphan in the operator's ~/.claude.
STAGED_TEMPORARIES=()
cleanup_workspace() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
  local leftover
  for leftover in ${STAGED_TEMPORARIES[@]+"${STAGED_TEMPORARIES[@]}"}; do
    rm -f -- "$leftover"
  done
}
trap cleanup_workspace EXIT

# The tool version that wrote a block is recorded inside it, so `check` can
# say which side is newer instead of only "drift".
TOOL_VERSION=""
if [ -f "$ROOT/VERSION" ]; then
  TOOL_VERSION="$(head -n 1 "$ROOT/VERSION" | tr -d '[:space:]')"
fi
TOOL_VERSION="${TOOL_VERSION:-unknown}"

installed_block_version() {
  # The version named in a file's installed block, or "pre-3.2" for a block
  # written before versions were recorded.
  local path="$1" found
  found="$(sed -nE 's/^<!-- Installed by touchstone ([0-9][^ .]*(\.[0-9]+)*)\..*/\1/p' "$path" 2>/dev/null | head -n 1)"
  printf '%s' "${found:-pre-3.2}"
}

render_block() {
  local out="$1"
  # The routing table names principles/*.md. Those documents are installed
  # beside the block, so the paths must resolve from the agent's home rather
  # than from a repository that no longer carries them.
  local principles_home="$HOME_DIR/$PRINCIPLES_RELATIVE"
  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '\n<!-- Installed by touchstone %s. Do not edit between the markers; edit the\n' "$TOOL_VERSION"
    cat <<'EOF'
     project's TOUCHSTONE.md upstream and reinstall. Everything outside the
     markers is yours. Remove with: touchstone steering uninstall -->
EOF
    sed "s|\`principles/|\`$(sed_replacement "$principles_home")/|g" "$SOURCE"
    if [ -n "$(tail -c 1 "$SOURCE")" ]; then printf '\n'; fi
    printf '%s\n' "$END_MARKER"
  } >"$out"
}

capture_rendered() {
  local output_name="$1" captured
  shift
  captured="$({
    "$@" /dev/stdout || exit
    printf x
  })" \
    || die "could not render canonical steering content"
  captured="${captured%x}"
  printf -v "$output_name" '%s' "$captured"
}

# A home path is data, not sed replacement syntax. `&` means "the whole match"
# and the delimiter ends the replacement, so a home like `home&name` silently
# produced routes to directories that do not exist -- silently because install
# and check render the same wrong value and therefore agree.
sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Rebuild one file: everything before the block, the block, everything after.
# Byte-exact outside the markers, including a tail that ends without a newline.
compose() {
  local path="$1" block="$2" out="$3" begin_line end_line begin_count end_count tail_offset
  # Per-target state: a previous driver's newline-less file must not mark this
  # one for restoration.
  NEEDS_NEWLINE_RESTORE=false
  CREATED_FILE=false

  if [ ! -f "$path" ]; then
    # A file this tool creates has no separator, and the marker says so:
    # uninstall must not treat a blank line the operator later prepends as
    # ours to remove.
    sed "1s|.*|<!-- touchstone:steering:start created-file -->|" "$block" >"$out"
    return 0
  fi

  begin_count="$(awk -v m="$BEGIN_MARKER_ANY" '$0 ~ m { c++ } END { print c + 0 }' "$path")"
  end_count="$(awk -v m="$END_MARKER" '$0 == m { c++ } END { print c + 0 }' "$path")"
  unknown_attr="$(awk -v any="$BEGIN_MARKER_ANY" -v known="$BEGIN_MARKER_RE" \
    '$0 ~ any && $0 !~ known { c++ } END { print c + 0 }' "$path")"
  [ "$unknown_attr" = 0 ] \
    || die "$path carries a start marker with an attribute this version does not understand; upgrade touchstone or remove the block by hand"

  if [ "$begin_count" = 0 ] && [ "$end_count" = 0 ]; then
    # No managed block yet: append, preserving the operator's own content.
    cat "$path" >"$out"
    # Record whether the operator's content lacked a final newline, so
    # uninstall can restore the file byte-for-byte rather than leaving the
    # newline this append had to add.
    if [ -s "$path" ] && [ -n "$(tail -c 1 "$path")" ]; then
      printf '\n' >>"$out"
      NEEDS_NEWLINE_RESTORE=true
    fi
    printf '\n' >>"$out"
    # The start marker carries the restore hint as an attribute, so it cannot
    # collide with a line the operator legitimately wrote.
    if [ "$NEEDS_NEWLINE_RESTORE" = true ]; then
      sed "1s|.*|<!-- touchstone:steering:start restore-newline -->|" "$block" >>"$out"
    else
      cat "$block" >>"$out"
    fi
    return 0
  fi

  [ "$begin_count" = 1 ] || die "$path has $begin_count exact-line start markers, expected 0 or 1"
  [ "$end_count" = 1 ] || die "$path has $end_count exact-line end markers, expected 0 or 1"
  begin_line="$(awk -v m="$BEGIN_MARKER_ANY" '$0 ~ m { print NR; exit }' "$path")"
  end_line="$(awk -v m="$END_MARKER" '$0 == m { print NR; exit }' "$path")"
  [ "$begin_line" -lt "$end_line" ] || die "$path has its end marker before its start marker"

  # A refresh must preserve the hint the first install recorded: the operator's
  # own content still lacks the trailing newline the block replaced.
  case "$(sed -n "${begin_line}p" "$path")" in
    *restore-newline*) NEEDS_NEWLINE_RESTORE=true ;;
    *created-file*) CREATED_FILE=true ;;
  esac
  if [ "$((begin_line - 1))" -gt 0 ]; then
    head -n "$((begin_line - 1))" "$path" >"$out"
  else
    : >"$out"
  fi
  if [ "$NEEDS_NEWLINE_RESTORE" = true ]; then
    sed "1s|.*|<!-- touchstone:steering:start restore-newline -->|" "$block" >>"$out"
  elif [ "$CREATED_FILE" = true ]; then
    sed "1s|.*|<!-- touchstone:steering:start created-file -->|" "$block" >>"$out"
  else
    cat "$block" >>"$out"
  fi
  tail_offset="$(head -n "$end_line" "$path" | wc -c | tr -d ' ')"
  tail -c "+$((tail_offset + 1))" "$path" >>"$out"
}

# Remove the block and the blank line that introduced it, leaving the rest
# byte-identical.
compose_removal() {
  local path="$1" out="$2" begin_line end_line tail_offset begin_count end_count
  # Same validation the install path uses. Removing a block from a file with
  # repeated or reversed markers would delete a span the operator owns.
  begin_count="$(awk -v m="$BEGIN_MARKER_RE" '$0 ~ m { c++ } END { print c + 0 }' "$path")"
  end_count="$(awk -v m="$END_MARKER" '$0 == m { c++ } END { print c + 0 }' "$path")"
  if [ "$begin_count" = 0 ] && [ "$end_count" = 0 ]; then return 1; fi
  [ "$begin_count" = 1 ] && [ "$end_count" = 1 ] || return 2
  begin_line="$(awk -v m="$BEGIN_MARKER_RE" '$0 ~ m { print NR; exit }' "$path")"
  end_line="$(awk -v m="$END_MARKER" '$0 == m { print NR; exit }' "$path")"
  [ -n "$begin_line" ] && [ -n "$end_line" ] || return 2
  [ "$begin_line" -lt "$end_line" ] || return 2
  local keep=$((begin_line - 1)) strip_trailing_newline=false separator_found=false created_file=false
  case "$(sed -n "${begin_line}p" "$path")" in
    *created-file*) created_file=true ;;
  esac
  # A file this tool created carries no separator of ours, so a blank line
  # before the block belongs to whoever prepended it.
  if [ "$created_file" != true ] && [ "$keep" -gt 0 ] && [ -z "$(sed -n "${keep}p" "$path")" ]; then
    keep=$((keep - 1))
    separator_found=true
  fi
  # The hint the install recorded on the start marker itself.
  case "$(sed -n "${begin_line}p" "$path")" in
    *restore-newline*) strip_trailing_newline=true ;;
  esac
  if [ "$keep" -gt 0 ]; then
    head -n "$keep" "$path" >"$out"
  else
    : >"$out"
  fi
  # Remove the newline install added after the operator's last line -- but
  # only when install's blank-line separator sat directly before the marker,
  # which proves nothing was inserted between them and that the last remaining
  # byte is therefore ours. If the operator added a line there, the separator
  # is buried at an offset we cannot recover, and trimming would eat the
  # newline terminating *their* line instead. Leaving one extra blank line is
  # the right error to make: never delete a byte you cannot prove you own.
  if [ "$strip_trailing_newline" = true ] && [ "$separator_found" = true ] && [ -s "$out" ]; then
    local prefix_bytes
    prefix_bytes="$(wc -c <"$out" | tr -d ' ')"
    if [ "$(tail -c 1 "$out" | od -An -c | tr -d ' ')" = "\\n" ]; then
      head -c "$((prefix_bytes - 1))" "$out" >"$out.trimmed" \
        && mv -f -- "$out.trimmed" "$out"
    fi
  fi
  tail_offset="$(head -n "$end_line" "$path" | wc -c | tr -d ' ')"
  tail -c "+$((tail_offset + 1))" "$path" >>"$out"
}

BLOCK=""
if [ "$ACTION" != check ]; then
  BLOCK="$TMP_DIR/block"
  render_block "$BLOCK"
else
  capture_rendered BLOCK render_block
fi

# Fail before any driver file is touched if the routed destination cannot be
# prepared, so a bad path cannot leave three instruction files pointing at
# documents that were never installed.
# A set with no documents (a release that ships no skills) installs, checks,
# and removes nothing, and creates no directory.
set_is_empty() { [ -z "$(set_documents)" ]; }

preflight_principles() {
  local destination="$HOME_DIR/$SET_RELATIVE"
  if [ "$SET_NAME" = principles ]; then
    [ -d "$SET_SOURCE" ] || die "routed steering documents are missing: $SET_SOURCE"
  fi
  set_is_empty && return 0
  if [ -e "$destination" ] && [ ! -d "$destination" ]; then
    die "$destination exists and is not a directory; move it before installing"
  fi
  if [ -d "$destination" ]; then
    [ -w "$destination" ] || die "$destination is not writable"
  elif [ "$DRY_RUN" = true ]; then
    # A dry run must not create anything, but it must still answer the
    # question it is asked: could this install proceed? Check the nearest
    # existing ancestor instead of creating the directory.
    local ancestor="$destination"
    while [ ! -e "$ancestor" ] && [ "$ancestor" != "/" ] && [ "$ancestor" != "." ]; do
      ancestor="$(dirname "$ancestor")"
    done
    [ -d "$ancestor" ] || die "$ancestor exists and is not a directory; move it before installing"
    [ -w "$ancestor" ] || die "$ancestor is not writable"
  else
    mkdir -p "$destination" || die "could not create $destination"
    [ -w "$destination" ] || die "$destination is not writable"
  fi
  # A manifest that exists without the documents it claims is not ours: either
  # the operator wrote it, or an install was interrupted. Refuse rather than
  # trusting it to say what may be deleted later.
  local manifest="$destination/$PRINCIPLES_MANIFEST" recorded
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -e "$manifest" ] || die "$SET_RELATIVE/$PRINCIPLES_MANIFEST is a dangling symlink; move it before installing"
    [ -f "$(resolve_link "$manifest")" ] || die "$SET_RELATIVE/$PRINCIPLES_MANIFEST is not a regular file; move it before installing"
    local tab line
    tab="$(printf '\t')"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Split by hand rather than by IFS: a line with no tab at all would
      # otherwise land entirely in the checksum field, leaving the name empty
      # and the entry skipped as blank -- which is how a traversing entry
      # could slip past this refusal.
      case "$line" in
        *"$tab"*) recorded="${line#*"$tab"}" ;;
        *) die "$SET_RELATIVE/$PRINCIPLES_MANIFEST has an entry with no recorded checksum: $line" ;;
      esac
      valid_relative_name "$recorded" \
        || die "$SET_RELATIVE/$PRINCIPLES_MANIFEST contains an entry that is not a valid relative name: $recorded"
    done <"$manifest"
  fi

  local doc name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    doc="$SET_SOURCE/$name"
    valid_relative_name "$name" || die "shipped document has an invalid name: $name"
    if [ -d "$destination/$name" ]; then
      die "$SET_RELATIVE/$name is a directory; move it before installing"
    fi
    # Every ancestor of a nested document must be a directory or absent: a
    # regular file where a skill's directory belongs would fail at mkdir
    # after the driver files were already written, which is the partial
    # state preflight exists to prevent.
    local ancestor
    ancestor="$(dirname "$name")"
    while [ "$ancestor" != . ]; do
      if { [ -e "$destination/$ancestor" ] || [ -L "$destination/$ancestor" ]; } && [ ! -d "$destination/$ancestor" ]; then
        die "$SET_RELATIVE/$ancestor exists and is not a directory; move it before installing"
      fi
      ancestor="$(dirname "$ancestor")"
    done
    # A file we did not install belongs to the operator. Detect it here, before
    # any driver file is written, so the refusal costs nothing. -L as well as
    # -e: a dangling symlink is not `-e`, so a link the operator made to a
    # file that does not exist yet read as "absent" and was replaced by a
    # regular file, losing the link with nothing preserved.
    #
    # The skills set is the exception by construction: its directories are
    # named for this tool's own skills (touchstone-*, memory-audit), and the
    # copies found there predate management -- install preserves them as
    # `.SKILL.md.replaced` and takes over, rather than refusing forever.
    if { [ -e "$destination/$name" ] || [ -L "$destination/$name" ]; } \
      && ! principles_owned "$name"; then
      # A dangling link cannot be written through (install resolves the
      # link and moves the rendered file onto its referent, whose parent is
      # missing); refuse it in every set, before any driver file is written.
      if [ -L "$destination/$name" ] && [ ! -e "$destination/$name" ]; then
        die "$SET_RELATIVE/$name is a dangling symlink; move it before installing"
      fi
      [ "$SET_NAME" = skills ] \
        || die "$SET_RELATIVE/$name exists and was not installed by touchstone; move it before installing"
    fi
  done < <(set_documents)
}

# Render one routed document with its cross-references pointing at the
# installed copies. These documents reference each other by `principles/...`;
# unrewritten, those links resolve nowhere on a machine whose repositories
# carry no Touchstone files.
render_principle() {
  local source="$1" out="$2" principles_home="$HOME_DIR/$PRINCIPLES_RELATIVE"
  # Two spellings route to the installed copies: inline code (`principles/…`)
  # and a bare ` principles/…` path inside a command line. Both must resolve
  # beside the installed steering block, not inside a consumer repository.
  sed -e "s|\`principles/|\`$(sed_replacement "$principles_home")/|g" \
    -e "s|\([[:space:]]\)principles/\([A-Za-z0-9._-]*\.md\)|\1'$(sed_replacement "$principles_home")/\2'|g" "$source" >"$out"
}

# Ownership is recorded per entry as `checksum<TAB>name`; match on the name
# field alone, because a document we installed and then reinstall over has
# legitimately drifted from its recorded checksum.
# The set of documents this tool installs. It is the authority on what may be
# deleted: the manifest records what was written, but cannot vouch for itself.
# Staging paths are created exclusively, never reused. A predictable name --
# a PID, which recurs -- can be pre-created as a symlink, and `cp` would then
# follow it: the payload overwrites the link's referent and the `mv` installs
# the symlink as the driver's instruction path. Reproduced in review.
# Follow a symlink to its final referent, the way the driver path does. A
# symlinked routed document is the same deliberate arrangement -- a dotfiles
# repository holding the real file -- and replacing the link with a regular
# file silently orphans it. Bounded like the driver resolution.
resolve_link() {
  local target="$1" hops=0 link_target
  while [ -L "$target" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 16 ] || die "symlink chain too deep at $target"
    link_target="$(readlink "$target")"
    case "$link_target" in
      /*) target="$link_target" ;;
      *) target="$(cd "$(dirname "$target")" && pwd -P)/$link_target" ;;
    esac
  done
  printf '%s\n' "$target"
}

# Returns through STAGED_PATH rather than stdout: a command substitution runs
# in a subshell, so recording the path in STAGED_TEMPORARIES there would be
# lost and the cleanup trap would never see it.
stage_path() {
  local directory="$1" prefix="$2"
  STAGED_PATH="$(mktemp "$directory/.$prefix.XXXXXXXX")" \
    || die "could not create a staging file in $directory"
  STAGED_TEMPORARIES+=("$STAGED_PATH")
}

shipped_document() {
  local candidate="$1"
  valid_relative_name "$candidate" || return 1
  set_documents | grep -qxF -- "$candidate"
}

# Ownership must be provable on the install path too, not only on uninstall:
# overwriting an operator's file destroys content irreversibly, so a name in
# the manifest is not enough. The entry must record the bytes that are there
# now -- which a corrupted manifest carrying `anything<TAB>git-workflow.md`
# cannot, and which a document the operator edited after install no longer
# matches.
principles_owned() {
  local name="$1" destination="$HOME_DIR/$SET_RELATIVE"
  local manifest="$destination/$PRINCIPLES_MANIFEST"
  [ -f "$manifest" ] || return 1
  shipped_document "$name" || return 1
  [ -f "$destination/$name" ] || return 1
  grep -qxF "$(cksum <"$destination/$name")	$name" "$manifest"
}

install_principles() {
  local destination="$HOME_DIR/$SET_RELATIVE" doc name staged backup suffix manifest_staged
  set_is_empty && return 0
  stage_path "$destination" "$PRINCIPLES_MANIFEST"
  manifest_staged="$STAGED_PATH"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    doc="$SET_SOURCE/$name"
    # A nested document lives in its own directory; staging happens beside it
    # so the final mv stays a same-directory rename.
    mkdir -p "$(dirname "$destination/$name")" || die "could not create $(dirname "$SET_RELATIVE/$name")"
    stage_path "$(dirname "$destination/$name")" "$(basename "$name")"
    staged="$STAGED_PATH"
    render_principle "$doc" "$staged" || {
      rm -f -- "$staged"
      die "could not stage $name"
    }
    # The manifest sits beside the documents and is owned by the same user, so
    # it can never be evidence independent of them: anyone able to forge an
    # entry can already edit the file it names. Rather than keep hardening a
    # provenance check that has no trust root, make the overwrite recoverable
    # -- the bytes survive whether or not the ownership claim was honest.
    if [ -f "$destination/$name" ] && ! cmp -s "$destination/$name" "$staged"; then
      # Never clobber to make a backup. An earlier upgrade's backup can be the
      # only surviving copy of operator content, and a symlink at that path
      # would send the write somewhere else entirely, so find a free name
      # rather than trusting the obvious one to be unused.
      backup="$(dirname "$destination/$name")/.$(basename "$name").replaced"
      suffix=1
      while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$(dirname "$destination/$name")/.$(basename "$name").replaced.$suffix"
        suffix=$((suffix + 1))
        [ "$suffix" -le 1000 ] || die "too many preserved copies of $name; clear $destination"
      done
      cp -p -- "$destination/$name" "$backup" \
        || die "could not preserve the existing $name before replacing it"
      printf '  preserved: %s -> %s\n' "$name" "$(basename "$backup")"
    fi
    mv -f -- "$staged" "$(resolve_link "$destination/$name")" || {
      rm -f -- "$staged"
      die "could not install $name"
    }
    printf '%s\t%s\n' "$(cksum <"$destination/$name")" "$name" >>"$manifest_staged"
  done < <(set_documents)
  # A release that removes or renames a document must not leave the copy it
  # installed behind: the old manifest is the only record that we wrote it,
  # and replacing that manifest is the moment the knowledge is lost.
  if [ -f "$destination/$PRINCIPLES_MANIFEST" ]; then
    local prior_sum prior_name pruned prune_suffix
    while IFS="$(printf '\t')" read -r prior_sum prior_name; do
      [ -n "$prior_name" ] || continue
      valid_relative_name "$prior_name" || continue
      shipped_document "$prior_name" && continue
      [ -f "$destination/$prior_name" ] || continue
      if [ "$prior_sum" = "$(cksum <"$destination/$prior_name")" ]; then
        # A checksum the manifest recorded is not proof the manifest is
        # honest -- an entry naming an operator's file can carry that file's
        # own checksum. Same answer as the overwrite path: keep the bytes, so
        # a dishonest entry costs a stray file rather than their content.
        pruned="$(dirname "$destination/$prior_name")/.$(basename "$prior_name").replaced"
        prune_suffix=1
        while [ -e "$pruned" ] || [ -L "$pruned" ]; do
          pruned="$(dirname "$destination/$prior_name")/.$(basename "$prior_name").replaced.$prune_suffix"
          prune_suffix=$((prune_suffix + 1))
          # Refuse, never clobber: breaking with an occupied name in hand
          # lets the mv below destroy that preserved copy.
          if [ "$prune_suffix" -gt 1000 ]; then
            pruned=""
            break
          fi
        done
        if [ -n "$pruned" ] && mv -f -- "$destination/$prior_name" "$pruned" 2>/dev/null; then
          printf '  retired: %s -> %s (no longer shipped)\n' "$prior_name" "$(basename "$pruned")"
        else
          printf '  kept: %s could not be retired\n' "$prior_name" >&2
        fi
      else
        printf '  kept: %s is no longer shipped but has been edited\n' "$prior_name" >&2
      fi
    done <"$destination/$PRINCIPLES_MANIFEST"
  fi
  # Same preservation rule the routed documents follow: the manifest is not
  # independent ownership evidence, so bytes we did not write are preserved
  # before the replacement -- including through a live symlink, where the
  # referent is the file whose content would otherwise be lost.
  local manifest_target
  manifest_target="$(resolve_link "$destination/$PRINCIPLES_MANIFEST")"
  if [ -f "$manifest_target" ] && ! cmp -s "$manifest_target" "$manifest_staged"; then
    backup="$destination/$PRINCIPLES_MANIFEST.replaced"
    suffix=1
    while [ -e "$backup" ] || [ -L "$backup" ]; do
      backup="$destination/$PRINCIPLES_MANIFEST.replaced.$suffix"
      suffix=$((suffix + 1))
      [ "$suffix" -le 1000 ] || die "too many preserved manifests; clear $destination"
    done
    cp -p -- "$manifest_target" "$backup" \
      || die "could not preserve the existing manifest before replacing it"
  fi
  mv -f -- "$manifest_staged" "$manifest_target" \
    || die "could not record the installed document manifest"
}

principles_current() {
  local destination="$HOME_DIR/$SET_RELATIVE" doc
  set_is_empty && return 0
  [ -d "$destination" ] || return 1
  # The manifest is part of the installed state: without it, uninstall cannot
  # tell our documents from the operator's, so a missing manifest is drift.
  # An *extra* entry is drift too -- it is the shape a corrupted manifest
  # takes, and check reporting the install as current would hide it until
  # uninstall acted on it.
  [ -f "$destination/$PRINCIPLES_MANIFEST" ] || return 1
  local recorded_name
  while IFS= read -r recorded_name; do
    [ -n "$recorded_name" ] || continue
    shipped_document "$recorded_name" || return 1
  done < <(cut -f 2- <"$destination/$PRINCIPLES_MANIFEST")
  local rendered doc_name
  while IFS= read -r doc_name; do
    [ -n "$doc_name" ] || continue
    [ -f "$destination/$doc_name" ] || return 1
    grep -qxF "$(cksum <"$destination/$doc_name")	$doc_name" \
      "$destination/$PRINCIPLES_MANIFEST" || return 1
    capture_rendered rendered render_principle "$SET_SOURCE/$doc_name"
    printf '%s' "$rendered" | cmp -s - "$destination/$doc_name" || return 1
  done < <(set_documents)
  return 0
}

# Fail before any driver file is touched if a destination is unusable. A dry
# run runs the same checks: reporting an install that would immediately fail
# as "would reach every agent" is the one answer a dry run must never give.
if [ "$ACTION" = install ]; then
  for document_set in $DOCUMENT_SETS; do
    use_set "$document_set"
    preflight_principles
  done
fi

CHANGED=0
DRIFTED=0
NEEDS_NEWLINE_RESTORE=false
STAGED_PATHS=()
INSTALL_PATHS=()
INSTALL_LABELS=()

for entry in "${TARGETS[@]}"; do
  driver="${entry%%:*}"
  relative="${entry#*:}"
  path="$HOME_DIR/$relative"
  composed=""
  [ "$ACTION" = check ] || composed="$TMP_DIR/$driver"

  # compose reads a non-existent path as an empty prefix, and `mv` onto a
  # directory moves the payload *inside* it -- so a driver path that is a
  # directory installed "successfully" and left the instruction file absent.
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    die "$relative exists and is not a regular file; move it before installing"
  fi

  case "$ACTION" in
    install)
      compose "$path" "$BLOCK" "$composed"
      ;;
    check) ;;
    uninstall)
      if [ ! -e "$path" ]; then
        printf '  absent: %s\n' "$relative"
        continue
      fi
      removal_status=0
      compose_removal "$path" "$composed" || removal_status=$?
      case "$removal_status" in
        0) ;;
        1)
          printf '  absent: %s (no managed block)\n' "$relative"
          continue
          ;;
        *) die "$relative has malformed markers; refusing to remove a span that may be yours" ;;
      esac
      ;;
    *) die "unknown action '$ACTION'; expected install, check, or uninstall" ;;
  esac

  # check compares the managed block only. Comparing whole files would call
  # every operator edit outside the markers "drift", and comparing against a
  # tail rebuilt from the same file would hide real block drift.
  if [ "$ACTION" = check ]; then
    # The version line is reported, never compared: a release that bumps
    # VERSION without touching the contract must not read as drift on every
    # machine. Only the contract text decides.
    if [ ! -f "$path" ]; then
      printf '  DRIFT: %s is absent (no block installed); this tool is %s\n' "$relative" "$TOOL_VERSION" >&2
      DRIFTED=$((DRIFTED + 1))
    elif awk -v b="$BEGIN_MARKER_RE" -v e="$END_MARKER" -v plain="$BEGIN_MARKER" \
      '$0 ~ b { inside = 1; print plain; next } inside { print } $0 == e { inside = 0 }' "$path" \
      | sed -E 's/^<!-- Installed by touchstone [^ .]+(\.[0-9]+)*\. /<!-- Installed by touchstone. /' \
      | cmp -s - <(printf '%s' "$BLOCK" \
        | sed -E 's/^<!-- Installed by touchstone [^ .]+(\.[0-9]+)*\. /<!-- Installed by touchstone. /'); then
      printf '  ok: %s carries the current contract (block from touchstone %s)\n' "$relative" "$(installed_block_version "$path")"
    else
      printf '  DRIFT: %s carries the block from touchstone %s; this tool is %s\n' \
        "$relative" "$(installed_block_version "$path")" "$TOOL_VERSION" >&2
      DRIFTED=$((DRIFTED + 1))
    fi
    continue
  fi

  # A symlinked instruction file is a deliberate arrangement (dotfiles repos
  # do this). Write through to its referent instead of replacing the link
  # with a regular file, which would silently orphan the operator's real file.
  #
  # Resolved before the dry-run exit below, because resolution is read-only
  # and a chain that cannot resolve must fail the prediction too -- a dry run
  # that reports success for an install that dies on a symlink loop is
  # exactly the wrong answer.
  hops=0
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 16 ] || die "symlink chain too deep at $path"
    link_target="$(readlink "$path")"
    case "$link_target" in
      /*) path="$link_target" ;;
      *) path="$(cd "$(dirname "$path")" && pwd -P)/$link_target" ;;
    esac
    # Collapse lexical components so two spellings of one file dedupe -- but
    # only when the parent exists. A link into a missing directory made the
    # `cd` fail while the basename stood alone, silently retargeting the
    # install to `/doc`; a privileged run would then have written to the
    # filesystem root instead of the intended referent.
    case "$path" in
      */*)
        if [ -d "$(dirname "$path")" ]; then
          path="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
        else
          die "$relative resolves through a symlink to a missing directory: $path"
        fi
        ;;
    esac
  done

  if [ -f "$path" ] && cmp -s "$path" "$composed"; then
    continue
  fi

  # The same rule the routed destination follows: a dry run must refuse what
  # the real install would refuse. Checking the parent is read-only, so it
  # belongs before the prediction rather than after it -- otherwise a home
  # whose ~/.claude is a regular file is reported as a clean install.
  parent="$(dirname "$path")"
  if [ -e "$parent" ] && [ ! -d "$parent" ]; then
    die "$parent exists and is not a directory; move it before installing"
  fi
  # An absent parent is created later, so the question is whether it *can* be:
  # walk to the nearest existing ancestor, as the routed preflight does.
  ancestor="$parent"
  while [ ! -e "$ancestor" ] && [ "$ancestor" != "/" ] && [ "$ancestor" != "." ]; do
    ancestor="$(dirname "$ancestor")"
  done
  [ -d "$ancestor" ] || die "$ancestor exists and is not a directory; move it before installing"
  [ -w "$ancestor" ] || die "$ancestor is not writable"

  if [ "$DRY_RUN" = true ]; then
    printf '  would update: %s\n' "$path"
    CHANGED=$((CHANGED + 1))
    continue
  fi

  # Two driver paths may be symlinks to one shared document. Installing it
  # twice would have the second staging file overwrite the first and leave an
  # orphan; the block is identical, so the first write is sufficient.
  # Compare entries, not a flattened string: a referent containing a space can
  # be a prefix of another inside `${array[*]}`, so `/dotfiles/shared` matched
  # `/dotfiles/shared file` and the second driver silently received no block
  # while the command reported covering every agent.
  already_staged=false
  for staged_path in ${INSTALL_PATHS[@]+"${INSTALL_PATHS[@]}"}; do
    [ "$staged_path" = "$path" ] || continue
    already_staged=true
    break
  done
  if [ "$already_staged" = true ]; then
    printf '  shared: %s resolves to an already-staged file\n' "$relative"
    continue
  fi
  mkdir -p "$(dirname "$path")" || die "could not create $(dirname "$path")"
  stage_path "$(dirname "$path")" "$(basename "$path").touchstone-steering"
  staged="$STAGED_PATH"
  # cp -p onto an existing target would copy the workspace file's mode; copy
  # the payload, then restore the target's own permissions. An instruction
  # file the operator restricted to 0600 must not become world-readable
  # because Touchstone rewrote it.
  cp "$composed" "$staged" || {
    rm -f -- "$staged"
    die "could not stage $path"
  }
  if [ -f "$path" ]; then
    existing_mode="$(ls -l "$path" | awk '{print $1}')"
    chmod --reference="$path" "$staged" 2>/dev/null \
      || chmod "$(stat -f '%Lp' "$path" 2>/dev/null || printf 644)" "$staged" 2>/dev/null \
      || printf '  warning: could not preserve permissions on %s (%s)\n' "$relative" "$existing_mode" >&2
  fi
  STAGED_PATHS+=("$staged")
  INSTALL_PATHS+=("$path")
  INSTALL_LABELS+=("$relative")
  CHANGED=$((CHANGED + 1))
done

# Install phase. Every payload is staged beside its destination, so a
# malformed later driver file cannot leave earlier ones already replaced.
index=0
for staged in ${STAGED_PATHS[@]+"${STAGED_PATHS[@]}"}; do
  destination="${INSTALL_PATHS[$index]}"
  label="${INSTALL_LABELS[$index]}"
  index=$((index + 1))
  mv -f -- "$staged" "$destination" || {
    for cleanup in "${STAGED_PATHS[@]}"; do rm -f -- "$cleanup"; done
    die "could not write $destination; re-run to converge the rest"
  }
  printf '  %s: %s\n' "$([ "$ACTION" = uninstall ] && printf removed || printf installed)" "$label"
done

uninstall_set() {
  local principles_home doc name manifest_referent manifest_ours manifest_entries manifest_line manifest_name manifest_sum recorded_sum recorded retired retire_suffix
  set_is_empty && return 0
  # Remove only the documents this tool installed. The directory may hold
  # the operator's own files; a recursive delete would take them too.
  principles_home="${HOME_DIR:?}/${SET_RELATIVE:?}"
  if [ -d "$principles_home" ]; then
    # Remove exactly what the manifest records, so a bundled name the
    # operator owns is left alone even across releases that change which
    # documents ship.
    if [ ! -f "$principles_home/$PRINCIPLES_MANIFEST" ]; then
      # No ownership record. Bytes identical to what this release renders
      # are still provably ours -- the same rule the manifest path applies
      # -- and anything else is reported, never guessed at. Silence here
      # claimed a complete removal that left every document behind.
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        doc="$SET_SOURCE/$name"
        [ -f "$principles_home/$name" ] || continue
        if render_principle "$doc" "$TMP_DIR/.verify" \
          && cmp -s "$TMP_DIR/.verify" "$principles_home/$name"; then
          # Same write-through rule as everywhere else: remove the referent
          # our bytes live at, then clear the pointer left dangling.
          rm -f -- "$(resolve_link "$principles_home/$name")"
          [ ! -L "$principles_home/$name" ] || rm -f -- "$principles_home/$name"
        else
          printf '  kept: %s (no ownership manifest and bytes differ from this release)\n' "$name" >&2
        fi
      done < <(set_documents)
    fi
    if [ -f "$principles_home/$PRINCIPLES_MANIFEST" ]; then
      # Judge the manifest's self-description NOW, against the directory as
      # it stands before this run deletes the documents it lists --
      # afterwards even our own manifest would fail its own check.
      manifest_referent="$(resolve_link "$principles_home/$PRINCIPLES_MANIFEST")"
      # Ours must be PROVEN, so it starts false and only an entry that
      # checks out establishes it -- an empty file proves nothing and a
      # zero-entry loop must not leave the presumption standing.
      manifest_ours=false
      manifest_entries=0
      while IFS= read -r manifest_line; do
        [ -n "$manifest_line" ] || continue
        manifest_entries=$((manifest_entries + 1))
        manifest_ours=true
        case "$manifest_line" in
          *[0-9]" "*[0-9]"$(printf '\t')"*) ;;
          *)
            manifest_ours=false
            break
            ;;
        esac
        manifest_name="${manifest_line#*"$(printf '\t')"}"
        manifest_sum="${manifest_line%%"$(printf '\t')"*}"
        shipped_document "$manifest_name" || {
          manifest_ours=false
          break
        }
        # Shape alone is spoofable (principles/README.md makes README.md a
        # shipped name). A manifest we wrote also DESCRIBES the directory:
        # each recorded checksum must match the file it names.
        if [ ! -f "$principles_home/$manifest_name" ] \
          || [ "$manifest_sum" != "$(cksum <"$principles_home/$manifest_name")" ]; then
          manifest_ours=false
          break
        fi
      done <"$manifest_referent"
      while IFS="$(printf '\t')" read -r recorded_sum recorded; do
        [ -n "$recorded" ] || continue
        # Entries are relative names whose every component is plain. A parent
        # reference, an absolute path, or a dash-led component is a corrupted
        # or edited manifest and must never direct a delete outside this
        # directory.
        valid_relative_name "$recorded" || {
          printf '  skipped: manifest entry is not a valid relative name: %s\n' "$recorded" >&2
          continue
        }
        [ -f "$principles_home/$recorded" ] || continue
        # Provenance comes from the shipped set, not from the manifest. cksum
        # is unkeyed and reproducible, so anyone who can append a line can
        # also compute a matching checksum for an operator's file -- the
        # manifest cannot vouch for itself. A name this tool never ships is
        # therefore never deleted, whatever the manifest claims.
        if ! shipped_document "$recorded"; then
          printf '  kept: %s is recorded but is not a document this tool installs\n' "$recorded" >&2
          continue
        fi
        # Among names we do ship, the checksum still decides: a document
        # edited after install carries the operator's content now.
        # Ownership that does not depend on the manifest: render what this
        # release would install for that name and compare bytes. A file
        # identical to our own output is provably ours, and the check is
        # reproducible by anyone. Only that earns an outright delete.
        if render_principle "$SET_SOURCE/$recorded" "$TMP_DIR/.verify" \
          && cmp -s "$TMP_DIR/.verify" "$principles_home/$recorded"; then
          # Install writes through a symlink, so uninstall must remove what
          # it wrote -- the referent -- and leave the operator's link. The
          # asymmetry deleted the link and kept the document.
          rm -f -- "$(resolve_link "$principles_home/$recorded")"
          [ ! -L "$principles_home/$recorded" ] || rm -f -- "$principles_home/$recorded"
        elif [ "$recorded_sum" = "$(cksum <"$principles_home/$recorded")" ]; then
          # The manifest says ours but the bytes are not what we render --
          # an older release's content, or an edit. The manifest shares a
          # trust domain with the file it describes, so it cannot authorize
          # destroying content. Retire it instead: recoverable either way.
          retired="$(dirname "$principles_home/$recorded")/.$(basename "$recorded").removed"
          retire_suffix=1
          while [ -e "$retired" ] || [ -L "$retired" ]; do
            retired="$(dirname "$principles_home/$recorded")/.$(basename "$recorded").removed.$retire_suffix"
            retire_suffix=$((retire_suffix + 1))
            # Refuse rather than break: breaking left the loop holding an
            # occupied name, and the mv below then destroyed that backup --
            # the same defect already fixed in the .replaced loop.
            if [ "$retire_suffix" -gt 1000 ]; then
              printf '  kept: %s has too many preserved copies to retire\n' "$recorded" >&2
              retired=""
              break
            fi
          done
          if [ -n "$retired" ] \
            && mv -f -- "$(resolve_link "$principles_home/$recorded")" "$retired" 2>/dev/null; then
            # Retiring the referent leaves the pointer dangling; clear it,
            # as the deletion branch already does.
            [ ! -L "$principles_home/$recorded" ] \
              || rm -f -- "$principles_home/$recorded"
            printf '  retired: %s -> %s\n' "$recorded" "$(basename "$retired")"
          else
            printf '  kept: %s could not be retired\n' "$recorded" >&2
          fi
        else
          printf '  kept: %s does not match what was installed\n' "$recorded" >&2
        fi
      done <"$principles_home/$PRINCIPLES_MANIFEST"
      # Same rule as the routed documents: install wrote the referent, so
      # that is what uninstall may remove -- but only after proving the
      # bytes are plausibly ours. A manifest we wrote is nothing but
      # `cksum size<TAB>shipped-name` lines; an operator's notes file that a
      # symlink happens to reach never matches that shape, so it is retired
      # by rename rather than destroyed.
      # Verdict computed above, before the documents were removed. Zero
      # entries proves nothing either way.
      if [ "$manifest_ours" = true ] && [ "$manifest_entries" -gt 0 ]; then
        rm -f -- "$manifest_referent"
      else
        retired="$principles_home/$PRINCIPLES_MANIFEST.removed"
        retire_suffix=1
        while [ -e "$retired" ] || [ -L "$retired" ]; do
          retired="$principles_home/$PRINCIPLES_MANIFEST.removed.$retire_suffix"
          retire_suffix=$((retire_suffix + 1))
          [ "$retire_suffix" -le 1000 ] || {
            retired=""
            break
          }
        done
        if [ -n "$retired" ] && mv -f -- "$manifest_referent" "$retired" 2>/dev/null; then
          printf '  retired: manifest content this tool cannot verify -> %s\n' "$(basename "$retired")" >&2
        else
          printf '  kept: manifest content this tool cannot verify\n' >&2
        fi
      fi
      [ ! -L "$principles_home/$PRINCIPLES_MANIFEST" ] \
        || rm -f -- "$principles_home/$PRINCIPLES_MANIFEST"
    fi
    # Only if nothing of the operator's remains: a skill's directory, then
    # the set's directory, then its parent.
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$name" in */*) rmdir "$(dirname "$principles_home/$name")" 2>/dev/null || true ;; esac
    done < <(set_documents | LC_ALL=C sort -r)
    rmdir "$principles_home" 2>/dev/null || true
    rmdir "$(dirname "$principles_home")" 2>/dev/null || true
  fi
}

case "$ACTION" in
  check)
    for document_set in $DOCUMENT_SETS; do
      use_set "$document_set"
      if ! principles_current; then
        printf '  DRIFT: %s does not carry the current routed documents\n' "$SET_RELATIVE" >&2
        DRIFTED=$((DRIFTED + 1))
      fi
    done
    if [ "$DRIFTED" -ne 0 ]; then
      echo "ERROR: $DRIFTED user-level steering file(s) do not carry this tool's contract" >&2
      echo "Run: touchstone steering install -- it rewrites only the block between the markers in each driver file and the routed documents it installed under ~/.touchstone/principles and ~/.claude/skills (idempotent; everything outside them is untouched). The supported 'touchstone upgrade' path refreshes them; a direct package-manager upgrade does not." >&2
      exit 1
    fi
    echo "==> PASS: every supported driver reads the current contract"
    ;;
  install)
    sets_current=true
    for document_set in $DOCUMENT_SETS; do
      use_set "$document_set"
      [ "$DRY_RUN" = true ] || install_principles
      principles_current || sets_current=false
    done
    if [ "$CHANGED" -eq 0 ] && [ "$sets_current" = true ]; then
      echo "==> already current: machine-level steering matches the contract"
    else
      # A dry run performed nothing at all, and must say so.
      if [ "$DRY_RUN" = true ]; then
        echo "==> dry run: predictions above; nothing was installed"
      else
        echo "==> machine-level steering installed for every supported agent"
      fi
    fi
    offer_review_setup
    ;;
  uninstall)
    if [ "$DRY_RUN" = true ]; then
      printf '  would remove: %s\n  would remove: %s\n' "$PRINCIPLES_RELATIVE" "$SKILLS_RELATIVE"
      echo "==> dry run: nothing was removed"
      exit 0
    fi
    for document_set in $DOCUMENT_SETS; do
      use_set "$document_set"
      uninstall_set
    done
    echo "==> removed from $CHANGED file(s) plus the routed documents; content outside the markers untouched"
    ;;
esac
