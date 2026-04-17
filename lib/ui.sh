#!/usr/bin/env bash
#
# lib/ui.sh — Touchstone branded UI helpers.
#
# Provides the double-rail verdict style and the figlet/gum hero banner.
# Gracefully degrades when gum or figlet are not installed: the rails turn
# into ASCII bars, and the hero turns into a bold "TOUCHSTONE" header.
#
# Sourced by bin/touchstone. The codex-review hook carries its own inline
# copy because it ships into downstream projects without lib/.

# Guard: only define helpers once per shell.
if [ -n "${TK_UI_SOURCED:-}" ]; then return 0; fi
TK_UI_SOURCED=1

# Brand palette. Orange is the Touchstone signature color; lime/red are the
# state accents; dim is for supporting text.
TK_BRAND_ORANGE="#FF6B35"
TK_BRAND_LIME="#A3E635"
TK_BRAND_RED="#EF4444"
TK_BRAND_DIM="#6B7280"

tk_have_gum()    { command -v gum    >/dev/null 2>&1; }
tk_have_figlet() { command -v figlet >/dev/null 2>&1; }

tk_color_enabled() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

# Internal: render the double-rail prefix "▌▌" in brand orange. Returns
# plain "▌▌" when gum is missing, disabled, or fails. Callers may run
# under `set -euo pipefail`; a silent gum failure would otherwise produce
# empty strings in the verdict lines and hide the rail from the user.
_tk_rail() {
  local rendered=""
  if tk_color_enabled && tk_have_gum; then
    rendered="$(gum style --foreground "$TK_BRAND_ORANGE" "▌▌" 2>/dev/null || true)"
  fi
  if [ -n "$rendered" ]; then
    printf '%s' "$rendered"
  else
    printf '▌▌'
  fi
}

_tk_paint() {
  local color="$1"; shift
  local flag="$1"; shift
  local rendered=""
  if tk_color_enabled && tk_have_gum; then
    if [ "$flag" = "bold" ]; then
      rendered="$(gum style --foreground "$color" --bold "$*" 2>/dev/null || true)"
    else
      rendered="$(gum style --foreground "$color" "$*" 2>/dev/null || true)"
    fi
  fi
  if [ -n "$rendered" ]; then
    printf '%s' "$rendered"
  else
    printf '%s' "$*"
  fi
}

# tk_verdict <state> <headline> [subtitle]
#   state: ok | fail | info
# Renders the Option E double-rail verdict signed "touchstone".
tk_verdict() {
  local state="$1" headline="$2" subtitle="${3:-}"
  local rail mark version_line sig
  rail="$(_tk_rail)"

  case "$state" in
    ok)   mark="$(_tk_paint "$TK_BRAND_LIME" plain "✓")" ;;
    fail) mark="$(_tk_paint "$TK_BRAND_RED"  plain "✗")" ;;
    info) mark="$(_tk_paint "$TK_BRAND_DIM"  plain "•")" ;;
    *)    mark="$(_tk_paint "$TK_BRAND_DIM"  plain "·")" ;;
  esac

  case "$state" in
    ok)   headline="$(_tk_paint "$TK_BRAND_LIME" bold "$headline")" ;;
    fail) headline="$(_tk_paint "$TK_BRAND_RED"  bold "$headline")" ;;
    *)    headline="$(_tk_paint "$TK_BRAND_DIM"  bold "$headline")" ;;
  esac

  printf '\n  %s  %s  %s\n' "$rail" "$headline" "$mark"
  if [ -n "$subtitle" ]; then
    printf '  %s  %s\n' "$rail" "$(_tk_paint "$TK_BRAND_DIM" plain "$subtitle")"
  fi
  sig="$(tk_signature)"
  printf '  %s  %s\n\n' "$rail" "$sig"
}

# tk_signature — the "touchstone vX.Y.Z" signature line (without rail).
# The caller is responsible for placing it next to a rail when needed.
tk_signature() {
  local version
  if [ -n "${TOUCHSTONE_ROOT:-}" ] && [ -f "$TOUCHSTONE_ROOT/VERSION" ]; then
    version="$(tr -d '[:space:]' < "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null || true)"
  fi
  if [ -n "$version" ]; then
    _tk_paint "$TK_BRAND_DIM" plain "touchstone v${version}"
  else
    _tk_paint "$TK_BRAND_DIM" plain "touchstone"
  fi
}

# tk_hero [subtitle] — figlet+gum hero banner for `touchstone init` /
# `touchstone version`. Falls back to a bold header when figlet is missing.
tk_hero() {
  local subtitle="${1:-}"
  local version=""
  if [ -n "${TOUCHSTONE_ROOT:-}" ] && [ -f "$TOUCHSTONE_ROOT/VERSION" ]; then
    version="$(tr -d '[:space:]' < "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null || true)"
  fi

  if tk_have_figlet && tk_have_gum && tk_color_enabled; then
    local banner painted_banner painted_sub
    banner="$(figlet -f slant TOUCHSTONE 2>/dev/null || figlet TOUCHSTONE 2>/dev/null || true)"
    if [ -n "$banner" ]; then
      painted_banner="$(gum style --foreground "$TK_BRAND_ORANGE" --margin "1 2" "$banner" 2>/dev/null || true)"
      if [ -n "$painted_banner" ]; then
        printf '%s\n' "$painted_banner"
        local sub_text=""
        if [ -n "$subtitle" ]; then
          sub_text="$subtitle${version:+ · v$version}"
        elif [ -n "$version" ]; then
          sub_text="shared engineering platform · v${version}"
        fi
        if [ -n "$sub_text" ]; then
          painted_sub="$(gum style --foreground "$TK_BRAND_DIM" --margin "0 2" "$sub_text" 2>/dev/null || true)"
          if [ -n "$painted_sub" ]; then
            printf '%s\n' "$painted_sub"
          else
            printf '  %s\n' "$sub_text"
          fi
        fi
        printf '\n'
        return 0
      fi
    fi
  fi

  # Plain fallback.
  printf '\n'
  if tk_color_enabled; then
    printf '  \033[1;38;5;208mTOUCHSTONE\033[0m'
  else
    printf '  TOUCHSTONE'
  fi
  if [ -n "$version" ]; then
    printf '  v%s' "$version"
  fi
  printf '\n'
  if [ -n "$subtitle" ]; then
    if tk_color_enabled; then
      printf '  \033[2m%s\033[0m\n' "$subtitle"
    else
      printf '  %s\n' "$subtitle"
    fi
  fi
  printf '\n'
}
