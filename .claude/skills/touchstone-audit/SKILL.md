---
name: touchstone-audit
description: Audits the Touchstone project at ~/Repos/touchstone for drift against its own engineering principles and against current Anthropic/Claude Code best practices. Evaluates principles, implementation, and process/workflow (git lifecycle, Codex review, release flow). Produces a dated markdown report in audits/ and never modifies touchstone files. Runs only when the user explicitly asks to audit the Touchstone, run a Touchstone health check, or verify the Touchstone is up to date against current best practices. Do not invoke for generic "review this code" or "review this PR" requests — those should use ad-hoc review, not this skill.
---

# Touchstone Audit

On-demand audit of `~/Repos/touchstone` — a shared engineering platform that propagates to every downstream project via `sync-all.sh`. This skill produces a structured audit report. **It never modifies touchstone files.** The user reviews the report and explicitly asks for follow-up changes in a separate turn.

The touchstone changes slowly but the ecosystem around it (Claude Code, Anthropic guidance, Codex, agent design patterns) changes quickly. The job of this audit is to surface drift in both directions: principles or implementation that have fallen behind current thinking, and new capabilities worth adopting.

## Hard constraints

- **Read + research + report only.** Do not edit `principles/`, `hooks/`, `lib/`, `scripts/`, `templates/`, `bin/`, `bootstrap/`, `completions/`, `tests/`, `CLAUDE.md`, `AGENTS.md`, `README.md`, or `VERSION`.
- **Write exactly one output file**: `audits/YYYY-MM-DD-audit.md` (UTC date). If a file with that name already exists, append `-2`, `-3`, etc. No other file writes.
- **No guessing.** If you are unsure whether a principle is still endorsed or whether a capability exists, say so in the report — don't invent a recommendation.
- **Anthropic-official sources only.** Restrict research to `docs.claude.com`, `docs.anthropic.com`, `anthropic.com`, `code.claude.com` (Claude Code docs subdomain), and `platform.claude.com` (redirect target for some Claude platform docs). No blogs, Medium, community repos, or third-party tutorials.
- **Scope is the Touchstone repo.** Do not audit the downstream projects listed in `~/.touchstone-projects`.

## Execution plan

Run phases sequentially. Later phases depend on earlier ones.

### Phase 1 — Learn the current state

Read in this order:

1. `CLAUDE.md` — what the Touchstone is, what propagates, release invariants.
2. `AGENTS.md` — agent-facing conventions if present.
3. Every file in `principles/` — the named rules you will grade against.
4. `VERSION` and the last 30 entries from `gh release list` (the canonical release history — there is no CHANGELOG.md).
5. Output of `git log --oneline -30` — recent direction of travel.
6. Tree listings (names only, not contents) of `bin/`, `lib/`, `hooks/`, `scripts/`, `bootstrap/`, `templates/`, `tests/`, `completions/`.
7. The most recent prior audit in `audits/` if one exists. Understand what was flagged, what was acted on (check git log), and what is still open.

After reading, hold in working memory (do not write to a file):
- A one-paragraph statement of what the Touchstone is and what it propagates.
- The explicit list of principles you will grade against (by filename).
- What has changed since the last audit, or "first audit" if none exists.

### Phase 2 — Research current best practices

Use `WebSearch` to discover current Anthropic-official guidance, then `WebFetch` the canonical pages. **Do not use a pinned URL list — URLs rot.** The search strategy is pinned; the destinations are rediscovered each run. When `WebSearch` is called with `allowed_domains`, pass the full allowlist from the Hard constraints section (`docs.claude.com`, `docs.anthropic.com`, `anthropic.com`, `code.claude.com`, `platform.claude.com`) so Claude Code and Claude Platform docs aren't filtered out.

Search topics (run these as separate WebSearch queries, not one mega-query):

