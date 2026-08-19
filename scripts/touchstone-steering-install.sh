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
    sed "s|\`principles/|\`$principles_home/|g" "$SOURCE"
    if [ -n "$(tail -c 1 "$SOURCE")" ]; then printf '\n'; fi
    printf '%s\n' "$END_MARKER"
  } >"$out"
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
  local keep=$((begin_line - 1)) strip_trailing_newline=false
  if [ "$keep" -gt 0 ] && [ -z "$(sed -n "${keep}p" "$path")" ]; then
    keep=$((keep - 1))
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
  if [ "$strip_trailing_newline" = true ] && [ -s "$out" ]; then
    # Drop the newline install added after the operator's last line.
    printf '%s' "$(cat "$out")" >"$out.trimmed" && mv -f -- "$out.trimmed" "$out"
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
  mkdir -p "$destination" || die "could not create $destination"
  [ -w "$destination" ] || die "$destination is not writable"
  # A manifest that exists without the documents it claims is not ours: either
  # the operator wrote it, or an install was interrupted. Refuse rather than
  # trusting it to say what may be deleted later.
  local manifest="$destination/$PRINCIPLES_MANIFEST" recorded
  if [ -e "$manifest" ]; then
    [ -f "$manifest" ] || die "$PRINCIPLES_RELATIVE/$PRINCIPLES_MANIFEST is not a regular file; move it before installing"
    while IFS= read -r recorded; do
      [ -n "$recorded" ] || continue
      case "$recorded" in
        */* | . | .. | -*)
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
    if [ -e "$destination/$name" ] && ! principles_owned "$name"; then
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
  sed "s|\`principles/|\`$principles_home/|g" "$source" >"$out"
}

principles_owned() {
  local name="$1" manifest="$HOME_DIR/$PRINCIPLES_RELATIVE/$PRINCIPLES_MANIFEST"
  [ -f "$manifest" ] || return 1
  grep -qxF "$name" "$manifest"
}

install_principles() {
  local destination="$HOME_DIR/$PRINCIPLES_RELATIVE" doc name staged
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    name="$(basename "$doc")"
    staged="$destination/.$name.$$"
    render_principle "$doc" "$staged" || {
      rm -f -- "$staged"
      die "could not stage $name"
    }
    mv -f -- "$staged" "$destination/$name" || {
      rm -f -- "$staged"
      die "could not install $name"
    }
    printf '%s\n' "$name" >>"$destination/.$PRINCIPLES_MANIFEST.$$"
  done
  mv -f -- "$destination/.$PRINCIPLES_MANIFEST.$$" "$destination/$PRINCIPLES_MANIFEST" \
    || die "could not record the installed document manifest"
}

principles_current() {
  local destination="$HOME_DIR/$PRINCIPLES_RELATIVE" doc
  [ -d "$destination" ] || return 1
  # The manifest is part of the installed state: without it, uninstall cannot
  # tell our documents from the operator's, so a missing manifest is drift.
  [ -f "$destination/$PRINCIPLES_MANIFEST" ] || return 1
  local rendered="$TMP_DIR/.principle-check" doc_name
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    doc_name="$(basename "$doc")"
    grep -qxF "$doc_name" "$destination/$PRINCIPLES_MANIFEST" || return 1
  done
  for doc in "$PRINCIPLES_SOURCE"/*.md; do
    [ -f "$doc" ] || continue
    render_principle "$doc" "$rendered" || return 1
    cmp -s "$rendered" "$destination/$(basename "$doc")" || return 1
  done
  return 0
}

# Fail before any driver file is touched if the routed destination is unusable.
[ "$ACTION" != install ] || [ "$DRY_RUN" = true ] || preflight_principles

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

  if [ -f "$path" ] && cmp -s "$path" "$composed"; then
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    printf '  would update: %s\n' "$path"
    CHANGED=$((CHANGED + 1))
    continue
  fi

  # A symlinked instruction file is a deliberate arrangement (dotfiles repos
  # do this). Write through to its referent instead of replacing the link
  # with a regular file, which would silently orphan the operator's real file.
  hops=0
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 16 ] || die "symlink chain too deep at $path"
    link_target="$(readlink "$path")"
    case "$link_target" in
      /*) path="$link_target" ;;
      *) path="$(cd "$(dirname "$path")" && pwd -P)/$link_target" ;;
    esac
    # Collapse lexical components so two spellings of one file dedupe.
    case "$path" in
      */*) path="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")" ;;
    esac
  done
  # Two driver paths may be symlinks to one shared document. Installing it
  # twice would have the second staging file overwrite the first and leave an
  # orphan; the block is identical, so the first write is sufficient.
  case " ${INSTALL_PATHS[*]-} " in
    *" $path "*)
      printf '  shared: %s resolves to an already-staged file\n' "$relative"
      continue
      ;;
  esac
  mkdir -p "$(dirname "$path")" || die "could not create $(dirname "$path")"
  staged="$path.touchstone-steering.$$"
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
        while IFS= read -r recorded; do
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
          rm -f -- "$principles_home/$recorded"
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
