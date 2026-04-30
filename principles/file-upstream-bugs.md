# Filing bugs in autumngarage tools

If you hit what looks like a bug in an autumngarage tool while working — actual unexpected behavior in the tool itself, not your project's misuse of it — file an issue upstream. Don't silently work around it; the same bug will bite the next user.

## The repos

- **touchstone** — `bin/touchstone`, the synced `scripts/`, `hooks/`, `principles/`, the bootstrap/update flow → https://github.com/autumngarage/touchstone/issues
- **conductor** — the `conductor` CLI, provider routing, `conductor exec` / `call` / `ask` / `review` → https://github.com/autumngarage/conductor/issues
- **cortex** — `.cortex/journal/`, `.cortex/doctrine/`, the Cortex Protocol → https://github.com/autumngarage/cortex/issues

## How

`gh issue create --repo autumngarage/<tool>` with this body shape:

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
<while shipping <what>, on YYYY-MM-DD>
```

Search before filing: `gh issue list --repo autumngarage/<tool> --search "<keywords>"`. If a matching issue exists, comment with your repro instead of opening a duplicate.

## When NOT to file

- The bug is in your project's *use* of the tool, not the tool itself.
- The bug is upstream of autumngarage (Anthropic / OpenAI / Google CLIs, `gh`, OS-level git, terminal emulators) — file with that vendor instead.
- It's a question, not a bug — open a discussion or ask in the project's chat surface rather than filing.

The point of this rule is that bugs in the autumngarage stack propagate to every project that uses it. Logging them upstream is how the ecosystem stays sharp; working around them silently is how the same bug bites the next person.