- Claude Code: skills, hooks, sub-agents, slash commands, settings.json, plugins, CLAUDE.md conventions
- Claude Code recent changelog / release notes
- Anthropic prompt engineering guide (current version)
- Anthropic guidance on tool use, context management, prompt-injection defense
- Agent design patterns published by Anthropic (multi-agent, sub-agents, sandboxing)
- Anything the Touchstone specifically uses: Codex CLI review workflows, Homebrew tap conventions, GitHub Releases automation

For each relevant finding, record internally: source URL, one-line summary, which touchstone file(s) or process it touches.

If WebSearch or WebFetch is unavailable, continue with Phase 1 knowledge only and note the gap explicitly in the report's "Gaps in this audit" section. Do not fabricate research findings.

### Phase 3 — Three-pass evaluation

Run three passes. Each pass produces findings that will be written into a dedicated section of the report.

#### Pass A — Principles drift

For each file in `principles/`, answer:

- Is the rule still endorsed by current Anthropic guidance? (Cite specific sources from Phase 2.)
- Is the rule *missing* something a 2026-era agent/touchstone needs? Examples: prompt-injection defense for tool results, sub-agent coordination, context-window hygiene, skill-authoring conventions, hook lifecycle guarantees.
- Does the rule contradict newer guidance?
- Is the language still precise given how terminology has evolved?

Classify each principle file as: `still-correct` / `update-suggested` / `gap-identified` / `needs-discussion`.

#### Pass B — Implementation drift

