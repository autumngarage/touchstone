# Tracker Adapter Contract

This document owns Touchstone's version-1 claim and body-validation boundary.
The configured tracker owns issue state; the adapter only parses references,
performs an available transport, and reports what it could verify.

## Declaration

Newly adopted projects declare the tracker once in `.touchstone-tracker.toml`:

```toml
schema = 1
type = "github"
```

`type` is `github` or `linear`. Linear declarations also require the team's
uppercase `key_prefix`, such as `AUT`. Projects without the tracker file retain
the pre-declaration GitHub behavior for compatibility; adoption creates the
declaration rather than rewriting it implicitly. The adapter independently
requires a valid schema-v1 `.touchstone.toml` before any mutation.

Tracker selection is a separate versioned boundary because it must not change
validation semantics or force a centrally pinned validator rollout. The tracker
reader rejects unsupported schemas and malformed values instead of silently
selecting another tracker.

## Operations and outcomes

`scripts/touchstone-tracker.sh` exposes the boundary that the versioned CLI
sequences:

```text
claim ISSUE [--project DIR] [--json]
validate ISSUE --disposition fixed|partial|stale --body-file FILE
  [--project DIR] [--json]
```

`validate` is a pure preflight: it checks reference and body grammar without
claiming that tracker state has changed. Human and JSON output use the same
three outcomes:

- `verified` means the available authority was re-read after any mutation.
- `unverifiable` means the requested policy is known but the authority cannot
  yet verify final state, or no usable transport exists in this process. It is
  not success and exits 3.
- `failed` means the input, transport, mutation, or verification failed. A
  response records `partial: true` when an earlier mutation succeeded.

JSON is versioned as `touchstone.tracker/v1`. Input/config errors exit 2;
operational failures exit 1; verified work exits 0. Linear operations name the
exact API/MCP action and remain `unverifiable` from a shell process that has no
Linear transport. A driving agent may perform that action through its Linear
API/MCP and must use Linear's returned state—not the adapter's instruction—as
verification.

## Reference and validation rules

GitHub issues use bare `123` or quoted `'#123'` at the shell; Linear issues use
the configured key, such as `AUT-123`. Fixed work must appear in the PR body
using the configured tracker's closing grammar (`Closes #123` or
`Fixes AUT-123`). The adapter rejects a
same-repository wrong-tracker close and prints the concrete replacement.
The body reference is valid preflight input, not evidence that the issue state
changed. State mutation and post-delivery reconciliation are a separate effect
boundary.

A qualified GitHub close such as `Closes owner/other#123` remains valid when it
targets another repository. It does not change the current project's tracker
or count as reconciliation of the local issue.

Partial and stale work use a non-closing `Refs ISSUE` body reference. The
validator rejects a same-repository closer for that issue while preserving
unrelated and cross-repository closes.

GitHub's documented `[skip-claim-check]` token bypasses only the GitHub
assignment guard for an exceptional PR. It does not bypass tracker selection,
reference parsing or closing grammar, and it has no implicit
Linear equivalent. A tracker-specific exception must remain visible in that
tracker and in the PR.

Claim and validation are delivery discipline, not merge adjudication. The
future `touchstone pr` commands may sequence this adapter, but GitHub remains
the authority for PR checks, review evidence, conversation resolution, and the
merge result.
