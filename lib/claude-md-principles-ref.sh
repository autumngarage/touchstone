#!/usr/bin/env bash
#
# lib/claude-md-principles-ref.sh — plant the @principles/* import block in
# a project's CLAUDE.md so Claude Code loads the touchstone engineering
# principles every session.
#
# Why this exists:
#   touchstone init can run on a repo that already has its own CLAUDE.md
#   (the user wrote one before adopting touchstone). We don't want to
#   silently overwrite that — but without the @principles/* imports, the
#   project's Claude sessions never load the engineering principles, even
#   after `touchstone update` syncs the principles/*.md files into the repo.
#
#   This helper is invoked at init time (one-shot, with consent). It plants
#   a small block of @-imports near the top of CLAUDE.md. Once planted, the
#   *content* behind those imports flows automatically — every `touchstone
#   update` refreshes principles/*.md, and every Claude session re-reads
#   the imports. We never touch CLAUDE.md again after init.
#
# Public surface:
#   claude_md_has_principles_ref <path>     — exit 0 if @principles/ is present
#   claude_md_render_principles_block       — print the block to stdout
#   claude_md_inject_principles_block <path> — append/inject the block once
#
# Exit codes for claude_md_inject_principles_block:
#   0 — block injected (or already present; idempotent)
#   1 — file missing or write failed
#   2 — file already has @principles/ references; no change made (caller's
#       cue to skip the prompt entirely)

# Marker is sourced into bin/touchstone and may be referenced by future
# doctor / connection-status checks; export-shaped for that consumer.
# shellcheck disable=SC2034
CLAUDE_MD_PRINCIPLES_MARKER='<!-- touchstone:claude-principles-ref -->'

# Read the recorded init-time decision from .touchstone-config.
# Echoes one of: connected | skipped | "" (unset).
# Always returns 0 so callers under `set -euo pipefail` can use
# `prior="$(claude_md_principles_ref_decision ...)"` without aborting on a
# missing config or unmatched grep.
claude_md_principles_ref_decision() {
  local config="$1/.touchstone-config"
  [ -f "$config" ] || { printf ''; return 0; }
  local val
  val="$(grep -E '^claude_principles_ref=' "$config" 2>/dev/null \
         | tail -n1 \
         | cut -d= -f2- \
         | tr -d '[:space:]' || true)"
  printf '%s' "$val"
  return 0
}

# Persist the init-time decision to .touchstone-config (idempotent rewrite).
# Caller passes the project dir and one of: connected | skipped.
claude_md_principles_ref_record() {
  local project_dir="$1"
  local value="$2"
  local config="$project_dir/.touchstone-config"
  case "$value" in
    connected|skipped) ;;
    *) return 1 ;;
  esac

  if [ ! -f "$config" ]; then
    printf '# touchstone project profile.\nclaude_principles_ref=%s\n' "$value" > "$config"
    return 0
  fi

  if grep -qE '^claude_principles_ref=' "$config"; then
    local tmp
    tmp="$(mktemp -t touchstone-config.XXXXXX)"
    awk -v v="$value" '
      /^claude_principles_ref=/ { print "claude_principles_ref=" v; next }
      { print }
    ' "$config" > "$tmp"
    cat "$tmp" > "$config"
    rm -f "$tmp"
  else
    printf 'claude_principles_ref=%s\n' "$value" >> "$config"
  fi
}

claude_md_has_principles_ref() {
  local target="$1"
  [ -f "$target" ] || return 1
  grep -qE '^@principles/' "$target"
}

claude_md_render_principles_block() {
  cat <<'BLOCK'
<!-- touchstone:claude-principles-ref -->
## Touchstone — Shared Engineering Principles

These imports load every Claude Code session in this repo. The files behind
them are touchstone-owned and refresh on every `touchstone update`.

@principles/engineering-principles.md
@principles/pre-implementation-checklist.md
@principles/documentation-ownership.md
@principles/git-workflow.md

---
BLOCK
}

