# Filing bugs as issues

When you find a bug, file an issue. Don't silently work around it. Two cases — bugs in the project you're working on, and bugs in the autumngarage tools you depend on — and the discipline is the same in both: write down what's broken so the next person doesn't trip over it.

**The two cases can land in different trackers, and that is not a detail to smooth over.** A project's own bugs go to *that project's* tracker, which is whatever `[issues].tracker` declares in its `.touchstone-review.toml` — GitHub unless it says otherwise. Bugs in the autumngarage tools always go to those tools' GitHub repositories, because that is where those repositories live, no matter which tracker the project you are standing in uses. Filing a Linear-tracked project's bug on GitHub records it where nobody will look; filing a touchstone bug in your project's Linear workspace never reaches the people who maintain touchstone.

The cost of filing an issue is two minutes. The cost of the next person rediscovering the same bug is hours.

## Bugs in this project

If you find a bug in the project you're working on, file an issue against that project — even one you can't fix right now, even one you're about to fix in the same session. The issue is the durable record; the fix commit is the resolution. A bug that lives only in conversation gets rediscovered.

When to file:

- **Discovered while doing unrelated work, not fixing now** → file an issue. Note it in the current PR description if relevant ("noticed in passing — see the issue").
- **Fixing in the current session** → file the issue first, then close it from the PR with a closing reference in your tracker's syntax. See `principles/git-workflow.md` for the per-tracker table: under GitHub that is a `Closes-issue: #<n>` commit trailer, which `scripts/open-pr.sh` turns into a `Closes #<n>` line in the PR body; under any other tracker Touchstone injects nothing and you write the reference into the PR **body** yourself (`Fixes CON-123`), keeping GitHub's `#N` closing syntax out of your commit messages entirely.
- **Suspect a bug but unsure** → file it as a question / "needs repro" issue rather than letting it sit in chat. Re-discovery later is more expensive than a wrong-flagged issue you close.
- **Hard-won lesson worth capturing** → if the bug taught a generalizable lesson, file the issue and link it from `CLAUDE.md`'s "Hard-Won Lessons" section.

File it in the project's declared tracker. Under **GitHub** that is `gh issue create` (no `--repo` flag — it defaults to the current project's repo). Under any **other** tracker, create it in that tracker; Touchstone has no transport for it and will not create it for you. Body shape, in either:

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

Search before filing — under GitHub, `gh issue list --search "<keywords>"`; under another tracker, that tracker's own search. If a matching issue exists, comment with your repro instead of opening a duplicate.

## Bugs in autumngarage tools

If you hit what looks like a bug in an autumngarage tool — actual unexpected behavior in the tool itself, not your project's misuse of it — file the issue **upstream against the tool's repo**, not against your project. The same bug will bite the next user; logging it in the tool's repo is how the ecosystem stays sharp.

This also applies to **workflow friction** caused by the tools, even when it is not a hard crash: excessive token use, poor parallelization, unclear delegation ergonomics, brittle review/merge behavior, or other agent-delivery inefficiency. If the pain repeats, it is an upstream product issue.

The repos:

- **touchstone** — `bin/touchstone`, the synced `scripts/`, `hooks/`, `principles/`, the bootstrap/update flow → https://github.com/autumngarage/touchstone/issues
- **cortex** — `.cortex/journal/`, `.cortex/doctrine/`, the Cortex Protocol → https://github.com/autumngarage/cortex/issues

These repositories are GitHub-hosted, so these commands are GitHub commands **whatever tracker your own project declares** — a Linear-tracked project still files touchstone bugs here, with `gh`:

`gh issue create --repo autumngarage/<tool>` with the same body shape as above. Search first: `gh issue list --repo autumngarage/<tool> --search "<keywords>"`. If a matching issue exists, comment with your repro instead of opening a duplicate.

The `--repo` flag is doing the work: it aims the issue at the tool, not at whatever repository you happen to be standing in. Reference such an issue the same fully-qualified way — `Fixes autumngarage/touchstone#12`, never a bare `Fixes #12`. The qualified form names another repository, so it closes nothing here and the wrong-tracker guards let it through; the bare form reads as a closing reference against *this* repository, which under a non-GitHub tracker `scripts/open-pr.sh` and `scripts/issue-claim-check.sh` refuse outright.

## When NOT to file

- The bug is in your project's *use* of the tool, not the tool itself → the issue belongs against your project, not the tool.
- The bug is upstream of autumngarage (Anthropic / OpenAI / Google CLIs, `gh`, OS-level git, terminal emulators) → file with that vendor instead.
- It's a question, not a bug → open a discussion or ask in the project's chat surface rather than filing.

The point of this rule is that bugs you don't write down propagate silently. Logging them — wherever they live — is how the work compounds instead of churning.
