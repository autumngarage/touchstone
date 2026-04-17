#!/usr/bin/env bash
#
# prototypes/ui-banners.sh — visual prototypes for Touchstone's branded output.
# Run this script in a real terminal to compare styles. Pick one and we'll wire
# it into lib/ui.sh and hooks/codex-review.sh.
#
# Requires: gum (brew install gum). Falls back to plain echoes without it.
#
set -uo pipefail

have_gum() { command -v gum >/dev/null 2>&1; }

# Touchstone brand palette — pick whichever you like; these are placeholders.
BRAND_ORANGE="#FF6B35"   # warm accent, reads "craft/tool"
BRAND_SLATE="#4A6FA5"    # cool accent, reads "enterprise/trust"
BRAND_INK="#1A1A2E"      # deep background accent
BRAND_LIME="#A3E635"     # success-pop
BRAND_RED="#EF4444"      # fail-pop
BRAND_DIM="#6B7280"      # supporting text

hr() { printf '\n\n'; printf '─%.0s' {1..72}; printf '  %s\n\n' "$1"; }

# ------------------------------------------------------------
hr "CURRENT — for reference"
# ------------------------------------------------------------
cat <<'EOF'

  ╔══════════════════════════════════════╗
  ║           ✅ ALL CLEAR              ║
  ║         Push approved.              ║
  ╚══════════════════════════════════════╝

EOF

# ------------------------------------------------------------
hr "OPTION A — left-rail, orange brand, no box (bun/vercel style)"
# ------------------------------------------------------------
if have_gum; then
  gum style --foreground "$BRAND_ORANGE" "▌ $(gum style --foreground "$BRAND_LIME" "✓") ALL CLEAR"
  gum style --foreground "$BRAND_ORANGE" "▌ $(gum style --foreground "$BRAND_DIM" "  Push approved · Codex · 3m5s · 0 findings")"
fi

# ------------------------------------------------------------
hr "OPTION B — rounded box, minimal, orange border"
# ------------------------------------------------------------
if have_gum; then
  gum style \
    --border rounded --padding "0 2" --margin "0 2" \
    --border-foreground "$BRAND_ORANGE" \
    --foreground "15" \
    "$(gum style --foreground "$BRAND_LIME" "✓") ALL CLEAR" \
    "$(gum style --foreground "$BRAND_DIM" "Codex · 3m5s · 0 findings")"
fi

# ------------------------------------------------------------
hr "OPTION C — rounded box with title, slate brand"
# ------------------------------------------------------------
if have_gum; then
  gum style \
    --border rounded --padding "1 3" --margin "0 2" \
    --border-foreground "$BRAND_SLATE" \
    --foreground "15" --align center --width 44 \
    "$(gum style --foreground "$BRAND_LIME" --bold "✓ ALL CLEAR")" \
    "$(gum style --foreground "$BRAND_DIM" "Push approved")"
fi

# ------------------------------------------------------------
hr "OPTION D — thick horizontal rule + inline label (biome/cargo style)"
# ------------------------------------------------------------
if have_gum; then
  label="$(gum style --foreground "$BRAND_LIME" --bold " ✓ ALL CLEAR ")"
  rule="$(gum style --foreground "$BRAND_ORANGE" "━━━━━━━━━━")"
  printf '\n  %s%s%s\n' "$rule" "$label" "$rule"
  printf '  %s\n\n' "$(gum style --foreground "$BRAND_DIM" "Codex · 3m5s · 0 findings · push approved")"
fi

# ------------------------------------------------------------
hr "OPTION E — double left-rail, stronger brand presence"
# ------------------------------------------------------------
if have_gum; then
  rail="$(gum style --foreground "$BRAND_ORANGE" "▌▌")"
  printf '\n  %s  %s  %s\n' "$rail" "$(gum style --foreground "$BRAND_LIME" --bold "ALL CLEAR")" "$(gum style --foreground "$BRAND_DIM" "✓")"
  printf '  %s  %s\n\n' "$rail" "$(gum style --foreground "$BRAND_DIM" "Codex · 3m5s · 0 findings · push approved")"
fi

# ------------------------------------------------------------
hr "OPTION F — thick block rail, serious/technical"
# ------------------------------------------------------------
if have_gum; then
  rail_ok="$(gum style --foreground "$BRAND_LIME" "█")"
  rail_brand="$(gum style --foreground "$BRAND_ORANGE" "█")"
  printf '\n  %s%s  %s\n' "$rail_brand" "$rail_ok" "$(gum style --bold "ALL CLEAR")"
  printf '  %s%s  %s\n\n' "$rail_brand" "$rail_ok" "$(gum style --foreground "$BRAND_DIM" "Codex · 3m5s · 0 findings")"
fi

# ------------------------------------------------------------
hr "OPTION G — blocked state, for contrast (rail pattern)"
# ------------------------------------------------------------
if have_gum; then
  rail="$(gum style --foreground "$BRAND_RED" "▌")"
  printf '\n  %s %s  %s\n' "$rail" "$(gum style --foreground "$BRAND_RED" --bold "✗")" "$(gum style --bold "BLOCKED")"
  printf '  %s   %s\n' "$rail" "$(gum style --foreground "$BRAND_DIM" "Codex flagged 2 unsafe changes — push refused")"
  printf '  %s   %s\n\n' "$rail" "$(gum style --foreground "$BRAND_DIM" "Re-run with CODEX_REVIEW_ALLOW_UNSAFE=1 to override")"
fi

# ------------------------------------------------------------
hr "OPTION H — phase/progress ticker (for in-progress, not endings)"
# ------------------------------------------------------------
if have_gum; then
  tick="$(gum style --foreground "$BRAND_ORANGE" "●")"
  past="$(gum style --foreground "$BRAND_LIME" "●")"
  idle="$(gum style --foreground "$BRAND_DIM" "○")"
  printf '\n  %s loading diff\n' "$past"
  printf '  %s checking cache\n' "$past"
  printf '  %s running codex review %s\n' "$tick" "$(gum style --foreground "$BRAND_DIM" "(iter 1/3)")"
  printf '  %s applying auto-fixes\n' "$idle"
  printf '  %s final verdict\n\n' "$idle"
fi

# ------------------------------------------------------------
hr "OPTION I — hero banner (for touchstone --version only, not per-op)"
# ------------------------------------------------------------
if command -v figlet >/dev/null 2>&1 && have_gum; then
  banner="$(figlet -f slant TOUCHSTONE 2>/dev/null || figlet TOUCHSTONE)"
  gum style --foreground "$BRAND_ORANGE" --margin "1 2" "$banner"
  gum style --foreground "$BRAND_DIM" --margin "0 2" "shared engineering platform · v1.1.0"
else
  echo "  (install 'figlet' to see the hero banner prototype — brew install figlet)"
fi

# ------------------------------------------------------------
hr "OPTION J — compact one-liner (for quiet/CI mode)"
# ------------------------------------------------------------
if have_gum; then
  rail="$(gum style --foreground "$BRAND_ORANGE" "▌")"
  ok="$(gum style --foreground "$BRAND_LIME" "✓")"
  printf '%s %s touchstone: ALL CLEAR %s\n\n' "$rail" "$ok" "$(gum style --foreground "$BRAND_DIM" "(codex · 3m5s · 0 findings)")"
fi

printf '\n\n────────── Tell me which option (or mix) feels right ──────────\n\n'
