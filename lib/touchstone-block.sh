#!/usr/bin/env bash
#
# lib/touchstone-block.sh — manage the touchstone-owned steering block inside
# a project's AGENTS.md / GEMINI.md.
#
# Why this exists:
#   AGENTS.md and GEMINI.md are project-owned but must contain the universal
#   Touchstone steering content (engineering principles, lifecycle, routing
#   table). Codex CLI does not resolve `@-imports` (open feature request
#   `openai/codex#17401`), so the content must be inlined into AGENTS.md
#   directly. This helper inserts/refreshes a sentinel-delimited block at the
#   top of the file. Everything outside the markers is project-owned and
#   never touched.
#
#   The block content is ALWAYS rendered from a single source-of-truth file:
#   `$TOUCHSTONE_ROOT/TOUCHSTONE.md` (or the file passed via `--source`).
#   That eliminates the codegen-from-bash-heredoc pattern in the previous
#   implementation, which made the bash file the secondary owner of content
#   that lived in markdown.
#
#   Sentinel: `<!-- touchstone:steering:start/end -->`. The previous sentinel
#   `<!-- touchstone:shared-principles:start/end -->` is recognized for
#   migration; `apply` rewrites it to the new sentinel on the first refresh.
#
# Public surface:
#   touchstone_block_render <touchstone_root>           — print block to stdout
#   touchstone_block_apply <agents_md> [touchstone_root] — apply (inject or refresh) in place
#
# Exit codes for touchstone_block_apply:
#   0 — file exists and is now current (may or may not have changed on disk)
#   1 — file is malformed (orphaned sentinel) or render source missing
#   2 — file does not exist (caller decides whether to copy a template first)

# New (canonical) sentinel.
TOUCHSTONE_BLOCK_BEGIN='<!-- touchstone:steering:start -->'
TOUCHSTONE_BLOCK_END='<!-- touchstone:steering:end -->'

# Legacy sentinel — recognized for migration, never written by render.
TOUCHSTONE_BLOCK_BEGIN_LEGACY='<!-- touchstone:shared-principles:start -->'
TOUCHSTONE_BLOCK_END_LEGACY='<!-- touchstone:shared-principles:end -->'

# Render the steering block to stdout.
# Caller passes touchstone_root (the directory containing TOUCHSTONE.md) as $1,
# or sets $TOUCHSTONE_ROOT in the environment.
touchstone_block_render() {
  local touchstone_root="${1:-${TOUCHSTONE_ROOT:-}}"

  if [ -z "$touchstone_root" ]; then
    # Last-resort: derive from this script's location (lib/ sibling of TOUCHSTONE.md).
    touchstone_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  local source="$touchstone_root/TOUCHSTONE.md"
  if [ ! -f "$source" ]; then
    echo "ERROR: touchstone_block_render: source file not found: $source" >&2
    return 1
  fi

  printf '%s\n' "$TOUCHSTONE_BLOCK_BEGIN"
  printf '\n'
  printf '%s\n' "<!-- This block is generated from TOUCHSTONE.md. \`touchstone update\` refreshes it."
  printf '%s\n' "     Edit content OUTSIDE the markers; touchstone will not touch project-owned content. -->"
  printf '\n'
  cat "$source"
  printf '\n'
  printf '%s\n' "$TOUCHSTONE_BLOCK_END"
}

# Inject or refresh the block in $target.
touchstone_block_apply() {
  local target="$1"
  local touchstone_root="${2:-${TOUCHSTONE_ROOT:-}}"

  if [ -z "$target" ]; then
    echo "ERROR: touchstone_block_apply requires a path argument" >&2
    return 1
  fi

  if [ ! -f "$target" ]; then
    return 2
  fi

  # Refuse a symlinked target. This function reads $target and rewrites it in
  # place; if $target is a symlink it would read AND clobber the link's target,
  # potentially outside the project. AGENTS.md/GEMINI.md are regular project
  # files, so a symlink here is anomalous — skip rather than follow it.
  if [ -L "$target" ]; then
    echo "ERROR: $target is a symlink — refusing to write the touchstone block through it." >&2
    return 1
  fi

  # Detect either sentinel pair. Both must be paired (begin AND end), or refuse.
  local has_new_begin=0 has_new_end=0
  grep -qF "$TOUCHSTONE_BLOCK_BEGIN" "$target" && has_new_begin=1
  grep -qF "$TOUCHSTONE_BLOCK_END" "$target" && has_new_end=1

  local has_legacy_begin=0 has_legacy_end=0
  grep -qF "$TOUCHSTONE_BLOCK_BEGIN_LEGACY" "$target" && has_legacy_begin=1
  grep -qF "$TOUCHSTONE_BLOCK_END_LEGACY" "$target" && has_legacy_end=1

  if [ "$has_new_begin" != "$has_new_end" ]; then
    echo "ERROR: $target has an orphaned $TOUCHSTONE_BLOCK_BEGIN sentinel — refusing to touch." >&2
    return 1
  fi
  if [ "$has_legacy_begin" != "$has_legacy_end" ]; then
    echo "ERROR: $target has an orphaned $TOUCHSTONE_BLOCK_BEGIN_LEGACY sentinel — refusing to touch." >&2
    return 1
  fi

  # Pick which sentinel pair (if any) currently delimits the block.
  local active_begin="" active_end=""
  if [ "$has_new_begin" = 1 ]; then
    active_begin="$TOUCHSTONE_BLOCK_BEGIN"
    active_end="$TOUCHSTONE_BLOCK_END"
  elif [ "$has_legacy_begin" = 1 ]; then
    active_begin="$TOUCHSTONE_BLOCK_BEGIN_LEGACY"
    active_end="$TOUCHSTONE_BLOCK_END_LEGACY"
  fi

  local block_file out_file
  block_file="$(mktemp -t touchstone-block.XXXXXX)"
  out_file="$(mktemp -t touchstone-block-out.XXXXXX)"
  if ! touchstone_block_render "$touchstone_root" >"$block_file"; then
    rm -f "$block_file" "$out_file"
    return 1
  fi

  if [ -n "$active_begin" ]; then
    # Refresh: copy lines, splice the rendered block at the start sentinel,
    # skip until the end sentinel. Always writes the new sentinel pair.
    local in_block=0 spliced=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$in_block" = 1 ]; then
        if [ "$line" = "$active_end" ]; then
          in_block=0
        fi
        continue
      fi
      if [ "$line" = "$active_begin" ]; then
        if [ "$spliced" = 0 ]; then
          cat "$block_file" >>"$out_file"
          spliced=1
        fi
        in_block=1
        continue
      fi
      printf '%s\n' "$line" >>"$out_file"
    done <"$target"
  else
    # Inject at top, after the first H1 if there is one — otherwise at line 1.
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
  fi

  if cmp -s "$out_file" "$target"; then
    rm -f "$block_file" "$out_file"
    return 0
  fi

  # Replace preserving the file's permissions — and PROPAGATE the write's
  # status. A readable-but-unwritable target (mode 0444) fails this redirect,
  # and the cleanup below must not launder that into success: callers commit
  # version bumps on this function's word, and a stale managed block behind a
  # reported success is exactly the silent-failure class (PR #703 review).
  local write_status=0
  cat "$out_file" >"$target" || write_status=$?
  rm -f "$block_file" "$out_file"
  if [ "$write_status" -ne 0 ]; then
    echo "ERROR: touchstone_block_apply: could not write the managed block to $target (status $write_status)." >&2
    return 1
  fi
  return 0
}
