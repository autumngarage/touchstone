#!/usr/bin/env bash
#
# scripts/refresh-principles.sh — regenerate lib/agents-principles-block.sh from principles/*.md.
#
# This ensures that the hardcoded principles block in the shell library
# never drifts from the canonical Markdown files.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PRINCIPLES_DIR="$REPO_ROOT/principles"
OUTPUT_LIB="$REPO_ROOT/lib/agents-principles-block.sh"

# Extract principles from engineering-principles.md
# We look for ## headers and take the first paragraph as the summary.
render_principles() {
  local file="$PRINCIPLES_DIR/engineering-principles.md"
  awk '
    /^## / {
      if (header) {
        printf "- **%s** — %s\n", header, summary
      }
      header = substr($0, 4)
      summary = ""
      next
    }
    header && !summary && /^[[:alnum:]]/ {
      summary = $0
      next
    }
    END {
      if (header) {
        printf "- **%s** — %s\n", header, summary
      }
    }
  ' "$file"
  printf '%s\n' '- **File issues for bugs** — Open a GitHub issue when you find a bug, in this project or in an autumngarage tool. Do not silently work around it.'
}

# The template for the block
BLOCK_HEADER="<!-- touchstone:shared-principles:start -->
## Shared Engineering Principles (apply these first)

These principles are touchstone-owned and shared across every project. Apply them as the **primary coding and review criteria** before any project-specific rule below — an agent that lets a band-aid or a silent failure through has missed the point of this gate.

## Agent Roles And Fallbacks

There are two AI roles in a Touchstone workflow:

- **Driving CLI:** Claude Code, Codex, or Gemini CLI owns the repo workflow. The driver reads the steering files, edits files, runs tests, creates the branch and commits, opens the PR, invokes review, and ships through the merge helper.
- **Conductor worker/reviewer:** Conductor is the model router used by the driving CLI for review and bounded model work. Conductor can route to Claude, Codex, Gemini, or other providers, and can fall back between configured providers, but Conductor does not replace the driving CLI's responsibility for the branch → PR → review → automerge workflow.

Driver fallback is shared-contract fallback: Codex and other AGENTS.md-native tools start here; Gemini starts in \`GEMINI.md\` and delegates back here; Claude starts in \`CLAUDE.md\` and imports the same \`principles/\` files. If one driving CLI is unavailable or rate-limited, another driving CLI can continue by reading its entry file plus this managed block and \`principles/*.md\`. If an agent-specific file is incomplete or conflicts with this block or \`principles/*.md\`, follow the managed block and principles first.
"

BLOCK_FOOTER="
Full rationale, worked examples, and the *why* behind each rule:

- \`principles/engineering-principles.md\`
- \`principles/pre-implementation-checklist.md\`
- \`principles/documentation-ownership.md\`
- \`principles/git-workflow.md\`
- \`principles/agent-swarms.md\`
- \`principles/file-upstream-bugs.md\`

## Required Delivery Workflow

For any task that may change tracked files, drive the full branch → PR → review → merge lifecycle unless the user explicitly asks you to stop before shipping:

1. Sync the default branch with \`git pull --rebase\`.
2. Before the first edit, run \`git branch --show-current\`. If it reports \`main\` or \`master\`, create a feature branch with \`git checkout -b <type>/<short-description>\`.
3. Make the change on that branch, keep commits scoped, stage explicit file paths, and commit with a concise message.
4. From a clean worktree, run \`CODEX_REVIEW_FORCE=1 bash scripts/codex-review.sh\`. If Conductor creates fix commits, let the loop finish; if it blocks, address findings, commit, and rerun until clean.
5. Ship with \`bash scripts/open-pr.sh --auto-merge\`. That command pushes the branch, creates the PR, runs the final read-only Conductor merge review, squash-merges after a clean review, and syncs the default branch.

Do not bypass the PR/review/automerge path with a direct default-branch push except through the documented emergency path in \`principles/git-workflow.md\`.

This block is managed by \`touchstone\` and refreshes on \`touchstone update\` / \`touchstone init\`. Edit content **outside** the markers to add project-specific agent guidance — touchstone will not touch it.
<!-- touchstone:shared-principles:end -->"

# Generate the full block
tmp_block="$(mktemp)"
printf "%s\n%s\n%s" "$BLOCK_HEADER" "$(render_principles)" "$BLOCK_FOOTER" > "$tmp_block"

# Update lib/agents-principles-block.sh
# We use a sed-like approach to replace the block inside agents_principles_block_render()
tmp_lib="$(mktemp)"
awk '
  BEGIN { in_render = 0; replaced = 0; block_file = ARGV[ARGC-1]; ARGC-- }
  /^agents_principles_block_render\(\) \{/ { in_render = 1; print; next }
  in_render && /^  cat <<\047BLOCK\047/ {
    print "  cat <<\047BLOCK\047"
    while ((getline < block_file) > 0) {
      print $0
    }
    replaced = 1
    next
  }
  in_render && /^BLOCK/ { in_render = 0; print; next }
  in_render && replaced { next }
  { print }
' "$OUTPUT_LIB" "$tmp_block" > "$tmp_lib"

cat "$tmp_lib" > "$OUTPUT_LIB"
rm "$tmp_lib" "$tmp_block"

echo "Successfully refreshed $OUTPUT_LIB from $PRINCIPLES_DIR"
