# Codex Pre-Push Review Hook

Automatically reviews your code with [Codex](https://github.com/openai/codex) before every push. Can auto-fix safe issues (typos, missing error logging, etc.) and blocks the push for unsafe findings.

## Setup

### 1. Install Codex CLI

```bash
npm install -g @openai/codex
codex login
```

### 2. Install pre-commit

```bash
brew install pre-commit
# or: python3 -m pip install --user pre-commit
```

### 3. Wire the hook

The toolkit's `.pre-commit-config.yaml` template already includes the Codex hook. Just install the hooks:

```bash
pre-commit install --install-hooks
```

For Python test hooks, prefer the toolkit wrapper over `python3 -m pytest` so the hook uses the project's virtualenv:

```yaml
entry: /usr/bin/env bash scripts/run-pytest-in-venv.sh tests/
```

### 4. Configure per-project behavior

Copy or edit `.codex-review.toml` at your repo root:

```bash
cp .codex-review.toml.example .codex-review.toml
# Edit unsafe_paths, safe_by_default, max_iterations as needed
```

### 5. Write your review rubric

Fill in `AGENTS.md` at the repo root with your project-specific review priorities. The hook tells Codex to read this file for the review rubric. See `templates/AGENTS.md` for the skeleton.

## How it works

On every `git push`, the pre-push hook:

1. Computes the diff between your branch and the default branch
2. Sends the diff to Codex with the review prompt + your AGENTS.md rubric
3. Codex reviews and outputs one of three sentinels:
   - `CODEX_REVIEW_CLEAN` — no issues, push proceeds
   - `CODEX_REVIEW_FIXED` — Codex applied auto-fixes, the hook commits them and re-reviews
   - `CODEX_REVIEW_BLOCKED` — Codex found issues it won't auto-fix, push is blocked
4. The loop repeats up to `max_iterations` times (default 3)

## Configuration reference

| Setting | Default | Description |
|---------|---------|-------------|
| `max_iterations` | 3 | Max review-fix-review loops before aborting |
| `max_diff_lines` | 5000 | Skip review if diff exceeds this |
| `safe_by_default` | false | Whether unlisted paths allow auto-fix |
| `unsafe_paths` | [] | Paths where auto-fix is never allowed |

## Environment overrides

| Variable | Description |
|----------|-------------|
| `CODEX_REVIEW_BASE` | Base ref to diff against (default: `origin/<default-branch>`) |
| `CODEX_REVIEW_MAX_ITERATIONS` | Overrides config file's `max_iterations` |
| `CODEX_REVIEW_MAX_DIFF_LINES` | Overrides config file's `max_diff_lines` |

## Graceful behavior

- If Codex CLI is not installed: skips review, push proceeds
- If `codex exec` fails (network, auth, quota): skips review, push proceeds
- If diff exceeds `max_diff_lines`: skips review, push proceeds
- If Codex output doesn't match the sentinel contract: skips review, push proceeds
- If `.codex-review.toml` is missing: all paths treated as unsafe (no auto-fix)

The hook never blocks a push for infrastructure reasons — only for actual code review findings.

## Emergency bypass

```bash
git push --no-verify
```

The next PR should include an "Emergency-bypass disclosure" section.