claude_md_inject_principles_block() {
  local target="$1"

  if [ -z "$target" ] || [ ! -f "$target" ]; then
    return 1
  fi

  if claude_md_has_principles_ref "$target"; then
    return 2
  fi

  local block_file out_file
  block_file="$(mktemp -t claude-md-principles.XXXXXX)"
  out_file="$(mktemp -t claude-md-principles-out.XXXXXX)"
  claude_md_render_principles_block > "$block_file"

  local first_line
  first_line="$(head -n 1 "$target" || true)"
  if [[ "$first_line" =~ ^\#\  ]]; then
    printf '%s\n' "$first_line" >> "$out_file"
    printf '\n' >> "$out_file"
    cat "$block_file" >> "$out_file"
    printf '\n' >> "$out_file"
    tail -n +2 "$target" >> "$out_file"
  else
    cat "$block_file" >> "$out_file"
    printf '\n' >> "$out_file"
    cat "$target" >> "$out_file"
  fi

  cat "$out_file" > "$target"
  rm -f "$block_file" "$out_file"
  return 0
}

# ensure_claude_principles_ref <project_dir> <mode>
#
# Plant the touchstone @principles/* import block in the project's CLAUDE.md
# so Claude Code loads the engineering principles every session. Idempotent:
# never asks twice, never overwrites an already-connected file.
#
# Modes:
#   yes     — inject without asking (still no-op if already connected).
#   no      — skip and record `claude_principles_ref=skipped` so future
#             touchstone init runs respect the decision.
#   prompt  — TTY: ask [Y/n], record the decision.
#             Non-TTY: skip, do NOT record (a later interactive run can prompt).
#
# Callers may shadow tk_ok / tk_warn / tk_dim / tk_header with their own
# implementations; this helper falls back to plain echo if they aren't defined.
ensure_claude_principles_ref() {
  local project_dir="$1"
  local mode="${2:-prompt}"
  local claude_md="$project_dir/CLAUDE.md"

  _epr_say()  { if command -v tk_dim   >/dev/null 2>&1; then tk_dim   "$@"; else echo "$@";   fi; }
  _epr_ok()   { if command -v tk_ok    >/dev/null 2>&1; then tk_ok    "$@"; else echo "OK: $*"; fi; }
  _epr_warn() { if command -v tk_warn  >/dev/null 2>&1; then tk_warn  "$@"; else echo "WARN: $*" >&2; fi; }
  _epr_head() { if command -v tk_header >/dev/null 2>&1; then tk_header "$@"; else echo "==> $*"; fi; }

  # Respect a prior decision. Once recorded, init never re-prompts —
  # the user said yes (already injected) or no (skipped on purpose).
  local prior
  prior="$(claude_md_principles_ref_decision "$project_dir")"
  case "$prior" in
    connected|skipped) return 0 ;;
  esac

  # Nothing to connect to — no CLAUDE.md means new-project.sh will copy the
  # template (which already has the @-imports baked in), or the user opted
  # out of having a CLAUDE.md altogether.
  if [ ! -f "$claude_md" ]; then
    return 0
  fi

  # Already connected via the template (fresh init) or a hand-written
  # equivalent — record the state and move on. No prompt needed.
  if claude_md_has_principles_ref "$claude_md"; then
    claude_md_principles_ref_record "$project_dir" connected
    return 0
  fi

  case "$mode" in
    yes)
      claude_md_inject_principles_block "$claude_md" || return 0
      claude_md_principles_ref_record "$project_dir" connected
      _epr_ok "Added @principles/* imports to CLAUDE.md."
      ;;
    no)
      claude_md_principles_ref_record "$project_dir" skipped
      _epr_say "Skipped Touchstone principles in CLAUDE.md (recorded in .touchstone-config)."
      ;;
    prompt|*)
      if [ ! -t 0 ] || [ ! -t 1 ]; then
        _epr_warn "CLAUDE.md exists but does not import touchstone principles."
        _epr_say  "Re-run interactively, or pass --no-claude-principles to skip permanently."
        return 0
      fi
      _epr_head "Touchstone — connect CLAUDE.md to engineering principles"
      _epr_say "Found CLAUDE.md without @principles/* imports. Adding them lets every"
      _epr_say "Claude Code session in this repo load the touchstone principles, and"
      _epr_say "lets future touchstone updates ship principle changes automatically."
      echo ""
      echo "  Will inject after the H1:"
      echo "    @principles/engineering-principles.md"
      echo "    @principles/pre-implementation-checklist.md"
      echo "    @principles/documentation-ownership.md"
      echo "    @principles/git-workflow.md"
      echo ""
      local answer=""
      printf "  Add the imports to CLAUDE.md? [Y/n] "
      read -r answer || answer=""
      case "$answer" in
        n|N|no|NO|No)
          claude_md_principles_ref_record "$project_dir" skipped
          _epr_say "Skipped. Re-run touchstone init to opt in later."
          ;;
        *)
          if claude_md_inject_principles_block "$claude_md"; then
            claude_md_principles_ref_record "$project_dir" connected
            _epr_ok "Added @principles/* imports to CLAUDE.md."
          else
            _epr_warn "Failed to inject imports into CLAUDE.md (file unreadable or write failed)."
          fi
          ;;
      esac
      ;;
  esac
}
