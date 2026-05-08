#!/usr/bin/env bash
#
# lib/claude-md-touchstone-ref.sh — plant the @TOUCHSTONE.md import in a
# project's CLAUDE.md so Claude Code loads the touchstone steering router
# every session.
#
# Why this exists:
#   touchstone init can run on a repo that already has its own CLAUDE.md.
#   We don't want to silently overwrite that — but without `@TOUCHSTONE.md`,
#   the project's Claude sessions never load the touchstone steering router
#   (universal principles, lifecycle, routing table), even after `touchstone
#   update` syncs TOUCHSTONE.md into the repo.
#
#   This helper is invoked at init time (one-shot, with consent). It plants
#   a small block at the top of CLAUDE.md that imports TOUCHSTONE.md. Once
#   planted, the *content* behind the import flows automatically — every
#   `touchstone update` refreshes TOUCHSTONE.md, and every Claude session
#   re-reads the import.
#
#   Replaces the previous pattern of @principles/* @-imports
#   (pre-implementation-checklist, documentation-ownership, git-workflow).
#   Those files are now routed via the routing table inside TOUCHSTONE.md
#   and via user-scoped Claude Code skills, so the per-turn token cost of
#   auto-loading them on every session is gone.
#
# Public surface:
#   claude_md_has_touchstone_ref <path>     — exit 0 if @TOUCHSTONE.md is present
#   claude_md_render_touchstone_block       — print the block to stdout
#   claude_md_inject_touchstone_ref <path>  — append/inject the block once
#   ensure_claude_touchstone_ref <project_dir> <mode>
#                                           — top-level entry; manages init prompt
#
# Exit codes for claude_md_inject_touchstone_ref:
#   0 — block injected
#   1 — file missing or write failed
#   2 — file already has @TOUCHSTONE.md; no change made (caller's cue to skip)

# Marker is exposed for downstream doctor / connection-status checks.
# shellcheck disable=SC2034
CLAUDE_MD_TOUCHSTONE_MARKER='<!-- touchstone:claude-touchstone-ref -->'

# Read the recorded init-time decision from .touchstone-config.
# Echoes one of: connected | skipped | "" (unset). The config key is
# `claude_principles_ref=` for backward compatibility — existing projects'
# decisions carry forward across the rename.
claude_md_touchstone_ref_decision() {
  local config="$1/.touchstone-config"
  [ -f "$config" ] || {
    printf ''
    return 0
  }
  local val
  val="$(grep -E '^claude_principles_ref=' "$config" 2>/dev/null \
    | tail -n1 \
    | cut -d= -f2- \
    | tr -d '[:space:]' || true)"
  printf '%s' "$val"
  return 0
}

# Persist the init-time decision to .touchstone-config (idempotent rewrite).
# Uses the legacy `claude_principles_ref=` key for backward compat with
# already-bootstrapped projects.
claude_md_touchstone_ref_record() {
  local project_dir="$1"
  local value="$2"
  local config="$project_dir/.touchstone-config"
  case "$value" in
    connected | skipped) ;;
    *) return 1 ;;
  esac

  if [ ! -f "$config" ]; then
    printf '# touchstone project profile.\nclaude_principles_ref=%s\n' "$value" >"$config"
    return 0
  fi

  if grep -qE '^claude_principles_ref=' "$config"; then
    local tmp
    tmp="$(mktemp -t touchstone-config.XXXXXX)"
    awk -v v="$value" '
      /^claude_principles_ref=/ { print "claude_principles_ref=" v; next }
      { print }
    ' "$config" >"$tmp"
    cat "$tmp" >"$config"
    rm -f "$tmp"
  else
    printf 'claude_principles_ref=%s\n' "$value" >>"$config"
  fi
}

claude_md_has_touchstone_ref() {
  local target="$1"
  [ -f "$target" ] || return 1
  grep -qF '@TOUCHSTONE.md' "$target"
}

claude_md_render_touchstone_block() {
  cat <<'BLOCK'
<!-- touchstone:claude-touchstone-ref -->
## Touchstone — Universal Steering

The import below loads every Claude Code session in this repo. The file
behind it is touchstone-owned and refreshes on every `touchstone update`.
TOUCHSTONE.md contains the universal contract: agent roles, the daily-
reminder engineering principles, the never-commit-on-main rule, the
required delivery workflow, memory hygiene, and a routing table to deeper
docs (`principles/git-workflow.md`, `.cortex/protocol.md`, etc.).

@TOUCHSTONE.md

---
BLOCK
}

