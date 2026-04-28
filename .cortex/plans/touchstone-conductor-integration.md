---
Status: active
Written: 2026-04-21
Author: claude-code (ratified by human 2026-04-21 — "let's build it all. let it rip brother")
Goal-hash: t5c0nd02
Updated-by:
  - 2026-04-21T00:00 claude-code (created as additive v0.1 plan)
  - 2026-04-21T00:30 claude-code (rewritten as ideal-state plan per human direction — "I don't need a short-term version")
  - 2026-04-21T01:00 claude-code (added best-model preference — quality tiers + prefer axis — per human "always use the best model")
  - 2026-04-21T01:15 claude-code (added concierge init C8 per human "make sure that is an experience")
  - 2026-04-21T01:30 claude-code (added effort axis C-wide per human "claude to use max effort", confirmed global not per-provider)
  - 2026-04-21T01:45 claude-code (added C9 configurability + C10 auto-mode reliability per human "configurable + make auto-mode actually work")
  - 2026-04-21T02:00 claude-code (Status proposed → active; human gave full green-light to implement across the roadmap)
Cites: doctrine/0004-conductor-as-fourth-peer, doctrine/0003-llm-providers-compose-by-contract, plans/conductor-bootstrap, journal/2026-04-21-conductor-v0.1-shipped, journal/2026-04-21-touchstone-conductor-build-ratified
---

# Touchstone × Conductor integration — ideal-state plan

> Collapse Touchstone's four per-provider reviewer adapters into a single Conductor call. The division of labor lands where it belongs: **Touchstone owns review orchestration** (prompt construction, sentinel parsing, caching, cascade-for-unavailability, modes, timeouts); **Conductor owns LLM access** (auth, routing, capability matching, tool-use, streaming, cost reporting, provider-CLI quirks). The per-provider bash adapters (codex/claude/gemini/local) in `scripts/codex-review.sh:745-847` are deleted. Touchstone stops knowing the strings `--sandbox`, `--allowedTools`, `--yolo`.
>
> This is a multi-release program, not a single PR. It requires Conductor to grow a tool-using-agent surface (`conductor exec`) before Touchstone can migrate without losing fix/no-tests modes. The plan covers both sides.

## Why (grounding)

The present four-adapter design in `codex-review.sh:745-847` is a catalog of provider idiosyncrasies:

