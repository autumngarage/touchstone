# Filing bugs as tracked work

When you find a bug, file it in the project's configured tracker. Don't
silently work around it. For bugs here and in upstream tools, the discipline is
the same: write down what's broken so the next person does not rediscover it.

The cost of filing an issue is two minutes. The cost of the next person rediscovering the same bug is hours.

## Bugs in this project

If you find a bug in the project you're working on, file a tracker item against
that project—even one you cannot fix now or are about to fix in the same
session. The tracker item is the durable record; the fix commit is evidence.

When to file:

- **Discovered during unrelated work, not fixing now** → file an item. Link it from the current PR when relevant.
- **Fixing now** → claim the item first, then put its configured close (`Closes #123` or `Fixes AUT-123`) in the **PR body**.
- **Suspect but unsure** → file it as "needs repro" rather than leaving it in chat.

Use the configured tracker API or CLI. For a GitHub-backed project,
`gh issue create` defaults to the current repository. Body shape:

```
## Symptom
<what happened, with the exact error / output verbatim>

## Repro
<minimal sequence to trigger it>

## Why this matters
<one paragraph on impact / who or what it blocks>

## Suggested fixes
<cheapest first; optional but appreciated>

## Discovered
<while doing <what>, on YYYY-MM-DD>
```

Search the configured tracker first. If a matching item exists, add the repro
there instead of opening a duplicate.

## Bugs in autumngarage tools

If an autumngarage tool itself misbehaves, file the bug **in that tool's
configured upstream tracker**, not against the consumer project.

This also applies to **workflow friction** caused by the tools, even when it is not a hard crash: excessive token use, poor parallelization, unclear delegation ergonomics, brittle review/merge behavior, or other agent-delivery inefficiency. If the pain repeats, it is an upstream product issue.

Inspect the upstream project's tracker declaration or contributor guidance. If
it is GitHub-backed, use `gh issue create --repo autumngarage/<tool>` and
search that repository first. If it is Linear-backed, use the configured team
key and Linear API or MCP, then verify the returned item.

## When NOT to file

- The bug is in your project's *use* of the tool, not the tool itself → the issue belongs against your project, not the tool.
- The bug is upstream of autumngarage (Anthropic / OpenAI / Google CLIs, `gh`, OS-level git, terminal emulators) → file with that vendor instead.
- It's a question, not a bug → open a discussion or ask in the project's chat surface rather than filing.

The point of this rule is that bugs you don't write down propagate silently. Logging them — wherever they live — is how the work compounds instead of churning.
