# Tracker Adapter Contract

This document owns Touchstone's version-1 claim and reconciliation boundaries.
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

`scripts/touchstone-tracker.sh` exposes the effect boundary that the versioned
CLI sequences:

```text
claim ISSUE [--project DIR] [--json]
reconcile ISSUE --disposition fixed|partial|stale
  [--note-file FILE] [--project DIR] [--json]
```

Human and JSON output use the same three outcomes:

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

## Reference and reconciliation rules

GitHub issues use bare `123` or quoted `'#123'` at the shell; Linear issues use
the configured key, such as `AUT-123`. The adapter rejects an issue reference
that does not belong to the configured tracker and prints the concrete
replacement grammar. The GitHub
adapter reuses the surviving claim script and verifies assignment after its
mutation; authentication errors, unavailable transports, and partial
mutations never produce `verified`.

The adapter does not parse or decide GitHub closing-reference grammar. GitHub
owns that language and applies it at merge time. Fixed reconciliation observes
the issue after default-branch delivery and requires `CLOSED/COMPLETED`.
Partial reconciliation posts a substantive evidence note and verifies the
issue remains open. Stale reconciliation posts the note, closes the issue as
`not planned`, and verifies both state and reason. Unexpected state is exposed
with a concrete remedy rather than hidden behind a local guess about PR text.

Reconciliation is resumable across partial failures. GitHub notes carry a
deterministic marker derived from the issue, disposition, and note content; a
retry reuses the matching note. Before a stale close, and again afterward, the
adapter reads GitHub's authoritative state. A retry that finds the requested
`CLOSED/NOT_PLANNED` result succeeds without repeating the close. Provider
failures retain a bounded, control-character-sanitized diagnostic so recovery
does not discard the reason the operation failed.

Linear reconciliation names the exact API/MCP action because the shell adapter
has no Linear transport. The driving agent performs that action and verifies
the returned Linear state.

GitHub's documented `[skip-claim-check]` token bypasses only the GitHub
assignment guard for an exceptional PR. It does not bypass tracker selection,
reference parsing, claim verification, or reconciliation, and it has no implicit
Linear equivalent. A tracker-specific exception must remain visible in that
tracker and in the PR.

Claiming and reconciliation are delivery discipline, not merge adjudication. The future
`touchstone pr` commands may sequence this adapter, but GitHub remains
the authority for PR checks, review evidence, conversation resolution, and the
merge result.
