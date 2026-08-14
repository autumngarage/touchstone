# Tracker Adapter Contract

This document owns Touchstone's version-1 claim and reconciliation boundary.
The configured tracker owns issue state; the adapter only parses references,
performs an available transport, and reports what it could verify.

## Declaration

Newly adopted projects declare the tracker once in `.touchstone.toml`:

```toml
[tracker]
schema = 1
type = "github"
```

`type` is `github` or `linear`. Linear declarations also require the team's
uppercase `key_prefix`, such as `AUT`. Contracts without `[tracker]` retain the
pre-declaration GitHub behavior for schema-1 compatibility; adoption and an
explicit upgrade add the declaration rather than rewriting it implicitly.

The validation engine ignores the known `[tracker]` table because the tracker
adapter owns it. Both readers still reject unsupported schemas and malformed
values instead of silently selecting a different tracker.

## Operations and outcomes

`scripts/touchstone-tracker.sh` exposes the boundary that the versioned CLI
sequences:

```text
claim ISSUE [--project DIR] [--json]
reconcile ISSUE --disposition fixed|partial|stale --body-file FILE
  [--note-file FILE] [--project DIR] [--json]
```

Human and JSON output use the same three outcomes:

- `verified` means the available authority was re-read after any mutation.
- `unverifiable` means the requested policy is known but no usable transport
  exists in this process. It is not success and exits 3.
- `failed` means the input, transport, mutation, or verification failed. A
  response records `partial: true` when an earlier mutation succeeded.

JSON is versioned as `touchstone.tracker/v1`. Input/config errors exit 2;
operational failures exit 1; verified work exits 0. Linear operations name the
exact API/MCP action and remain `unverifiable` from a shell process that has no
Linear transport. A driving agent may perform that action through its Linear
API/MCP and must use Linear's returned state—not the adapter's instruction—as
verification.

## Reference and reconciliation rules

GitHub issues use `#123`; Linear issues use the configured key, such as
`AUT-123`. Fixed work must appear in the PR body using the configured tracker's
closing grammar (`Closes #123` or `Fixes AUT-123`). The adapter rejects a
same-repository wrong-tracker close and prints the concrete replacement.

A qualified GitHub close such as `Closes owner/other#123` remains valid when it
targets another repository. It does not change the current project's tracker
or count as reconciliation of the local issue.

Partial work remains open and receives a note naming shipped evidence and the
remaining gap. Stale work receives an evidence note before closure. The
GitHub adapter reuses the surviving claim script and verifies close state;
authentication errors, unavailable transports, and partial mutations never
produce `verified`.

Claim and reconciliation are delivery discipline, not merge adjudication. The
future `touchstone pr` commands may sequence this adapter, but GitHub remains
the authority for PR checks, review evidence, conversation resolution, and the
merge result.