Spot-check (do not exhaustively audit — that's a separate task) the implementation for violations of the Touchstone's *own* principles:

- **No band-aids** — symptom-patches in `hooks/` or `lib/` or `scripts/`?
- **No silent failures** — do shell scripts swallow errors? Look for `|| true`, missing `set -euo pipefail`, ignored exit codes, `2>/dev/null` on operations that should surface errors.
- **Derive, don't persist** — is any derived state cached in ways that can go stale? (e.g., `last-update-check` files, cached version strings.)
- **One code path** — divergent code paths for test/prod, dev/ci, or interactive/non-interactive modes?
- **Documentation ownership** — are volatile facts (version numbers, file lists, URLs, test counts) duplicated across `README.md`, `CLAUDE.md`, and `AGENTS.md`?
- **Every fix gets a test** — does every script in `bin/`, `lib/`, `scripts/`, `hooks/`, `bootstrap/` have at least one corresponding test in `tests/`?

Only flag things you have direct evidence for (file path + line or pattern). If you'd need to read more code to confirm, list it as `needs-investigation`, not as a finding.

#### Pass C — Process & workflow evaluation

This pass evaluates the *workflows* the Touchstone enforces, not just the code. For each workflow below, ask: *is this still the right shape? Should anything be added, refined, or retired?*

Workflows to evaluate:

- **Git lifecycle** (`principles/git-workflow.md` + `scripts/open-pr.sh` + `scripts/merge-pr.sh` + `scripts/cleanup-branches.sh`) — branch naming, PR creation, merge flow, branch hygiene. Does current Claude Code / agent guidance suggest refinements?
- **Codex review hook** (`hooks/codex-review.sh` + `hooks/codex-review.config.example.toml`) — the merge/default-branch review gate. Is the auto-fix loop shape still right? Are there new Codex CLI features worth adopting? Is the high-scrutiny-paths concept aligned with current thinking on AI code review?
- **Release flow** (`lib/release.sh` + `bin/touchstone release` + Homebrew tap in `homebrew-touchstone/`) — the four-way agreement invariant (GitHub Releases, Homebrew, `origin/main`, local brew install). Anything new to add here? Any steps that are now redundant?
- **Bootstrap & propagation** (`bootstrap/new-project.sh`, `bootstrap/update-project.sh`, `bootstrap/sync-all.sh`) — the mechanism by which touchstone changes reach downstream projects. Are there Claude Code–native mechanisms (plugins, skills, hooks) that should replace or augment file-copy propagation?
- **Auto-update check** (`lib/auto-update.sh` and `~/.touchstone/last-update-check`) — is file-based update polling still the right pattern?
- **Testing discipline** (`tests/test-*.sh`) — is shell-based self-testing still the right approach, or would a different harness serve the propagation-sensitive nature of the Touchstone better?

For each workflow, classify as: `keep-as-is` / `refine` / `add-capability` / `retire` / `needs-discussion`.

Important: process changes are high-blast-radius because they change how the user works every day. Bias toward `needs-discussion` over `refine` unless you have strong evidence.

### Phase 4 — Write the report

Compute today's UTC date with `date -u +%Y-%m-%d`. Create `audits/<date>-audit.md` (suffix with `-2`, `-3`... if a file with that name exists).

Use this exact structure:

```markdown
# Touchstone Audit — YYYY-MM-DD

## Summary
- Touchstone version: vX.Y.Z
- Commits since last audit: N (or "first audit")
- Principles reviewed: N
- Findings: X adopt / Y refine / Z already-have / W needs-discussion / V skip
- Research coverage: <sources successfully consulted, or gaps>

## Principles drift
One subsection per file in `principles/`. Each includes:
- **Classification**: still-correct / update-suggested / gap-identified / needs-discussion
- **Evidence**: what you read in the principle + what current guidance says
- **Source citations**: specific URLs from Phase 2
- **Recommendation** (if any): what the user should consider changing, not what to do blindly

## Implementation drift
One subsection per finding. Each includes:
- **What**: one-line description
- **Principle touched**: named principle file
- **Evidence**: file:line or concrete pattern
- **Classification**: adopt / skip / already-have / needs-discussion / needs-investigation
- **Blast radius**: propagates via sync-all.sh? touches release gate? affects bootstrap?
- **Recommendation**: what to consider

## Process & workflow
One subsection per workflow evaluated in Pass C. Each includes:
- **Workflow**: name + key files
- **Current shape**: one-paragraph description of what exists today
- **Classification**: keep-as-is / refine / add-capability / retire / needs-discussion
- **Evidence**: what in current guidance prompted this classification
- **Recommendation**: what to consider, framed as a question if it's a judgment call

## New capabilities worth considering
Anything from Phase 2 research that isn't drift per se but is new surface area the Touchstone could adopt. One subsection per capability. Include what it is, where it would fit, and what it would replace or augment.

## Gaps in this audit
Things you couldn't check and why — missing tool access, files too large to read, research sources unavailable, areas that need deeper investigation.

## Prior-audit follow-up (if applicable)
For each finding in the most recent prior audit: is it still open, acted on, or obsolete?
```

After writing the file, print to the user: one sentence with the absolute path to the report and a one-line summary of the finding counts. Nothing else — the user reads the report.

## Grading rubric

Use these definitions consistently across all passes:

- **adopt** / **refine** / **add-capability** — a concrete change is recommended and fits the Touchstone's philosophy
- **skip** — current guidance exists but contradicts a deliberate touchstone decision; name the principle that conflicts
- **already-have** / **keep-as-is** / **still-correct** — no action needed; note it briefly so the user can confirm
- **needs-discussion** — involves a judgment call the user should make; frame as a question
- **needs-investigation** — you'd need more context to classify; list exactly what's needed
- **retire** — a workflow or piece of infrastructure is obsolete and should be removed; provide strong evidence

## What NOT to do

- Don't propose changes to the downstream projects registered in `~/.touchstone-projects`. Scope is the Touchstone repo only.
- Don't research non-Anthropic sources. No blogs, no Medium, no community repos.
- Don't write or edit any file outside `audits/`.
- Don't generate a punch-list of trivial style nits. The touchstone's principles are about structural quality.
- Don't re-report findings from a prior audit unless the situation has changed. Cross-reference prior audits in the "Prior-audit follow-up" section instead.
- Don't exhaustively audit large surface areas. Spot-check with evidence and list the rest as `needs-investigation`.
- Don't invent research findings if WebSearch/WebFetch fails. Note the gap and continue.
