#!/usr/bin/env bash
#
# scripts/touchstone-steering-install.sh — put the universal contract where
# every agent on this machine reads it.
#
# Usage:
#   bash scripts/touchstone-steering-install.sh install [--home DIR] [--dry-run]
#   bash scripts/touchstone-steering-install.sh check   [--home DIR]
#   bash scripts/touchstone-steering-install.sh uninstall [--home DIR]
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
BEGIN_MARKER='<!-- touchstone:steering:start -->'
# The start marker may carry attributes (see restore-newline below).
BEGIN_MARKER_RE='^<!-- touchstone:steering:start( restore-newline)? -->$'
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
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
shift

HOME_DIR="${HOME:-}"
DRY_RUN=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --home requires a directory" >&2
        exit 2
      }
      HOME_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
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
  exit 1
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
[ -f "$SOURCE" ] || die "canonical steering is missing: $SOURCE"

# A marker line in the source would be copied into the block and make the very
# next check reject it.
for marker in "$BEGIN_MARKER" "$END_MARKER"; do
  if awk -v m="$marker" '$0 == m { found = 1 } END { exit !found }' "$SOURCE"; then
    die "canonical steering contains a managed marker line; document markers only in inline code"
  fi
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-steering-install.XXXXXX")" || die "could not create workspace"
trap 'rm -rf "$TMP_DIR"' EXIT