- **codex**: `--sandbox read-only|workspace-write` (binary switch; `diff-only` and `no-tests` can't be distinguished from `review-only` and `fix` respectively at enforcement level)
- **claude**: `--allowedTools Read,Grep,Glob,Bash,Edit,Write` (fine-grained; gold-standard)
- **gemini**: `--yolo` toggle only; `no-tests` silently degrades to `review-only`
- **local**: entirely different contract — prompt on stdin, custom context assembly, no tool model

Every one of these leaks a provider's CLI into Touchstone's bash. When the next provider ships (mistral, qwen, openai-o5), Touchstone grows a fifth adapter. When `codex exec` changes its sandbox flag names, Touchstone breaks.

This is precisely the duplication Doctrine 0004 committed to solving: **Conductor as the single owner of provider adapters, with a capability-contract interface**. v0.1 shipped that ownership for single-turn calls. The ideal end-state extends it to tool-using agent sessions and retires every downstream caller's per-provider code — starting with Touchstone, then Sentinel.

Grounds-in: Doctrine 0003 (provider-contract composition), Doctrine 0004 (Conductor as fourth peer).

## End state — what Touchstone looks like

### 1. One reviewer concept

```toml
# .codex-review.toml (new default, post-migration)

[review]
# `conductor` is the only reviewer. Config knobs influence routing,
# not provider selection at the adapter layer.
reviewer = "conductor"

[review.conductor]
# Which provider to pick. One of:
#   "best"     — prefer highest-quality-tier provider (frontier > strong > standard > local)
#   "cheapest" — minimize $/tok
#   "fastest"  — minimize p50 latency
#   "balanced" — pure tag-overlap match (today's v0.1 router behavior)
# Code review defaults to "best": reviewers should catch real issues,
# not optimize for pennies.
prefer = "best"

# How hard the chosen provider should think before answering. One of:
#   "minimal" | "low" | "medium" | "high" | "max"  (symbolic, Conductor translates per provider)
#   <integer>                                      (explicit thinking-token budget, power-user)
# Code review defaults to "max": when a reviewer is gating pushes,
# shallow reasoning is worse than a slower review. Providers without
# a thinking/reasoning mode (e.g., ollama base models) no-op this.
effort = "max"

tags = ["code-review"]

# Optional: force a specific provider. When set, uses `--with <id>`
# and bypasses auto-routing. Rarely needed — mostly for isolating
# a regression to one provider.
# with = "claude"

# Optional: exclude specific providers from auto-routing.
# Useful when one provider is degraded / rate-limited / expensive.
# exclude = ["gemini"]

[review.routing]
# Size-based overrides. Only Touchstone knows what a "large" diff is
# in this repo's terms, so size-to-routing lives here.
small_max_diff_lines = 50
small_prefer = "cheapest"                  # trivial changes: cheap + shallow
small_effort = "minimal"
small_tags   = ["code-review"]

# Above small_max_diff_lines but below large_max_diff_lines: use [review.conductor] defaults.

large_max_diff_lines = 1000
large_prefer = "best"
large_effort = "max"
large_tags   = ["code-review", "long-context"]

[review.assist]
# Peer review: ask Conductor for a second opinion, excluding
# the provider that answered the primary review.
enabled = true
timeout = 60
max_rounds = 1
```

The whole `reviewer_codex_*`, `reviewer_claude_*`, `reviewer_gemini_*`, `reviewer_local_*` apparatus in `codex-review.sh:745-847` — **deleted**. Replaced by one ~30-line adapter:

```bash
reviewer_conductor_available() { command -v conductor >/dev/null 2>&1; }

reviewer_conductor_auth_ok() {
  # Delegate to conductor. Any configured provider passes.
  conductor doctor --json 2>/dev/null \
    | grep -q '"configured"[[:space:]]*:[[:space:]]*true'
}

reviewer_conductor_exec() {
  local prompt="$1"
  local tools; tools=$(map_mode_to_tools "$REVIEW_MODE")
  local tags;  tags=$(compute_review_tags)      # base + routing enrichment
  local args=(--auto --tags "$tags" --tools "$tools" --sandbox "$REVIEW_MODE" \
              --timeout "${CODEX_REVIEW_TIMEOUT:-300}" --log-route)
  [ -n "${REVIEW_CONDUCTOR_WITH:-}" ] && args=(--with "$REVIEW_CONDUCTOR_WITH" "${args[@]#--auto}")
  [ -n "${REVIEW_CONDUCTOR_EXCLUDE:-}" ] && args+=(--exclude "$REVIEW_CONDUCTOR_EXCLUDE")
  printf '%s' "$prompt" | conductor exec "${args[@]}"
}
```

That is the entire provider-integration surface of Touchstone.

### 2. Capability-based mode mapping

Touchstone maps its modes to generic tool requirements, not provider flags:

| Touchstone mode | `--tools` passed to Conductor | `--sandbox` |
|---|---|---|
| `diff-only`   | `Read`                                   | `read-only` |
| `review-only` | `Read,Grep,Glob,Bash`                    | `read-only` |
| `no-tests`    | `Read,Grep,Glob,Edit,Write`              | `workspace-write` |
| `fix`         | `Read,Grep,Glob,Bash,Edit,Write`         | `workspace-write` |

Conductor's auto-router filters providers on declared tool-support capability before scoring. If `fix` is requested and only `kimi` is authed but `kimi` doesn't yet support tool-use, router errors cleanly with "no configured provider supports requested tools: Edit,Write" — Touchstone surfaces that per its `CODEX_REVIEW_ON_ERROR` policy.

Provider-specific translation (map `--tools Edit,Write` → `codex --sandbox workspace-write` vs `claude --allowedTools Edit,Write` vs `gemini --yolo`) lives inside Conductor. Touchstone neither knows nor cares.

### 3. Observability first-class

Every review produces a two-line summary written to stderr before the sentinel — the user sees *which* provider ran, *why*, and *how hard it thought*:

```
[conductor] auto (prefer=best, effort=max) → claude (tier: frontier · matched: code-review,tool-use)
            · 18.4s · 12,384 tok in · 42,102 tok thinking · 1,892 tok out · $0.0987 · sandbox=workspace-write
```

Thinking tokens are broken out separately because (a) they're billed on most frontier providers and (b) seeing a non-zero thinking count is the evidence that `effort=max` actually engaged the provider's reasoning mode — otherwise the config knob is unverifiable.

Exposed via Conductor's `--log-route` flag. Touchstone captures this into its pre-push transcript unchanged. This is **default behavior, not opt-in** — users always want to know which model reviewed their code, how hard it thought, and what it cost, so they can trust (or tune) the routing.

### 4. Cost budget enforcement

New config knob: `[review.conductor].max_cost_usd = 0.50` — if exceeded, pre-push blocks and prints the chosen provider + cost so the user can switch via `TOUCHSTONE_CONDUCTOR_WITH=ollama`. Requires Conductor to emit `cost_usd` (v0.1 does for HTTP providers; needs to be added for CLI shell-outs, best-effort via token counts).

### 5. `local` reviewer becomes a Conductor custom provider

The `[review.local]` TOML block and the `reviewer_local_*` 46-line adapter in `codex-review.sh:801-847` — gone. The user's custom command is registered once with Conductor:

```bash
conductor providers add --name my-local --shell 'my-reviewer-script %p' \
  --tags code-review,offline --accepts stdin
```

Then Touchstone uses `TOUCHSTONE_CONDUCTOR_WITH=my-local` (or tags-based routing) like any other provider. One code path instead of two.

## What Conductor must expose — required surface additions

Touchstone's end state depends on these landing first. Each is a real piece of Conductor work.

### C1. `conductor exec` — tool-using agent sessions

New top-level subcommand. Input: prompt (via `--task` or stdin). Output: the agent's final response (streamable). Flags:

```
conductor exec [--with ID | --auto] [--tags t1,t2]
               [--tools Read,Grep,Edit,...]
               [--sandbox read-only|workspace-write|none]
               [--cwd PATH]
               [--timeout SEC]
               [--exclude ID1,ID2]
               [--log-route]
               [--stream]
               [--json]
               [--task TEXT]
```

Semantics per provider type:

- **Shell-out providers (codex, claude, gemini):** Conductor owns the flag translation. `exec --tools Read,Grep --sandbox read-only` on `claude` becomes `claude -p --allowedTools Read,Grep --output-format text`. Same inputs on `codex` become `codex exec --sandbox read-only`. Conductor's adapter layer handles the dialect.
- **HTTP providers (kimi, ollama):** Conductor implements a tool-use loop. Receives model tool-calls, executes them (with sandbox enforcement: `read-only` blocks writes, `workspace-write` constrains to `--cwd` subtree), feeds results back, iterates to final response. This is real engineering — ~2 weeks of work, probably.
- **Custom providers (see C5):** pipe prompt to the user's shell command; tool-use not supported for stdin-style customs.

### C2. Provider capability declarations + quality tiers + effort mapping

Providers declare supported tools, capability tags, a quality tier, and an effort mapping:

```python
class ClaudeProvider:
    name = "claude"
    tags = ["strong-reasoning", "long-context", "code-review", "tool-use"]
    supported_tools = {"Read", "Grep", "Glob", "Bash", "Edit", "Write"}
    supported_sandboxes = {"read-only", "workspace-write"}
    quality_tier = "frontier"        # frontier | strong | standard | local
    cost_per_1k_in = 0.015           # for prefer=cheapest
    cost_per_1k_out = 0.075
    cost_per_1k_thinking = 0.015     # thinking tokens billed at input rate
    typical_p50_ms = 2400            # for prefer=fastest (measured, updated periodically)
    effort_map = {                   # symbolic effort → provider-native setting
        "minimal": "--thinking-budget 0",
        "low":     "--thinking-budget 2000",
        "medium":  "--thinking-budget 8000",
        "high":    "--thinking-budget 24000",
        "max":     "--thinking-budget 64000",
    }
    supports_effort = True
```

Providers without a thinking/reasoning mode (e.g., base ollama models) set `supports_effort = False`; requested effort is accepted but silently no-ops, and `conductor doctor` warns once at init so the user knows their `effort=max` isn't doing anything when ollama is picked.

Router pipeline:
1. **Filter** providers that can't satisfy the request: `supported_tools ⊇ requested_tools` AND `sandbox ∈ supported_sandboxes` AND `configured()` AND `id ∉ --exclude`.
2. **Score** surviving candidates per `--prefer` mode:
   - `best`: primary key = `quality_tier`, secondary = tag-overlap
   - `cheapest`: primary key = `cost_per_1k_in + cost_per_1k_out + cost_per_1k_thinking × expected_thinking_tokens(effort)`, secondary = quality_tier
   - `fastest`: primary key = `typical_p50_ms`, secondary = quality_tier
   - `balanced`: primary key = tag-overlap (today's v0.1 behavior)
3. **Break ties** via the existing DEFAULT_PRIORITY list.
4. **Apply effort** by translating the symbolic `--effort` level through the chosen provider's `effort_map`. If the provider doesn't support effort, log the no-op to the route line.
5. **Return** `(provider, RouteDecision)` — decision includes `prefer`, `effort`, chosen provider's `quality_tier`, and the scoring breakdown for observability.

**Cost scoring under `prefer=cheapest` with `effort=max` is important.** A frontier provider with max thinking can easily cost 10× a cheaper provider. The scoring must include expected thinking tokens, not just input+output — otherwise `prefer=cheapest` silently picks expensive effort.

Quality tiers are maintained in Conductor, not user-configurable. A `conductor providers show claude` command prints the current tier + justification. Tiers get updated on Conductor release when flagship models ship.

### C3. Route logging and JSON introspection

`--log-route` emits one structured line to stderr:

```
[conductor] route: provider=claude score=2 matched=[code-review,tool-use] duration_ms=4217 tokens_in=12384 tokens_out=1892 cost_usd=0.0341 sandbox=workspace-write
```

`--json` mode wraps this in the existing `CallResponse.route` field (v0.1 already has `RouteDecision`).

### C4. Exclusion flag for peer review

`--exclude ID1,ID2` tells the auto-router to skip listed providers. Enables Touchstone's `[review.assist]` peer feature: primary review picks via `--auto`, peer call passes `--exclude <primary_provider>`. Requires Touchstone to read the primary's `route` from its JSON output and pass it to the peer call.

### C5. Custom provider registration

`conductor providers add --name my-local --shell 'cmd %p' --tags offline --accepts stdin|argv` writes to a user-local providers config. Registry loader picks them up. This retires Touchstone's `[review.local]`.

### C6. Cost emission (input + thinking + output) for all providers

Shell-out CLIs (`codex exec`, `claude -p`, `gemini -p`) don't currently surface token counts to Conductor. Options: (a) parse CLI JSON output where available; (b) approximate via `tiktoken` on prompt + response text. Best-effort acceptable for input/output.

**Thinking-token accounting is not optional.** When `effort` is non-minimal, thinking tokens can dominate cost (10× the visible output on max-effort claude). Both the cost emission and the `cost_usd` sum must include thinking tokens — otherwise `max_cost_usd` budget gates leak and `prefer=cheapest` picks the wrong provider under high effort. For providers that don't expose a separate thinking-token count, estimate via response duration × typical thinking throughput for that effort level.

Enables Touchstone's `max_cost_usd` knob and correct cost scoring in the router.

### C7. Streaming

`--stream` emits incremental stdout. Lets Touchstone display "reviewer thinking…" to the user instead of a blocking spinner during long reviews. Not strictly blocking, but strongly improves UX; ships in the same release as the tool-use loop since both require touching the request path.

### C8. `conductor init` as a concierge, one provider at a time

The init wizard is the user's first contact with the garage. It must feel like a guided setup, not a status dump. Requirements:

**Flow shape:**
- Walks providers sequentially, one screen/section per provider.
- Each provider gets: short description (what it's for, quality tier, cost profile), explicit current status (CLI installed? authed? credentials present?), the **exact commands** to remediate (copy-pasteable — `brew install claude-code`, not "install the Claude CLI"), and an inline smoke test once the user says they're ready.
- For API-key providers: prompts for the credential, offers storage choice (Keychain / direnv / print-only), smoke-tests after storing.
- For CLI-wrapped providers that are missing the CLI: prints install commands for every supported install path (brew, npm, curl-pipe-sh) — not just one.
- For API-key providers with a credential source URL: includes the URL + menu path (e.g., "dash.cloudflare.com → My Profile → API Tokens → Workers AI: Read").

**Per-provider menu at every step:**
- `[t]` test now (I've done the setup)
- `[s]` skip this provider
- `[b]` back to previous provider
- `[q]` quit setup (preserves progress)
- For API-key providers: also `[k]/[d]/[e]` for storage choice

**Skip + resume:**
- Any provider can be skipped without blocking the others.
- `conductor init --only <name>` jumps straight to one provider's flow — used to resume after a skip.
- `conductor init --remaining` resumes with only the not-yet-configured providers.

**Closing summary:**
- Configured / skipped tally.
- Next-step pointers: `conductor list`, `conductor smoke --all`, `touchstone init`, `conductor init --only <skipped>`.
- States the default routing preference (`prefer=best`) and what it implies ("code review will try claude first, fall back to…").

**Failure handling:**
- If a smoke test fails after the user claims setup is done: show the actual error (stderr from the provider), offer `[r]etry`, `[t]roubleshoot` (prints common fixes for that provider), or `[s]kip`.
- Never wedges the user — every failure state has at least one forward path.

**Non-TTY behavior:**
- `--yes` / non-TTY inherits the current v0.1 behavior (report state, no prompts) so CI pipelines aren't broken.
- `--interactive` is the new explicit flag for the concierge flow (default when TTY is detected).

**Why this is in the Touchstone plan:** Touchstone users hit this wizard when they first install Conductor as a dependency. A frictional init directly translates to Touchstone looking broken — "I installed touchstone and now my pushes fail because no providers are configured." The concierge flow is the thing that makes the single-auth story land. Without it, the whole "authenticate once" pitch is hollow.

### C9. Configurability, verified

The config surface (`prefer` / `effort` / `tags` / `with` / `exclude` / size-routing) is only useful if users can trust it does what they asked. Three pieces:

**Validation.** Every field has a known-value enum or type. Typos fail loudly at load time with a fix-it hint:

```
$ git push
touchstone: pre-push review
conductor: config error in .codex-review.toml
  [review.conductor].prefer = "beast"
                             ^^^^^^^
  unknown value. Valid: "best" | "cheapest" | "fastest" | "balanced".
  Did you mean "best"?
```

Validation also catches invalid combinations: `with = "claude"` + `exclude = ["claude"]` is a contradiction; `effort = 999999` exceeds the highest supported budget across providers; `tags = ["code-revew"]` (typo) produces a warning because no provider matches.

**Effective-config inspection.**

```
$ conductor config show                    # resolved config after env+repo+global merge
prefer:  best           (from .codex-review.toml)
effort:  max            (from .codex-review.toml)
tags:    code-review    (from .codex-review.toml)
with:    <unset>
exclude: []
—————
Env overrides in effect:
  TOUCHSTONE_CONDUCTOR_WITH=codex  (overrides `with`)
```

Shows where each value came from (repo config / user defaults / env var / Conductor default) so "why didn't my change take effect?" has an immediate answer.

**Dry-run routing.**

```
$ conductor route --tags code-review --prefer best --effort max --tools Read,Grep,Edit
→ would pick: claude
  tier: frontier, matched tags: [code-review], effort translates to --thinking-budget 64000
  candidates considered: claude, codex, kimi
  candidates skipped:    gemini (not configured), ollama (no tool-use support)
  estimated cost: $0.03–$0.12 depending on diff size
```

Lets users sanity-check "what will happen next push" without committing to a review run. Touchstone exposes this as `touchstone review --dry-run`.

**Env-var parity.** Every config knob has a matching env var. Precedence: env > repo-config > user-defaults > Conductor-default. Documented in one place (`conductor config --help`), not scattered.

### C10. Auto-mode reliability

For `reviewer = "conductor"` to be trusted as default, the router has to degrade gracefully and be introspectable. Four pieces beyond the v0.1 "tag count + alphabetical" behavior:

**Health tracking.** Conductor keeps a per-provider rolling window (last ~20 calls) with outcomes: success, rate-limit (429), timeout, upstream-5xx, auth-fail. Router filters providers with recent hard failures:

- Rate-limited in the last 60s → skip (assume cooldown).
- Auth failed on last call → skip (credentials went bad; surface in doctor).
- Timeout + 5xx combined >30% in last window → deprioritize (push to end of ranking, don't hard-skip).

Health is session-local at first (forgotten between runs) — no persistent state file in v1 to keep things simple. Upgrade to a small state cache later if needed.

**Deterministic, explainable scoring.** The router emits a RouteDecision every call that shows the full ranking, not just the winner:

```
[conductor] route decision (prefer=best, effort=max):
  1. claude    (score: tier=frontier[4] tags=+2 health=ok)   ← picked
  2. codex     (score: tier=frontier[4] tags=+2 health=ok)   tiebreak: DEFAULT_PRIORITY
  3. kimi      (score: tier=strong[3]   tags=+2 health=ok)
  4. ollama    (score: tier=local[1]    tags=+1 health=ok)
  5. gemini    (skipped: not configured)
  6. mistral   (skipped: rate-limited 34s ago)
```

Always computed, emitted with `--log-route --verbose` (or always in `--json` mode). Makes "why did it pick claude over codex?" a 2-second read.

**Graceful degradation on primary failure.** If the chosen provider fails mid-call (not pre-call — health filter handles pre-call), Conductor retries once with the next-ranked provider, logs the fallback, returns the second provider's response with a note. Touchstone shows this:

```
[conductor] auto (prefer=best, effort=max) → claude (tier: frontier)
  reviewing... claude returned 529 (overloaded) · falling back
  [conductor] → codex (tier: frontier)  ← fallback
  reviewing... ████████  3.8s
```

Caller (Touchstone) doesn't see the failure as an error. One automatic retry with a different provider; beyond that, error propagates.

**Override-feedback loop (soft).** If a user repeatedly sets `TOUCHSTONE_CONDUCTOR_WITH=codex` after auto picked claude, that's signal the defaults are wrong for them. v1 doesn't learn (no persistent state), but `conductor doctor` can surface: "In the last 20 reviews, you overrode the auto choice 14 times to pick `codex`. Consider setting `with = \"codex\"` in `.codex-review.toml`." Optional, off by default, opt-in.

**What's out of scope for v1 of auto-mode reliability:** persistent cross-session health state; actual quality benchmarking of providers (tiers are Conductor-maintained declarations, not measured); ML-based routing; learned user preferences. These are v2+ items. The v1 goal is "auto-mode is good enough that users don't reach for `--with` every push."

## Sequencing

Five stages, each a coherent release. Each stage is shippable in isolation — the chain stops at any stage and leaves the system in a good state.

### Stage 1 — Conductor v0.2: `exec` for shell-out providers only (~1 sprint)

Ship C1 for codex/claude/gemini (the three that already have native agent CLIs). C2, C3, C4 land with this. C6 via best-effort. Kimi and ollama return `UnsupportedCapability` on tool-use requests — explicit, not silent.

Test: `conductor exec --with claude --tools Read,Grep --sandbox read-only --task "hello"` produces the same result as direct `claude -p --allowedTools Read,Grep "hello"`. Parity across the three shell-out providers.

### Stage 2 — Touchstone migration PR (~3 days)

Blocked on Stage 1. Single PR to `autumngarage/touchstone`:

- Delete `reviewer_codex_*`, `reviewer_claude_*`, `reviewer_gemini_*` in `codex-review.sh:745-799`.
- Delete `reviewer_local_*` and `build_local_reviewer_prompt` in `codex-review.sh:801-847` (with migration warning — see below).
- Add single `reviewer_conductor_*` trio (~30 lines).
- Rewrite config parsing: `[review].reviewers` array → `[review].reviewer` scalar (always `"conductor"`); add `[review.conductor]` and `[review.routing]` (latter is capability-tag enrichment, not provider cascade).
- Migration in `codex-review.sh` startup: if legacy `[review].reviewers` array is detected, print a one-time migration hint and auto-translate (first entry → `reviewer = "conductor"`, warn if it was "local" that user needs to run `conductor providers add`).
- Update `tests/test-review-hook.sh` and friends. Replace 4× mock-binary tests with 1× mock-`conductor` (simpler).
- Bump `VERSION` 1.2.3 → **2.0.0** (breaking config change).
- CHANGELOG migration guide.

Post-merge: autumn-mail and sigint repos need `touchstone update` + config migration run. Autumn-garage journal entry per T1.9.

### Stage 3 — Conductor v0.3: HTTP-side tool-use (~2 sprints)

Ship the real work: a tool-use loop for HTTP providers (kimi, ollama). OpenAI-compatible function-calling schema. Sandbox enforcement (a subprocess or chroot for `workspace-write`; strict path allowlists). This is where the complexity lives — scope for a dedicated plan.

Post-Stage 3, Touchstone's `fix` mode on a Kimi-only install works. The auto-router stops having to filter kimi/ollama out of tool-using requests.

### Stage 4 — Conductor v0.4: streaming, cost precision, budgets (~1 sprint)

Ship C7 (streaming) and tighten C6 (real token counts for shell-outs via output parsing, not estimation). Touchstone picks up `[review.conductor].max_cost_usd` enforcement.

### Stage 5 — Retire the dogfood bifurcation (concurrent with Stage 4)

Sentinel migrates in parallel via its own plan (replaces `src/sentinel/providers/*.py` with `conductor exec` subprocess calls). Once both Touchstone and Sentinel are on Conductor, the garage has exactly one provider-owning codebase. That's the point.

## Success criteria

1. **Touchstone has zero strings `--sandbox`, `--allowedTools`, `--yolo` in source.** Grep-verifiable.
2. **Adding a new provider (e.g., mistral) requires changes to Conductor only.** Touchstone binary/config unchanged. Demonstrable by shipping a mistral adapter and having it work in Touchstone on first `conductor doctor` authenticate.
3. **All four modes (diff-only, review-only, no-tests, fix) work on all five providers** where capabilities permit, with consistent tool-enforcement semantics across providers. No more "gemini no-tests degrades to review-only" silent drift.
4. **Observability parity.** Every review shows provider, cost, tokens, duration in the push transcript. Works identically for all providers.
5. **Peer review uses exclusion.** Primary and peer are guaranteed to be different providers. Verifiable by test: primary forced to `claude`, peer must not be `claude`.
6. **Cost-budget blocks correctly.** A mock `conductor exec` reporting `cost_usd=1.00` with `max_cost_usd=0.50` aborts the push.
7. **Legacy config auto-migrates.** A `.codex-review.toml` with the pre-2.0 `[review].reviewers = ["codex","claude"]` produces a warning + clean translation, not a parse error.
8. **Custom reviewer survives migration.** Users with `[review.local].command = "..."` get migrated via a `conductor providers add` one-liner, fully documented.

## Risks & open questions

### R1 — Conductor v0.3 tool-use loop is genuinely hard

HTTP-side tool use requires: OpenAI-schema translation, per-model schema differences (Kimi vs OpenAI function-calling vary), tool execution in a sandbox (process isolation, path allowlists), iteration until model returns a final message, context-window budget management across turns. **This is the single largest engineering cost in the entire plan** — probably 50% of total effort. Worth a dedicated plan before Stage 3 kicks off.

### R2 — `codex exec --ephemeral` vs `claude -p` vs `gemini -p` semantics differ

Even wrapping them, the three shell-outs behave subtly differently: codex's `workspace-write` allows arbitrary shell commands; claude's `--allowedTools Edit,Write` does not include Bash; gemini's `--yolo` is all-or-nothing. "Same tools" in our abstraction will produce different *behavior* across providers. This is inherent to multi-provider routing and won't fully go away — but Conductor can surface the translation matrix in `conductor doctor --explain-tools` so users see what they're getting.

### R3 — Breaking config change stings users

Stage 2 is Touchstone 2.0.0. Every existing user's `.codex-review.toml` needs migration. Auto-migration helps but isn't zero-friction. Consider: keep parsing the old format for a full 1.x release cycle while emitting deprecation warnings, *then* ship 2.0.0 as pure removal. Adds ~1 sprint to the timeline but removes the cliff.

### R4 — Loss of "reviewer cascade" as user concept

Pre-migration users can write `reviewers = ["claude", "codex"]` and intuitively know "try claude, then codex." Post-migration, cascade-for-unavailability lives inside Conductor's auto-router and is invisible. Users who liked the explicit cascade may miss it. Mitigation: `conductor doctor --explain-routing --tags code-review` prints the deterministic order, making the invisible visible on demand.

### R5 — `conductor exec` vs `conductor call` schism

Two subcommands risks confusion. Alternative: unify under `conductor call`, infer mode from presence/absence of `--tools`. Cleaner surface but less self-documenting. Defer the naming call to when C1 is actually implemented.

### Q1 — Sandbox enforcement for HTTP providers: subprocess or library-level?

A tool-use loop running in-process has attack-surface implications (a malicious model could try to read env vars, etc.). Spawning a subprocess with ulimit + path restrictions is safer but slower. Likely need both: a `--sandbox strict` (subprocess) vs `--sandbox cooperative` (in-process). Decide in the Stage 3 design doc.

### Q2 — Who owns the prompt template?

Touchstone builds the review prompt (AGENTS.md + commits + diff + sentinel instruction) at `codex-review.sh:1139-1185`. That stays in Touchstone — it's review-specific and Conductor has no business knowing about it. But local's custom prompt assembly (`build_local_reviewer_prompt` at `codex-review.sh:818-841`) is interesting: it wraps the base prompt with stdin-specific framing. Post-migration, is that wrapping still Touchstone's job, or does it move to the Conductor custom-provider definition? Probably Touchstone (it's a review semantic, not an LLM-access semantic). Confirm in Stage 2 design.

## Out of scope (explicitly)

- **Changing Touchstone's sentinel contract** (`CODEX_REVIEW_CLEAN|FIXED|BLOCKED`). Remains as-is.
- **Touchstone's review cache, timeout, peer-assist orchestration machinery.** All stays Touchstone-side. Only the LLM-invocation adapter changes.
- **Sentinel migration.** Separate plan. Almost certainly lands at Stage 5 (post-tool-use) because Sentinel's coder role needs the tool-use loop working for HTTP providers.
- **Cortex integration with Conductor.** Separate question; Cortex is read-heavy and doesn't route LLM calls today.
- **Brew tap for Conductor.** Separate plan; blocking distribution, not this integration.

## Effort estimate

Total: ~8 weeks of focused work across the two repos, assuming one engineer mostly-dedicated.

- Stage 1 (Conductor v0.2 exec, shell-outs): 2 weeks
- Stage 2 (Touchstone migration): 3 days
- Stage 3 (Conductor v0.3 HTTP tool-use): 4 weeks  ← the real cost
- Stage 4 (Conductor v0.4 polish): 1 week
- Migration support + user hand-holding: ~0.5 week

Most of the value lands at end of Stage 2 (Touchstone gets simpler, auth consolidates, observability arrives). Stages 3–4 unlock the "works with every provider, not just shell-outs" story. If we only ever shipped Stages 1–2 we'd still have won — the Touchstone side is clean, users authenticate once, the idiosyncrasy moves to the right place. Stage 3 is the investment that lets the whole garage converge.
