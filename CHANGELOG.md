# Changelog

## 2.0.0

### Breaking changes

**Single reviewer: `conductor`.** The v1.x per-provider cascade (`codex`, `claude`, `gemini`, `local`) is retired. Touchstone 2.0 delegates all LLM access to the [Conductor CLI](https://github.com/autumngarage/conductor) — Conductor owns provider selection, auth, tool translation, route logging, and cost reporting. Touchstone speaks in capability-level intent (what tools, what sandbox, how much effort) and lets Conductor pick how.

**New config shape.** `.codex-review.toml` v2.0:

```toml
[review]
enabled = true
# reviewer = "conductor"          # single-valued; absent reviewers[]

[review.conductor]
prefer = "best"                   # best | cheapest | fastest | balanced
effort = "max"                    # minimal | low | medium | high | max | <int>
tags   = "code-review"
# with    = "claude"              # optional: pin one provider
# exclude = "gemini"              # optional: exclude one or more providers

[review.routing]
# Size-based routing overrides — now knobs on conductor's preferences,
# not a separate cascade.
small_max_diff_lines = 50
small_prefer = "cheapest"
small_effort = "minimal"
```

**Legacy config auto-migrates with a warning.** If Touchstone sees `[review].reviewers = [...]` (v1.x shape), it prints a one-time migration hint and routes through `conductor` anyway. Update at your convenience.

**Deprecated env vars:**
- `TOUCHSTONE_REVIEWER=<provider>` → translates to `TOUCHSTONE_CONDUCTOR_WITH=<provider>` with a warning.
- `TOUCHSTONE_LOCAL_REVIEWER_COMMAND` + `TOUCHSTONE_LOCAL_REVIEWER_AUTH_COMMAND` → retired. Use a Conductor custom provider (roadmap v0.3).

**Removed surface:**
- `[review.local]` section — ignored with a warning.
- `[review.assist]` peer-review — disabled in 2.0.0; returns in 2.1 via `conductor call --exclude <primary>`.

### New

- **New env-var surface for per-push overrides:**
  - `TOUCHSTONE_CONDUCTOR_WITH=<provider>` — pin a specific provider this push
  - `TOUCHSTONE_CONDUCTOR_PREFER=<mode>` — override `prefer` for this push
  - `TOUCHSTONE_CONDUCTOR_EFFORT=<level>` — override `effort` for this push
  - `TOUCHSTONE_CONDUCTOR_TAGS=<tags>` — override routing tags
  - `TOUCHSTONE_CONDUCTOR_EXCLUDE=<providers>` — exclude from auto-routing
- **Quality-tier-aware routing.** `prefer = "best"` picks the frontier-tier provider; Touchstone users automatically benefit when new frontier models ship and Conductor bumps their tier.
- **Visible routing.** Every review shows which underlying provider ran (e.g. `[conductor] best (effort=max) → claude`), token counts including thinking tokens, and cost.
- **Graceful fallback.** When the chosen provider returns 5xx / 429 / timeout, Conductor retries once with the next-ranked provider. Transparent — Touchstone surfaces the fallback in the transcript.

### Migration

From a v1.x project:

1. Install Conductor: `brew install autumngarage/conductor/conductor`.
2. Run `conductor init` — walks each provider concierge-style, collects credentials, runs smoke tests.
3. Update `.codex-review.toml` (optional; legacy shape is accepted with a warning):
   - Replace `[review].reviewers = ["claude", "codex"]` with `reviewer = "conductor"`.
   - Add a `[review.conductor]` block with `prefer` / `effort` / `tags` as needed.
4. Remove any `[review.local]` block and register the custom command as a Conductor custom provider (roadmap v0.3).
5. Remove `[review.assist]` — peer review returns in 2.1.
6. Run `touchstone update` in your project to pull the new `.codex-review.toml` example and hook.

### Internals

- `scripts/codex-review.sh` / `hooks/codex-review.sh`: the four per-provider adapter trios (~100 lines each) deleted in favor of a single `reviewer_conductor_*` trio (~60 lines).
- Tests: ~475 lines of v1.x-cascade tests retired; `tests/test-review-hook.sh` now covers the conductor adapter, mode→flag translation, migration warning, graceful fail when conductor isn't installed.

### Dependencies

- **Requires Conductor ≥ 0.2.** Touchstone 2.0 speaks `conductor exec --tools ... --sandbox ... --effort ...` — surface added in Conductor v0.2. Older Conductor versions don't support tool-using agent sessions.
- macOS / Linux supported.

---

Older releases tracked via git tags: v1.2.3, v1.2.2, v1.2.1, v1.2.0, v1.1.0, v1.0.
