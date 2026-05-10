# AI Review Hook

Reviews your code with an AI reviewer before it reaches the default branch. Normal feature-branch pushes stay fast; review runs from `scripts/merge-pr.sh` and from the pre-push hook only when pushing directly to the default branch.

Touchstone 2.0 delegates all LLM access to [Conductor](https://github.com/autumngarage/conductor). The hook declares *what it needs* (review mode → tool access, effort budget, routing preference) and Conductor picks *how* to satisfy it (provider, model, auth, cost tracking, provider permissions).

## Setup

### 1. Install Conductor

```bash
brew install autumngarage/conductor/conductor
conductor init          # guided provider setup (auth, model defaults)
conductor doctor        # confirm at least one provider is ready
```

A Touchstone review needs exactly one configured provider. `conductor list` shows which ones are ready, which are missing credentials, and which can't satisfy the requested tool set.

### 2. Install pre-commit

```bash
brew install pre-commit
# or: python3 -m pip install --user pre-commit
```

### 3. Wire the hook

Touchstone's `.pre-commit-config.yaml` template already includes the AI review hook. Install:

```bash
pre-commit install --install-hooks
```

### 4. Configure per-project behavior (optional)

The defaults in `.codex-review.toml` (written by `touchstone init`) work for most projects:

```toml
[review]
reviewer = "conductor"      # the only supported value in 2.0

[review.conductor]
prefer = "best"             # best | cheapest | fastest | balanced
effort = "high"             # minimal | low | medium | high | max | <int tokens>
tags   = "code-review"
with = "openrouter"         # hosted default for live review
exclude = ["ollama"]        # keep local providers out of hosted merge gates
```

### 5. Write your review rubric

Fill in `AGENTS.md` at the repo root with your project-specific coding-agent guidance and review priorities. The hook tells the reviewer to use the Review Guide section as the rubric. See `templates/AGENTS.md` for the skeleton.

## How it works

When the review runs, the hook:

1. Computes the diff between your branch and the default branch
2. Chooses prompt context: small/simple diffs use a bounded rubric, while large, broad, high-risk, architectural, or configured paths keep full `AGENTS.md`/`CLAUDE.md` context
3. Skips review if the exact same diff and review inputs already passed cleanly (cache key includes the Conductor knobs and prompt context mode, so changing `prefer`/`effort`/`with` or context mode invalidates)
4. Invokes Conductor with the review prompt and requested tool set
5. Reads one of three sentinels from the reviewer's output:
   - `CODEX_REVIEW_CLEAN` — no issues, push proceeds
   - `CODEX_REVIEW_FIXED` — the reviewer applied auto-fixes; the hook commits them and re-reviews
   - `CODEX_REVIEW_BLOCKED` — the reviewer found issues it won't auto-fix; push is blocked
6. The loop repeats up to `max_iterations` times (default 3)

Conductor logs its route decision (provider, cost estimate, token count, wall-clock time) into the review transcript.

## Configuration reference

| Setting | Default | Description |
|---------|---------|-------------|
| `max_iterations` | 3 | Max review-fix-review loops before aborting |
| `max_diff_lines` | 5000 | Skip review if diff exceeds this |
| `cache_clean_reviews` | true | Cache clean reviews under `.git/` to skip repeat calls on the same diff |
| `safe_by_default` | false | Whether unlisted paths allow auto-fix |
| `unsafe_paths` | [] | Paths where auto-fix is never allowed |
| `[review].enabled` | true | Set false to skip AI review without removing the hook |
| `[review].reviewer` | `"conductor"` | The only supported value in 2.0 |
| `[review.conductor].prefer` | size-aware | `best` \| `cheapest` \| `fastest` \| `balanced`; used as a global fallback, but default size routing applies per bucket |
| `[review.conductor].effort` | size-aware | `minimal` \| `low` \| `medium` \| `high` \| `max` \| integer thinking-token budget; used as a global fallback, but default size routing applies per bucket |
| `[review.conductor].tags` | `"code-review"` | Capability tags passed to the router |
| `[review.conductor].with` | `"openrouter"` in newly bootstrapped projects; unset otherwise | Pin a specific provider (bypasses auto-routing) |
| `[review.conductor].exclude` | `["ollama"]` | Exclude providers from hosted auto-routing; use explicit all-local/offline review for Ollama |
| `[review.routing].enabled` | true | Route by diff size |
| `[review.routing].small_max_diff_lines` | 400 | Diffs ≤ this use the `small_*` knobs unless high-risk paths are touched |
| `[review.routing].small_prefer` | `"cheapest"` | Routing preference for small diffs |
| `[review.routing].small_effort` | `"minimal"` | Thinking effort for small diffs |
| `[review.routing].small_with` | unset | Pin provider for small diffs |
| `[review.routing].small_tags` | unset | e.g. `"code-review"` for small diffs |
| `[review.routing].large_prefer` | `"best"` | Routing preference for larger low-risk diffs |
| `[review.routing].large_effort` | `"medium"` | Thinking effort for larger low-risk diffs |
| `[review.routing].large_with` | unset | Pin provider for larger low-risk diffs |
| `[review.routing].large_tags` | unset | e.g. `"code-review,long-context"` for larger low-risk diffs |
| `[review.routing].high_risk_prefer` | `"best"` | Routing preference when unsafe or architectural paths are touched |
| `[review.routing].high_risk_effort` | `"high"` | Thinking effort when unsafe or architectural paths are touched |
| `[review.routing].high_risk_with` | unset | Pin provider when unsafe, architectural, or configured full-context paths are touched |
| `[review.routing].high_risk_tags` | unset | e.g. `"code-review,long-context"` for high-risk diffs |
| `[review.context].mode` | `"auto"` | `auto` prunes low-risk diffs; `full` always loads full project context |
| `[review.context].small_max_diff_lines` | 400 | Max diff lines for bounded prompt context |
| `[review.context].small_max_files` | 4 | Max changed files for bounded prompt context |
| `[review.context].full_context_paths` | [] | Extra path patterns that always require full `AGENTS.md`/`CLAUDE.md` context |

Routing uses a single cutoff (`small_max_diff_lines`) plus path risk. Diffs at or below the cutoff use the `small_*` bucket unless they touch `unsafe_paths`, built-in architectural paths, or configured `full_context_paths`; those use `high_risk_*`. Diffs above the cutoff use `large_*` only when they are low-risk. The default route is `cheapest`/`minimal` for small low-risk diffs, `best`/`medium` for larger low-risk diffs, and `best`/`high` for high-risk diffs. There is no separate `large_max_diff_lines`. Use `TOUCHSTONE_CONDUCTOR_EFFORT=max` when release-level scrutiny is worth the extra latency. Explicit `TOUCHSTONE_CONDUCTOR_*` environment variables still win over bucket defaults.

Prompt-context pruning is separate from provider routing, but uses the same path-risk checks. In `auto` mode, the hook uses bounded context for low-risk diffs, including large or broad diffs, and uses full context for `unsafe_paths`, built-in architectural files, and configured `full_context_paths`. The prompt states when full context was intentionally omitted and why.

### Retired in 2.0

`[review].reviewers = [...]` cascade, `[review.local]`, `[review.assist]`, `[review.routing].small_reviewers/large_reviewers`. Legacy configs auto-migrate at push time with a one-time hint. Run `touchstone migrate-review-config` to silence the hint and rewrite your file in place. `[review.assist]` (peer second-opinion) returns in 2.1 via `conductor call --exclude <primary>`.

## Environment overrides

| Variable | Description |
|----------|-------------|
| `CODEX_REVIEW_ENABLED` | Overrides `[review].enabled` |
| `CODEX_REVIEW_BASE` | Base ref to diff against (default: `origin/<default-branch>`) |
| `CODEX_REVIEW_MODE` | Override review mode: `fix` \| `review-only` \| `diff-only` \| `no-tests` |
| `CODEX_REVIEW_MAX_ITERATIONS` | Overrides `max_iterations` |
| `CODEX_REVIEW_MAX_DIFF_LINES` | Overrides `max_diff_lines` |
| `CODEX_REVIEW_CACHE_CLEAN` | Overrides `cache_clean_reviews` |
| `CODEX_REVIEW_DISABLE_CACHE` | `1` forces a fresh review for one push |
| `CODEX_REVIEW_FORCE` | `1` runs on feature-branch pushes too |
| `CODEX_REVIEW_NO_AUTOFIX` | `1` switches to `review-only` mode for one run |
| `CODEX_REVIEW_ON_ERROR` | `fail-open` (default) \| `fail-closed` |
| `CODEX_REVIEW_TIMEOUT` | Wall-clock timeout per reviewer invocation (seconds) |
| `CODEX_REVIEW_CONTEXT_MODE` | Override prompt context mode: `auto` \| `full` \| `bounded` |
| `CODEX_REVIEW_CONTEXT_SMALL_MAX_DIFF_LINES` | Override bounded-context diff line cap |
| `CODEX_REVIEW_CONTEXT_SMALL_MAX_FILES` | Override bounded-context changed-file cap |
| `CODEX_REVIEW_SUPPRESS_LEGACY_WARNINGS` | `1` silences the one-time 1.x → 2.0 migration hint |
| `TOUCHSTONE_CONDUCTOR_WITH` | Pin Conductor to a specific provider |
| `TOUCHSTONE_CONDUCTOR_PREFER` | Override `[review.conductor].prefer` |
| `TOUCHSTONE_CONDUCTOR_EFFORT` | Override `[review.conductor].effort` |
| `TOUCHSTONE_CONDUCTOR_TAGS` | Override `[review.conductor].tags` |
| `TOUCHSTONE_CONDUCTOR_EXCLUDE` | Override `[review.conductor].exclude` |
| `TOUCHSTONE_REVIEWER` | Deprecated in 2.0 — auto-translates to `TOUCHSTONE_CONDUCTOR_WITH=<provider>` with a one-time hint |

## Graceful behavior

- If AI review is disabled: skips review, push proceeds
- If the `conductor` CLI is missing: prints `brew install …` + `conductor init` hints, skips review, push proceeds
- If Conductor is installed but no provider is configured: prints `conductor doctor` + `conductor init` hints, skips review, push proceeds
- If pushing a feature branch: skips review, push proceeds
- If Conductor fails (network, quota, provider permission denial): skips review per `on_error = "fail-open"` (default); set `fail-closed` to block instead
- If diff exceeds `max_diff_lines`: skips review, push proceeds
- If the exact diff and review inputs already passed cleanly: skips repeat review, push proceeds
- If reviewer output doesn't match the sentinel contract: skips review, push proceeds
- If `.codex-review.toml` is missing: all paths treated as unsafe (no auto-fix)

The hook's default is fail-open on infrastructure errors and block on actual review findings. Flip to `fail-closed` in CI or for strict review gates.

## Preview without spending tokens

```bash
touchstone review --dry-run
```

Shows which provider auto-routing would pick for the next push, the route ranking, and tool set — no upstream calls made. Touchstone does not send Conductor a sandbox flag; Conductor derives provider permission behavior from the requested tools.

## Emergency bypass

```bash
git push --no-verify
SKIP_CODEX_REVIEW=1 bash scripts/merge-pr.sh <pr-number>
```

The next PR should include an "Emergency-bypass disclosure" section.
