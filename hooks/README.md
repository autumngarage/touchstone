# Touchstone Hooks

Touchstone's local hooks are deterministic. Semantic review happens visibly on
the GitHub pull request and is enforced by `scripts/open-pr.sh` and
`scripts/merge-pr.sh`.

## Local Gates

Fresh projects install:

- `no-commit-to-branch` to prevent commits on `main` or `master`
- `branch-naming` to enforce short-lived branch naming
- `touchstone-validate` to run the project profile's deterministic checks
- standard formatting, secret, and conflict checks

Feature-branch pushes do not run a local LLM review. This keeps pushes fast,
avoids hidden model spend, and leaves semantic findings on the PR where they can
be audited and addressed.

## PR Review

`.touchstone-review.toml` owns the review policy:

```toml
[review]
preflight_required = true

[review.pr_triggered]
required = true
provider = "github-codex"
request_on_push = true
timeout_sec = 1800
poll_sec = 10
trusted_review_authors = ["chatgpt-codex-connector", "chatgpt-codex-connector[bot]"]
```

`open-pr.sh --draft` creates or updates a review-free coordination surface.
Final shipping posts one `@codex review` request per ready head and records
durable request evidence bound to the full head and base revisions.
`merge-pr.sh` waits for a trusted result, rejects stale or ambiguous review
state, runs deterministic preflight, and revalidates the exact revision before
merge.

Review findings are addressed by the driving CLI in normal commits. Every new
head entering final shipping requires a new review. Touchstone never applies
hidden reviewer edits.

## Emergency Path

`TOUCHSTONE_NO_PREFLIGHT=1` bypasses deterministic preflight only. It does not
bypass PR review.

When orchestration wedges after a trusted clean exact-head review already
exists, use:

```bash
bash scripts/merge-pr.sh <pr-number> \
  --bypass-with-disclosure="<specific reason>"
```

The helper keeps the bypass revision-bound, comments on the PR, and records the
reason in the squash commit.