render_block() {
  local out="$1"
  # The routing table names principles/*.md. Those documents are installed
  # beside the block, so the paths must resolve from the agent's home rather
  # than from a repository that no longer carries them.
  local principles_home="$HOME_DIR/$PRINCIPLES_RELATIVE"
  {
    printf '%s\n' "$BEGIN_MARKER"
    cat <<'EOF'

<!-- Installed by touchstone. Do not edit between the markers; edit the
     project's TOUCHSTONE.md upstream and reinstall. Everything outside the
     markers is yours. Remove with: touchstone steering uninstall -->
EOF
    sed "s|\`principles/|\`$(sed_replacement "$principles_home")/|g" "$SOURCE"
    if [ -n "$(tail -c 1 "$SOURCE")" ]; then printf '\n'; fi
    printf '%s\n' "$END_MARKER"
  } >"$out"
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

  if [ ! -f "$path" ]; then
    cat "$block" >"$out"
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
  esac
  if [ "$((begin_line - 1))" -gt 0 ]; then
    head -n "$((begin_line - 1))" "$path" >"$out"
  else
    : >"$out"
  fi
  if [ "$NEEDS_NEWLINE_RESTORE" = true ]; then
    sed "1s|.*|<!-- touchstone:steering:start restore-newline -->|" "$block" >>"$out"
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
  local keep=$((begin_line - 1)) strip_trailing_newline=false separator_found=false
  if [ "$keep" -gt 0 ] && [ -z "$(sed -n "${keep}p" "$path")" ]; then
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

BLOCK="$TMP_DIR/block"
render_block "$BLOCK"

# Fail before any driver file is touched if the routed destination cannot be
# prepared, so a bad path cannot leave three instruction files pointing at
# documents that were never installed.
preflight_principles() {
  local destination="$HOME_DIR/$PRINCIPLES_RELATIVE"
  [ -d "$PRINCIPLES_SOURCE" ] || die "routed steering documents are missing: $PRINCIPLES_SOURCE"
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
    [ -e "$manifest" ] || die "$PRINCIPLES_RELATIVE/$PRINCIPLES_MANIFEST is a dangling symlink; move it before installing"
    [ -f "$(resolve_link "$manifest")" ] || die "$PRINCIPLES_RELATIVE/$PRINCIPLES_MANIFEST is not a regular file; move it before installing"
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
        *) die "$PRINCIPLES_RELATIVE/$PRINCIPLES_MANIFEST has an entry with no recorded checksum: $line" ;;
      esac
      case "$recorded" in
        '' | */* | . | .. | -*)
          die "$PRINCIPLES_RELATIVE/$PRINCIPLES_MANIFEST contains an entry that is not a plain name: $recorded"
          ;;
      esac
    done <"$manifest"
  fi

  local doc name
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    name="$(basename "$doc")"
    if [ -d "$destination/$name" ]; then
      die "$PRINCIPLES_RELATIVE/$name is a directory; move it before installing"
    fi
    # A file we did not install belongs to the operator. Detect it here, before
    # any driver file is written, so the refusal costs nothing.
    :
    # -L as well as -e: a dangling symlink is not `-e`, so a link the operator
    # made to a file that does not exist yet read as "absent" and was replaced
    # by a regular file, losing the link with nothing preserved.
    if { [ -e "$destination/$name" ] || [ -L "$destination/$name" ]; } \
      && ! principles_owned "$name"; then
      die "$PRINCIPLES_RELATIVE/$name exists and was not installed by touchstone; move it before installing"
    fi
  done
}

# Render one routed document with its cross-references pointing at the
# installed copies. These documents reference each other by `principles/...`;
# unrewritten, those links resolve nowhere on a machine whose repositories
# carry no Touchstone files.
render_principle() {
  local source="$1" out="$2" principles_home="$HOME_DIR/$PRINCIPLES_RELATIVE"
  sed "s|\`principles/|\`$(sed_replacement "$principles_home")/|g" "$source" >"$out"
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

stage_path() {
  local directory="$1" prefix="$2" staged
  staged="$(mktemp "$directory/.$prefix.XXXXXXXX")" \
    || die "could not create a staging file in $directory"
  printf '%s\n' "$staged"
}

shipped_document() {
  local candidate="$1" doc
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    [ "$(basename "$doc")" = "$candidate" ] && return 0
  done
  return 1
}

# Ownership must be provable on the install path too, not only on uninstall:
# overwriting an operator's file destroys content irreversibly, so a name in
# the manifest is not enough. The entry must record the bytes that are there
# now -- which a corrupted manifest carrying `anything<TAB>git-workflow.md`
# cannot, and which a document the operator edited after install no longer
# matches.
principles_owned() {
  local name="$1" destination="$HOME_DIR/$PRINCIPLES_RELATIVE"
  local manifest="$destination/$PRINCIPLES_MANIFEST"
  [ -f "$manifest" ] || return 1
  shipped_document "$name" || return 1
  [ -f "$destination/$name" ] || return 1
  grep -qxF "$(cksum <"$destination/$name")	$name" "$manifest"
}

install_principles() {
  local destination="$HOME_DIR/$PRINCIPLES_RELATIVE" doc name staged backup suffix manifest_staged
  manifest_staged="$(stage_path "$destination" "$PRINCIPLES_MANIFEST")"
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    name="$(basename "$doc")"
    staged="$(stage_path "$destination" "$name")"
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
      backup="$destination/.$name.replaced"
      suffix=1
      while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$destination/.$name.replaced.$suffix"
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
  done
  # A release that removes or renames a document must not leave the copy it
  # installed behind: the old manifest is the only record that we wrote it,
  # and replacing that manifest is the moment the knowledge is lost.
  if [ -f "$destination/$PRINCIPLES_MANIFEST" ]; then
    local prior_sum prior_name pruned prune_suffix
    while IFS="$(printf '\t')" read -r prior_sum prior_name; do
      [ -n "$prior_name" ] || continue
      case "$prior_name" in */* | . | .. | -*) continue ;; esac
      shipped_document "$prior_name" && continue
      [ -f "$destination/$prior_name" ] || continue
      if [ "$prior_sum" = "$(cksum <"$destination/$prior_name")" ]; then
        # A checksum the manifest recorded is not proof the manifest is
        # honest -- an entry naming an operator's file can carry that file's
        # own checksum. Same answer as the overwrite path: keep the bytes, so
        # a dishonest entry costs a stray file rather than their content.
        pruned="$destination/.$prior_name.replaced"
        prune_suffix=1
        while [ -e "$pruned" ] || [ -L "$pruned" ]; do
          pruned="$destination/.$prior_name.replaced.$prune_suffix"
          prune_suffix=$((prune_suffix + 1))
          [ "$prune_suffix" -le 1000 ] || break
        done
        if mv -f -- "$destination/$prior_name" "$pruned" 2>/dev/null; then
          printf '  retired: %s -> %s (no longer shipped)\n' "$prior_name" "$(basename "$pruned")"
        else
          printf '  kept: %s could not be retired\n' "$prior_name" >&2
        fi
      else
        printf '  kept: %s is no longer shipped but has been edited\n' "$prior_name" >&2
      fi
    done <"$destination/$PRINCIPLES_MANIFEST"
  fi
  mv -f -- "$manifest_staged" "$(resolve_link "$destination/$PRINCIPLES_MANIFEST")" \
    || die "could not record the installed document manifest"
}

principles_current() {
  local destination="$HOME_DIR/$PRINCIPLES_RELATIVE" doc
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
  local rendered="$TMP_DIR/.principle-check" doc_name
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    doc_name="$(basename "$doc")"
    [ -f "$destination/$doc_name" ] || return 1
    grep -qxF "$(cksum <"$destination/$doc_name")	$doc_name" \
      "$destination/$PRINCIPLES_MANIFEST" || return 1
  done
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    render_principle "$doc" "$rendered" || return 1
    cmp -s "$rendered" "$destination/$(basename "$doc")" || return 1
  done
  return 0
}

