# Tracker Adapter Contract

This document owns Touchstone's version-1 claim boundary.
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

`scripts/touchstone-tracker.sh` exposes the claim boundary that the versioned
CLI sequences:

```text
claim ISSUE [--project DIR] [--json]
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

## Reference and claim rules

GitHub issues use bare `123` or quoted `'#123'` at the shell; Linear issues use
the configured key, such as `AUT-123`. The adapter rejects an issue reference
that does not belong to the configured tracker and prints the concrete
replacement grammar. The GitHub
adapter reuses the surviving claim script and verifies assignment after its
mutation; authentication errors, unavailable transports, and partial
mutations never produce `verified`.

Claiming and reconciliation are delivery discipline, not merge adjudication.
The claim adapter does not infer repository identity for tracker mutations;
drivers reconcile through the configured tracker's API or CLI. `touchstone pr`
sequences GitHub delivery only. GitHub remains the authority for PR checks,
review evidence, conversation resolution, and the merge result.
