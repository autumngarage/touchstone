## Intent
<!-- The exact user-visible or system behavior this change creates or fixes. -->

## Invariants
<!-- Conditions that must remain true. Required for normal and serious tiers. -->

## Risk areas
<!-- Only real risks introduced by this change, and the blast radius. -->

## Validation
<!-- Record what actually ran; a check that does not apply is `n/a — <reason>`. Never claim a build, test, or manual validation happened unless it did — a generated body states only what its generator observed or what GitHub's own check witnessed. -->
- Build:
- Automated tests:
- Manual validation:
- Local review:
- Review budget:
<!-- The tier's one local pass, recorded as it ran: normal → `touchstone review check`, then `touchstone review run` on the isolated staged slice before commit; serious → capture `git rev-parse HEAD`, then run `touchstone review run --base origin/<default>` on that committed branch before push; It runs Codex and falls back to the bounded OpenRouter pass over the same branch on any Codex non-success, including an exhausted quota. Begin normal with `openrouter on the staged slice (review-normal): <n> findings, <disposition>`; begin serious with `<reviewer> on <captured-head-sha>: <n> findings, <disposition>` for whichever reviewer it reported. The serious SHA is the current head the pass reviewed; `<default>` is only the comparison boundary. Normal may waive for a failed configured check/pass; serious may waive only when Codex and the fallback are both unavailable. A size-limit refusal is a slicing error, not a waiver: re-slice and run. -->
<!-- The budget ledger: `v2 capability=<tracker ref> local_rounds=<n> fix_rounds=<n> prior_fix_rounds=<n> reviewed_head=<sha|none> cascade=<true|false> exit=<continue|merge-answered|revert-simplify|split|close-replan>`. A fix round is one push of review-driven change; an attest request and a provider retry are not rounds. The budget is three per capability and follows it across replacement PRs, so carry the count into `prior_fix_rounds` when replacing one — closing or renaming never resets it. Past three, `exit=continue` is not available: pick merge-answered, revert-simplify, split, or close-replan. Rules in principles/local-review.md. -->

## Out of scope
<!-- Intentionally excluded related work, and where it is tracked. -->

## Review tier
<!-- trivial | normal | serious — rules in principles/local-review.md -->

## Why this tier
<!-- One or two concrete sentences from the tier rules. -->