claude_md_inject_touchstone_ref() {
  local target="$1"

  if [ -z "$target" ] || [ ! -f "$target" ]; then
    return 1
  fi

  if claude_md_has_touchstone_ref "$target"; then
    return 2
  fi

  local block_file out_file
  block_file="$(mktemp -t claude-md-touchstone.XXXXXX)"
  out_file="$(mktemp -t claude-md-touchstone-out.XXXXXX)"
  claude_md_render_touchstone_block >"$block_file"

  local first_line
  first_line="$(head -n 1 "$target" || true)"
  if [[ "$first_line" =~ ^\#\  ]]; then
    printf '%s\n' "$first_line" >>"$out_file"
    printf '\n' >>"$out_file"
    cat "$block_file" >>"$out_file"
    printf '\n' >>"$out_file"
    tail -n +2 "$target" >>"$out_file"
  else
    cat "$block_file" >>"$out_file"
    printf '\n' >>"$out_file"
    cat "$target" >>"$out_file"
  fi

  cat "$out_file" >"$target"
  rm -f "$block_file" "$out_file"
  return 0
}

# ensure_claude_touchstone_ref <project_dir> <mode>
#
# Plant the @TOUCHSTONE.md import in the project's CLAUDE.md so Claude Code
# loads the touchstone steering router every session. Idempotent: never asks
# twice, never overwrites an already-connected file.
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
ensure_claude_touchstone_ref() {
  local project_dir="$1"
  local mode="${2:-prompt}"
  local claude_md="$project_dir/CLAUDE.md"

  _epr_say() { if command -v tk_dim >/dev/null 2>&1; then tk_dim "$@"; else echo "$@"; fi; }
  _epr_ok() { if command -v tk_ok >/dev/null 2>&1; then tk_ok "$@"; else echo "OK: $*"; fi; }
  _epr_warn() { if command -v tk_warn >/dev/null 2>&1; then tk_warn "$@"; else echo "WARN: $*" >&2; fi; }
  _epr_head() { if command -v tk_header >/dev/null 2>&1; then tk_header "$@"; else echo "==> $*"; fi; }

  # Respect a prior decision. `skipped` remains opt-out indefinitely.
  local prior
  prior="$(claude_md_touchstone_ref_decision "$project_dir")"
  case "$prior" in
    skipped) return 0 ;;
    connected)
      # Already opted in. If the file lost the import (manual edit), re-add it.
      if [ -f "$claude_md" ] && ! claude_md_has_touchstone_ref "$claude_md"; then
        if claude_md_inject_touchstone_ref "$claude_md"; then
          _epr_ok "Re-added @TOUCHSTONE.md import to CLAUDE.md."
        fi
      fi
      return 0
      ;;
  esac

  # No CLAUDE.md → new-project.sh's template copy planted @TOUCHSTONE.md, or
  # the user opted out of having a CLAUDE.md. Either way, nothing to do here.
  if [ ! -f "$claude_md" ]; then
    return 0
  fi

  # Already connected via the template (fresh init) or by hand — record and move on.
  if claude_md_has_touchstone_ref "$claude_md"; then
    claude_md_touchstone_ref_record "$project_dir" connected
    return 0
  fi

  case "$mode" in
    yes)
      claude_md_inject_touchstone_ref "$claude_md" || return 0
      claude_md_touchstone_ref_record "$project_dir" connected
      _epr_ok "Added @TOUCHSTONE.md import to CLAUDE.md."
      ;;
    no)
      claude_md_touchstone_ref_record "$project_dir" skipped
      _epr_say "Skipped Touchstone steering import in CLAUDE.md (recorded in .touchstone-config)."
      ;;
    prompt | *)
      if [ ! -t 0 ] || [ ! -t 1 ]; then
        _epr_warn "CLAUDE.md exists but does not import @TOUCHSTONE.md."
        _epr_say "Re-run interactively, or pass --no-claude-principles to skip permanently."
        return 0
      fi
      _epr_head "Touchstone — connect CLAUDE.md to the steering router"
      _epr_say "Found CLAUDE.md without @TOUCHSTONE.md. Adding it lets every Claude Code"
      _epr_say "session in this repo load the touchstone steering router (principles,"
      _epr_say "lifecycle, routing table). Future touchstone updates ship changes"
      _epr_say "automatically."
      echo ""
      echo "  Will inject after the H1:"
      echo "    @TOUCHSTONE.md"
      echo ""
      local answer=""
      printf "  Add the import to CLAUDE.md? [Y/n] "
      read -r answer || answer=""
      case "$answer" in
        n | N | no | NO | No)
          claude_md_touchstone_ref_record "$project_dir" skipped
          _epr_say "Skipped. Re-run touchstone init to opt in later."
          ;;
        *)
          if claude_md_inject_touchstone_ref "$claude_md"; then
            claude_md_touchstone_ref_record "$project_dir" connected
            _epr_ok "Added @TOUCHSTONE.md import to CLAUDE.md."
          else
            _epr_warn "Failed to inject @TOUCHSTONE.md import (file unreadable or write failed)."
          fi
          ;;
      esac
      ;;
  esac
}
