# AI Review Hook

Reviews your code with the configured AI reviewer before it reaches the default branch. Normal feature-branch pushes stay fast; review runs from `scripts/merge-pr.sh` and from the pre-push hook only when pushing directly to the default branch.

## Setup

### 1. Pick a reviewer

Run `toolkit new` or `toolkit init` interactively and answer the AI review prompts. You can choose:
- `codex` — default, and `setup.sh` can install it if `npm` is available
- `claude` — use an existing Claude CLI install
- `gemini` — use an existing Gemini CLI install
- `local` — use a local model or wrapper command that reads the review prompt from stdin
- `none` — leave the review hook installed but disabled

Edit `.codex-review.toml` later if you change your mind.

### 2. Install pre-commit

```bash
brew install pre-commit
# or: python3 -m pip install --user pre-commit
```

### 3. Wire the hook

The toolkit's `.pre-commit-config.yaml` template already includes the AI review hook. Just install the hooks:

```bash
pre-commit install --install-hooks
```

For project validation, prefer the toolkit runner so hooks use the repo's `.toolkit-config` profile instead of hardcoding an ecosystem command:

```yaml
entry: /usr/bin/env bash scripts/toolkit-run.sh validate
```

### 4. Configure per-project behavior

Copy or edit `.codex-review.toml` at your repo root:

```bash
cp .codex-review.toml.example .codex-review.toml
# Edit reviewers, unsafe_paths, safe_by_default, max_iterations as needed
```

### 5. Write your review rubric

Fill in `AGENTS.md` at the repo root with your project-specific review priorities. The hook tells the reviewer to read this file for the review rubric. See `templates/AGENTS.md` for the skeleton.

## How it works

When the review runs, the hook:

1. Computes the diff between your branch and the default branch
2. Skips review if the exact same diff and review inputs already passed cleanly
3. Sends the diff to the selected reviewer with the review prompt + your AGENTS.md rubric
4. If peer assistance is enabled and the primary reviewer asks for help on a larger change, the hook asks one helper reviewer for a read-only second opinion
5. The reviewer outputs one of three sentinels:
   - `CODEX_REVIEW_CLEAN` — no issues, operation proceeds
   - `CODEX_REVIEW_FIXED` — the reviewer applied auto-fixes, the hook commits them and re-reviews
   - `CODEX_REVIEW_BLOCKED` — the reviewer found issues it won't auto-fix, push is blocked
6. The loop repeats up to `max_iterations` times (default 3)

## Configuration reference

| Setting | Default | Description |
|---------|---------|-------------|
| `max_iterations` | 3 | Max review-fix-review loops before aborting |
| `max_diff_lines` | 5000 | Skip review if diff exceeds this |
| `cache_clean_reviews` | true | Cache exact-input clean reviews under `.git/` to avoid repeat Codex calls |
| `safe_by_default` | false | Whether unlisted paths allow auto-fix |
| `unsafe_paths` | [] | Paths where auto-fix is never allowed |
| `[review].enabled` | true | Set false to skip AI review without removing the hook |
| `[review].reviewers` | `["codex"]` | Reviewer cascade, e.g. `["claude", "codex", "gemini", "local"]` |
| `[review.local].command` | empty | Local reviewer command; receives the prompt on stdin |
| `[review.local].auth_command` | empty | Optional local command that must pass before review runs |
| `[review.assist].enabled` | false | Allow the primary reviewer to request one peer second opinion |
| `[review.assist].helpers` | `["codex", "gemini", "claude"]` | Helper reviewers to try, skipping the active primary reviewer |
| `[review.assist].timeout` | 60 | Timeout in seconds for the helper reviewer |
| `[review.assist].max_rounds` | 1 | Max helper calls per review run |

## Environment overrides

| Variable | Description |
|----------|-------------|
| `CODEX_REVIEW_ENABLED` | Overrides `[review].enabled` |
| `CODEX_REVIEW_BASE` | Base ref to diff against (default: `origin/<default-branch>`) |
| `CODEX_REVIEW_MAX_ITERATIONS` | Overrides config file's `max_iterations` |
| `CODEX_REVIEW_MAX_DIFF_LINES` | Overrides config file's `max_diff_lines` |
| `CODEX_REVIEW_CACHE_CLEAN` | Overrides `cache_clean_reviews` |
| `CODEX_REVIEW_DISABLE_CACHE` | Set to `1`/`true` to force a fresh Codex review |
| `CODEX_REVIEW_FORCE` | Set to `1`/`true` to run on non-default-branch pushes |
| `CODEX_REVIEW_NO_AUTOFIX` | Set to `1`/`true` for review-only mode |
| `CODEX_REVIEW_ASSIST` | Set to `1`/`true` to allow peer assistance for one run |
| `CODEX_REVIEW_ASSIST_TIMEOUT` | Overrides helper reviewer timeout |
| `CODEX_REVIEW_ASSIST_MAX_ROUNDS` | Overrides max helper calls per review run |
| `TOOLKIT_LOCAL_REVIEWER_COMMAND` | Overrides `[review.local].command` |
| `TOOLKIT_LOCAL_REVIEWER_AUTH_COMMAND` | Overrides `[review.local].auth_command` |

## Graceful behavior

- If AI review is disabled: skips review, operation proceeds
- If no configured reviewer is installed/authenticated: skips review, operation proceeds
- If pushing a feature branch: skips review, push proceeds
- If a reviewer fails (network, auth, quota, local command error): skips review, operation proceeds
- If diff exceeds `max_diff_lines`: skips review, operation proceeds
- If the exact diff and review inputs already passed cleanly: skips repeat review, operation proceeds
- If reviewer output doesn't match the sentinel contract: skips review, push proceeds
- If `.codex-review.toml` is missing: all paths treated as unsafe (no auto-fix)

The hook never blocks a push for infrastructure reasons — only for actual code review findings.

## Emergency bypass

```bash
git push --no-verify
SKIP_CODEX_REVIEW=1 bash scripts/merge-pr.sh <pr-number>
```

The next PR should include an "Emergency-bypass disclosure" section.
