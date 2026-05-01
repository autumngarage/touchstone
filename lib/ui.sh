#!/usr/bin/env bash
#
# lib/ui.sh — Touchstone branded UI helpers.
#
# Provides the double-rail verdict style and the embedded wordmark/gum hero
# banner. Gracefully degrades when gum is not installed: the rails turn into
# ASCII bars, and the hero turns into a plain wordmark.
#
# Sourced by bin/touchstone. The codex-review hook carries its own inline
# copy because it ships into downstream projects without lib/.

# Guard: only define helpers once per shell.
if [ -n "${TK_UI_SOURCED:-}" ]; then return 0; fi
TK_UI_SOURCED=1

# Brand palette. Orange is the Touchstone signature color; lime/red are the
# state accents; dim is for supporting text.
TK_BRAND_ORANGE="#FF6B35"
TK_BRAND_PEACH="#ffaf87"
TK_BRAND_WHEAT="#ffd7af"
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
  local rail mark sig
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
  local version=""
  if [ -n "${TOUCHSTONE_ROOT:-}" ] && [ -f "$TOUCHSTONE_ROOT/VERSION" ]; then
    version="$(tr -d '[:space:]' < "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null || true)"
  fi
  if [ -n "$version" ]; then
    _tk_paint "$TK_BRAND_DIM" plain "touchstone v${version}"
  else
    _tk_paint "$TK_BRAND_DIM" plain "touchstone"
  fi
}

_tk_wordmark() {
  cat <<'WORDMARK'
 _____                _         _                   
|_   _|__  _   _  ___| |__  ___| |_ ___  _ __   ___ 
  | |/ _ \| | | |/ __| '_ \/ __| __/ _ \| '_ \ / _ \
  | | (_) | |_| | (__| | | \__ \ || (_) | | | |  __/
  |_|\___/ \__,_|\___|_| |_|___/\__\___/|_| |_|\___|
WORDMARK
}

# tk_hero [subtitle] — embedded wordmark+gum hero banner for
# `touchstone init` / `touchstone version`. Falls back to a plain wordmark.
tk_hero() {
  local subtitle="${1:-}"
  local version=""
  if [ -n "${TOUCHSTONE_ROOT:-}" ] && [ -f "$TOUCHSTONE_ROOT/VERSION" ]; then
    version="$(tr -d '[:space:]' < "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null || true)"
  fi

  if tk_have_gum && tk_color_enabled; then
    local banner painted_banner painted_sub painted_attr
    banner="$(_tk_wordmark)"
    painted_banner="$(gum style --foreground "$TK_BRAND_PEACH" --margin "1 2" "$banner" 2>/dev/null || true)"
    if [ -n "$painted_banner" ]; then
      printf '%s\n' "$painted_banner" >&2
      local sub_text=""
      if [ -n "$subtitle" ]; then
        sub_text="$subtitle${version:+ · v$version}"
      elif [ -n "$version" ]; then
        sub_text="shared engineering platform · v${version}"
      fi
      if [ -n "$sub_text" ]; then
        painted_sub="$(gum style --foreground "$TK_BRAND_WHEAT" --margin "0 2" "$sub_text" 2>/dev/null || true)"
        if [ -n "$painted_sub" ]; then
          printf '%s\n' "$painted_sub" >&2
        else
          printf '  %s\n' "$sub_text" >&2
        fi
      fi
      painted_attr="$(gum style --foreground "$TK_BRAND_WHEAT" --margin "0 2" "by Autumn Garage" 2>/dev/null || true)"
      if [ -n "$painted_attr" ]; then
        printf '%s\n' "$painted_attr" >&2
      else
        printf '  by Autumn Garage\n' >&2
      fi
      printf '\n' >&2
      return 0
    fi
  fi

  # Plain fallback.
  printf '\n' >&2
  if tk_color_enabled; then
    while IFS= read -r line; do
      printf '  \033[38;5;216m%s\033[0m\n' "$line" >&2
    done <<WORDMARK
$(_tk_wordmark)
WORDMARK
  else
    while IFS= read -r line; do
      printf '  %s\n' "$line" >&2
    done <<WORDMARK
$(_tk_wordmark)
WORDMARK
  fi
  if [ -n "$subtitle" ]; then
    if tk_color_enabled; then
      printf '  \033[38;5;223m%s\033[0m\n' "$subtitle${version:+ · v$version}" >&2
    else
      printf '  %s\n' "$subtitle${version:+ · v$version}" >&2
    fi
  elif [ -n "$version" ]; then
    if tk_color_enabled; then
      printf '  \033[38;5;223mshared engineering platform · v%s\033[0m\n' "$version" >&2
    else
      printf '  shared engineering platform · v%s\n' "$version" >&2
    fi
  fi
  if tk_color_enabled; then
    printf '  \033[38;5;223mby Autumn Garage\033[0m\n' >&2
  else
    printf '  by Autumn Garage\n' >&2
  fi
  printf '\n' >&2
}