# Fail before any driver file is touched if a destination is unusable. A dry
# run runs the same checks: reporting an install that would immediately fail
# as "would reach every agent" is the one answer a dry run must never give.
[ "$ACTION" != install ] || preflight_principles

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
  composed="$TMP_DIR/$driver"

  # compose reads a non-existent path as an empty prefix, and `mv` onto a
  # directory moves the payload *inside* it -- so a driver path that is a
  # directory installed "successfully" and left the instruction file absent.
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    die "$relative exists and is not a regular file; move it before installing"
  fi

  case "$ACTION" in
    install | check)
      compose "$path" "$BLOCK" "$composed"
      ;;
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
    if [ -f "$path" ] \
      && awk -v b="$BEGIN_MARKER_RE" -v e="$END_MARKER" -v plain="$BEGIN_MARKER" \
        '$0 ~ b { inside = 1; print plain; next } inside { print } $0 == e { inside = 0 }' "$path" \
      | cmp -s - "$BLOCK"; then
      printf '  ok: %s carries the current contract\n' "$relative"
    else
      printf '  DRIFT: %s does not carry the current contract\n' "$relative" >&2
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
  staged="$(stage_path "$(dirname "$path")" "$(basename "$path").touchstone-steering")"
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

case "$ACTION" in
  check)
    if ! principles_current; then
      printf '  DRIFT: %s does not carry the current routed documents\n' "$PRINCIPLES_RELATIVE" >&2
      DRIFTED=$((DRIFTED + 1))
    fi
    if [ "$DRIFTED" -ne 0 ]; then
      echo "ERROR: $DRIFTED user-level steering file(s) do not carry the current contract" >&2
      echo "Run: touchstone steering install" >&2
      exit 1
    fi
    echo "==> PASS: every supported driver reads the current contract"
    ;;
  install)
    [ "$DRY_RUN" = true ] || install_principles
    if [ "$CHANGED" -eq 0 ] && principles_current; then
      echo "==> already current: machine-level steering matches the contract"
    else
      echo "==> steering reaches every agent on this machine; repositories carry none"
    fi
    ;;
  uninstall)
    if [ "$DRY_RUN" = true ]; then
      printf '  would remove: %s\n' "$PRINCIPLES_RELATIVE"
      echo "==> dry run: nothing was removed"
      exit 0
    fi
    # Remove only the documents this tool installed. The directory may hold
    # the operator's own files; a recursive delete would take them too.
    principles_home="${HOME_DIR:?}/${PRINCIPLES_RELATIVE:?}"
    if [ -d "$principles_home" ]; then
      # Remove exactly what the manifest records, so a bundled name the
      # operator owns is left alone even across releases that change which
      # documents ship.
      if [ -f "$principles_home/$PRINCIPLES_MANIFEST" ]; then
        while IFS="$(printf '\t')" read -r recorded_sum recorded; do
          [ -n "$recorded" ] || continue
          # Entries are plain basenames. Anything else -- a path separator, a
          # parent reference, a leading dash -- is a corrupted or edited
          # manifest and must never direct a delete outside this directory.
          case "$recorded" in
            */* | . | .. | -*)
              printf '  skipped: manifest entry is not a plain name: %s\n' "$recorded" >&2
              continue
              ;;
          esac
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
          if render_principle "$PRINCIPLES_SOURCE/$recorded" "$TMP_DIR/.verify" \
            && cmp -s "$TMP_DIR/.verify" "$principles_home/$recorded"; then
            rm -f -- "$principles_home/$recorded"
          elif [ "$recorded_sum" = "$(cksum <"$principles_home/$recorded")" ]; then
            # The manifest says ours but the bytes are not what we render --
            # an older release's content, or an edit. The manifest shares a
            # trust domain with the file it describes, so it cannot authorize
            # destroying content. Retire it instead: recoverable either way.
            retired="$principles_home/.$recorded.removed"
            retire_suffix=1
            while [ -e "$retired" ] || [ -L "$retired" ]; do
              retired="$principles_home/.$recorded.removed.$retire_suffix"
              retire_suffix=$((retire_suffix + 1))
              [ "$retire_suffix" -le 1000 ] || break
            done
            if mv -f -- "$principles_home/$recorded" "$retired" 2>/dev/null; then
              printf '  retired: %s -> %s\n' "$recorded" "$(basename "$retired")"
            else
              printf '  kept: %s could not be retired\n' "$recorded" >&2
            fi
          else
            printf '  kept: %s does not match what was installed\n' "$recorded" >&2
          fi
        done <"$principles_home/$PRINCIPLES_MANIFEST"
        rm -f -- "$principles_home/$PRINCIPLES_MANIFEST"
      fi
      # Only if nothing of the operator's remains.
      rmdir "$principles_home" 2>/dev/null || true
      rmdir "$(dirname "$principles_home")" 2>/dev/null || true
    fi
    echo "==> removed from $CHANGED file(s) plus the routed documents; content outside the markers untouched"
    ;;
esac
